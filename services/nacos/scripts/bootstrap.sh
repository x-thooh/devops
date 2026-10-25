#!/usr/bin/env bash
# 幂等引导：等 server actuator 可访问；库表由 pre.sh 导入。
# 3.x 不再提供 v1 console readiness（404），actuator 才是真实存活探针。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
for row in $(rows_of nacos); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    case "${role}" in
        server)
            [[ "${MODE}" == "solo" && "${name}" != "nacos-server-1" ]] && continue
            for _ in $(seq 1 45); do
                curl -sf -o /dev/null "http://${ip}:8848/nacos/actuator/prometheus" && break
                sleep 2
            done
            printf '%s: ' "${name}"
            curl -sf -o /dev/null -w 'actuator %{http_code}\n' \
                "http://${ip}:8848/nacos/actuator/prometheus" || echo "actuator down"
            ;;
        console)
            for _ in $(seq 1 30); do
                curl -sf -o /dev/null "http://${ip}:8080/" && break
                sleep 2
            done
            printf '%s: ' "${name}"
            curl -sf -o /dev/null -w 'console %{http_code}\n' "http://${ip}:8080/" || echo "console down"
            ;;
    esac
done
