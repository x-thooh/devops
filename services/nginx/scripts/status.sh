#!/usr/bin/env bash
# nginx 栈状态：容器状态 + 入口健康 + 一条 [routes] 探测 + nginx -t（单实例，无 ha 分支，DEC-53）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${STACK_DIR}/../../scripts/lib.sh"
cd "${DEVOPS_ROOT}"

profile="${1:-nginx}"

PORT="$(awk -F= '$1 == "ENTRY_HTTP_PORT" {print $2}' env/.env 2>/dev/null | tail -1 || true)"
PORT="${PORT:-80}"

echo "== edge health (127.0.0.1:${PORT}) =="
curl -fsS "http://127.0.0.1:${PORT}/healthz" || echo "FAIL: edge health endpoint unreachable"

# 路由与节点地址一律取自 ini：脚本里写死 host / IP 会和 [routes] 漂移（DEC-22）
route="$(ini routes | sed -n '1p')"
host="${route%%|*}"
upstream_ip="${route#*|}"
upstream_ip="${upstream_ip%%|*}"
if [[ -n "${host}" ]]; then
    echo "== route ${host} -> ${upstream_ip} =="
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://127.0.0.1:${PORT}/" || true)"
    echo "HTTP ${code:-000} (502 = 路由已通但上游未起；200 = 上游可达)"
else
    echo "== route: ini [routes] 为空，跳过 =="
fi

COMPOSE=(docker compose --env-file env/.env -f compose.generated.yml --profile "${profile}")
# 节点名取自 ini（入口单实例，不带序号）：写死会和改名 / 换入口产品一起漂移
node="$(ini services "${profile}" solo | sed -n '1p')"
if [[ -n "${node}" ]] && "${COMPOSE[@]}" ps --status running --services 2>/dev/null | grep -qx "${node}"; then
    echo "== nginx -t =="
    "${COMPOSE[@]}" exec -T "${node}" nginx -t
fi
