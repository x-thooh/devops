#!/usr/bin/env bash
# 幂等引导：等 broker 就绪 → 建演示 topic（ha 用 RF=3 + min.insync=2）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

PROFILE="${1:-kafka}"
MODE="${2:-solo}"
KAFKA_BIN="/opt/kafka/bin"

topic_cmd() {
    docker exec kafka-1 "${KAFKA_BIN}/kafka-topics.sh" --bootstrap-server 127.0.0.1:9092 "$@"
}

if [[ "${MODE}" == "ha" ]]; then
    for _ in $(seq 1 30); do
        if docker exec kafka-1 "${KAFKA_BIN}/kafka-metadata-quorum.sh" \
            --bootstrap-controller kafka-ctrl-1:9093 describe --status >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    rf=3
    extra=(--config min.insync.replicas=2)
else
    for _ in $(seq 1 30); do
        topic_cmd --list >/dev/null 2>&1 && break
        sleep 2
    done
    rf=1
    extra=()
fi

topic_cmd --create --if-not-exists --topic devops-demo \
    --partitions 3 --replication-factor "${rf}" ${extra[@]+"${extra[@]}"} >/dev/null
echo "topic devops-demo ready (rf=${rf})"
