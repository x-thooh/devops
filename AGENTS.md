# AGENTS.md

> 面向**在本仓库里干活的 agent / 协作者**的操作契约。设计细节不在这里，在 [`docs/plan.md`](docs/plan.md)。
> 本文件只回答四件事：**什么能改、什么不能改、改完怎么验证、有分歧怎么办**。

---

## 0. 仓库现状

| 项 | 状态 |
|---|---|
| 已有内容 | `docs/`（方案与决策文档）；`base/`、`stock/network.ini`、`scripts/`（ini 解析 / render-all / doctor / stack / tier）、`Makefile`、`env/.env.example`、`README.md`；**17 个组件目录**（nginx / pg / redis / mysql / mongo / kafka / rocketmq / rabbitmq / etcd / consul / nats / nacos / prometheus / alertmanager / grafana / jaeger / docsify），`docs/stacks.md` 每栈一章 |
| 当前版本 | **plan v4.5**：15 域 / 17 目录 / 18 部署单元 / 28 → 71 容器（Nacos 3.x：server×3 + console；v4.4 加 docsify） |

### 0.1 文档层级（只读与可写要分清）

| 文件 | 角色 | 能否修改 |
|---|---|---|
| `docs/plan.md` | 唯一设计源（架构、IP、契约、ADR、风险） | ✅ 可改，但要同步 §11 ADR 与受影响表格 |
| `docs/pending-decisions.md` | 未定案决策（D/F/N 编号） | ✅ 可改；定案后把结论写回 plan ADR |
| `docs/archive/*` | 历史版本（v2.3 13 域、v3.2 缩容版） | ❌ **只读**，不要"顺手修正" |

---

## 1. 事实源与生成物

| 路径 | 角色 | 规则 |
|---|---|---|
| `stock/network.ini` | **IP / 端口 / 角色 / mode / 路由 的唯一权威** | 新增栈、改 IP、加路由**只能改这里** |
| `mise.toml` | 工具链唯一入口（`python = "3.12"`） | 解释器版本**只能**改这里，不要去改脚本里的 `python3` 调用（DEC-51） |
| `base/network.yml` | `devnet` 网段 | 全仓库唯一出现 `subnet:` 的地方 |
| `base/anchors.yml` | `logging` / `restart` / `TZ` / 健康检查默认 | 组件里出现同类字段 = 打回 |
| `base/images.yml` | 镜像唯一清单（官方源，`.env` 可覆盖） | compose 内禁止字面量 `image:` |
| `base/jvm/heap.env` | JVM 限堆 | kafka / rocketmq 引用 |
| `services/<stack>/compose.yml` | **手写骨架**（输入，入库） | 只写 `services` / `container_name` / `profiles` / `volumes` / `healthcheck` / `x-image`；禁止 `image` / `restart` / `logging` / `networks` / `TZ` |
| `services/<stack>/config/` | 配置**模板**（入库） | 只放模板，`render.sh` 产物不许写进来 |
| `services/<stack>/.data/` | 运行时状态（gitignore） | 永不入库；`**/.data/` 一条规则覆盖 |
| `.venv/` | 仓库内 Python 环境（生成物） | `make setup` 重建；依赖**不得**装进宿主解释器（DEC-51） |
| `.generated/<stack>.yml` | 单栈渲染结果（生成物） | 不提交；`render-all.py` 每次覆盖 |
| `compose.yml`、`compose.generated.yml` | 根聚合入口（生成物，两份同内容） | 手改无效，`render-all.sh` 会覆盖；不提交 |
| `services/nginx/.data/conf.d/`、`*/.data/**/prometheus.yml`、`sentinel.conf`、`nodes.conf` | 渲染产物 / 运行时重写 | 手改会被下一次 render 或重启冲掉 |

> **一句话**：`ini`、`base/`、`mise.toml`、`services/*/compose.yml` 与 `config/` 是输入；`.generated/`、根 `compose*.yml`、`.venv/` 与 `.data/` 是输出。只改输入。

---

## 2. 组件模型（改任何东西前先看这层）

