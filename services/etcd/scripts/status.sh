#!/usr/bin/env bash
# etcd 状态：逐成员 endpoint health（只探当前在跑的节点）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

endpoints=""
for row in $(rows_of etcd); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null | grep -q true || continue
    endpoints+="${endpoints:+,}http://${ip}:2379"
done

if [[ -z "${endpoints}" ]]; then
    echo "etcd: no running member"
    exit 1
fi

docker exec etcd-1 etcdctl --endpoints="${endpoints}" endpoint health --write-out=table
