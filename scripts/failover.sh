#!/usr/bin/env bash
# 故障转移演练：只 stop 不 kill（DEC-17 / R12），观察选主/路由跟随，再 start 让旧节点回归。
# 用法：scripts/failover.sh <profile> [kafka:controller|broker]
# 支持：pg / redis-sentinel / redis-cluster / mysql / mongo / kafka / rocketmq /
#       etcd / consul / nats / rabbitmq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# shellcheck disable=SC1091
set -a; source "${ROOT}/env/.env"; set +a

PROFILE="${1:-}"
TARGET="${2:-}"
die() {
    echo "ERROR: $*" >&2
    exit 2
}
[[ -n "${PROFILE}" ]] || die "usage: scripts/failover.sh <profile> [kafka:controller|broker]"

dir="$(python3 scripts/ini.py dir "${PROFILE}")" || die "未知 profile：${PROFILE}"
stack_dir="${ROOT}/services/${dir}"
marker="${stack_dir}/data/.mode-${PROFILE}"
if [[ -f "${marker}" && "$(cat "${marker}")" != "ha" ]]; then
    die "${PROFILE} 当前不是 ha 形态（$(cat "${marker}")）；演练只对集群形态有意义"
fi

COMPOSE=(docker compose --env-file "${ROOT}/env/.env" -f "${ROOT}/compose.generated.yml")
compose() { "${COMPOSE[@]}" --profile "${PROFILE}" "$@"; }

stop_node() {
    echo "  stop ${1}（不触发 restart）"
    compose stop "${1}" >/dev/null
}

start_node() {
    echo "  start ${1}（观察回归）"
    compose start "${1}" >/dev/null
}

is_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

# wait_until <描述> <秒> <谓词...>
wait_until() {
    local desc="$1" timeout="$2"
    shift 2
    local deadline
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if "$@" >/dev/null 2>&1; then
            echo "  OK: ${desc}"
            return 0
        fi
        sleep 2
    done
    echo "  TIMEOUT(${timeout}s): ${desc}" >&2
    return 1
}

node_by_ip() {
    local profile="$1" want="$2" row name ip _ports _role _mode
    for row in $(rows_of "${profile}"); do
        IFS='|' read -r name ip _ports _role _mode <<<"${row}"
        if [[ "${ip}" == "${want}" ]]; then
            echo "${name}"
            return 0
        fi
    done
    return 1
}