| 层 | 单位 | 数量 | 你要动的文件 |
|---|---|---|---|
| 域 | `/24` IP 块 | 15 | `stock/network.ini` |
| 组件目录 | `services/<name>/` | 17 | `compose.yml` + `config/` + `scripts/` |
| 部署单元（profile） | `compose.yml` 的 `profiles` | 18 | 同上 |
| 容器 | service | 28 / 71 | 同上 |

- `services/redis/` 是**唯一复合栈**（一个目录两组互斥 profile）。它成立的四条硬条件见 plan §8.0.1，**不要再造第二个**，除非四条都满足。
- 新增组件的固定步骤：plan §17（ini 取预留块 → 建目录 → `render-all` → 可选加路由 → `doctor` 自动纳入）。

---

## 3. 硬规则（review 见到直接打回）

> plan §6 的「三大铁律」是设计层约束（不变量不下沉 / 端口校验 / doctor 15 项）；本节是**执行层**的 8 条，两者互补。

1. **不变量不下沉**：`subnet` / `gateway` / `logging` / `restart` / `TZ` / 字面量 `image:` 只允许出现在 `base/`。
2. **端口按"同一 IP 内不重复"校验**：不按宿主端口，因为除 nginx 外不发布。
3. **一个 service 必须带 profile**：否则任何 `up` 都会起它，破坏 redis 复合栈互斥（doctor 第 5 项判失败）。
4. **`config/` 只放模板**：运行时重写或含渲染 IP 的文件必须落 `.data/`（DEC-11）。
5. **宿主端口只有 `[stack.nginx]` 的 `nginx-1`**；其它 UI 一律经 `<svc>.localhost`（DEC-3 / DEC-42）。
6. **不改 `docs/archive/`**；不在容器内用 `.localhost`（R15）。
7. **演练只用 `docker compose stop`**，禁止 `docker kill`（DEC-17 / R12）。
8. **容器 `Up` ≠ 集群成立**：Docker daemon 重启只复活容器，不恢复集群不变量（如 mysql 的
   `group_replication_start_on_boot=OFF`）。按依赖顺序重跑 `make stack-up`（先 mysql 后 nacos），
   **不要**为了省事把 `start_on_boot` 改成 `ON`（DEC-48 / plan §8.4）。

---

## 4. 常用命令（P0 已可用）

```bash
make setup                # 首次 / 换机器必跑：mise 定 python 3.12 + 建 .venv + 装 PyYAML
make secrets                # 生成 env/.env（已存在则不动）
make doctor                 # 15 项体检；按"已启用的栈"取集合（第 15 项看运行态）
make render                 # ini → compose.generated.yml + 各栈配置
make up / make down         # 起停当前档位（默认 A）
make tier-s | tier-a..f     # 档位：solo 全栈 / 数据库 / 消息 / 重栈 / 组合 / 共识 / 注册配置
make stack-up     S=<profile> MODE=solo|ha
make stack-status S=<profile>
make stack-reset  S=<profile>   # 只清本 profile 的 .data/ 子树
make stack-shell  S=<profile> N=<node>
make failover-drill S=pg|redis-sentinel|redis-cluster|mysql|mongo|kafka|rocketmq
make ui-open S=grafana|jaeger|rabbitmq|consul|prometheus|alertmanager|nacos|docsify
make trace-demo             # 推一条 OTLP trace 给 jaeger
```

> `S` 填的是**部署单元名（profile）**，不是目录名：`redis` 目录下是 `redis-sentinel` / `redis-cluster`，**没有 `S=redis`**。
>
> `MODE` 省略时**不是 solo**：`stack.sh` 读 `.mode-<profile>` marker 沿用当前部署形态，从没部署过才回退 solo，并打印 `# MODE 未指定 -> <mode>`（DEC-50）。要换形态必须显式写 `MODE=solo|ha`。
> `stack-up` / `stack-reset` 是**两段式**：起容器 → `bootstrap` → 再等健康（DEC-52）——需要先 bootstrap 才转健康的栈（mysql 的 Router）若先 `--wait` 就永远等不到。

---

## 5. 标准工作流（改一个栈）

