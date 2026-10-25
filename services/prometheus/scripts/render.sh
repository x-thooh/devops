#!/usr/bin/env bash
# 渲染 prometheus：scrape_configs 全部由 ini 生成（exporter 行 + 原生指标固定表）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

MODE="${1:-solo}"
ACTIVE="${STACK_DIR}/data/active"
ensure_dir "${ACTIVE}"

am_target="$(ip_of alertmanager):9093"
prom_targets=""
for row in $(services_of prometheus "${MODE}"); do
    prom_targets+="${prom_targets:+, }'$(ip_of "${row}"):9090'"
done
grafana="$(ip_of grafana):3000"
jaeger="$(ip_of jaeger):8888"

# 目标只列“该栈当前形态真会起的节点”：否则 solo 形态的栈会把它那些
# 不该存在的副本节点长期报成 down，看板上分不清故障与未部署（DEC-47）。
is_active() {
    local profile="$1" name="$2" active
    active=" $(services_of "${profile}" "$(deployed_mode "${profile}")") "
    [[ "${active}" == *" ${name} "* ]]
}

redis_targets() {
    local profile="$1" out=""
    for row in $(rows_of "${profile}"); do
        IFS='|' read -r name ip ports role _mode <<<"${row}"
        [[ "${role}" == "exporter" ]] && continue
        # sentinel 口不抓（DEC-49）：/scrape 中继只有一份共享 REDIS_PASSWORD，
        # 而 sentinel 自己不设密码（只用 auth-pass 连 master），带密码去连它会 AUTH 失败，
        # 于是三个 sentinel 永远报 redis_up=0 —— 又是一个分不清真故障的假信号。
        [[ "${role}" == "sentinel" ]] && continue
        is_active "${profile}" "${name}" || continue
        out+="${out:+, }'${ip}:${ports%%,*}'"
    done
    echo "${out}"
}

hosts_of() {
    local profile="$1" roles="$2" port="$3" out="" name ip _ports role _mode
    for row in $(rows_of "${profile}"); do
        IFS='|' read -r name ip _ports role _mode <<<"${row}"
        [[ ",${roles}," == *",${role},"* ]] || continue
        is_active "${profile}" "${name}" || continue
        out+="${out:+, }'${ip}:${port}'"
    done
    echo "${out}"
}

for row in $(rows_of prometheus); do
    IFS='|' read -r name ip _ports _role _mode <<<"${row}"
    ensure_dir "${ACTIVE}/${name}"
    if [[ "${MODE}" == "solo" ]]; then
        tsdb="/data/solo/tsdb"
    else
        tsdb="/data/${name}/tsdb"
    fi
    ensure_dir "${STACK_DIR}${tsdb}"

    cat >"${ACTIVE}/${name}/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    instance: ${name}

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['${am_target}']

scrape_configs:
  - job_name: pg
    static_configs:
      - targets: ['$(ip_of pg-exporter):9187']
  - job_name: redis-sentinel
    metrics_path: /scrape
    static_configs:
      - targets: [$(redis_targets redis-sentinel)]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: '$(ip_of redis-sentinel-exporter):9121'
  - job_name: redis-cluster
    metrics_path: /scrape
    static_configs:
      - targets: [$(redis_targets redis-cluster)]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: '$(ip_of redis-cluster-exporter):9121'
  - job_name: mysql
    static_configs:
      - targets: ['$(ip_of mysql-exporter):9104']
  - job_name: mongo
    static_configs:
      - targets: ['$(ip_of mongo-exporter):9216']
  - job_name: kafka
    static_configs:
      - targets: ['$(ip_of kafka-exporter):9308']
  - job_name: rocketmq
    static_configs:
      - targets: ['$(ip_of rmq-exporter):5557']
  - job_name: nats
    static_configs:
      - targets: ['$(ip_of nats-exporter):7777']
  - job_name: etcd
    static_configs:
      - targets: [$(hosts_of etcd member 2379)]
  - job_name: consul
    metrics_path: /v1/agent/metrics
    params:
      format: ['prometheus']
    static_configs:
      - targets: [$(hosts_of consul bootstrap,server 8500)]
  - job_name: rabbitmq
    static_configs:
      - targets: [$(hosts_of rabbitmq seed,member 15692)]
  - job_name: prometheus
    static_configs:
      - targets: [${prom_targets}]
  - job_name: alertmanager
    static_configs:
      - targets: ['${am_target}']
  - job_name: grafana
    static_configs:
      - targets: ['${grafana}']
  - job_name: jaeger
    static_configs:
      - targets: ['${jaeger}']
  - job_name: nacos
    metrics_path: /nacos/actuator/prometheus
    static_configs:
      - targets: [$(hosts_of nacos server 8848)]
EOF

    cat >"${ACTIVE}/${name}/entry.sh" <<EOF
#!/bin/sh
exec /bin/prometheus \\
  --config.file=/data/active/${name}/prometheus.yml \\
  --storage.tsdb.path=${tsdb} \\
  --web.external-url=http://prometheus.localhost/ \\
  --web.enable-lifecycle \\
  --storage.tsdb.retention.time=15d \\
  --storage.tsdb.retention.size=2GB
EOF
done

echo "rendered prometheus (${MODE})"
