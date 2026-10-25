#!/usr/bin/env bash
# 渲染 mongod 配置：solo 单实例（无副本集）/ ha 三节点副本集 rs0。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/data/active"
ensure_dir "${ACTIVE}"

repl=""
if [[ "${MODE}" == "ha" ]]; then
    repl=$'replication:\n  replSetName: rs0\n'
fi

for row in $(rows_of mongo); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "exporter" ]] && continue
    if [[ "${MODE}" == "solo" ]]; then
        data_dir="/data/solo/db"
    else
        data_dir="/data/${name}/db"
    fi
    ensure_dir "${STACK_DIR}${data_dir}"
    ensure_dir "${ACTIVE}/${name}"
    cat >"${ACTIVE}/${name}/mongod.conf" <<EOF
storage:
  dbPath: ${data_dir}
  wiredTiger:
    engineConfig:
      cacheSizeGB: 0.25
net:
  bindIp: 0.0.0.0
  port: 27017
EOF
    [[ -n "${repl}" ]] && printf '%s' "${repl}" >>"${ACTIVE}/${name}/mongod.conf"
    echo "rendered mongo ${name} (${MODE})"
done

printf 'MONGODB_URI=mongodb://%s:27017\n' "$(ip_of mongo-1)" >"${ACTIVE}/mongo-exporter.env"
chmod 600 "${ACTIVE}/mongo-exporter.env"
