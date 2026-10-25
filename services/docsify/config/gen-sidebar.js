/*
 * docsify 动态侧栏生成器（无第三方依赖，仅 node 内置 fs/path）。
 * 按“实际挂载的内容目录”生成 _sidebar.md / home.md —— 与内容源无关：
 * 挂仓库 docs/ 或外部笔记库都适用；watch 模式周期性重扫，随文件增删自动刷新，
 * 因此不必再靠 `make render` 把侧栏烤死成某个固定文件名清单。
 *
 * 可调项全部走环境变量（在 compose 里覆盖即可，无需改代码）：
 *   DOCSIFY_CONTENT_DIR  内容根        默认 /docs/content
 *   DOCSIFY_OUT_DIR      产物目录      默认 /docs（站点壳，可写）
 *   DOCSIFY_BASE_PATH    站点内前缀    默认 content（侧栏链接前缀）
 *   DOCSIFY_TITLE        站点标题      默认 文档
 *   DOCSIFY_MAX_DEPTH    最大目录深度  默认 3
 *   DOCSIFY_PER_DIR_CAP  单目录条目数  默认 200
 *   DOCSIFY_TOTAL_CAP    全局条目上限  默认 3000
 *   DOCSIFY_REGEN_SEC    重扫周期(秒)  默认 15
 *   DOCSIFY_SKIP_DIRS    跳过的目录名  逗号分隔
 */
'use strict';
const fs = require('fs');
const path = require('path');

const CONTENT = process.env.DOCSIFY_CONTENT_DIR || '/docs/content';
const OUT     = process.env.DOCSIFY_OUT_DIR     || '/docs';
const BASE    = process.env.DOCSIFY_BASE_PATH   || 'content';
const TITLE   = process.env.DOCSIFY_TITLE       || '文档';
const MAXD    = parseInt(process.env.DOCSIFY_MAX_DEPTH || '3', 10);
const PCAP    = parseInt(process.env.DOCSIFY_PER_DIR_CAP || '200', 10);
const TCAP    = parseInt(process.env.DOCSIFY_TOTAL_CAP || '3000', 10);
const INTERVAL= parseInt(process.env.DOCSIFY_REGEN_SEC || '15', 10) * 1000;
const SKIP    = new Set(
  (process.env.DOCSIFY_SKIP_DIRS ||
    'node_modules,.obsidian,.git,.agents,assets,99_附件（Attachments）')
    .split(',').map((s) => s.trim()).filter(Boolean)
);

function hiddenOrSkip(name) {
  return name.startsWith('.') || SKIP.has(name);
}

// 侧栏链接：相对内容根，逐段 encodeURIComponent（空格/中文安全），括号等 URL 允许字符保留
function href(rel) {
  return BASE + '/' + rel.split('/').map(encodeURIComponent).join('/');
}

let total = 0;
function walk(dir, relBase, depth, lines) {
  let ents;
  try {
    ents = fs.readdirSync(dir, { withFileTypes: true });
  } catch (e) {
    return;
  }
  ents.sort((a, b) => a.name.localeCompare(b.name, 'zh'));
  const dirs = [];
  const files = [];
  for (const e of ents) {
    if (hiddenOrSkip(e.name)) continue;
    if (e.isDirectory()) dirs.push(e.name);
    else if (e.isFile() && /\.md$/i.test(e.name)) files.push(e.name);
  }
  let shown = 0;
  for (const f of files) {
    if (total >= TCAP || shown >= PCAP) break;
    const rel = relBase ? relBase + '/' + f : f;
    lines.push('  '.repeat(depth) + `- [${f.replace(/\.md$/i, '')}](${href(rel)})`);
    total++; shown++;
  }
  if (depth < MAXD) {
    for (const d of dirs) {
      if (total >= TCAP) break;
      const rel = relBase ? relBase + '/' + d : d;
      const sub = [];
      walk(path.join(dir, d), rel, depth + 1, sub);
      if (sub.length === 0) continue; // 空分支或被裁掉的不显示
      lines.push('  '.repeat(depth) + `- ${d}`);
      for (const l of sub) lines.push('  ' + l);
    }
  }
}

// 原子写：先写临时文件再 rename，避免 docsify 读到半截
function writeAtomic(file, content) {
  const tmp = file + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, file);
}

function generate() {
  let present = false;
  try {
    present = fs.readdirSync(CONTENT).length > 0;
  } catch (e) {
    present = false;
  }

  if (!present) {
    // 内容没挂上/为空：给出明确提示而不是空白，便于定位
    writeAtomic(path.join(OUT, '_sidebar.md'), `- ${TITLE}\n- _（内容目录为空或未挂载）_\n`);
    writeAtomic(path.join(OUT, 'home.md'), `# ${TITLE}\n\n> 内容目录为空或未挂载。检查 compose 里 \`/docs/content\` 的挂载源。\n`);
    return;
  }

  total = 0;
  const lines = [];
  walk(CONTENT, '', 0, lines);
  writeAtomic(path.join(OUT, '_sidebar.md'), lines.join('\n') + '\n');

  // 首页：标题 + 顶层概览（顶层 md 直接给链接；子目录提示展开侧栏）
  const rootFiles = fs
    .readdirSync(CONTENT, { withFileTypes: true })
    .filter((e) => e.isFile() && /\.md$/i.test(e.name) && !hiddenOrSkip(e.name))
    .map((e) => e.name)
    .sort((a, b) => a.localeCompare(b, 'zh'));
  const home = [
    `# ${TITLE}`,
    '',
    rootFiles.length
      ? rootFiles.map((f) => `- [${f.replace(/\.md$/i, '')}](${href(f)})`).join('\n')
      : '_（顶层无 Markdown 文件，请从左侧目录树选择页面）_',
    '',
    `_侧栏随内容变化自动刷新，共 ${total} 个页面（最近生成 ${new Date().toISOString()}）_`,
    '',
  ].join('\n');
  writeAtomic(path.join(OUT, 'home.md'), home);
}

const mode = process.argv[2] || 'once';
if (mode === 'watch') {
  generate();
  setInterval(() => {
    try { generate(); } catch (e) { console.error('gen error', e.message); }
  }, INTERVAL);
} else {
  generate();
}