first_running() {
    local name
    for name in "$@"; do
        if is_running "${name}"; then
            echo "${name}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------- pg（Patroni）
pg_leader_ip() {
    local row name ip _ports role _mode
    for row in $(rows_of pg); do
        IFS='|' read -r name ip _ports role _mode <<<"${row}"
        [[ "${role}" == "leader" || "${role}" == "replica" ]] || continue
        curl -sf -m 2 "http://${ip}:8008/leader" >/dev/null 2>&1 && {
            echo "${ip}"
            return 0
        }
    done
    return 1
}

pg_psql() {
    local sql="$1" c
    c="$(first_running patroni-1 patroni-2 patroni-3)" || return 1
    docker exec "${c}" psql "postgresql://postgres:${PG_SUPERUSER_PASSWORD}@$(ip_of pg-haproxy-1):5000/postgres" \
        -Atc "${sql}" 2>/dev/null
}

pg_leader_changed() {
    local old="$1" cur
    cur="$(pg_leader_ip)" || return 1
    [[ "${cur}" != "${old}" ]]
}

pg_haproxy_follows() {
    local want="$1" got
    got="$(pg_psql 'select inet_server_addr()')" || return 1
    [[ "${got}" == "${want}" ]]
}

pg_is_replica() {
    curl -sf -m 2 "http://${1}:8008/replica" >/dev/null 2>&1
}

drill_pg() {
    local old_ip victim new_ip
    old_ip="$(pg_leader_ip)" || die "找不到 Patroni leader（集群没起来？）"
    victim="$(node_by_ip pg "${old_ip}")" || die "leader IP 不在 ini：${old_ip}"
    echo "pg: 当前 leader=${victim} (${old_ip})"
    stop_node "${victim}"
    if ! wait_until "选出新 leader" 90 pg_leader_changed "${old_ip}"; then
        start_node "${victim}"
        exit 1
    fi
    new_ip="$(pg_leader_ip)"
    echo "  新 leader ip=${new_ip}（$(node_by_ip pg "${new_ip}")）"
    if ! wait_until "HAProxy 5000 跟随新主" 60 pg_haproxy_follows "${new_ip}"; then
        start_node "${victim}"
        exit 1
    fi
    start_node "${victim}"
    wait_until "旧主以 replica 回归" 90 pg_is_replica "${old_ip}" ||
        echo "  WARN: 旧主未在 90s 内回归，看 make stack-logs S=pg" >&2
}

# ---------------------------------------------------------- redis-sentinel
red() { docker exec "$1" redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning "${@:2}"; }

sentinel_master_ip() {
    docker exec sentinel-1 redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning -p 26379 \
        sentinel get-master-addr-by-name devmaster 2>/dev/null | head -1
}

sentinel_master_changed() {
    local old="$1" cur
    cur="$(sentinel_master_ip)" || return 1
    [[ -n "${cur}" && "${cur}" != "${old}" ]]
}

redis_ping() {
    red "$1" -h "$2" ping 2>/dev/null | grep -q PONG
}

redis_role_is() {
    red "$1" -h "$2" info replication 2>/dev/null | grep -q "role:${3}"
}

drill_redis_sentinel() {
    local old_ip victim new_ip new_node
    old_ip="$(ip_of redis-master)"
    victim="redis-master"
    echo "redis-sentinel: 当前 master=${victim} (${old_ip})"
    stop_node "${victim}"
    if ! wait_until "sentinel 升主" 60 sentinel_master_changed "${old_ip}"; then
        start_node "${victim}"
        exit 1
    fi
    new_ip="$(sentinel_master_ip)"
    new_node="$(node_by_ip redis-sentinel "${new_ip}")"
    echo "  新 master=${new_node} (${new_ip})"
    wait_until "新 master 可写" 30 redis_ping "${new_node}" "${new_ip}" || {
        start_node "${victim}"
        exit 1
    }
    start_node "${victim}"
    wait_until "旧 master 降为 replica" 90 redis_role_is "${victim}" "${old_ip}" slave ||
        echo "  WARN: 旧 master 未回归为 replica" >&2
}

# ----------------------------------------------------------- redis-cluster
rc_nodes() { red "$1" cluster nodes; }

rc_state_ok() {
    red "$1" cluster info | grep -q 'cluster_state:ok'
}

rc_has_master() {
    # $1=查询容器 $2=master IP
    rc_nodes "$1" | awk -v ip="$2" '$2 ~ ip && $3 ~ /master/ { found=1 } END { exit !found }'
}

rc_has_node() {
    rc_nodes "$1" | awk -v ip="$2" '$2 ~ ip { found=1 } END { exit !found }'
}

drill_redis_cluster() {
    local victim="rc-1" old_ip new_master_ip survivor
    old_ip="$(ip_of "${victim}")"
    new_master_ip="$(ip_of rc-1r)"
    survivor="rc-2"
    echo "redis-cluster: stop ${victim} (${old_ip})，期待 rc-1r 顶替"
    stop_node "${victim}"
    if ! wait_until "cluster 恢复 ok 且 rc-1r 成为 master" 120 rc_cluster_failover; then
        start_node "${victim}"
        exit 1
    fi
    start_node "${victim}"
    wait_until "rc-1 重新加入集群" 90 rc_has_node "${survivor}" "${old_ip}" ||
        echo "  WARN: rc-1 未重新加入，看 make stack-logs S=redis-cluster" >&2
}

rc_cluster_failover() {
    rc_state_ok rc-2 || return 1
    rc_has_master rc-2 "$(ip_of rc-1r)"
}

# ----------------------------------------------------------------- mysql（MGR）
mysql_sql() {
    local c="$1" sql="$2"
    docker exec "${c}" mysql -h127.0.0.1 -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B -e "${sql}" 2>/dev/null
}

mysql_primary_host() {
    local c host
    for c in mysql-1 mysql-2 mysql-3; do
        is_running "${c}" || continue
        host="$(mysql_sql "${c}" "select MEMBER_HOST from performance_schema.replication_group_members where MEMBER_ROLE='PRIMARY' limit 1")" || true
        if [[ -n "${host}" ]]; then
            echo "${host}"
            return 0
        fi
    done
    return 1
}

mysql_primary_changed() {
    local old="$1" cur
    cur="$(mysql_primary_host)" || return 1
    [[ -n "${cur}" && "${cur}" != "${old}" ]]
}

mysql_all_online() {
    local c n
    for c in mysql-1 mysql-2 mysql-3; do
        is_running "${c}" || return 1
        n="$(mysql_sql "${c}" "select count(*) from performance_schema.replication_group_members where MEMBER_STATE='ONLINE'")" || return 1
        [[ "${n}" == "3" ]] || return 1
    done
}

mysql_router_serves() {
    # $1=期望的 server_id；Router 6446 应指向新主且 read_only=0
    local want="$1" c out
    c="$(first_running mysql-1 mysql-2 mysql-3)" || return 1
    out="$(docker exec "${c}" mysql -h"$(ip_of mysql-router-1)" -P6446 -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B \
        -e 'select concat(@@server_id, ":", @@read_only)' 2>/dev/null)" || return 1
    [[ "${out}" == "${want}:0" ]]
}

drill_mysql() {
    local old_host victim new_host new_sid
    old_host="$(mysql_primary_host)" || die "找不到 MGR primary（集群没起来？）"
    victim="${old_host}"
    echo "mysql: 当前 primary=${victim} ($(ip_of "${victim}"))"
    stop_node "${victim}"
    if ! wait_until "MGR 选出新 primary" 90 mysql_primary_changed "${old_host}"; then
        start_node "${victim}"
        exit 1
    fi
    new_host="$(mysql_primary_host)"
    new_sid="$(mysql_sql "${new_host}" 'select @@server_id')"
    echo "  新 primary=${new_host}（server_id=${new_sid}）"
    if ! wait_until "Router 6446 指向新主" 60 mysql_router_serves "${new_sid}"; then
        start_node "${victim}"
        exit 1
    fi
    start_node "${victim}"
    # MGR 不会自动让重启节点归队：调 bootstrap.sh 的修复分支（START GROUP_REPLICATION + 元数据 rescan）
    bash "${ROOT}/services/mysql/scripts/bootstrap.sh" mysql ha >/dev/null 2>&1 ||
        echo "  WARN: bootstrap 修复失败，看 make stack-logs S=mysql" >&2
    wait_until "三节点回到 ONLINE" 120 mysql_all_online ||
        echo "  WARN: 旧主未在 120s 内归队，必要时 stack-reset" >&2
}

# ---------------------------------------------------------------- mongo（RS）
mongo_primary_ip() {
    local c ip
    for c in mongo-1 mongo-2 mongo-3; do
        is_running "${c}" || continue
        ip="$(docker exec "${c}" mongosh --quiet --eval 'db.hello().primary' 2>/dev/null | sed 's/:.*//')" || true
        if [[ -n "${ip}" ]]; then
            echo "${ip}"
            return 0
        fi
    done
    return 1
}

mongo_primary_changed() {
    local old="$1" cur
    cur="$(mongo_primary_ip)" || return 1
    [[ -n "${cur}" && "${cur}" != "${old}" ]]
}

mongo_writable() {
    local c="$1"
    docker exec "${c}" mongosh --quiet --eval \
        'db.getSiblingDB("devops").drill.insertOne({ts: new Date()})' >/dev/null 2>&1
}

mongo_is_secondary() {
    local c="$1"
    docker exec "${c}" mongosh --quiet --eval \
        'rs.status().members.some(m => m.name.startsWith("'"$(ip_of "${c}")"'") && m.stateStr === "SECONDARY")' \
        2>/dev/null | grep -q true
}

drill_mongo() {
    local old_ip victim new_ip new_node
    old_ip="$(mongo_primary_ip)" || die "找不到 mongo primary"
    victim="$(node_by_ip mongo "${old_ip}")"
    echo "mongo: 当前 primary=${victim} (${old_ip})"
    stop_node "${victim}"
    if ! wait_until "副本集选出新 primary" 90 mongo_primary_changed "${old_ip}"; then
        start_node "${victim}"
        exit 1
    fi
    new_ip="$(mongo_primary_ip)"
    new_node="$(node_by_ip mongo "${new_ip}")"
    echo "  新 primary=${new_node} (${new_ip})"
    wait_until "新 primary 可写" 30 mongo_writable "${new_node}" || {
        start_node "${victim}"
        exit 1
    }
    start_node "${victim}"
    wait_until "旧主以 SECONDARY 回归" 90 mongo_is_secondary "${victim}" ||
        echo "  WARN: 旧主未在 90s 内回归" >&2
}

# ---------------------------------------------------------------- kafka（KRaft）
kafka_quorum() {
    local c="$1"
    docker exec "${c}" /opt/kafka/bin/kafka-metadata-quorum.sh \
        --bootstrap-controller 127.0.0.1:9093 describe --status 2>/dev/null
}

kafka_leader_id() {
    local c="$1"
    kafka_quorum "${c}" | awk '/^LeaderId:/ {print $2}'
}

kafka_quorum_ok() {
    # 期望：leader 存在且 CurrentVoters 3 个
    local c="$1" out leader voters
    out="$(kafka_quorum "${c}")" || return 1
    leader="$(echo "${out}" | awk '/^LeaderId:/ {print $2}')"
    voters="$(echo "${out}" | awk '/^CurrentVoters:/ {n = gsub(/"id":/, "&"); print n}')"
    [[ -n "${leader}" && "${voters}" == "3" ]]
}

kafka_topic_ok() {
    local c="$1"
    docker exec "${c}" /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
        --list >/dev/null 2>&1
}

kafka_brokers() {
    docker exec kafka-1 /opt/kafka/bin/kafka-broker-api-versions.sh \
        --bootstrap-server 127.0.0.1:9092 2>/dev/null | grep -c 'id:'
}

drill_kafka() {
    local kind="${TARGET:-controller}"
    case "${kind}" in
        controller)
            local leader_id victim old_leader survivor
            survivor="$(first_running kafka-ctrl-1 kafka-ctrl-2 kafka-ctrl-3)" || die "没有运行中的 controller"
            old_leader="$(kafka_leader_id "${survivor}")"
            [[ -n "${old_leader}" ]] || die "读不到 controller quorum leader"
            victim="kafka-ctrl-$((old_leader - 100))"
            echo "kafka: stop controller leader=${victim}（id=${old_leader}）"
            stop_node "${victim}"
            if ! wait_until "controller 选出新 leader" 90 kafka_new_controller "${old_leader}"; then
                start_node "${victim}"
                exit 1
            fi
            wait_until "broker 仍在服务" 30 kafka_topic_ok kafka-1 || {
                start_node "${victim}"
                exit 1
            }
            start_node "${victim}"
            wait_until "旧 controller 回归 quorum" 90 kafka_quorum_ok "${victim}" ||
                echo "  WARN: 旧 controller 未回归" >&2
            ;;
        broker)
            local survivor
            survivor="$(first_running kafka-1 kafka-2 kafka-3)" || die "没有运行中的 broker"
            echo "kafka: stop broker kafka-2"
            stop_node kafka-2
            wait_until "剩余 broker 仍可服务" 30 kafka_topic_ok "${survivor}" || {
                start_node kafka-2
                exit 1
            }
            start_node kafka-2
            wait_until "三 broker 全部可见" 90 kafka_brokers_is_3 ||
                echo "  WARN: kafka-2 未回归" >&2
            ;;
        *)
            die "kafka 的第二个参数只能是 controller 或 broker（收到 ${kind}）"
            ;;
    esac
}

