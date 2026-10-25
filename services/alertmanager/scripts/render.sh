#!/usr/bin/env bash
# 渲染 alertmanager：receiver 固定 nul（不外发），存储与 external-url 写死。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ACTIVE="${STACK_DIR}/.data/active"
ensure_dir "${ACTIVE}/alertmanager"
ensure_dir "${STACK_DIR}/.data/alertmanager"

cat >"${ACTIVE}/alertmanager/alertmanager.yml" <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: nul
  group_by: [alertname, instance]
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h

receivers:
  - name: nul
EOF

cat >"${ACTIVE}/alertmanager/entry.sh" <<'EOF'
#!/bin/sh
exec /bin/alertmanager \
  --config.file=/data/active/alertmanager/alertmanager.yml \
  --storage.path=/data/alertmanager \
  --web.external-url=http://alertmanager.localhost/ \
  --web.listen-address=0.0.0.0:9093
EOF

echo "rendered alertmanager"
