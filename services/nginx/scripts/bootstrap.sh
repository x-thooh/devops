#!/usr/bin/env bash
# 幂等引导：把新渲染的 .data/conf.d 载入运行中的 nginx。
# stack.sh up 只在 mode 变化时重建容器；平时 up 不会重启节点，而 nginx 只在启动 / reload
# 时才读 conf.d —— 所以改完 [routes] 光跑 make render / stack-up 会继续用旧路由。
# 签名与其它栈一致：<profile> <mode>；容器没起则跳过（首次 up 时配置本来就是新的）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${STACK_DIR}/../../scripts/lib.sh"
cd "${DEVOPS_ROOT}"

profile="${1:-nginx}"
mode="${2:-$(deployed_mode "${profile}" solo)}"

COMPOSE=(docker compose --env-file "${DEVOPS_ROOT}/env/.env"
    -f "${DEVOPS_ROOT}/compose.generated.yml" --profile "${profile}")

running="$("${COMPOSE[@]}" ps --status running --services 2>/dev/null || true)"

reload_node() {
    local node="$1" attempt
    for attempt in $(seq 1 30); do
        # -t 先验语法：配置坏掉时 nginx 会保留旧 worker，必须让 stack-up 失败而不是静默沿用旧路由。
        # </dev/null 不可省：compose exec 会读 stdin，不挡住就把 while read 的剩余节点吃掉（ha 只 reload 第一个节点）。
        if "${COMPOSE[@]}" exec -T "${node}" nginx -t </dev/null >/dev/null 2>&1 &&
            "${COMPOSE[@]}" exec -T "${node}" nginx -s reload </dev/null >/dev/null 2>&1; then
            echo "nginx: ${node} reloaded (attempt ${attempt})"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: ${node} reload 失败（nginx -t 未通过或 master 未就绪）" >&2
    "${COMPOSE[@]}" exec -T "${node}" nginx -t </dev/null || true
    return 1
}

nodes=0
while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    if ! grep -qx -- "${node}" <<<"${running}"; then
        echo "nginx: ${node} 未运行（profile=${profile} mode=${mode}），跳过 reload"
        continue
    fi
    reload_node "${node}"
    nodes=$((nodes + 1))
done < <(ini services "${profile}" "${mode}")

# reload 只发信号，再用入口 /healthz 确认 master 与 worker 都还活着（宿主端口随 HTTP_PORT）
# 判据用 nodes 而不是写死节点名：入口只有单实例，改名（nginx-1 → nginx）不该让健康探测静默跳过
port="$(awk -F= '$1 == "HTTP_PORT" {print $2}' "${DEVOPS_ROOT}/env/.env" 2>/dev/null | tail -1 || true)"
port="${port:-80}"
if [[ "${nodes}" -gt 0 ]]; then
    for _ in $(seq 1 30); do
        curl -fsS -o /dev/null "http://127.0.0.1:${port}/healthz" && break
        sleep 1
    done
    curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null
fi

echo "nginx: ${nodes} node(s) reloaded; routes=$(ini routes | sed -n '$=')"
