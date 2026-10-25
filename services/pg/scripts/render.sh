#!/usr/bin/env bash
# 渲染 pg：solo 单实例 postgres / ha Patroni×3 + etcd DCS×3 + HAProxy×2。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/data/active"
ensure_dir "${ACTIVE}"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
PASS="${PG_SUPERUSER_PASSWORD:?PG_SUPERUSER_PASSWORD missing in env/.env}"

dcs_hosts=""
etcd_cluster=""
for row in $(rows_of pg); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    if [[ "${role}" == "dcs" ]]; then
        dcs_hosts+="${dcs_hosts:+,}${ip}:2379"
        etcd_cluster+="${etcd_cluster:+,}${name}=http://${ip}:2380"
    fi
done

# ---- patroni / postgres
for row in $(rows_of pg); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "leader" || "${role}" == "replica" ]] || continue
    if [[ "${MODE}" == "solo" ]]; then
        data_dir="/data/solo/pgdata"
    else
        data_dir="/data/${name}/pgdata"
    fi
    ensure_dir "${STACK_DIR}${data_dir}"
    ensure_dir "${ACTIVE}/${name}"

    if [[ "${MODE}" == "solo" ]]; then
        cat >"${ACTIVE}/${name}/entry.sh" <<EOF
#!/bin/sh
set -e
mkdir -p "$(dirname "${data_dir}")"
chown -R postgres:postgres "$(dirname "${data_dir}")"
if [ ! -f "${data_dir}/PG_VERSION" ]; then
    gosu postgres initdb -D "${data_dir}" -U postgres --auth=trust >/dev/null
fi
exec gosu postgres postgres -D "${data_dir}" -c listen_addresses=0.0.0.0 -c unix_socket_directories=/tmp
EOF
    else
        cat >"${ACTIVE}/${name}/patroni.yml" <<EOF
scope: devops-pg
name: ${name}
restapi:
  listen: 0.0.0.0:8008
  connect_address: ${ip}:8008
etcd3:
  hosts: ${dcs_hosts}
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5
  users:
    admin:
      password: "${PASS}"
      options: [superuser]
postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${ip}:5432
  data_dir: ${data_dir}
  pgpass: /tmp/pgpass
  authentication:
    replication:
      username: replicator
      password: "${PASS}"
    superuser:
      username: postgres
      password: "${PASS}"
  parameters:
    unix_socket_directories: /tmp
EOF
        cat >"${ACTIVE}/${name}/entry.sh" <<EOF
#!/bin/sh
set -e
# OrbStack 的 virtiofs 上 chown 是空操作（容器里永远显示 root:root），
# 只能靠 chmod：父目录 0777 让 patroni 能落文件，pgdata 0700 通过 postgres 的权限校验。
mkdir -p "$(dirname "${data_dir}")"
chmod 0777 "$(dirname "${data_dir}")"
mkdir -p "${data_dir}"
chmod 0700 "${data_dir}"
exec gosu postgres patroni /data/active/${name}/patroni.yml
EOF
    fi
done

# ---- DCS（仅 ha 启动，配置照常渲染）
for row in $(rows_of pg); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "dcs" ]] || continue
    ensure_dir "${STACK_DIR}/data/${name}"
    ensure_dir "${ACTIVE}/${name}"
    cat >"${ACTIVE}/${name}/etcd.yml" <<EOF
name: ${name}
data-dir: /data/${name}
listen-client-urls: http://0.0.0.0:2379
advertise-client-urls: http://${ip}:2379
listen-peer-urls: http://0.0.0.0:2380
initial-advertise-peer-urls: http://${ip}:2380
initial-cluster: ${etcd_cluster}
initial-cluster-state: new
initial-cluster-token: devops-pg-dcs
EOF
done

# ---- HAProxy（ha）：5000=主，5001=只读，7000=stats
servers=""
for row in $(rows_of pg); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    [[ "${role}" == "leader" || "${role}" == "replica" ]] || continue
    servers+="    server ${name} ${ip}:5432 check port 8008"$'\n'
done
for row in $(rows_of pg); do
    IFS='|' read -r name _ip _ports role _mode <<<"${row}"
    [[ "${role}" == "proxy" ]] || continue
    ensure_dir "${ACTIVE}/${name}"
    cat >"${ACTIVE}/${name}/haproxy.cfg" <<EOF
global
    maxconn 200
    log stdout format raw local0

defaults
    mode tcp
    log global
    timeout connect 5s
    timeout client 30s
    timeout server 30s

listen postgres
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2
${servers}
listen postgres-ro
    bind *:5001
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2
${servers}
listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /
EOF
done

if [[ "${MODE}" == "solo" ]]; then
    target="$(ip_of patroni-1):5432"
else
    target="$(ip_of pg-haproxy-1):5000"
fi
printf 'DATA_SOURCE_NAME=postgresql://postgres:%s@%s/postgres?sslmode=disable\n' \
    "${PASS}" "${target}" >"${ACTIVE}/pg-exporter.env"
chmod 600 "${ACTIVE}/pg-exporter.env"

echo "rendered pg (${MODE})"
