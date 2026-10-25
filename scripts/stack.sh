#!/usr/bin/env bash
# 单栈操作：up / stop / rm / status / reset / shell / logs
# 用法：scripts/stack.sh <action> <profile> [solo|ha] [node]（MODE 缺省按当前部署形态）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"              # 取 deployed_mode()：形态单一事实源（marker）

if [[ ! -f "${ROOT}/env/.env" ]]; then
    bash "${SCRIPT_DIR}/gen-secrets.sh"
fi

COMPOSE=(docker compose --env-file "${ROOT}/env/.env" -f "${ROOT}/compose.generated.yml")

usage() {
    cat <<'EOF'
usage: scripts/stack.sh <action> <profile> [solo|ha] [node]

  up       render + 起容器 + bootstrap + 等健康（按 ini 的 mode 选择 service）
  stop     docker compose stop（演练用，不触发 restart）
  rm       docker compose rm -sf（只删本 profile 的容器）
  status   容器状态 + 栈自带 status.sh
  reset    停容器 → 删本 profile 的 data 子树 → 重新 render → 重启
  shell    exec 进节点（默认第一个 service）
  logs     docker compose logs -f

profile 是部署单元名：nginx / pg / redis-sentinel / redis-cluster / ...
MODE 缺省不写死 solo：读当前部署形态 marker，从没部署过才回退 solo。
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

action="${1:-}"
profile="${2:-}"
mode="${3:-}"
node="${4:-}"

if [[ -z "${action}" || -z "${profile}" ]]; then
    usage
    exit 2
fi

dir="$(python3 scripts/ini.py dir "${profile}")"
stack_dir="${ROOT}/services/${dir}"
if [[ ! -f "${stack_dir}/compose.yml" ]]; then
    die "profile ${profile} 尚未实现（缺少 services/${dir}/compose.yml）"
fi

# MODE 缺省不写死 solo：用 solo 视图去查/起一个 ha 部署，会得到"看着对但错"的结果
#（实测：ha 部署上跑 mysql 的 solo 分支，打的是 @@server_id 而不是 MGR 成员表）。
# 与 DEC-47/48 同源：读 .mode-<profile> marker；从没部署过的栈才回退 solo
#（plan §8.0：新栈先证"能跑"，再证"集群成立"）。
if [[ -z "${mode}" ]]; then
    mode="$(deployed_mode "${profile}" solo)"
    echo "# MODE 未指定 -> ${mode}（来自 services/${dir}/data/.mode-${profile}）"
fi

case "${mode}" in
    solo|ha) ;;
    *) die "MODE 必须是 solo 或 ha（收到 ${mode}）" ;;
esac

services=()
while IFS= read -r name; do
    [[ -n "${name}" ]] && services+=("${name}")
