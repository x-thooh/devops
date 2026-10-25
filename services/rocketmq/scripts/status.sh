#!/usr/bin/env bash
# rocketmq 状态：namesrv 上的 broker 注册信息 + 演示 topic 路由。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

NS="$(ip_of rmq-namesrv-1):9876"
docker exec rmq-broker-1 sh mqadmin clusterList -n "${NS}"
docker exec rmq-broker-1 sh mqadmin topicRoute -n "${NS}" -t devops-demo 2>/dev/null || true
