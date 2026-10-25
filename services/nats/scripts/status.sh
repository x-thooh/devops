#!/usr/bin/env bash
# nats 状态：逐节点 /varz（只探运行中的节点）+ JetStream 摘要。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

for row in $(rows_of nats); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    [[ "${name}" == "nats-exporter" ]] && continue
    docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null | grep -q true || continue
    printf '%s: ' "${name}"
    curl -sf "http://${ip}:8222/varz" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["server_name"], "uptime=" + str(d["uptime"]))'
done
