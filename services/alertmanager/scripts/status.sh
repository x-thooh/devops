#!/usr/bin/env bash
# alertmanager 状态：ready + 当前告警数。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ip="$(ip_of alertmanager)"
printf 'alertmanager: '
curl -sf -o /dev/null -w 'ready %{http_code}\n' "http://${ip}:9093/-/ready" || echo "down"
curl -s "http://${ip}:9093/api/v2/alerts" || true
echo
