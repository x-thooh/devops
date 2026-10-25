#!/usr/bin/env bash
# mysql 状态：solo ping / ha MGR 成员表。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
PASS="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD missing in env/.env}"

# 必须显式 -h 127.0.0.1：my.cnf 把 socket 改到 /data 下，走默认 socket 会报 ERROR 2002
if [[ "${MODE}" == "solo" ]]; then
    docker exec mysql-1 mysqladmin ping -h 127.0.0.1 -uroot -p"${PASS}" --silent
    docker exec mysql-1 mysql -h 127.0.0.1 -uroot -p"${PASS}" -N -B -e "SELECT @@server_id, @@gtid_mode, @@version"
    exit 0
fi

docker exec mysql-1 mysql -h 127.0.0.1 -uroot -p"${PASS}" -e \
    "SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members"
for node in mysql-router-1 mysql-router-2; do
    docker inspect -f '{{.State.Running}}' "${node}" 2>/dev/null | grep -q true || continue
    printf '%s rw/ro: ' "${node}"
    (exec 3<>"/dev/tcp/$(ip_of "${node}")/6446") 2>/dev/null && echo -n "6446 ok " || echo -n "6446 down "
    (exec 3<>"/dev/tcp/$(ip_of "${node}")/6447") 2>/dev/null && echo "6447 ok" || echo "6447 down"
done