kafka_new_controller() {
    local old="$1" c cur
    c="$(first_running kafka-ctrl-1 kafka-ctrl-2 kafka-ctrl-3)" || return 1
    cur="$(kafka_leader_id "${c}")" || return 1
    [[ -n "${cur}" && "${cur}" != "${old}" ]]
}

kafka_brokers_is_3() {
    [[ "$(kafka_brokers)" == "3" ]]
}

# ------------------------------------------------------------- rocketmq（DLedger）
rmq_admin() {
    local c="$1"
    shift
    docker exec "${c}" sh mqadmin "$@" -n "$(ip_of rmq-namesrv-1):9876" 2>/dev/null
}

rmq_cluster_list() {
    local c="$1"
    rmq_admin "${c}" clusterList
}

rmq_leader_addr() {
    local c="$1"
    rmq_cluster_list "${c}" | awk '$1 !~ /^#/ && $NF == "true" {print $4; exit}'
}

rmq_rows() {
    local c="$1"
    rmq_cluster_list "${c}" | awk '$1 !~ /^#/ && $1 == "DefaultCluster"' | wc -l | tr -d ' '
}

rmq_leader_changed() {
    local old="$1" c cur
    c="$(first_running rmq-broker-1 rmq-broker-2 rmq-broker-3)" || return 1
    cur="$(rmq_leader_addr "${c}")" || return 1
    [[ -n "${cur}" && "${cur}" != "${old}" ]]
}

