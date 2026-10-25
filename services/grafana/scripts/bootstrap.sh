#!/usr/bin/env bash
# 幂等引导：等 /api/health 为 ok，并确认 provisioned 数据源数量。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
ip="$(ip_of grafana)"

for _ in $(seq 1 30); do
    curl -sf -o /dev/null "http://${ip}:3000/api/health" && break
    sleep 2
done
curl -sf "http://${ip}:3000/api/health"
echo
curl -sf -u "admin:${GRAFANA_ADMIN_PASSWORD}" "http://${ip}:3000/api/datasources" |
    python3 -c 'import json,sys; print("datasources:", [d["name"] for d in json.load(sys.stdin)])'
