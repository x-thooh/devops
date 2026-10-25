#!/bin/sh
# docsify 入口包装：先按实际挂载内容生成一次侧栏/首页（保证 serve 起来即有目录），
# 再起后台 watch 循环随文件增删周期刷新，最后 exec docsify 作为 PID 1（优雅停止）。
# 内容源无关：/docs/content 挂什么都自适应。生成器见同目录 gen-sidebar.js。
set -e

GEN="/opt/docsify/gen-sidebar.js"

# 1) 首次同步生成（失败不阻断启动：最差是空侧栏，页面仍起）
node "${GEN}" once || true

# 2) 后台周期性重扫，反映挂载内容变化
node "${GEN}" watch &

# 3) 前台起 docsify，接管为 PID 1
cd /docs
exec docsify serve .
