#!/usr/bin/env bash
# 渲染 docsify 站点壳：config/index.html.tpl + config/assets → .data/site/
# 产物落 .data/（DEC-11）；内容本体不复制，由 compose 只读挂载仓库 docs/ 到 /docs/content。
# docsify 无 solo/ha 之分，mode 参数只接收不使用。
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${STACK_DIR}/../../scripts/lib.sh"

ROOT="${DEVOPS_ROOT}"
SITE="${STACK_DIR}/.data/site"
ensure_dir "${SITE}"

TITLE="devops 本地栈"

# 1) index.html：替换 @TITLE@ / @BASEPATH@（BASEPATH 留空 = 站点根，内容挂在 /content）
sed -e "s|@TITLE@|${TITLE}|g" \
    -e "s|@BASEPATH@||g" \
    "${STACK_DIR}/config/index.html.tpl" >"${SITE}/index.html"

# 2) 前端资产：随镜像版本钉在 config/assets/（升级 docsify 时重新从镜像 /opt/docsify-template/assets 导出）
ensure_dir "${SITE}/assets"
cp -f "${STACK_DIR}"/config/assets/* "${SITE}/assets/"

# 3) 侧栏：按 docs/ 现有 markdown 生成（归档多一级，与 docs/ 目录形状一致）
{
    echo "- [${TITLE}](/)"
    for f in "${ROOT}"/docs/*.md; do
        [[ -e "${f}" ]] || continue
        name="$(basename "${f}")"
        echo "- [${name%.md}](content/${name})"
    done
    if compgen -G "${ROOT}/docs/archive/*.md" >/dev/null; then
        echo "- 归档"
        for f in "${ROOT}"/docs/archive/*.md; do
            [[ -e "${f}" ]] || continue
            name="$(basename "${f}")"
            echo "  - [${name%.md}](content/archive/${name})"
        done
    fi
} >"${SITE}/_sidebar.md"

echo "rendered docsify (site=${SITE#"${ROOT}/"}, docs=docs/)"
