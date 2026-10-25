#!/usr/bin/env bash
# 幂等引导：ha 形态首次运行 rs.initiate（成员地址取 ini 固定 IP）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
[[ "${MODE}" == "solo" ]] && exit 0

if docker exec mongo-1 mongosh --quiet --eval 'rs.status().ok' 2>/dev/null | grep -qx 1; then
    echo "mongo replica set already initiated"
    exit 0
fi

members=""
idx=0
for row in $(rows_of mongo); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "exporter" ]] && continue
    members+="${members:+,}{\"_id\":${idx},\"host\":\"${ip}:27017\"}"
    idx=$((idx + 1))
done

echo "initiating rs0: ${members}"
docker exec mongo-1 mongosh --quiet --eval "rs.initiate({_id:'rs0', members:[${members}]})"

for _ in $(seq 1 30); do
    state="$(docker exec mongo-1 mongosh --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null || true)"
    [[ "${state}" == "true" ]] && break
    sleep 2
done
docker exec mongo-1 mongosh --quiet --eval 'rs.status().members.map(m => m.name + " " + m.stateStr).join("\n")'
