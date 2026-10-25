#!/usr/bin/env bash
# 启动前钩子：nacos 的库表在 mysql；镜像自带 3.x schema，首次启动前导入一次。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

if ! docker ps --format '{{.Names}}' | grep -qx mysql-1; then
    echo "WARN: mysql-1 未运行；nacos 需要 MySQL，请先 make stack-up S=mysql" >&2
    exit 0
fi

if docker exec mysql-1 sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h127.0.0.1 -uroot -N -e "select 1 from nacos_config.config_info limit 1"' \
    >/dev/null 2>&1; then
    exit 0
fi

echo "importing nacos 3.x schema into mysql-1:nacos_config"
docker exec -i mysql-1 sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h127.0.0.1 -uroot -e "CREATE DATABASE IF NOT EXISTS nacos_config DEFAULT CHARACTER SET utf8mb4"'
docker exec -i mysql-1 sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h127.0.0.1 -uroot nacos_config' \
    <"${STACK_DIR}/config/mysql-schema.sql"
