#!/usr/bin/env bash
# 渲染 grafana：数据源 URL 由 ini 注入（Prometheus / Jaeger），面板走 provisioning。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

STACK_NAME="grafana"
ACTIVE="${STACK_DIR}/data/active"
PROV="${ACTIVE}/${STACK_NAME}/provisioning"
# 容器内视角：compose 只把 ./data 挂到 /data，所以写进 provisioning 的 path
# 必须是 /data/... 而不是宿主的 ${ACTIVE}（后者在容器里不存在，面板会全部不加载）
CTR_DATA="/data"
CTR_DASHBOARDS="${CTR_DATA}/active/${STACK_NAME}/dashboards"
ensure_dir "${PROV}/datasources"
ensure_dir "${PROV}/dashboards"
ensure_dir "${ACTIVE}/${STACK_NAME}/dashboards"
ensure_dir "${STACK_DIR}/data/${STACK_NAME}"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
PASS="${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD missing in env/.env}"

prom="http://$(ip_of prometheus-1):9090"
jaeger="http://$(ip_of jaeger):16686"

cat >"${PROV}/datasources/datasources.yml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    uid: devops-prom
    type: prometheus
    access: proxy
    url: ${prom}
    isDefault: true
  - name: Jaeger
    uid: devops-jaeger
    type: jaeger
    access: proxy
    url: ${jaeger}
EOF

cat >"${PROV}/dashboards/dashboards.yml" <<EOF
apiVersion: 1
providers:
  - name: devops
    folder: DevOps
    type: file
    disableDeletion: false
    options:
      path: ${CTR_DASHBOARDS}
EOF

cat >"${ACTIVE}/${STACK_NAME}/dashboards/overview.json" <<EOF
{
  "uid": "devops-overview",
  "title": "DevOps 总览",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "time": {"from": "now-1h", "to": "now"},
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "up 目标数",
      "gridPos": {"h": 6, "w": 8, "x": 0, "y": 0},
      "datasource": {"type": "prometheus", "uid": "devops-prom"},
      "targets": [{"refId": "A", "expr": "sum(up)"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "id": 2,
      "type": "stat",
      "title": "down 目标数",
      "gridPos": {"h": 6, "w": 8, "x": 8, "y": 0},
      "datasource": {"type": "prometheus", "uid": "devops-prom"},
      "targets": [{"refId": "A", "expr": "count(up == 0)"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    }
  ]
}
EOF

cat >"${ACTIVE}/${STACK_NAME}.env" <<EOF
GF_SERVER_ROOT_URL=http://grafana.localhost/
GF_SERVER_HTTP_PORT=3000
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=${PASS}
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_USERS_ALLOW_SIGN_UP=false
GF_PATHS_DATA=${CTR_DATA}/${STACK_NAME}
GF_PATHS_PROVISIONING=/etc/grafana/provisioning
EOF
chmod 600 "${ACTIVE}/${STACK_NAME}.env"

echo "rendered grafana (prom=${prom}, jaeger=${jaeger}, dashboards=${CTR_DASHBOARDS})"
