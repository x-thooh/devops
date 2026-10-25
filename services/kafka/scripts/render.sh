#!/usr/bin/env bash
# 渲染 kafka（KRaft）：solo 单节点兼任 broker+controller；ha broker×3 + controller×3。
# 直接生成 server.properties + entry.sh：advertised.listeners / quorum voters / clusterId 全部写死。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/.data/active"
ensure_dir "${ACTIVE}"

cluster_file="${ACTIVE}/kafka-cluster-id"
if [[ ! -s "${cluster_file}" ]]; then
    python3 -c 'import uuid; print(uuid.uuid4().hex[:22])' >"${cluster_file}"
fi
CLUSTER_ID="$(cat "${cluster_file}")"

voters=""
for row in $(rows_of kafka); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "controller" ]] || continue
    idx=$((100 + ${name##*-}))
    voters+="${voters:+,}${idx}@${ip}:9093"
done

for row in $(rows_of kafka); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    ensure_dir "${ACTIVE}/${name}"

    case "${role}" in
        broker)
            idx="${name##*-}"
            if [[ "${MODE}" == "solo" ]]; then
                log_dir="/data/solo/kraft"
                roles="broker,controller"
                listeners="PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093"
                # 合体节点必须把 CONTROLLER 也公告出去，否则 "listeners" 的 0.0.0.0 会触发校验失败
                advertised="PLAINTEXT://${ip}:9092,CONTROLLER://${ip}:9093"
                local_voters="1@${ip}:9093"
                rf=1
            else
                log_dir="/data/${name}/kraft"
                roles="broker"
                listeners="PLAINTEXT://0.0.0.0:9092"
                advertised="PLAINTEXT://${ip}:9092"
                local_voters="${voters}"
                rf=3
            fi
            ensure_dir "${STACK_DIR}${log_dir}"
            cat >"${ACTIVE}/${name}/server.properties" <<EOF
process.roles=${roles}
node.id=${idx}
controller.quorum.voters=${local_voters}
listeners=${listeners}
advertised.listeners=${advertised}
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
log.dirs=${log_dir}
num.partitions=3
default.replication.factor=${rf}
offsets.topic.replication.factor=${rf}
transaction.state.log.replication.factor=${rf}
transaction.state.log.min.isr=$((rf > 1 ? rf - 1 : 1))
auto.create.topics.enable=false
group.initial.rebalance.delay.ms=0
EOF
            heap="-Xms512m -Xmx512m"
            ;;
        controller)
            idx=$((100 + ${name##*-}))
            log_dir="/data/${name}/kraft"
            ensure_dir "${STACK_DIR}${log_dir}"
            cat >"${ACTIVE}/${name}/server.properties" <<EOF
process.roles=controller
node.id=${idx}
controller.quorum.voters=${voters}
listeners=CONTROLLER://0.0.0.0:9093
advertised.listeners=CONTROLLER://${ip}:9093
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT
log.dirs=${log_dir}
EOF
            heap="-Xms256m -Xmx256m"
            ;;
    esac

    cat >"${ACTIVE}/${name}/entry.sh" <<EOF
#!/bin/bash
set -e
export KAFKA_HEAP_OPTS="${heap}"
CONF=/data/active/${name}/server.properties
mkdir -p ${log_dir}
if [[ ! -f ${log_dir}/meta.properties ]]; then
    /opt/kafka/bin/kafka-storage.sh format -t "${CLUSTER_ID}" -c "\$CONF"
fi
exec /opt/kafka/bin/kafka-server-start.sh "\$CONF"
EOF
    chmod +x "${ACTIVE}/${name}/entry.sh"
done

echo "rendered kafka (${MODE}, clusterId=${CLUSTER_ID})"
