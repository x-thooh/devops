#!/usr/bin/env bash
# 幂等引导：等 query API 与自身指标就绪。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ip="$(ip_of jaeger)"
for _ in $(seq 1 30); do
    curl -sf -o /dev/null "http://${ip}:16686/api/services" && break
    sleep 2
done
printf 'jaeger query: '
curl -sf -o /dev/null -w '%{http_code}\n' "http://${ip}:16686/api/services"
printf 'jaeger metrics: '
curl -sf -o /dev/null -w '%{http_code}\n' "http://${ip}:8888/metrics"
