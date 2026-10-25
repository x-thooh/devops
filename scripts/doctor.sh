#!/usr/bin/env bash
# doctor 包装：保持 docs/plan.md §4 约定的 scripts/doctor.sh 入口。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"      # 取 .venv 优先的 PATH（DEC-51）
exec python3 "${SCRIPT_DIR}/doctor.py" "$@"