done < <(python3 scripts/ini.py services "${profile}" "${mode}" 2>/dev/null || true)
if [[ ${#services[@]} -eq 0 ]]; then
    die "profile ${profile} 在 MODE=${mode} 下没有 service"
fi

# 本 profile 的全部节点（solo + ha），用于 down / reset / mode 切换
all_services=()
while IFS= read -r name; do
    [[ -n "${name}" ]] && all_services+=("${name}")
done < <(python3 scripts/ini.py services "${profile}" ha 2>/dev/null || true)

mode_marker_path() {
    echo "${stack_dir}/data/.mode-${profile}"
}

# 形态 marker 必须先写：render-all.sh 按 marker 决定每个栈的渲染形态
write_marker() {
    local marker
    marker="$(mode_marker_path)"
    mkdir -p "$(dirname "${marker}")"
    printf '%s\n' "${mode}" >"${marker}"
}

render() {
    python3 scripts/render-all.py
    if [[ -x "${stack_dir}/scripts/render.sh" ]]; then
        # 栈配置按 mode 渲染：同一路径在 up 前覆盖为当前形态（两形态互斥）
        "${stack_dir}/scripts/render.sh" "${mode}"
    fi
}

# 可选启动前钩子：依赖他栈（如 nacos → mysql 的 schema）时用
pre() {
    if [[ -x "${stack_dir}/scripts/pre.sh" ]]; then
        "${stack_dir}/scripts/pre.sh" "${profile}" "${mode}"
    fi
}

# 可选启动后钩子：集群组建 / 建用户建 topic / 建库表
bootstrap() {
    if [[ -x "${stack_dir}/scripts/bootstrap.sh" ]]; then
        "${stack_dir}/scripts/bootstrap.sh" "${profile}" "${mode}"
    fi
}

data_root() {
    if [[ "${dir}" == "redis" ]]; then
        echo "${ROOT}/services/redis/data/${profile#redis-}"
    else
        echo "${ROOT}/services/${dir}/data"
    fi
}

compose() {
    "${COMPOSE[@]}" --profile "${profile}" "$@"
}

contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

# solo ↔ ha 互斥：停掉不属于当前 mode 的节点（stop，不删数据）
sync_mode() {
    local name
    for name in "${all_services[@]}"; do
        if ! contains "${name}" "${services[@]}"; then
            echo "stop ${name} (not in MODE=${mode})"
            compose stop "${name}" >/dev/null 2>&1 || true
        fi
    done
}

case "${action}" in
    up)
        # 形态切换必须重建容器：挂载的渲染配置只在启动时读取
        mode_marker="$(mode_marker_path)"
        recreate=()
        if [[ -f "${mode_marker}" && "$(cat "${mode_marker}")" != "${mode}" ]]; then
            echo "mode changed ($(cat "${mode_marker}") -> ${mode}); recreating"
            recreate=(--force-recreate)
        fi
        write_marker
        render
        pre
        sync_mode
        echo "starting ${profile} (${mode}): ${services[*]}"
        # 两段式：先起容器（不等健康）-> bootstrap -> 再等健康。
        # 单段 --wait 会把「要 bootstrap 才转健康」的栈锁死：mysql 实测 down 后三个节点
        # 的 MGR 全是 OFFLINE，而 Router 只有 metadata cache 里看到 ONLINE primary 才监听
        # 6446 -> --wait 超时失败 -> bootstrap 永远轮不到（DEC-52）。
        # bootstrap 自己带就绪轮询（各栈 20-60 次），所以第一段不等健康是安全的。
        compose up -d ${recreate[@]+"${recreate[@]}"} "${services[@]}"
        bootstrap
        compose up -d --wait --wait-timeout 180 "${services[@]}"
        compose ps "${services[@]}"
        ;;
    stop)
        compose stop "${all_services[@]}"
        ;;
    rm)
        compose rm -sf "${all_services[@]}"
        ;;
    status)
        compose ps --all "${all_services[@]}"
        if [[ -x "${stack_dir}/scripts/status.sh" ]]; then
            "${stack_dir}/scripts/status.sh" "${profile}" "${mode}"
        fi
        ;;
    reset)
        echo "resetting ${profile} (${mode})"
        compose rm -sf "${all_services[@]}" >/dev/null 2>&1 || true
        if [[ -x "${stack_dir}/scripts/reset.sh" ]]; then
            "${stack_dir}/scripts/reset.sh" "${mode}"
        else
            data="$(data_root)"
            case "${data}" in
                "${ROOT}/services/"*/data*) ;;
                *) die "拒绝删除可疑路径：${data}" ;;
            esac
            echo "clearing data=${data#"${ROOT}/"}"
            mkdir -p "${data}"
            find "${data}" -mindepth 1 -maxdepth 1 ! -name .gitkeep -exec rm -rf {} +
        fi
        write_marker
        render
        pre
        compose up -d "${services[@]}"
        bootstrap
        compose up -d --wait --wait-timeout 180 "${services[@]}"
        ;;
    shell)
        target="${node:-${services[0]}}"
        compose exec "${target}" sh
        ;;
    logs)
        compose logs -f --tail=100 "${services[@]}"
        ;;
    *)
        usage
        exit 2
        ;;
esac
