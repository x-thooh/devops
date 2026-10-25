#!/usr/bin/env bash
# 渲染入口：ini → 聚合 compose + 各已实现栈的真实配置。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"      # 取 .venv 优先的 PATH（DEC-51）

python3 scripts/render-all.py

mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

for compose in services/*/compose.yml; do
    [[ -e "${compose}" ]] || continue
    dir="$(dirname "${compose}")"
    if [[ -x "${dir}/scripts/render.sh" ]]; then
        # 按当前形态渲染：marker 由 stack.sh 在起栈时写，没有 marker 视为 solo。
        # 同一目录多 profile（redis）取最近一次起栈的形态。
        mode=""
        newest=0
        for marker in "${dir}"/.data/.mode-*; do
            [[ -f "${marker}" ]] || continue
            ts="$(mtime "${marker}")"
            if [[ "${ts}" -gt "${newest}" ]]; then
                newest="${ts}"
                mode="$(cat "${marker}")"
            fi
        done
        "${dir}/scripts/render.sh" "${mode:-solo}"
    fi
done
