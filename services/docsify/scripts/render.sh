#!/usr/bin/env bash
# 渲染 docsify 站点壳：config/index.html.tpl + config/assets → .data/site/
# 产物落 .data/（DEC-11）；内容本体不复制，由 compose 只读挂载到 /docs/content。
# 侧栏/首页不在此生成：改由容器内 config/entry.sh 按实际挂载内容动态生成（见下）。
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

# 3) 侧栏/首页：不在此静态生成。改由容器启动时 config/entry.sh 按实际挂载的
#    /docs/content 动态生成 _sidebar.md / home.md 并周期重扫（内容源无关）。
#    删除旧版可能残留的静态侧栏，避免与运行时产物混淆。
rm -f "${SITE}/_sidebar.md"

echo "rendered docsify (site=${SITE#"${ROOT}/"}; 侧栏由容器动态生成)"
