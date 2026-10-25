#!/usr/bin/env bash
# 推一条 OTLP trace 给 jaeger（HTTP/JSON，4318），用于验证链路：jaeger → grafana。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

JAEGER_IP="$(ip_of jaeger)"
TRACE_ID="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
SPAN_ID="$(python3 -c 'import uuid; print(uuid.uuid4().hex[:16])')"
NOW_NS="$(python3 -c 'import time; print(time.time_ns())')"
END_NS="$(python3 -c 'import time; print(time.time_ns() + 5_000_000)')"

payload="$(
    cat <<EOF
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "trace-demo"}},
        {"key": "deployment.environment", "value": {"stringValue": "lab"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "devops.trace-demo", "version": "1.0.0"},
      "spans": [{
        "traceId": "${TRACE_ID}",
        "spanId": "${SPAN_ID}",
        "name": "make trace-demo",
        "kind": 1,
        "startTimeUnixNano": "${NOW_NS}",
        "endTimeUnixNano": "${END_NS}",
        "attributes": [
          {"key": "demo.source", "value": {"stringValue": "scripts/trace-demo.sh"}}
        ],
        "status": {"code": 1}
      }]
    }]
  }]
}
EOF
)"

code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data-binary "${payload}" \
    "http://${JAEGER_IP}:4318/v1/traces")"

if [[ "${code}" != "200" ]]; then
    echo "ERROR: OTLP ingest failed (HTTP ${code})" >&2
    exit 1
fi

echo "pushed trace ${TRACE_ID} (service=trace-demo)"
echo "jaeger: http://jaeger.localhost/trace/${TRACE_ID}"
