#!/usr/bin/env bash
# nginx 栈状态：容器状态 + 入口健康 + 一条路由探测 + 直连 nginx-2。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${STACK_DIR}/../.." && pwd)"
cd "${ROOT}"

PORT="$(awk -F= '$1 == "ENTRY_HTTP_PORT" {print $2}' env/.env 2>/dev/null | tail -1 || true)"
PORT="${PORT:-80}"

echo "== edge health (127.0.0.1:${PORT}) =="
curl -fsS "http://127.0.0.1:${PORT}/healthz" || echo "FAIL: edge health endpoint unreachable"

echo "== route grafana.localhost =="
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: grafana.localhost' "http://127.0.0.1:${PORT}/" || true)"
echo "HTTP ${code:-000} (502 until grafana is up; 200 means upstream reachable)"

echo "== nginx-2 direct (172.28.0.12) =="
code2="$(curl -s -o /dev/null -w '%{http_code}' "http://172.28.0.12/healthz" || true)"
echo "HTTP ${code2:-000} (000 means nginx-2 not running / mode=solo)"

if docker compose --env-file env/.env -f compose.generated.yml --profile nginx ps --status running --services 2>/dev/null | grep -qx 'nginx-1'; then
    echo "== nginx -t =="
    docker compose --env-file env/.env -f compose.generated.yml --profile nginx exec -T nginx-1 nginx -t
fi
