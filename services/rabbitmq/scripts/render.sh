#!/usr/bin/env bash
# 渲染 rabbitmq：solo 单节点 / ha 三节点 quorum queue。
# 身份：固定 hostname、erlang cookie 一致、classic_config 静态 peer discovery。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/.data/active"
ensure_dir "${ACTIVE}"

# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
COOKIE="${RABBITMQ_ERLANG_COOKIE:?RABBITMQ_ERLANG_COOKIE missing in env/.env}"

for row in $(rows_of rabbitmq); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    ensure_dir "${ACTIVE}/${name}"
    if [[ "${MODE}" == "solo" ]]; then
        base="/data/solo"
    else
        base="/data/${name}"
    fi
    ensure_dir "${STACK_DIR}${base}"
    chmod 777 "${STACK_DIR}${base}"

    {
        cat <<EOF
default_queue_type = quorum
prometheus.tcp.port = 15692
EOF
        if [[ "${MODE}" == "ha" ]]; then
            cat <<EOF
cluster_formation.peer_discovery_backend = classic_config
cluster_formation.classic_config.nodes.1 = rabbit@rabbit-1
cluster_formation.classic_config.nodes.2 = rabbit@rabbit-2
cluster_formation.classic_config.nodes.3 = rabbit@rabbit-3
EOF
        fi
    } >"${ACTIVE}/${name}/rabbitmq.conf"

    printf '[rabbitmq_management,rabbitmq_prometheus].\n' >"${ACTIVE}/${name}/enabled_plugins"

    cat >"${ACTIVE}/${name}.env" <<EOF
RABBITMQ_NODENAME=rabbit@${name}
RABBITMQ_ERLANG_COOKIE=${COOKIE}
RABBITMQ_CONFIG_FILE=/data/active/${name}/rabbitmq.conf
RABBITMQ_ENABLED_PLUGINS_FILE=/data/active/${name}/enabled_plugins
RABBITMQ_MNESIA_BASE=${base}/mnesia
RABBITMQ_LOG_BASE=${base}/log
RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS=-kernel inet_dist_listen_min 35672 inet_dist_listen_max 35682
EOF
    chmod 600 "${ACTIVE}/${name}.env"
done

echo "rendered rabbitmq (${MODE})"
