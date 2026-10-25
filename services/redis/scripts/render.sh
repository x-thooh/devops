#!/usr/bin/env bash
# 渲染 redis 两组配置：sentinel（1M+2R+3S）/ cluster（3M+3R），数据按形态隔离。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/.data/active"
ensure_dir "${ACTIVE}"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
PASS="${REDIS_PASSWORD:?REDIS_PASSWORD missing in env/.env}"

master_ip="$(ip_of redis-master)"

redis_common() {
    cat <<EOF
bind 0.0.0.0
protected-mode no
port 6379
appendonly yes
appendfsync everysec
save 900 1
maxmemory 256mb
maxmemory-policy noeviction
slowlog-log-slower-than 10000
requirepass ${PASS}
masterauth ${PASS}
EOF
}

# ---- sentinel 组
for row in $(rows_of redis-sentinel); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "exporter" ]] && continue
    if [[ "${MODE}" == "solo" && "${name}" == "redis-master" ]]; then
        data_dir="/data/sentinel/solo"
    else
        data_dir="/data/sentinel/${name}"
    fi
    ensure_dir "${ACTIVE}/${name}"
    ensure_dir "${STACK_DIR}${data_dir}"
    if [[ "${role}" == "sentinel" ]]; then
        cat >"${ACTIVE}/${name}/sentinel.conf" <<EOF
port 26379
dir ${data_dir}
sentinel monitor devmaster ${master_ip} 6379 2
sentinel auth-pass devmaster ${PASS}
sentinel down-after-milliseconds devmaster 5000
sentinel failover-timeout devmaster 10000
sentinel parallel-syncs devmaster 1
EOF
    else
        {
            redis_common
            echo "dir ${data_dir}"
            if [[ "${role}" == "replica" ]]; then
                echo "replicaof ${master_ip} 6379"
            fi
        } >"${ACTIVE}/${name}/redis.conf"
    fi
    printf 'REDIS_PASSWORD=%s\n' "${PASS}" >"${ACTIVE}/${name}.env"
    chmod 600 "${ACTIVE}/${name}.env"
done

printf 'REDIS_ADDR=redis://%s:6379\nREDIS_PASSWORD=%s\n' "$(ip_of redis-master)" "${PASS}" \
    >"${ACTIVE}/redis-sentinel-exporter.env"
chmod 600 "${ACTIVE}/redis-sentinel-exporter.env"

# ---- cluster 组
for row in $(rows_of redis-cluster); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "exporter" ]] && continue
    if [[ "${MODE}" == "solo" && "${name}" == "rc-1" ]]; then
        data_dir="/data/cluster/solo"
    else
        data_dir="/data/cluster/${name}"
    fi
    ensure_dir "${ACTIVE}/${name}"
    ensure_dir "${STACK_DIR}${data_dir}"
    {
        redis_common
        echo "dir ${data_dir}"
        if [[ "${MODE}" == "solo" ]]; then
            echo "cluster-enabled no"
        else
            echo "cluster-enabled yes"
            echo "cluster-config-file ${data_dir}/nodes.conf"
            echo "cluster-node-timeout 5000"
            echo "cluster-announce-ip ${ip}"
            echo "cluster-announce-port 6379"
            echo "cluster-announce-bus-port 16379"
        fi
    } >"${ACTIVE}/${name}/redis.conf"
    printf 'REDIS_PASSWORD=%s\n' "${PASS}" >"${ACTIVE}/${name}.env"
    chmod 600 "${ACTIVE}/${name}.env"
done

printf 'REDIS_ADDR=redis://%s:6379\nREDIS_PASSWORD=%s\n' "$(ip_of rc-1)" "${PASS}" \
    >"${ACTIVE}/redis-cluster-exporter.env"
chmod 600 "${ACTIVE}/redis-cluster-exporter.env"

echo "rendered redis (${MODE})"
