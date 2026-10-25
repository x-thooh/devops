#!/usr/bin/env bash
# pg 状态：solo=pg_isready；ha=patronictl list + HAProxy 端口。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
if [[ "${MODE}" == "solo" ]]; then
    docker exec patroni-1 pg_isready -h 127.0.0.1 -p 5432
    exit 0
fi

docker exec patroni-1 patronictl -c /data/active/patroni-1/patroni.yml list
for node in pg-haproxy-1 pg-haproxy-2; do
    printf '%s: ' "${node}"
    curl -sf -o /dev/null -w 'stats %{http_code}\n' "http://$(ip_of "${node}"):7000/" || echo "stats down"
done
