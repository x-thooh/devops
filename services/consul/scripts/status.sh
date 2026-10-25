#!/usr/bin/env bash
# consul 状态：members + raft leader（在第一个运行中的节点上执行）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

target=""
for row in $(rows_of consul); do
    IFS='|' read -r name _ip _ports _role _mode <<<"${row}"
    if docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null | grep -q true; then
        target="${name}"
        break
    fi
done

if [[ -z "${target}" ]]; then
    echo "consul: no running member"
    exit 1
fi

docker exec "${target}" consul members
echo "--- raft ---"
docker exec "${target}" consul operator raft list-peers 2>/dev/null || true
