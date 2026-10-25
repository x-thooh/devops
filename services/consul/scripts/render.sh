#!/usr/bin/env bash
# 渲染 consul agent 配置：solo 单 server（bootstrap_expect=1）/ ha 三 server。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/data/active"

join=""
for row in $(rows_of consul); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    join+="${join:+, }\"${ip}\""
done

for row in $(rows_of consul); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    if [[ "${MODE}" == "solo" ]]; then
        data_dir="/data/solo"
        bootstrap=1
        retry_join="[]"
    else
        data_dir="/data/${name}"
        bootstrap=3
        retry_join="[${join}]"
    fi
    ensure_dir "${ACTIVE}/${name}"
    cat >"${ACTIVE}/${name}/consul.json" <<EOF
{
  "node_name": "${name}",
  "data_dir": "${data_dir}",
  "server": true,
  "bootstrap_expect": ${bootstrap},
  "bind_addr": "${ip}",
  "client_addr": "0.0.0.0",
  "retry_join": ${retry_join},
  "ui_config": { "enabled": true },
  "ports": { "server": 8300, "serf_lan": 8301, "serf_wan": 8302, "http": 8500, "dns": 8600 }
}
EOF
done

echo "rendered consul (${MODE})"
