#!/usr/bin/env bash
# redis 状态：profile 由第一个参数决定（redis-sentinel / redis-cluster）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

PROFILE="${1:-redis-sentinel}"
# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
PASS="${REDIS_PASSWORD:?REDIS_PASSWORD missing in env/.env}"

if [[ "${PROFILE}" == "redis-cluster" ]]; then
    docker exec rc-1 redis-cli --no-auth-warning -a "${PASS}" cluster info | sed -n '1,6p'
    docker exec rc-1 redis-cli --no-auth-warning -a "${PASS}" cluster nodes | awk '{print $1, $2, $3, $9}'
    exit 0
fi

if ! docker inspect -f '{{.State.Running}}' sentinel-1 2>/dev/null | grep -q true; then
    echo "(solo) sentinel not running; master info from redis-master"
    docker exec redis-master redis-cli --no-auth-warning -a "${PASS}" info replication | sed -n '1,6p'
    exit 0
fi

docker exec sentinel-1 redis-cli -p 26379 sentinel get-master-addr-by-name devmaster
docker exec sentinel-1 redis-cli -p 26379 sentinel master devmaster | sed -n '1,12p'
