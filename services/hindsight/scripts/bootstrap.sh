#!/usr/bin/env bash
# 幂等引导：等 hindsight API /health 就绪。
# 存储后端在 pg 栈（DEC-55）：role/db/pgvector 扩展已由 scripts/pre.sh 建好，
# 本钩子只覆盖容器起来后 hindsight 首次连外部 PG 跑 schema migrate 的窗口。
# 就绪信号只认 /health：provider/key 缺失不影响服务启动，只在 retain/recall 时显形，
# 因此这里不拿 LLM 调用当判据（否则 mock 之外的配置会把"能跑"误判成失败）。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ip="$(ip_of hindsight)"
api_port="$(port_of hindsight)"   # ini 第一个端口 = 8888（API）；9999 是 Control Plane

ready=""
for _ in $(seq 1 30); do
    if curl -sf -o /dev/null "http://${ip}:${api_port}/health"; then
        ready=1
        break
    fi
    sleep 3
done

api="$(curl -s -o /dev/null -w '%{http_code}' "http://${ip}:${api_port}/health" || true)"
cp="$(curl -s -o /dev/null -w '%{http_code}' "http://${ip}:9999/" || true)"
echo "hindsight: api(/health)=${api:-000} cp(9999)=${cp:-000}"
if [[ -z "${ready}" ]]; then
    echo "ERROR: hindsight API 未就绪（外部 PG 不可达 / schema migrate 卡住 / 镜像或端口形态与假设不符：看 make stack-logs S=hindsight 与 make stack-status S=pg）" >&2
    exit 1
fi
