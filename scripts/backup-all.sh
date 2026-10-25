#!/usr/bin/env bash
# 归档所有 services/*/.data 子树（运行时身份与状态）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

mkdir -p backups
stamp="$(date +%Y%m%d-%H%M%S)"
list="$(mktemp -t devops-data-list)"
trap 'rm -f "${list}"' EXIT

find services -type d -name .data -prune -print > "${list}"
if [[ ! -s "${list}" ]]; then
    echo "no .data/ directories found"
    exit 0
fi

out="backups/data-${stamp}.tar.gz"
tar -czf "${out}" -T "${list}"
echo "wrote ${out} ($(du -h "${out}" | awk '{print $1}'))"
