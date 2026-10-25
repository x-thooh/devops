#!/usr/bin/env bash
# 幂等引导：ha 首次在 mysql-1 上 bootstrap MGR，其余节点 join；
# 重启 / 演练后只修复离队节点（START GROUP_REPLICATION），不会重建集群。
#
# 不能直接 join 的原因：官方镜像 entrypoint 初始化时会写几条本地事务，三个节点
# 各自带着不同的 GTID 集合（UUID 不同），MGR 会以 "member has more executed
# transactions" 拒绝。做法：成组前 RESET MASTER 清空各节点 GTID（数据保留，
# 三份初始化产物结构一致），让组从空 GTID 起步；建库/建用户放到成组之后。
#
# 成组后如果元数据不存在，用 mysqlsh 以 adoptFromGR 接管已有复制组：
# Router 的 metadata-cache 依赖它才能让 6446 真正跟随 primary。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
[[ "${MODE}" == "solo" ]] && exit 0

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
PASS="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD missing in env/.env}"
REPL_PASS="${MYSQL_REPL_PASSWORD:?MYSQL_REPL_PASSWORD missing in env/.env}"

NODES=(mysql-1 mysql-2 mysql-3)
CLUSTER_NAME=devops

# 等实例可登录：重启后的节点需要 10–20s 做 crash recovery，
# 过早去查状态会把刚重启的节点误判成 OFF LINE 并错过 START GROUP_REPLICATION。
for node in "${NODES[@]}"; do
    for _ in $(seq 1 45); do
        docker exec "${node}" mysqladmin ping -h127.0.0.1 -uroot -p"${PASS}" --silent >/dev/null 2>&1 && break
        sleep 2
    done
done

sql() {
    local node="$1"
    shift
    docker exec "${node}" mysql -h127.0.0.1 -uroot -p"${PASS}" -N -B -e "$*" 2>/dev/null
}

node_state() {
    sql "$1" "SELECT COALESCE(MAX(MEMBER_STATE),'OFFLINE')
              FROM performance_schema.replication_group_members WHERE MEMBER_ID=@@server_uuid"
}

any_online_node() {
    local node
    for node in "${NODES[@]}"; do
        if [[ "$(node_state "${node}")" == "ONLINE" ]]; then
            echo "${node}"
            return 0
        fi
    done
    return 1
}

primary_node() {
    local node
    for node in "${NODES[@]}"; do
        [[ "$(node_state "${node}")" == "ONLINE" ]] || continue
        if [[ "$(sql "${node}" "SELECT MEMBER_ROLE FROM performance_schema.replication_group_members WHERE MEMBER_ID=@@server_uuid")" == "PRIMARY" ]]; then
            echo "${node}"
            return 0
        fi
    done
    return 1
}

online_count() {
    local probe
    probe="$(any_online_node)" || {
        echo 0
        return 0
    }
    sql "${probe}" "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE='ONLINE'"
}

mysqlsh_cmd() {
    local node="$1" code="$2" out rc=0
    if ! out="$(docker exec "${node}" mysqlsh --no-wizard "root:${PASS}@127.0.0.1:3306" -e "${code}" 2>&1)"; then
        rc=1
    fi
    echo "${out}" | grep -v 'Using a password' || true
    return "${rc}"
}

# ---- 已成组：只修复离队节点（演练重启、容器重启都走这里）
if any_online_node >/dev/null; then
    echo "MGR 已存在，检查成员状态"
    for node in "${NODES[@]}"; do
        state="$(node_state "${node}")"
        [[ "${state}" == "ONLINE" ]] && continue
        echo "rejoining ${node} (state=${state})"
        sql "${node}" "STOP GROUP_REPLICATION" >/dev/null 2>&1 || true
        sql "${node}" "START GROUP_REPLICATION" >/dev/null 2>&1 || true
    done
