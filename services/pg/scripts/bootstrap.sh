#!/usr/bin/env bash
# 幂等引导：Patroni 自管选主；这里只做状态确认，不手工 initdb。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
if [[ "${MODE}" == "solo" ]]; then
    docker exec patroni-1 pg_isready -h 127.0.0.1 -p 5432
    exit 0
fi

for _ in $(seq 1 30); do
    if docker exec patroni-1 patronictl -c /data/active/patroni-1/patroni.yml list 2>/dev/null | grep -q Leader; then
        break
    fi
    sleep 2
done
docker exec patroni-1 patronictl -c /data/active/patroni-1/patroni.yml list
