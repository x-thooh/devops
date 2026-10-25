#!/usr/bin/env bash
# 各栈 render/status 共用的小工具：只读 stock/network.ini，不写生成物。
# 用法：在 services/<stack>/scripts/*.sh 里 source 之后调用 ip_of / rows_of 等。
set -euo pipefail

DEVOPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 仓库内 venv 优先：让不走 make 的直接调用（./scripts/xxx.sh）也命中同一个解释器，
# 不依赖宿主 PATH 顺序（mise.toml 定版本 + make setup 装依赖，DEC-51）。
# 实测过的坑：交互式 zsh 与 `bash -lc` / cron / IDE Run Config 解析到的 python3 不是同一个。
if [[ -x "${DEVOPS_ROOT}/.venv/bin/python3" ]]; then
    PATH="${DEVOPS_ROOT}/.venv/bin:${PATH}"
    export PATH
fi

ini() { python3 "${DEVOPS_ROOT}/scripts/ini.py" "$@"; }

ip_of() { ini ip "$1"; }

# 同一 IP 的第一个端口（多数健康检查/单端口客户端够用）
port_of() { ini ports "$1" | cut -d, -f1 | cut -d- -f1; }

# 输出 profile 的行：name|ip|ports|role|mode
rows_of() {
    ini rows | awk -F'|' -v p="$1" '$1 == p { print $2 "|" $3 "|" $4 "|" $5 "|" $6 }'
}

# 该 profile 在指定形态下应启动的 service（空格分隔）
services_of() { ini services "$1" "${2:-solo}" | tr '\n' ' '; }

# 该节点在 ini 里的 mode（both/solo/ha）
mode_of() {
    ini rows | awk -F'|' -v n="$1" '$2 == n { print $6 }'
}

# 该 profile 当前的部署形态：读 stack.sh 写的 services/<dir>/data/.mode-<profile>。
# 没有 marker = 从没起过，回退第 2 参数（缺省 ha，保住 DEC-23「新增栈自动纳入监控」）。
deployed_mode() {
    local profile="${1:?profile}" fallback="${2:-ha}" marker
    marker="$(find "${DEVOPS_ROOT}/services" -maxdepth 3 -name ".mode-${profile}" -print 2>/dev/null | head -1)"
    if [[ -n "${marker}" ]]; then
        tr -d '[:space:]' <"${marker}"
    else
        echo "${fallback}"
    fi
}

# 生成物目录：配置/启动脚本都落这里，容器挂载 /data 后按同一相对路径读取
active_dir() { echo "${STACK_DIR}/data/active"; }

# 幂等创建目录并给容器用户可写（macOS bind mount 忽略 uid，这里只保证目录存在）
ensure_dir() { mkdir -p "$1"; }

# 稳定的集群/密钥文件：不存在才生成，避免每次 render 改身份
ensure_secret() {
    local path="$1"
    shift
    if [[ ! -s "${path}" ]]; then
        mkdir -p "$(dirname "${path}")"
        "$@" >"${path}"
        chmod 600 "${path}"
    fi
}
