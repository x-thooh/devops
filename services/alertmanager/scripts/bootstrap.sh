#!/usr/bin/env bash
# 幂等引导：等 /-/ready。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ip="$(ip_of alertmanager)"
for _ in $(seq 1 20); do
    curl -sf -o /dev/null "http://${ip}:9093/-/ready" && break
    sleep 2
done
printf 'alertmanager: '
curl -sf -o /dev/null -w 'ready %{http_code}\n' "http://${ip}:9093/-/ready"
