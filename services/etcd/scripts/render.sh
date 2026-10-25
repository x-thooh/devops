#!/usr/bin/env bash
# 渲染 etcd 配置：solo 单成员集群 / ha 三成员集群（数据目录按形态隔离）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/data/active"
ensure_dir "${ACTIVE}"

cluster=""
for row in $(rows_of etcd); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    cluster+="${cluster:+,}${name}=http://${ip}:2380"
done

for row in $(rows_of etcd); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    if [[ "${MODE}" == "solo" ]]; then
        data_dir="/data/solo"
        initial_cluster="${name}=http://${ip}:2380"
    else
        data_dir="/data/${name}"
        initial_cluster="${cluster}"
    fi
    ensure_dir "${ACTIVE}/${name}"
    cat >"${ACTIVE}/${name}/etcd.yml" <<EOF
name: ${name}
data-dir: ${data_dir}
listen-client-urls: http://0.0.0.0:2379
advertise-client-urls: http://${ip}:2379
listen-peer-urls: http://0.0.0.0:2380
initial-advertise-peer-urls: http://${ip}:2380
initial-cluster: ${initial_cluster}
initial-cluster-state: new
initial-cluster-token: devops-etcd
EOF
done

echo "rendered etcd (${MODE}): ${cluster}"