```text
1. 改输入       stock/network.ini（IP/端口/mode）或 services/<stack>/config/*.tpl
2. make render  生成 compose + 各栈真实配置（产物都进 .data/）
3. make stack-up S=<profile> MODE=solo   ← 先 solo 证"能跑"（省略 MODE 会沿用当前形态，DEC-50）
4. make stack-up S=<profile> MODE=ha     ← 再 ha 证"集群成立"，跑 failover-drill
5. make doctor  15 项；失败项按提示修，不要靠手工改生成物绕过
```

改完一个栈要同时更新：`docs/plan.md` 对应表格（§5 花名册 / §7 身份清单 / §9 资源）+ `docs/stacks.md` 的该栈章节（起停、验证命令、演练、重置、solo↔ha 语义差异、坑）。

---

## 6. 文档约定

- **语言**：中文；表格优先；章节引用一律用 `§x.y`，引用前确认目标章节存在（当前 §0–§17）。
- **编号只增不复用**：
  - ADR `DEC-1` … `DEC-52`（顺序即时间顺序）；
  - 风险 `R-n`（R9/R20/R21 已随范围删除，编号留空不复用）；
  - 决策 `D-n` / `F-n` / `N-n`（D 可作废但不重编号，如 D17）。
- **一处决策，三处同步**：`plan §11 ADR` + `pending-decisions`（标 ✅ 已定案）+ 受影响的表格/计数。
- **计数必须自洽**：改完跑一遍"域 / 目录 / 单元 / 容器 / 内存"五组数，确认 §0.1 沿革、§2.1、§5 总计、§9.1、§12 R2 一致。
- 提交前：`npx markdownlint-cli2 "docs/**/*.md"`（应 0 issues）。

---

## 7. 不要做的事

| ❌ 不要 | 原因 |
|---|---|
| 在 compose 里写 IP、镜像、`subnet`、`logging` | 与 ini / base 双份事实源，必漂移 |
| 手改 `compose.generated.yml`、`.data/` 下的 rendered 配置 | 下次 render / 重启即失效 |
| 猜镜像版本或端口 | 版本形态见 DEC-40；端口见 §6.2；不确定就写进 `pending-decisions` |
| 新增组件却不加 ini 行 / 不加 profile / 不写 bootstrap 探测 | `doctor` 第 4/5/11 项会失败，且 `backup-all` 漏数据 |
| 用 `docker kill` 做演练、或让 `restart:` 复活容器 | 会误判"切换成功" |
| 在容器之间用 `*.localhost` | 只有宿主浏览器能解析 |
| 静默改变已定案（D01/D02/D03/D08/D31 等） | 先改 ADR + pending，再改实现 |
| 把 `.data/`、`.env`、生成物提交进 git | `.gitignore` 已覆盖，提交前 `git status` 自查 |
| 把 Python 依赖装进宿主解释器（`pip install --break-system-packages` 等） | 宿主同时有 uv / mise / /usr/bin 三个 `python3`，不同 shell 会选不中同一个；依赖只进 `.venv`（`make setup`，DEC-51） |
| 把 `bootstrap` 排在 `compose up -d --wait` 之后 | 需要先引导才转健康的栈会死锁（实测 mysql：Router 等 MGR 有主，`--wait` 超时又挡住 bootstrap）；`up`/`reset` 均为两段式（DEC-52） |

---

## 8. 快速导航

| 想查 | 看 |
|---|---|
| 某个栈的 IP / 端口 / mode | plan §5.1 `stock/network.ini` |
| 某组件为什么要 HA、怎么选型 | plan §5.2 / §5.3（豁免） |
| 身份文件与"搞错会怎样" | plan §7 |
| 目录契约、bootstrap 探测、演练 | plan §8 |
| daemon 重启 / 宕机后怎么恢复 | plan §8.4（DEC-48） |
| 内存预算与限流 | plan §9 |
| 入口域名与路由 | plan §15 |
| 观测四栈（prom / am / grafana / jaeger） | plan §16 |
| 加一个新域 | plan §17 |
| 未定的事项 | `docs/pending-decisions.md` |