drill_rocketmq() {
    local survivor old_addr old_ip victim new_addr
    survivor="$(first_running rmq-broker-1 rmq-broker-2 rmq-broker-3)" || die "没有运行中的 broker"
    old_addr="$(rmq_leader_addr "${survivor}")"
    [[ -n "${old_addr}" ]] || die "读不到 DLedger leader（mqadmin 失败？）"
    old_ip="${old_addr%%:*}"
    victim="$(node_by_ip rocketmq "${old_ip}")"
    echo "rocketmq: 当前 DLedger leader=${victim} (${old_addr})"
    stop_node "${victim}"
    # mqadmin 每次十几秒，轮询次数有限
    if ! wait_until "DLedger 选出新 leader" 150 rmq_leader_changed "${old_addr}"; then
        start_node "${victim}"
        exit 1
    fi
    new_addr="$(rmq_leader_addr "$(first_running rmq-broker-1 rmq-broker-2 rmq-broker-3)")"
    echo "  新 leader=${new_addr}"
    start_node "${victim}"
    wait_until "三 broker 回到 clusterList" 150 rmq_rows_is_3 ||
        echo "  WARN: 旧 broker 未回归" >&2
}

rmq_rows_is_3() {
    local c
    c="$(first_running rmq-broker-1 rmq-broker-2 rmq-broker-3)" || return 1
    [[ "$(rmq_rows "${c}")" == "3" ]]
}

