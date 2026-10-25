#!/usr/bin/env bash
# 幂等引导：建管理用户（4.0 不再从 env 建用户）→ ha 等三节点组成集群。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
# shellcheck disable=SC1091
set -a; source "${DEVOPS_ROOT}/env/.env"; set +a
PASS="${RABBITMQ_PASSWORD:?RABBITMQ_PASSWORD missing in env/.env}"

# 就绪关口：await_startup 必须真正成功才能跑后续 rabbitmqctl（否则 Erlang 节点未起，
# list_users/add_user 会撞 "unable to perform an operation on node" 并被 set -e 打断）。
for _ in $(seq 1 30); do
    if docker exec rabbit-1 rabbitmqctl -q await_startup >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! docker exec rabbit-1 rabbitmqctl -q list_users 2>/dev/null | cut -f1 | grep -qx devops; then
    docker exec rabbit-1 rabbitmqctl -q add_user devops "${PASS}" >/dev/null
    docker exec rabbit-1 rabbitmqctl -q set_user_tags devops administrator >/dev/null
    docker exec rabbit-1 rabbitmqctl -q set_permissions -p / devops ".*" ".*" ".*" >/dev/null
    echo "created user devops"
fi

if [[ "${MODE}" == "ha" ]]; then
    for _ in $(seq 1 45); do
        # 用 JSON formatter 数 running_nodes：纯文本里节点名后面并没有 "running" 字样
        running="$(docker exec rabbit-1 rabbitmqctl -q cluster_status --formatter json 2>/dev/null |
            python3 -c 'import json,sys; print(len(json.load(sys.stdin)["running_nodes"]))' 2>/dev/null || true)"
        [[ "${running:-0}" -ge 3 ]] && break
        sleep 2
    done
fi

docker exec rabbit-1 rabbitmqctl -q cluster_status
