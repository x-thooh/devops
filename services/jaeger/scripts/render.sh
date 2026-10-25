#!/usr/bin/env bash
# 渲染 jaeger v2（OTel Collector 发行版）：OTLP 接入 + Badger + 查询 UI。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ACTIVE="${STACK_DIR}/data/active"
ensure_dir "${ACTIVE}/jaeger"
ensure_dir "${STACK_DIR}/data/jaeger/badger/keys"
ensure_dir "${STACK_DIR}/data/jaeger/badger/values"

cat >"${ACTIVE}/jaeger/config.yml" <<'EOF'
service:
  extensions: [jaeger_storage, jaeger_query, healthcheckv2]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [jaeger_storage_exporter]
  telemetry:
    resource:
      service.name: jaeger
    metrics:
      level: detailed
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888

extensions:
  healthcheckv2:
    use_v2: true
    http:
      endpoint: 0.0.0.0:13133
  jaeger_query:
    storage:
      traces: badger_store
    base_path: /
  jaeger_storage:
    backends:
      badger_store:
        badger:
          directories:
            keys: /data/jaeger/badger/keys
            values: /data/jaeger/badger/values
          ephemeral: false
          ttl:
            spans: 72h

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:

exporters:
  jaeger_storage_exporter:
    trace_storage: badger_store
EOF

echo "rendered jaeger"
