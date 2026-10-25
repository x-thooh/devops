#!/usr/bin/env bash
# 幂等引导：等站点根与内容挂载都可读（内容不可读 = docs/ 没挂上，不是"没起"）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ip="$(ip_of docsify-1)"

for _ in $(seq 1 30); do
    curl -sf -o /dev/null "http://${ip}:3000/" && break
    sleep 2
done

root="$(curl -s -o /dev/null -w '%{http_code}' "http://${ip}:3000/")"
content="$(curl -s -o /dev/null -w '%{http_code}' "http://${ip}:3000/content/plan.md")"
assets="$(curl -s -o /dev/null -w '%{http_code}' "http://${ip}:3000/assets/docsify.min.js")"
echo "docsify: root=${root} content=${content} assets=${assets}"
if [[ "${root}" != "200" || "${content}" != "200" || "${assets}" != "200" ]]; then
    echo "ERROR: docsify 未就绪（content != 200 通常是 docs/ 未挂载或 render 未跑）" >&2
    exit 1
fi
