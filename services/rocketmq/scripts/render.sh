#!/usr/bin/env bash
# 渲染 rocketmq 配置：solo 单 broker（无 DLedger）/ ha 三 broker 一组 DLedger。
# 身份：brokerIP1、namesrvAddr、dLegerGroup/Peers/SelfId 全部写死。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/.data/active"
ensure_dir "${ACTIVE}"

namesrv=""
peers=""
for row in $(rows_of rocketmq); do
    IFS='|' read -r name ip _ports role mode <<<"${row}"
    case "${role}" in
        namesrv)
            # solo 只起 namesrv-1，地址里不要留未启的 ha 节点（会刷注册失败日志）
            [[ "${MODE}" == "solo" && "${mode}" == "ha" ]] && continue
            namesrv+="${namesrv:+;}${ip}:9876"
            ;;
        dledger)
            idx=$(( ${name##*-} - 1 ))
            peers+="${peers:+;}n${idx}-${ip}:40911"
            ;;
    esac
done

for row in $(rows_of rocketmq); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    case "${role}" in
        dledger)
            ensure_dir "${ACTIVE}/${name}"
            if [[ "${MODE}" == "solo" ]]; then
                store="/data/solo/store"
                dledger=False
                broker_name="broker-solo"
                broker_role="ASYNC_MASTER"
                self_id="n0"
            else
                store="/data/${name}/store"
                dledger=True
                broker_name="broker-dledger"
                broker_role="SYNC_MASTER"
                self_id="n$(( ${name##*-} - 1 ))"
            fi
            ensure_dir "${STACK_DIR}${store}"
            cat >"${ACTIVE}/${name}/broker.conf" <<EOF
brokerClusterName=DefaultCluster
brokerName=${broker_name}
brokerId=0
brokerRole=${broker_role}
flushDiskType=ASYNC_FLUSH
deleteWhen=04
fileReservedTime=48
namesrvAddr=${namesrv}
brokerIP1=${ip}
listenPort=10911
storePathRootDir=${store}
storePathCommitLog=${store}/commitlog
autoCreateTopicEnable=true
enableDLegerCommitLog=${dledger}
sendMessageThreadPoolNums=16
EOF
            if [[ "${MODE}" == "ha" ]]; then
                cat >>"${ACTIVE}/${name}/broker.conf" <<EOF
dLegerGroup=${broker_name}
dLegerPeers=${peers}
dLegerSelfId=${self_id}
EOF
            fi
            ;;
        namesrv)
            ensure_dir "${ACTIVE}/${name}"
            ;;
    esac
done

cat >"${ACTIVE}/rmq-exporter.env" <<EOF
rocketmq.config.namesrvAddr=${namesrv}
EOF
chmod 600 "${ACTIVE}/rmq-exporter.env"

echo "rendered rocketmq (${MODE})"
