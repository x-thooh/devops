#!/usr/bin/env bash
# prometheus 状态：ready + up/down 目标计数。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
for row in $(rows_of prometheus); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    [[ "${MODE}" == "solo" && "${name}" != "prometheus-1" ]] && continue
    printf '%s: ' "${name}"
    curl -sf -o /dev/null -w 'ready %{http_code}\n' "http://${ip}:9090/-/ready" || echo "down"
    curl -sG --data-urlencode 'query=count(up == 1)' "http://${ip}:9090/api/v1/query" || true
    echo
    curl -sG --data-urlencode 'query=count(up == 0)' "http://${ip}:9090/api/v1/query" || true
    echo
done
