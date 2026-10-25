#!/usr/bin/env bash
# rabbitmq 状态：集群成员 + 队列类型（验证 quorum）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

docker exec rabbit-1 rabbitmqctl -q cluster_status
docker exec rabbit-1 rabbitmqctl -q list_queues name type messages 2>/dev/null || true
