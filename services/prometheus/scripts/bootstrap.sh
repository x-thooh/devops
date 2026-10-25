#!/usr/bin/env bash
# 幂等引导：等 /-/ready 就绪；不修改配置（配置由 render.sh 生成）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
for row in $(rows_of prometheus); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    [[ "${MODE}" == "solo" && "${name}" != "prometheus-1" ]] && continue
    for _ in $(seq 1 30); do
        curl -sf -o /dev/null "http://${ip}:9090/-/ready" && break
        sleep 2
    done
    printf '%s: ' "${name}"
    curl -sf "http://${ip}:9090/-/ready" && echo
done
