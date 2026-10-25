#!/usr/bin/env bash
# 幂等引导：等 broker 注册到 namesrv → 建演示 topic。
#
# 注意 mqadmin 是 JVM 工具，单次调用要十几秒；不能拿它当轮询探针。
# DLedger 组在 clusterList 里表现为同一 brokerName 的 3 行（BID 0 是从 leader
# 槽位映射来的地址），看不到 SYNC_MASTER 字样，所以按行数判断组是否齐。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
NS="$(ip_of rmq-namesrv-1):9876"

mqadmin() {
    docker exec rmq-broker-1 sh mqadmin "$@" -n "${NS}"
}

if [[ "${MODE}" == "ha" ]]; then
    want=3
    queues=3
else
    want=1
    queues=1
fi

for _ in $(seq 1 30); do
    got="$(mqadmin clusterList 2>/dev/null | grep -c '^DefaultCluster' || true)"
    [[ "${got}" -ge "${want}" ]] && break
    sleep 5
done

if [[ "${got:-0}" -lt "${want}" ]]; then
    echo "WARN: clusterList 只看到 ${got:-0}/${want} 个 broker" >&2
fi

mqadmin updateTopic -c DefaultCluster -t devops-demo -r "${queues}" -w "${queues}" >/dev/null
echo "topic devops-demo ready (queues=${queues})"
