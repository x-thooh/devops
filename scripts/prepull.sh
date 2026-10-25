#!/usr/bin/env bash
# 按聚合 compose 的镜像清单预拉（默认官方源；env 可覆盖）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

images="$(docker compose --env-file env/.env -f compose.generated.yml --profile '*' config --images | sort -u)"
if [[ -z "${images}" ]]; then
    echo "no images to pull"
    exit 0
fi
while IFS= read -r image; do
    echo "pull ${image}"
    docker pull "${image}"
done <<< "${images}"
