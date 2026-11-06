#!/usr/bin/env bash
# 幂等建库：hindsight 的存储后端在 pg 栈（DEC-55）。三件事按顺序做，重复调用无副作用：
#   1) role hindsight（存在则改密）
#   2) database hindsight（owner=hindsight）
#   3) CREATE EXTENSION vector（在 hindsight 库内；pgvector 0.8，镜像见 services/pg/Dockerfile）
# 跨栈依赖：pg 未起 → 直接失败并给出补救命令（同 nacos → mysql 的 R25 口径，比 crash loop 更早暴露）。
# 写路径：ha 走 pg-haproxy-1:5000（自动路由到 leader），solo 走 patroni-1:5432（trust 认证，密码被忽略但保留同一份 URL）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
DB_PASS="${HINDSIGHT_DB_PASSWORD:?HINDSIGHT_DB_PASSWORD missing in env/.env}"
PG_PASS="${PG_SUPERUSER_PASSWORD:?PG_SUPERUSER_PASSWORD missing in env/.env}"

if [[ "${MODE}" == "solo" ]]; then
    db_host="$(ip_of patroni-1)"; db_port=5432
else
    db_host="$(ip_of pg-haproxy-1)"; db_port=5000
fi

if ! docker ps --format '{{.Names}}' | grep -qx patroni-1; then
    echo "ERROR: pg 栈未运行；hindsight 的存储在 pg 上（DEC-55），请先 make stack-up S=pg MODE=${MODE}" >&2
    exit 1
fi

pg() {
    # ${1}=database, 其余 = SQL 片段（多条 -c 各自独立事务，CREATE DATABASE 不能在事务里）
    local dbname="$1"; shift
    docker exec -e PGPASSWORD="${PG_PASS}" patroni-1 \
        psql -h "${db_host}" -p "${db_port}" -U postgres -d "${dbname}" \
        -v ON_ERROR_STOP=1 -q "$@"
}

# 探一次可达：pg-haproxy 只在 MGR 之类没有的场景，这里是 haproxy 起来但后端未选主时也会连不上；
# 与 DEC-52 的两段式一致，pre 只负责"起前引导"，容器起来的 wait 归 bootstrap。
if ! pg_isready_out="$(docker exec -e PGPASSWORD="${PG_PASS}" patroni-1 \
        pg_isready -h "${db_host}" -p "${db_port}" -U postgres 2>&1)"; then
    echo "ERROR: 无法连接 pg（${db_host}:${db_port}）：${pg_isready_out}" >&2
    echo "       先 make stack-up S=pg MODE=${MODE}（ha 形态还要 Patroni 已选出 leader）" >&2
    exit 1
fi

# 1) role（hex 密码不含引号，直接内插；若换成任意字符密码要改走 \set 变量）
pg postgres -c "DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='hindsight') THEN
        CREATE ROLE hindsight LOGIN PASSWORD '${DB_PASS}';
    ELSE
        ALTER ROLE hindsight WITH PASSWORD '${DB_PASS}';
    END IF;
END \$\$;"

# 2) database（CREATE DATABASE 不能在事务里；先查再建，psql 默认每条自动提交）
if ! pg postgres -tA -c "SELECT 1 FROM pg_database WHERE datname='hindsight'" | grep -qx 1; then
    echo "creating database hindsight (owner=hindsight)"
    pg postgres -c "CREATE DATABASE hindsight OWNER hindsight"
fi

# 3) extension（pgvector 是 trusted extension，但用 superuser 更保险；IF NOT EXISTS 幂等）
pg hindsight -c "CREATE EXTENSION IF NOT EXISTS vector"

ver="$(pg hindsight -tA -c "SHOW server_version")"
pvr="$(pg hindsight -tA -c "SELECT extversion FROM pg_extension WHERE extname='vector'")"
echo "hindsight db ready: postgres=${ver} pgvector=${pvr} @ ${db_host}:${db_port}"
