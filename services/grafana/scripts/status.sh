#!/usr/bin/env bash
# grafana 状态：健康 + 数据源 + 面板。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
ip="$(ip_of grafana)"

printf 'grafana: '
curl -sf -o /dev/null -w 'health %{http_code}\n' "http://${ip}:3000/api/health" || echo "down"
curl -sf -u "admin:${GRAFANA_ADMIN_PASSWORD}" "http://${ip}:3000/api/datasources" |
    python3 -c 'import json,sys; print("datasources:", [d["name"] for d in json.load(sys.stdin)])' || true
curl -sf -u "admin:${GRAFANA_ADMIN_PASSWORD}" "http://${ip}:3000/api/search?query=DevOps" |
    python3 -c 'import json,sys; print("dashboards:", [d.get("title") for d in json.load(sys.stdin)])' || true
