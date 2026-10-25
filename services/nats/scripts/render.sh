#!/usr/bin/env bash
# 渲染 nats 配置：solo 单节点 / ha 三节点全互联（R3 由 JetStream 复制因子约束）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/.data/active"
ensure_dir "${ACTIVE}"

for row in $(rows_of nats); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    [[ "${name}" == "nats-exporter" ]] && continue
    if [[ "${MODE}" == "solo" ]]; then
        store_dir="/data/solo"
        routes=""
    else
        store_dir="/data/${name}"
        routes=$'  routes: [\n'
        for peer in $(rows_of nats); do
            IFS='|' read -r pname _pip _pports _prole _pmode <<<"${peer}"
            [[ "${pname}" == "nats-exporter" || "${pname}" == "${name}" ]] && continue
            routes+="    nats-route://${pname}:6222"$'\n'
        done
        routes+=$'  ]\n'
    fi
    ensure_dir "${ACTIVE}/${name}"
    {
        cat <<EOF
server_name: ${name}
port: 4222
http_port: 8222
jetstream {
  store_dir: "${store_dir}"
  max_mem_store: 256MB
  max_file_store: 1GB
}
EOF
        if [[ -n "${routes}" ]]; then
            cat <<EOF
cluster {
  name: devops
  listen: 0.0.0.0:6222
${routes}}
EOF
        fi
    } >"${ACTIVE}/${name}/nats.conf"
    echo "rendered nats ${name} (${MODE})"
done
