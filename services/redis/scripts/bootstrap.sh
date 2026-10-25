#!/usr/bin/env bash
# 幂等引导：sentinel 无需操作；cluster 首次运行时创建 3M3R 并等待 slot 覆盖。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

PROFILE="${1:-redis-sentinel}"
MODE="${2:-solo}"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
PASS="${REDIS_PASSWORD:?REDIS_PASSWORD missing in env/.env}"

if [[ "${PROFILE}" == "redis-sentinel" ]]; then
    docker exec sentinel-1 redis-cli -p 26379 sentinel get-master-addr-by-name devmaster 2>/dev/null || true
    exit 0
fi

[[ "${MODE}" == "solo" ]] && exit 0

state="$(docker exec rc-1 redis-cli --no-auth-warning -a "${PASS}" cluster info | awk -F: '/cluster_state/{print $2}' | tr -d '\r')"
if [[ "${state}" == "ok" ]]; then
    echo "redis-cluster already formed"
    exit 0
fi

nodes=""
for row in $(rows_of redis-cluster); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "exporter" ]] && continue
    nodes+="${nodes:+ }${ip}:6379"
done

echo "creating redis-cluster: ${nodes}"
# shellcheck disable=SC2086
docker exec rc-1 redis-cli --no-auth-warning -a "${PASS}" --cluster create ${nodes} \
    --cluster-replicas 1 --cluster-yes >/dev/null

for _ in $(seq 1 30); do
    state="$(docker exec rc-1 redis-cli --no-auth-warning -a "${PASS}" cluster info | awk -F: '/cluster_state/{print $2}' | tr -d '\r')"
    [[ "${state}" == "ok" ]] && break
    sleep 2
done
docker exec rc-1 redis-cli --no-auth-warning -a "${PASS}" cluster info | head -3
