#!/usr/bin/env bash
# jaeger 状态：服务列表（trace 覆盖的 service）+ 健康端点。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ip="$(ip_of jaeger)"
printf 'jaeger health: '
curl -sf -o /dev/null -w '%{http_code}\n' "http://${ip}:13133/status" || echo "down"
printf 'jaeger services: '
curl -sf "http://${ip}:16686/api/services" || echo "down"
echo
