#!/usr/bin/env bash
# nginx 无状态：停容器后清掉生成的路由配置并重新渲染。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${STACK_DIR}/../.." && pwd)"
cd "${ROOT}"

rm -f "${STACK_DIR}/.data/conf.d"/*.conf
"${SCRIPT_DIR}/render.sh"
echo "nginx reset: generated route config cleared; run stack-up to restart"
