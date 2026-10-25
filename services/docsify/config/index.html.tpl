<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <meta http-equiv="X-UA-Compatible" content="IE=edge,chrome=1" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0" />
    <title>@TITLE@</title>
    <meta name="description" content="docsify 只读浏览（内容源动态生成侧栏）" />
    <link rel="stylesheet" href="assets/vue.css" />
    <link rel="stylesheet" href="assets/toc.css" />
    <style>
      .app-name { width: 150px; }
      .page_toc { top: 12rem; }
      .app-sub-sidebar li:before { content: "○"; }
      @media screen and (max-width: 1300px) { .nav { display: none; } }
    </style>
  </head>

  <body class="body--ready">
    <div id="app">Loading...</div>
    <script>
      // 产物：services/docsify/.data/site/index.html（由 scripts/render.sh 从本模板生成）
      // 内容根 = /docs（站点壳）；实际内容以只读嵌套挂载挂到 /docs/content；
      // 侧栏 _sidebar.md 与首页 home.md 由容器内 config/entry.sh 按挂载内容动态生成。
      window.$docsify = {
        name: "@TITLE@",
        nameLink: "@BASEPATH@/",
        homepage: "home.md",
        notFoundPage: "home.md",
        auto2top: true,
        loadSidebar: "_sidebar.md",
        alias: {
          "/.*/_sidebar.md": "@BASEPATH@/_sidebar.md",
        },
        maxLevel: 4,
        subMaxLevel: 2,
        search: {
          maxAge: 86400000,
          paths: "auto",
          placeholder: "搜索",
          noData: "无结果",
          depth: 3,
          hideOtherSidebarContent: false,
        },
        toc: {
          scope: ".markdown-section",
          headings: "h2, h3, h4, h5, h6",
          title: "",
        },
      };
    </script>

    <script src="assets/docsify.min.js"></script>
    <script src="assets/search.min.js"></script>
    <script src="assets/zoom-image.min.js"></script>
    <script src="assets/toc.js"></script>
    <script src="assets/countable.min.js"></script>
  </body>
</html>
