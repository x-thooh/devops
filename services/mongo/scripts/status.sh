#!/usr/bin/env bash
# mongo 状态：副本集成员（ha）或单实例 ping（solo）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
if [[ "${MODE}" == "solo" ]]; then
    docker exec mongo-1 mongosh --quiet --eval 'db.runCommand({ping:1}).ok'
    exit 0
fi
docker exec mongo-1 mongosh --quiet --eval 'rs.status().members.map(m => m.name + " " + m.stateStr).join("\n")'