# -------------------------------------------------------------------- etcd
etcd_ctl() { docker exec etcd-1 etcdctl --endpoints="http://$(ip_of etcd-1):2379" "$@"; }

drill_etcd() {
    local victim="etcd-2"
    echo "etcd: stop ${victim}"
    stop_node "${victim}"
    if ! wait_until "剩余节点可读写" 30 etcd_rw; then
        start_node "${victim}"
        exit 1
    fi
    start_node "${victim}"
    wait_until "${victim} 重新 healthy" 60 etcd_node_healthy ||
        echo "  WARN: ${victim} 未回归" >&2
}

etcd_rw() {
    etcd_ctl put /devops-drill "$(date +%s)" >/dev/null || return 1
    etcd_ctl get /devops-drill >/dev/null
}

etcd_node_healthy() {
    curl -sf "http://$(ip_of etcd-2):2379/health" >/dev/null 2>&1
}

# ------------------------------------------------------------------ consul
consul_leader() { curl -sf "http://$(ip_of consul-1):8500/v1/status/leader"; }

drill_consul() {
    local victim="consul-2"
    echo "consul: stop ${victim}"
    stop_node "${victim}"
    if ! wait_until "仍有 leader 且 KV 可写" 30 consul_rw; then
        start_node "${victim}"
        exit 1
    fi
    start_node "${victim}"
    wait_until "${victim} 重新加入" 60 consul_member_alive ||
        echo "  WARN: ${victim} 未回归" >&2
}

