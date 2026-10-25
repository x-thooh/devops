#!/usr/bin/env bash
# 幂等引导：等站点根可读 + 内容挂载非空 + 侧栏已被容器动态生成（_sidebar.md 非空）。
# 侧栏不再绑具体文件名（内容源可能是仓库 docs/ 或外部笔记库），以“生成产物就位”为就绪信号。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ip="$(ip_of docsify-1)"

for _ in $(seq 1 30); do
    curl -sf -o /dev/null "http://${ip}:3000/" && break
    sleep 2
done

root="$(curl -s -o /dev/null -w '%{http_code}' "http://${ip}:3000/")"
assets="$(curl -s -o /dev/null -w '%{http_code}' "http://${ip}:3000/assets/docsify.min.js")"
# 内容就绪 = /docs/content 目录存在且非空；不绑具体文件名（宿主挂空目录会被 bind mount 自动建成空 dir，据此判定"没挂上"）
if docker exec docsify-1 sh -c '[ -n "$(ls -A /docs/content 2>/dev/null)" ]' >/dev/null 2>&1; then
    content="mounted"
else
    content="empty"
fi
# 侧栏就绪 = 容器内 entry.sh 已按挂载内容动态生成 /_sidebar.md 且非空（异步，需轮询等待）
sidebar="empty"
for _ in $(seq 1 15); do
    body="$(curl -s "http://${ip}:3000/_sidebar.md")"
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://${ip}:3000/_sidebar.md")"
    if [[ "${code}" == "200" && -n "${body}" ]]; then
        sidebar="generated"
        break
    fi
    sleep 2
done
echo "docsify: root=${root} content=${content} sidebar=${sidebar} assets=${assets}"
if [[ "${root}" != "200" || "${content}" != "mounted" || "${sidebar}" != "generated" || "${assets}" != "200" ]]; then
    echo "ERROR: docsify 未就绪（content=empty=内容没挂上；sidebar=empty=entry.sh 未生成侧栏；root/assets!=200=render 未跑或站点壳缺失）" >&2
    exit 1
fi
