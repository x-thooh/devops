#!/usr/bin/env bash
# hindsight 状态：后端 pg 目标（从 .data/active/hindsight.env 解出 host:port，密码不出镜）
#                + API /health + Control Plane UI + 经 nginx 的两条路由（只报状态码，不改退出码）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ip="$(ip_of hindsight)"

env_file="${STACK_DIR}/.data/active/hindsight.env"
if [[ -f "${env_file}" ]]; then
    # 从 postgresql://user:pass@host:port/db 抽出 host:port（密码不回显）
    target="$(sed -nE 's#.*@([^/]+).*#\1#p' "${env_file}" | head -n1)"
    printf 'backend pg: %s\n' "${target:-unknown}"
else
    printf 'backend pg: (未渲染 env)\n'
fi

printf 'hindsight api(8888/health): '
curl -sf -o /dev/null -w '%{http_code}\n' "http://${ip}:8888/health" || { echo "down"; exit 0; }
printf 'hindsight cp(9999): '
curl -s -o /dev/null -w '%{http_code}\n' "http://${ip}:9999/" || true
# 入口链路：只在上游存活时才断言 200；nginx 未起时跳过而不是失败（口径同其它 UI 栈）
if curl -sf -o /dev/null http://127.0.0.1/healthz; then
    printf 'route hindsight.localhost: '
    curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: hindsight.localhost' http://127.0.0.1/ || true
    printf 'route hindsight-api.localhost: '
    curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: hindsight-api.localhost' http://127.0.0.1/health || true
fi
