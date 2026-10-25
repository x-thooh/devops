#!/usr/bin/env bash
# docsify 状态：站点根 + 侧栏 + 内容抽样。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ip="$(ip_of docsify-1)"

printf 'docsify: '
curl -sf -o /dev/null -w 'root %{http_code} ' "http://${ip}:3000/" || { echo "down"; exit 0; }
curl -sf -o /dev/null -w 'sidebar %{http_code} ' "http://${ip}:3000/_sidebar.md"
curl -sf -o /dev/null -w 'content %{http_code}\n' "http://${ip}:3000/content/plan.md"
