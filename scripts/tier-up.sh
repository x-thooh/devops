#!/usr/bin/env bash
# 档位启动：A–F / S。只启动已实现的 profile（services/<dir>/compose.yml 存在）。
# 用法：scripts/tier-up.sh [a|b|c|d|e|f|s]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"      # 取 .venv 优先的 PATH（DEC-51）

tier="${1:-a}"
case "${tier}" in
    a)
        entries=(
            nginx:solo pg:ha redis-sentinel:ha
            prometheus:solo alertmanager:solo grafana:solo jaeger:solo
        )
        ;;
    b)
        entries=(nginx:solo kafka:ha rabbitmq:ha prometheus:solo alertmanager:solo grafana:solo jaeger:solo)
        ;;
    c)
        entries=(nginx:solo rocketmq:ha mysql:ha prometheus:solo alertmanager:solo grafana:solo jaeger:solo)
        ;;
    d)
        entries=(nginx:solo redis-cluster:ha kafka:ha prometheus:solo alertmanager:solo grafana:solo jaeger:solo)
        ;;
    e)
        entries=(nginx:solo etcd:ha consul:ha nats:ha prometheus:solo alertmanager:solo grafana:solo jaeger:solo)
        ;;
    f)
        entries=(nginx:solo nacos:ha mysql:ha prometheus:solo alertmanager:solo grafana:solo jaeger:solo)
        ;;
    s)
        entries=(
            nginx:solo pg:solo redis-sentinel:solo redis-cluster:solo mysql:solo mongo:solo
            kafka:solo rocketmq:solo rabbitmq:solo etcd:solo consul:solo nats:solo
            prometheus:solo alertmanager:solo grafana:solo jaeger:solo nacos:solo docsify:solo
        )
        ;;
    *)
        echo "ERROR: 未知档位 ${tier}（a|b|c|d|e|f|s）" >&2
        exit 2
        ;;
esac

python3 scripts/render-all.py

started=0
skipped=0
for entry in "${entries[@]}"; do
    profile="${entry%%:*}"
    mode="${entry##*:}"
    dir="$(python3 scripts/ini.py dir "${profile}")"
    if [[ ! -f "${ROOT}/services/${dir}/compose.yml" ]]; then
        echo "skip ${profile} (${mode}): services/${dir} 尚未实现"
        skipped=$((skipped + 1))
        continue
    fi
    "${SCRIPT_DIR}/stack.sh" up "${profile}" "${mode}"
    started=$((started + 1))
done

echo "tier ${tier}: started ${started} profile(s), skipped ${skipped} not implemented"
if [[ ${started} -eq 0 ]]; then
    exit 1
fi