consul_rw() {
    local leader
    leader="$(consul_leader)"
    [[ -n "${leader}" && "${leader}" != '""' ]] || return 1
    curl -sf -X PUT -d drill "http://$(ip_of consul-1):8500/v1/kv/devops-drill" >/dev/null || return 1
    curl -sf "http://$(ip_of consul-1):8500/v1/kv/devops-drill?raw" | grep -q drill
}

consul_member_alive() {
    curl -sf "http://$(ip_of consul-2):8500/v1/agent/self" >/dev/null 2>&1
}

# -------------------------------------------------------------------- nats
nats_check() { curl -sf "http://$(ip_of nats-1):8222/healthz" >/dev/null; }

nats_routes_eq() {
    curl -s "http://$(ip_of nats-1):8222/routez" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["num_routes"])' 2>/dev/null |
        grep -qx "$1"
}

drill_nats() {
    local victim="nats-2"
    echo "nats: stop ${victim}"
    stop_node "${victim}"
    if ! wait_until "剩余两节点健康（1 条路由）" 30 nats_routes_eq 1; then
        start_node "${victim}"
        exit 1
    fi
    start_node "${victim}"
    wait_until "路由恢复为 2 条" 60 nats_routes_eq 2 ||
        echo "  WARN: ${victim} 未回归" >&2
}

# ---------------------------------------------------------------- rabbitmq
rabbit_running() {
    local c="$1" want="$2" n
    n="$(docker exec "${c}" rabbitmqctl -q cluster_status --formatter json 2>/dev/null |
        python3 -c 'import json,sys; print(len(json.load(sys.stdin)["running_nodes"]))' 2>/dev/null || true)"
    [[ "${n}" == "${want}" ]]
}

drill_rabbitmq() {
    local victim="rabbit-3"
    echo "rabbitmq: stop ${victim}"
    stop_node "${victim}"
    if ! wait_until "集群仍为 2/3 running" 30 rabbit_running rabbit-1 2; then
        start_node "${victim}"
        exit 1
    fi
    start_node "${victim}"
    wait_until "三节点全部 running" 90 rabbit_running rabbit-1 3 ||
        echo "  WARN: ${victim} 未回归" >&2
}

# -------------------------------------------------------------------- main
echo "== failover-drill: ${PROFILE}${TARGET:+ (${TARGET})}"
case "${PROFILE}" in
    pg) drill_pg ;;
    redis-sentinel) drill_redis_sentinel ;;
    redis-cluster) drill_redis_cluster ;;
    mysql) drill_mysql ;;
    mongo) drill_mongo ;;
    kafka) drill_kafka ;;
    rocketmq) drill_rocketmq ;;
    etcd) drill_etcd ;;
    consul) drill_consul ;;
    nats) drill_nats ;;
    rabbitmq) drill_rabbitmq ;;
    *) die "该 profile 不支持 failover-drill：${PROFILE}" ;;
esac
echo "== done"
