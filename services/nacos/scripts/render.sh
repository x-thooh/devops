#!/usr/bin/env bash
# 渲染 nacos 3.x：server×3（只跑服务端）+ console×1（无状态前端）。
# 身份：cluster.conf 固定 IP、NACOS_SERVER_IP、token/identity 三节点一致、db.url 按形态切换。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/data/active"
ensure_dir "${ACTIVE}"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
TOKEN="${NACOS_TOKEN_SECRET_KEY:?NACOS_TOKEN_SECRET_KEY missing in env/.env}"
DB_PASS="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD missing in env/.env}"

servers=""
for row in $(rows_of nacos); do
    IFS='|' read -r name ip _ports role mode <<<"${row}"
    [[ "${role}" == "server" ]] || continue
    # solo 只写自己：ServerMemberManager 会去连列表里的每个节点，
    # 名单里留着未启动的 ha 节点会直接 SocketTimeout 启动失败。
    [[ "${MODE}" == "solo" && "${mode}" == "ha" ]] && continue
    servers+="${servers:+ }${ip}:8848"
done

if [[ "${MODE}" == "solo" ]]; then
    db_host="$(ip_of mysql-1)"
    db_port=3306
else
    db_host="$(ip_of mysql-router-1)"
    db_port=6446
fi
DB_PARAM="characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Shanghai"

common_env() {
    cat <<EOF
MODE=cluster
NACOS_SERVERS=${servers}
# 3.x 默认会走 address-server 查成员列表（没有 address server 就 3s 超时起不来），
# 显式指定 file，改用下面 CLUSTER_CONF 指向的 cluster.conf。
NACOS_CORE_MEMBER_LOOKUP_TYPE=file
NACOS_AUTH_ENABLE=false
NACOS_AUTH_TOKEN=${TOKEN}
NACOS_AUTH_IDENTITY_KEY=devops
NACOS_AUTH_IDENTITY_VALUE=devops-identity
SPRING_DATASOURCE_PLATFORM=mysql
MYSQL_DATABASE_NUM=1
MYSQL_SERVICE_HOST=${db_host}
MYSQL_SERVICE_PORT=${db_port}
MYSQL_SERVICE_DB_NAME=nacos_config
MYSQL_SERVICE_USER=root
MYSQL_SERVICE_PASSWORD=${DB_PASS}
MYSQL_SERVICE_DB_PARAM=${DB_PARAM}
EOF
}

for row in $(rows_of nacos); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    case "${role}" in
        server)
            ensure_dir "${ACTIVE}/${name}"
            ensure_dir "${STACK_DIR}/data/${name}/logs"
            : >"${ACTIVE}/${name}/cluster.conf"
            for peer in ${servers}; do
                echo "${peer}" >>"${ACTIVE}/${name}/cluster.conf"
            done
            {
                common_env
                cat <<EOF
NACOS_DEPLOYMENT_TYPE=server
NACOS_SERVER_IP=${ip}
CLUSTER_CONF=/data/active/${name}/cluster.conf
JVM_XMS=384m
JVM_XMX=384m
JVM_XMN=128m
EOF
            } >"${ACTIVE}/${name}.env"
            chmod 600 "${ACTIVE}/${name}.env"
            ;;
        console)
            ensure_dir "${ACTIVE}/${name}"
            : >"${ACTIVE}/${name}/cluster.conf"
            for peer in ${servers}; do
                echo "${peer}" >>"${ACTIVE}/${name}/cluster.conf"
            done
            {
                common_env
                cat <<EOF
NACOS_DEPLOYMENT_TYPE=console
NACOS_CONSOLE_PORT=8080
NACOS_SERVER_IP=${ip}
# console 是独立进程，靠 MEMBER_LIST 找服务端（镜像会转成 -Dnacos.member.list）
MEMBER_LIST=$(echo "${servers}" | tr ' ' ',')
CLUSTER_CONF=/data/active/${name}/cluster.conf
JVM_XMS=192m
JVM_XMX=192m
EOF
            } >"${ACTIVE}/${name}.env"
            chmod 600 "${ACTIVE}/${name}.env"
            ;;
    esac
done

echo "rendered nacos (${MODE}, db=${db_host}:${db_port})"
