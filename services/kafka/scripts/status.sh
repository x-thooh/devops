#!/usr/bin/env bash
# kafka 状态：solo=topic 列表；ha=KRaft quorum + 副本分配。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

PROFILE="${1:-kafka}"
MODE="${2:-solo}"
KAFKA_BIN="/opt/kafka/bin"

if [[ "${MODE}" == "ha" ]]; then
    docker exec kafka-1 "${KAFKA_BIN}/kafka-metadata-quorum.sh" \
        --bootstrap-controller kafka-ctrl-1:9093 describe --status
fi
docker exec kafka-1 "${KAFKA_BIN}/kafka-topics.sh" --bootstrap-server 127.0.0.1:9092 --list
docker exec kafka-1 "${KAFKA_BIN}/kafka-topics.sh" --bootstrap-server 127.0.0.1:9092 \
    --describe --topic devops-demo 2>/dev/null || true
