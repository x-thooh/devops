#!/usr/bin/env bash
# 从 stock/network.ini 的 [routes] 生成 nginx server 块。
# 产物：services/nginx/.data/conf.d/<host>.conf（config/ 只放模板）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${STACK_DIR}/../.." && pwd)"
cd "${ROOT}"

CONF_DIR="${STACK_DIR}/.data/conf.d"
mkdir -p "${CONF_DIR}"
rm -f "${CONF_DIR}"/*.conf

count=0
while IFS='|' read -r host ip port capability; do
    host="$(echo "${host}" | xargs)"
    ip="$(echo "${ip}" | xargs)"
    port="$(echo "${port}" | xargs)"
    capability="$(echo "${capability}" | xargs)"
    [[ -n "${host}" ]] || continue
    if [[ ! "${host}" =~ ^[a-z0-9.-]+$ ]]; then
        echo "ERROR: invalid route host: ${host}" >&2
        exit 1
    fi
    if [[ ! "${ip}" =~ ^[0-9.]+$ || ! "${port}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: invalid route upstream: ${host} -> ${ip}:${port}" >&2
        exit 1
    fi

    cat > "${CONF_DIR}/${host}.conf" <<EOF
# generated from stock/network.ini [routes]; do not edit
# upstream: ${ip}:${port} (${capability})
server {
    listen 80;
    server_name ${host};

    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    proxy_connect_timeout 5s;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    proxy_buffering off;
    client_max_body_size 0;

    location / {
        proxy_pass http://${ip}:${port};
    }
}
EOF
    count=$((count + 1))
done < <(python3 scripts/ini.py routes)

echo "rendered ${count} nginx route(s) into ${CONF_DIR#"${ROOT}/"}"
