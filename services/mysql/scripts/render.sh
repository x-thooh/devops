#!/usr/bin/env bash
# 渲染 mysql 实例配置：solo 单实例 / ha MGR 三节点（Router 仅 ha 启动）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/data/active"
ensure_dir "${ACTIVE}"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
ROOT_PASS="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD missing in env/.env}"

GROUP_UUID_FILE="${ACTIVE}/mgr-group.uuid"
ensure_secret "${GROUP_UUID_FILE}" python3 -c 'import uuid; print(uuid.uuid4())'
GROUP_UUID="$(cat "${GROUP_UUID_FILE}")"

seeds=""
for row in $(rows_of mysql); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "mgr-member" ]] || continue
    seeds+="${seeds:+,}${ip}:33061"
done

server_id=0
for row in $(rows_of mysql); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "mgr-member" ]] && { server_id=$((server_id + 1)); } || continue
    if [[ "${MODE}" == "solo" ]]; then
        data_dir="/data/solo/data"
    else
        data_dir="/data/${name}/data"
    fi
    ensure_dir "${STACK_DIR}${data_dir}"
    ensure_dir "${ACTIVE}/${name}"

    cat >"${ACTIVE}/${name}/my.cnf" <<EOF
[mysqld]
server_id=${server_id}
datadir=${data_dir}
socket=/tmp/mysql.sock
bind_address=0.0.0.0
port=3306
character-set-server=utf8mb4
collation-server=utf8mb4_0900_ai_ci
innodb_buffer_pool_size=128M
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_format=ROW
log_replica_updates=ON
relay_log=relay-bin
skip_name_resolve=ON
mysqlx=OFF
EOF
    if [[ "${MODE}" == "ha" ]]; then
        # MEMBER_HOST 默认是容器 ID，写死成节点名便于读
        # loose_ 前缀：entrypoint 的 --initialize 阶段 GR 插件尚未加载，
        # 直接写 group_replication_* 会因 unknown variable 中断初始化。
        cat >>"${ACTIVE}/${name}/my.cnf" <<EOF
report_host=${name}
plugin_load_add=group_replication.so
loose_group_replication_group_name=${GROUP_UUID}
loose_group_replication_start_on_boot=OFF
loose_group_replication_local_address=${ip}:33061
loose_group_replication_group_seeds=${seeds}
loose_group_replication_bootstrap_group=OFF
loose_group_replication_single_primary_mode=ON
loose_group_replication_recovery_get_public_key=ON
loose_group_replication_recovery_use_ssl=OFF
loose_group_replication_message_cache_size=128M
EOF
    fi

    cat >"${ACTIVE}/${name}.env" <<EOF
MYSQL_ROOT_PASSWORD=${ROOT_PASS}
MYSQL_ROOT_HOST=%
EOF
    # ha 的库由 bootstrap 在成组后建（各节点本地建会造成 GTID 分叉）
    if [[ "${MODE}" == "solo" ]]; then
        echo "MYSQL_DATABASE=nacos_config" >>"${ACTIVE}/${name}.env"
    fi
    chmod 600 "${ACTIVE}/${name}.env"
    echo "rendered mysql ${name} (${MODE})"
done

printf '[client]\nhost=mysql-1\nport=3306\nuser=root\npassword=%s\n' "${ROOT_PASS}" >"${ACTIVE}/mysql-exporter.my.cnf"
chmod 600 "${ACTIVE}/mysql-exporter.my.cnf"

# ---- Router（ha）：metadata-cache 路由（solo 不启）。
# mysql:8.0 镜像自带 mysqlsh：bootstrap.sh 用 adoptFromGR 把 MGR 接管成 InnoDB Cluster，
# Router 启动时 --bootstrap 生成 metadata-cache 配置，6446 才会真正跟随 primary。
# （纯静态 first-available 只会连“第一个活节点”，主库挂了会连到只读库。）
members=""
seeds=""
for row in $(rows_of mysql); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "mgr-member" ]] || continue
    members+="${members:+,}${ip}:3306"
    seeds+="${seeds:+ }${ip}:3306"
done

rid=0
for row in $(rows_of mysql); do
    IFS='|' read -r name _ip _ports role _mode <<<"${row}"
    [[ "${role}" == "proxy" ]] || continue
    rid=$((rid + 1))
    ensure_dir "${ACTIVE}/${name}"
    ensure_dir "${STACK_DIR}/data/${name}"
    # 镜像以 uid 999 运行 mysqlrouter，bind mount 需可写
    chmod 0777 "${STACK_DIR}/data/${name}"

    # 元数据未就绪时的兜底：能启动、能过健康检查，bootstrap.sh 就绪后会重启切回 metadata 路由
    cat >"${ACTIVE}/${name}/fallback.conf" <<EOF
[DEFAULT]
logging_folder = /data/${name}/log
runtime_folder = /data/${name}/run
data_folder = /data/${name}/data

[logger]
level = INFO

[routing:primary]
bind_address = 0.0.0.0
bind_port = 6446
destinations = ${members}
routing_strategy = first-available

[routing:secondary]
bind_address = 0.0.0.0
bind_port = 6447
destinations = ${members}
routing_strategy = round-robin
EOF

    cat >"${ACTIVE}/${name}/entry.sh" <<EOF
#!/bin/bash
set -e
BASE=/data/${name}
CONF=\${BASE}/bootstrap/mysqlrouter.conf
mkdir -p "\${BASE}"
if [[ ! -f "\${CONF}" ]]; then
    # 等 bootstrap.sh 建好 InnoDB Cluster 元数据（容器先起、引导后跑）
    ok=""
    for _ in \$(seq 1 10); do
        for member in ${seeds}; do
            if mysqlrouter --bootstrap "root:${ROOT_PASS}@\${member}" \\
                --directory "\${BASE}/bootstrap" --force >/dev/null 2>&1; then
                ok=1
                break 2
            fi
        done
        sleep 4
    done
    if [[ -n "\${ok}" ]]; then
        # 只保留 ini 声明的 6446/6447：去掉 X protocol 与 http_server 段
        sed -i '/^\[routing:bootstrap_x_rw\]/,\$d' "\${CONF}"
        # 两个 router 的 router_id 必须不同
        sed -i "s/^router_id=.*/router_id=${rid}/" "\${CONF}"
    else
        echo "WARN: 元数据未就绪，先用静态兜底配置（bootstrap.sh 就绪后会重启切换）" >&2
        exec mysqlrouter --config "/data/active/${name}/fallback.conf"
    fi
fi
exec mysqlrouter --config "\${CONF}"
EOF
    chmod 700 "${ACTIVE}/${name}/entry.sh"
done
