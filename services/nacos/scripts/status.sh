#!/usr/bin/env bash
# nacos 状态：server 存活 + 关键指标 + console 首页。
# 3.x 默认关闭了 v1/v2 console 与 operator API（返回 404/410），
# 唯一稳定的免鉴权探针是 actuator：/nacos/actuator/prometheus。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${2:-solo}"
for row in $(rows_of nacos); do
    IFS='|' read -r name ip _ports role _mode <<<"${row}"
    case "${role}" in
        server)
            [[ "${MODE}" == "solo" && "${name}" != "nacos-server-1" ]] && continue
            printf '%s: ' "${name}"
            curl -sf -o /dev/null -w 'actuator %{http_code}\n' \
                "http://${ip}:8848/nacos/actuator/prometheus" || echo "down"
            curl -s "http://${ip}:8848/nacos/actuator/prometheus" |
                grep -E 'name="(configCount|serviceCount|longConnection)"' || true
            ;;
        console)
            printf '%s: ' "${name}"
            curl -sf -o /dev/null -w 'console %{http_code}\n' "http://${ip}:8080/" || echo "down"
            ;;
    esac
done