else
    # ---- 首次成组：解只读 → 清 GTID → 建 repl 用户与 recovery channel → bootstrap → join
    # down / 宿主机重启后，单主 MGR 会让三个节点都带 super_read_only=ON 回来
    #（运行时行为，不落 mysqld-auto.cnf），而 repl 用户必须在成组之前建 —— 不解锁
    # 就是 ERROR 1290 + set -e 中断：MGR 起不来 -> Router 6446 不监听 -> 依赖它的栈全挂。
    # join 后 MGR 自己会把 SECONDARY 置回 ON，这里解锁不破坏单主语义。
    for node in "${NODES[@]}"; do
        sql "${node}" "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF" >/dev/null
    done
    for node in "${NODES[@]}"; do
        gtids="$(sql "${node}" "SELECT @@GLOBAL.gtid_executed")"
        if [[ -n "${gtids}" ]]; then
            echo "clearing local GTID set on ${node} (${gtids})"
            sql "${node}" "RESET MASTER" >/dev/null
        fi
    done

    echo "configuring recovery channel"
    sql mysql-1 "CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${REPL_PASS}';
                 GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';" >/dev/null
    for node in "${NODES[@]}"; do
        sql "${node}" "STOP GROUP_REPLICATION" >/dev/null 2>&1 || true
        sql "${node}" "CHANGE REPLICATION SOURCE TO SOURCE_USER='repl', SOURCE_PASSWORD='${REPL_PASS}'
                       FOR CHANNEL 'group_replication_recovery'" >/dev/null
    done

    echo "bootstrapping MGR on mysql-1"
    sql mysql-1 "SET GLOBAL group_replication_bootstrap_group=ON;
                 START GROUP_REPLICATION;
                 SET GLOBAL group_replication_bootstrap_group=OFF;"

    for _ in $(seq 1 20); do
        [[ "$(online_count)" -ge 1 ]] && break
        sleep 1
    done

    for node in mysql-2 mysql-3; do
        echo "joining ${node}"
        sql "${node}" "START GROUP_REPLICATION;" >/dev/null 2>&1 || true
    done
fi

for _ in $(seq 1 60); do
    [[ "$(online_count)" == "3" ]] && break
    sleep 2
done

if [[ "$(online_count)" != "3" ]]; then
    echo "WARN: MGR 未在 120s 内回到 3 ONLINE；成员状态如下" >&2
fi

# ---- 元数据（Router 依赖）：首次 adoptFromGR，之后 rescan 补上重启的节点
primary="$(primary_node || true)"
if [[ -n "${primary}" ]]; then
    if mysqlsh_cmd "${primary}" "dba.getCluster('${CLUSTER_NAME}')" >/dev/null 2>&1; then
        echo "refreshing InnoDB Cluster metadata on ${primary}"
        mysqlsh_cmd "${primary}" "dba.getCluster('${CLUSTER_NAME}').rescan()" >/dev/null || true
    else
        echo "creating InnoDB Cluster metadata (adoptFromGR) on ${primary}"
        mysqlsh_cmd "${primary}" "dba.createCluster('${CLUSTER_NAME}', {adoptFromGR: true})" >/dev/null || true
    fi
fi

sql "${primary:-mysql-1}" "CREATE DATABASE IF NOT EXISTS nacos_config" >/dev/null
sql "${primary:-mysql-1}" "SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members"

# ---- Router：首次起容器时元数据还没就绪，Router 用的是静态兜底配置；
# 元数据就绪后重启一次，让它按 metadata-cache 跟随 primary。
for router in mysql-router-1 mysql-router-2; do
    docker inspect -f '{{.State.Running}}' "${router}" 2>/dev/null | grep -q true || continue
    if ! docker exec "${router}" test -f "/data/${router}/bootstrap/mysqlrouter.conf" 2>/dev/null; then
        echo "restarting ${router} to pick up metadata routing"
        docker restart "${router}" >/dev/null
    fi
done
