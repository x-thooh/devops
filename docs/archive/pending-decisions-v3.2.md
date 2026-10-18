# 待决事项清单（决策清单）

> 配套文档：`docs/plan.md`（**v3.2：Redis + 可观测性，全部按组件拆目录**）。本文件只列**未定案**的问题。
> 每项给出：问题 → 选项 → 我的推荐 → 影响面 → 阻塞阶段。
> **回复格式**：只需写 `D01=A, D31=A` 这样的键值即可；同意的推荐值写 `OK`。
>
> v2.3（13 域）版本的决策清单归档在 `docs/archive/pending-decisions-v2.3.md`；
> 与已移出域相关的 D09–D11、D13–D17 已作废（见 §3.1）。

---

## 0. 汇总统计

| 类别 | 数量 | 阻塞 |
|---|---|---|
| 阻塞 P0 | 8（D01–D08） | 不答无法开工 |
| Redis / 入口 / 观测 / 镜像 | 5（D12 / D18 / D19 / D33 / D34） | P0–P3 |
| 方案缺口 | 10（D20–D29 + D30–D32 中的有效项） | 建议 P0/P1 一并定 |
| 明确不做 | 10（N01–N10） | 已排除，供你否决 |
| 已定案（v3.2 关闭） | 19（F01–F19） | 已写入 plan v3.2 |
| 作废（域移出） | 8（D09–D11、D13–D17） | 无需回答 |

**最小决策集**：只答 **D01 / D02 / D03 / D08 / D31** 五项即可开始 P0。

---

## 1. 已定案（不需再讨论，仅备忘）

| # | 决策 | 出处 |
|---|---|---|
| F01 | 单一网络 `devnet` = `172.28.0.0/16`，网关 `.1` | plan §3.1 |
| F02 | 块号 = 域号（`.0.x` edge / `.2.x` 哨兵 / `.3.x` 集群 / `.12.x` 观测），其余块保留不分配 | plan §3.2 |
| F03 | 块内尾号约定（`.11–19` 核心 / `.21–29` 副本与哨兵 / `.31–39` 代理与前端 / `.41–49` exporter / `.51–59` 客户端） | plan §3.3 |
| F04 | 目录按组件内聚，不变量集中 `base/` | plan §2 |
| F05 | 数据放各组件 `data/`，`**/data/` 一条 gitignore | plan §4 |
| F06 | **除 `[stack.nginx]` 外不发布宿主端口**（宿主直连容器 IP，已实测） | plan DEC-3 / DEC-33 |
| F07 | `stock/network.ini` 单一事实源，compose 由脚本生成 | plan DEC-4 |
| F08 | 每栈双形态 solo / ha，profile 切换 | plan DEC-18 |
| F09 | 演练一律 `docker compose stop` | plan DEC-17 |
| F10 | 不用 keepalived/VIP，nginx 双实例 + 客户端双地址 | plan DEC-12 |
| F11 | **只保留 Redis**：哨兵栈（1M+2R+3S）+ 集群栈（3M+3R）；10 个组件域移出 | plan DEC-26 |
| F12 | 保留**最小入口**：`services/nginx/`（双入口）+ `services/mailpit/`（告警收件箱），各一目录 | plan DEC-27 / DEC-33 |
| F13 | UI 统一经 `<svc>.localhost` 子域，路由表进 ini `[routes]` 段 | plan §15 / DEC-21/22 |
| F14 | 可观测性按组件拆栈：`services/prometheus/`、`services/alertmanager/`、`services/grafana/` | plan §16.1 / DEC-24 |
| F15 | 三层模型：域（4）/ 组件目录（7）/ 部署单元（8）/ 容器（10→22） | plan §2.1 |
| F16 | 缩容**不移除块号**（`[stack.*]` 命名与尾号保留），追加域按原块号回填 | plan DEC-28 / §17 |
| **F17** | **新增 `services/jaeger/`**（观测域第 4 栈，`.12.32`）：OTLP 接收 + Badger 存储 + UI；**不伪装双实例 HA** | plan DEC-29/30 / §16.5 |
| **F18** | **`redis-sentinel` 与 `redis-cluster` 合并为复合栈 `services/redis/`**（两个互斥 profile；数据仍分 `data/sentinel/` 与 `data/cluster/`） | plan DEC-31/32 / §2.1 §8.0.1 |
| **F19** | **拆掉 `services/core/`**：`services/nginx/` + `services/mailpit/`；`.0.x` 域更名 `edge`（计数不变，只改归属） | plan DEC-33 / §2.1 |

---

## 2. 阻塞 P0 的决策（必须现在定）

### D01 镜像源与首次拉取策略 🔴

**问题**：缩容后镜像数量从 ~25 降到 6（`nginx`、`redis`、`mailpit`、`prom/prometheus`、`prom/alertmanager`、`grafana/grafana` + `oliver006/redis_exporter`），
但冷拉仍可能几十秒/个，首次 7 个镜像预计 **3–8 分钟**。

| 选项 | 说明 |
|---|---|
| A | 不配，接受慢（首次一次性成本，已可接受） |
| B | 配 Docker Hub 镜像加速器（写入 daemon `registry-mirrors`） |
| C | 只配 OrbStack 的 proxy 设置（`orb config set docker.proxy`），走系统代理 |
| D | 预拉取清单：`scripts/prepull.sh` 一次性按 ini 拉全镜像并缓存 |

**推荐**：**D 必做，B 可选**（缩容后 A 也基本可接受；D 的成本极低，能保证"一条命令起全栈"）
**影响**：全部 6 栈的可用性；不涉及容器数/内存
**阻塞**：P0

### D02 镜像版本锁定策略 🔴

**问题**：`latest` 会导致重建后行为漂移；对 Redis 集群尤其致命（`nodes.conf` 与版本行为绑定）。

| 选项 | 说明 |
|---|---|
| A | 精确 pin 到 minor（`redis:7.4.2`、`nginx:1.27.4`），版本表集中 `base/images.yml` |
| B | major.minor（`redis:7.4`、`nginx:1.27`），随补丁自动更新 |
| C | `latest` |

**推荐**：**B**（补丁自动、跨大版本不漂移）；`redis_exporter` / `mailpit` 用 A（小版本变化会影响指标名）
**影响**：决定 `base/images.yml` 是否存在
**阻塞**：P0

### D03 宿主入口端口 🔴

**问题**：nginx 用 `80/443` 还是 `8080/8443`？

**实测**：非 root 绑定 80 ✅ 可用（OrbStack 代理）。

| 选项 | 说明 |
|---|---|
| A | `80/443`（最短 URL，`http://grafana.localhost` 直接可用） |
| B | `8080/8443`（避开与宿主其他服务冲突） |

**推荐**：**A**，但保留 B 作为 `.env` 可覆盖项（`ENTRY_HTTP_PORT=80`）
**影响**：仅在 `[stack.nginx]`
**阻塞**：P0

### D04 凭据策略 🔴

**问题**：缩容后需要凭据的只剩 **Redis（2 栈，`requirepass`+`masterauth`）** 和 **Grafana admin**。

| 选项 | 说明 |
|---|---|
| A | 单一 `env/.env`，`scripts/gen-secrets.sh` 首次生成随机密码（chmod 600，gitignore） |
| B | 统一简单密码（如 `devops123`），方便 `redis-cli -a` 手敲/贴连接串 |
| C | 不设密码（Redis 无 ACL） |

**推荐**：**A**，但给 `make secrets-show` 打印；Redis 密码必须**两组 profile 一致**（哨兵切主后 `masterauth` 不匹配会直接踢连接）
**影响**：2 栈 + 监控面板；决定是否需要 `gen-secrets.sh`
**阻塞**：P0

### D05 共享配置注入机制 🔴

**问题**：`logging` / `restart` / `TZ` / 健康检查默认值如何复用到 6 个组件文件？

**实测背景**：`include` 只合并 project，**YAML 锚点不跨文件继承**。

| 选项 | 说明 |
|---|---|
| A | `base/anchors.yml` 定义 `x-common:`，渲染时由 `render-all.sh` 展开写入各 compose |
| B | 每个组件 `compose.yml` 顶部 `extends: ../base/base-service.yml` |
| C | 在每个组件文件内重复写 5 行（放弃复用） |

**推荐**：**A**（生成期展开，最可控）
**影响**：`render-all.sh` 复杂度；不影响运行时
**阻塞**：P0

### D06 `compose.yml` 生成 vs 手写 🔴

| 选项 | 说明 |
|---|---|
| A | 全生成（`render-all.sh` 扫 `services/*/compose.yml`） |
| B | 手写 include 列表（7 行），靠 `doctor.sh` 检查漏登记 |

**推荐**：**A**；`compose.generated.yml` 标记为生成物，禁止手改
**阻塞**：P0

### D07 `stock/network.ini` 格式确认 🔴

现方案：竖线分隔 5 列 `name | ip | ports | role | mode`，`awk -F'|'` 解析，`mode` 缺省 = `ha`。

| 选项 | 说明 |
|---|---|
| A | 保持竖线 5 列（零依赖 awk） |
| B | 改 TOML/JSON（需 `jq`/python 依赖） |
| C | 改 YAML（需 `yq`） |

**推荐**：**A**
**阻塞**：P0

### D08 时区与字符集 🔴

| 选项 | 说明 |
|---|---|
| A | `TZ=Asia/Shanghai` |
| B | `UTC`（跨时区协作/日志对齐更方便） |

**推荐**：**A**（与你的使用场景一致）；Redis 无字符集配置，本条只影响日志时间戳
**阻塞**：P0

---

## 3. 保留域的分栈决策

### D12 Redis 版本 ✅ 建议锁定

| 选项 | 说明 | 影响 |
|---|---|---|
| A | `redis:7.4`（稳，Sentinel/Cluster 生态成熟） | 推荐 |
| B | `redis:8.x`（新特性，部分客户端未适配） | — |

**推荐**：**A**；两组 profile 必须**同版本**（同一份 `services/redis/config/base/redis-base.conf` 渲染）

### D18 nginx 版本

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | **1.27**（mainline）/ 1.26（stable） | 1.27 |

> 已定：统一入口 + 子域 `<svc>.localhost`（F13 / DEC-21）。

### D19 镜像版本总表（缩容后只剩 8 个）

| 组件 | 候选 |
|---|---|
| nginx | `1.27-alpine` |
| mailpit | `axllent/mailpit:v1.21`（pin minor） |
| redis | `7.4-alpine`（两组同版本） |
| redis_exporter | `oliver006/redis_exporter:v1.67.0` |
| prometheus | `prom/prometheus:v3.x`（待定大版本，见下） |
| alertmanager | `prom/alertmanager:v0.28.x` |
| grafana | `grafana/grafana:11.x` |
| jaeger | `jaegertracing/jaeger:2.x`（见 D33） |

**待你确认**：Prometheus 是否直接上 **v3**（TSDB 格式与 v2 不兼容，但本项目无历史数据包袱）。
**推荐**：上 v3，并在 `docs/stacks.md` 记录"TSDB 不可降级"。

### D33 Jaeger 版本、存储与保留 🆕

**问题**：Jaeger 是新增组件，版本代际与存储选择直接决定 `data/` 形态与能否扩 HA。

| 选项 | 说明 |
|---|---|
| A | **`jaeger:2.x`（OTel Collector 发行版）+ Badger 本地存储**，TTL 72h |
| B | `jaegertracing/all-in-one:1.6x`（v1 老架构，配置简单，但已 EOL） |
| C | Jaeger + Elasticsearch/Cassandra 存储（真 HA，但需再加 1–2 个域） |

**推荐**：**A**（v2 是官方方向，OTLP 原生；Badger 不新增存储域；ES 后端列入 N09）
**影响**：`services/jaeger/config/` 为 OTel Collector YAML（比 v1 的 flag 多，但可完全入库渲染）
**阻塞**：P3

### D34 谁来产生 trace（验收口径）🆕

**问题**：缩容后环境里**没有任何业务应用**，Jaeger 默认会是空的（"装了但没数据"）。

| 选项 | 说明 | 成本 |
|---|---|---|
| A | 只提供接入点，trace 由你的应用推（验收时你自己写 demo） | 0；但 P3 验收无法自动完成 |
| B | `make trace-demo`：用 curl 向 `:4318/v1/traces` 推一条固定 trace（两层 span） | 约 30 行脚本 |
| C | 新增 `services/otel-demo/` 组件栈（持续发 trace 的示例服务） | +0.2 GB / +1 容器 / +1 栈 |

**推荐**：**B**（P3 验收可重复执行；不引入常驻演示负载）
**影响**：`Makefile` + `scripts/trace-demo.sh`；§16.5 验收口径
**阻塞**：P3

### 3.1 作废项（域已移出，无需回答）

| # | 原议题 | 原因 |
|---|---|---|
| D09 | PostgreSQL 版本与访问层 | pg 域移出（plan DEC-26） |
| D10 | MySQL 版本与 Router | mysql 域移出 |
| D11 | MongoDB 形态 | mongo 域移出 |
| D13 | Kafka 版本与附加件 | kafka 域移出 |
| D14 | RocketMQ 版本与架构 | rocketmq 域移出 |
| D15 | RabbitMQ 版本与队列语义 | rabbitmq 域移出 |
| D16 | etcd / Consul / NATS 版本与安全 | 三域移出 |
| D17 | MinIO 版本与容量 | minio 域移出（core 不再含对象存储） |

---

## 4. 方案缺口

### D20 监控后端（最大缺口） ✅ 已定案

**已定**（plan DEC-20 / DEC-24 / §16）：新增 observability **域**（块 `172.28.12.x`），并按组件拆为 3 个独立组件栈：

| 组件栈 | 目录 | 容器 | IP | 内存 solo / ha |
|---|---|---|---|---|
| prometheus | `services/prometheus/` | `prometheus-1` / `prometheus-2`(ha) | `.12.11` / `.12.12` | 0.30 / 0.85 GB |
| alertmanager | `services/alertmanager/` | `alertmanager` | `.12.21` | 0.05 / 0.05 GB |
| grafana | `services/grafana/` | `grafana` | `.12.31` | 0.25 / 0.25 GB |

抓取目标由 ini 的 `exporter` 角色自动生成；跨栈引用由 `render.sh` 从 ini 注入（DEC-25）。
仅剩子项：① 是否后续上 Thanos（需先追加对象存储域）；② 是否加 Loki/Promtail；③ 容器指标来源（D30）。

**已否决**：不做观测栈（exporter 白采）；合成单目录 `services/observability/`（重置会连带删 TSDB）。

### D21 solo↔ha 切换的数据处理

**问题**：两形态数据目录隔离（`data/solo/` vs `data/<node>/`），切换时默认**不迁移**。

| 选项 | 说明 |
|---|---|
| A | 不迁移，切换提示"数据不互通"（最快，适合测试） |
| B | 提供 `stack-switch --migrate`：solo → ha 走 `DUMP`/`RESTORE` 或 RDB 拷贝 |
| C | 禁用手动切换，只能 `stack-reset`（最安全） |

**推荐**：**A**，P2 之后再考虑 B（Redis 的 RDB 迁移相对简单，但集群 slot 元数据不能直接搬）
**阻塞**：P0（决定 `stack-switch` 是否有 `--migrate` 分支）

### D22 资源硬限额

**问题**：是否给每容器设 `deploy.resources.limits`。

| 选项 | 说明 |
|---|---|
| A | 设 limits（cpus + memory） |
| B | 不设，靠 `maxmemory` 等应用层限制 |

**推荐**：**B**（缩容后 ha 全量仅 2.05 GB / 可见 15.7 GB，硬限额只会制造调试噪音）
**阻塞**：无（P0 即可按 B 落地）

### D23 人类可读域名 ✅ 已定案

`<svc>.localhost`（macOS 原生解析，不改 `/etc/hosts`）；容器内禁止用 `.localhost`，一律 IP/服务名。

| 选项 | 结论 |
|---|---|
| A 路径前缀 `localhost/grafana` | ❌ 已否（Grafana 子路径需 `serve_from_sub_path`，易错） |
| **B `*.localhost`** | ✅ 采用 |
| C `*.orb.local` | ❌（换运行时域名失效） |
| D 写 `/etc/hosts` | ❌（需维护，且与 B 重复） |

### D24 备份策略

| 项 | 选项 | 推荐 |
|---|---|---|
| 形式 | (a) tar 冷备（停栈） (b) 状态文件 + `BGSAVE` RDB 导出（在线） | **(b)** |
| 内容 | 至少含 `nodes.conf` / `sentinel.conf` / TSDB 元数据 / Grafana SQLite | 全部 |
| 存放 | `data/backups/`（仓库内，gitignore） | 仓库内（符合需求②） |
| 保留 | 最近 5 份 / 按日期 | 最近 5 份 |

### D25 CI

| 选项 | 说明 | 推荐 |
|---|---|---|
| A | GitHub Actions：`doctor.sh` + `compose config` + yamllint + markdownlint | ✅ 便宜 |
| B | A + 夜间跑 `failover-drill`（需 Linux runner 特权，成本高） | — |
| C | 不做 | — |

**推荐**：**A**（只做静态校验，不跑容器）

### D26 日志去向

| 选项 | 说明 |
|---|---|
| A | 各栈 `data/<node>/logs/` + json-file 限流（plan 现状） |
| B | A + 统一到 `data/_logs/` 软链，便于 `make logs-all` |
| C | A + Loki（依赖 D20 子项） |

**推荐**：**B**

### D27 首次拉取与建栈总耗时预算

**问题**：缩容后 21 容器全量首次 `stack-up`（拉 7 个镜像 + 初始化 + bootstrap）预计 **5–10 分钟**。

**需要你确认**：是否仍要 `make prepull`（按 ini 预拉 7 个镜像）
**推荐**：要（成本极低，保证离线可复现）

### D28 故障演练的范围与频率

| 选项 | 说明 |
|---|---|
| A | 每栈一个 `failover-drill`，手动按需跑 |
| B | A + `make drill-all` 顺序跑两组（约 3 min） |
| C | 纳入 CI 定时跑 |

**推荐**：**A + B**（不纳入 CI，见 D25）

### D29 OrbStack VM 内存

| 选项 | 说明 |
|---|---|
| A | 保持自动（当前可见 15.7 GB），无需调整 |
| B | `orb config set memory_mib 24576` |

**推荐**：**A**（v3.0 全量仅 2.05 GB，改动全局运行时配置没有必要）
**注**：v2.3 曾推荐 B，缩容后该理由消失。

### D30 容器资源指标来源

**问题**：§16.4 有一张"容器资源总览"面板，但目前没有对应采集组件（无 cadvisor / node-exporter）。

| 选项 | 说明 | 成本 |
|---|---|---|
| A | `services/cadvisor/` 独立目录（`.12.41`，`role=exporter`，profile `cadvisor`） | +0.10 GB / +1 容器 |
| B | 改用 Docker daemon metrics（`metrics-addr`，需改 OrbStack daemon 配置） | 0 容器；改全局配置 |
| C | 不做容器级面板，只留"全栈 up/down" | 0；容器资源 `docker stats` 手看 |

**推荐**：**A**（符合"按组件来"：一个采集器 = 一个组件栈；且不动 daemon 配置）
**影响**：容器数 22 → 23，内存 2.20 → 2.30 GB
**阻塞**：P3

### D31 Redis 持久化组合 🆕

**问题**：两组 profile 的持久化决定"重启后数据是否还在"，也决定 `data/` 的体积与恢复速度。

| 选项 | 说明 |
|---|---|
| A | `appendonly yes` + `appendfsync everysec`，同时保留 RDB 快照（默认 `save 3600 1 300 100 60 10000`） |
| B | 只开 AOF（纯追加，恢复最完整，`data/` 变大） |
| C | 只开 RDB（体积小、恢复快，但会丢最后一次快照后的数据） |
| D | 全关（纯缓存，重启即空） |

**推荐**：**A**（AOF 保证"演练切主后不丢写"，RDB 便于 D24 的在线导出）
**影响**：`data/` 体积、`bootstrap` 时间、备份策略（D24）
**阻塞**：P1（哨兵栈开工前）

### D32 Redis 内存档位与淘汰策略 🆕

**问题**：`maxmemory` 与 `maxmemory-policy` 决定"缓存压力下暴露什么问题"。

| 选项 | 说明 |
|---|---|
| A | `maxmemory 256mb` + `noeviction`（写满即报错，问题显性） |
| B | `maxmemory 512mb` + `allkeys-lru`（贴近生产缓存行为，问题隐性） |
| C | 两组分档：哨兵组 A（验证主从一致性与报错路径）、集群组 B（验证淘汰与 slot 倾斜） |

**推荐**：**C**（一次覆盖两种真实场景）
**影响**：§9.2 的限流表、压测口径
**阻塞**：P1

---

## 5. 明确不做（供你否决）

| # | 项 | 理由 |
|---|---|---|
| N01 | Kubernetes / k3s | 目标是"组件栈验证"，不是编排平台验证；OrbStack k8s 保持关闭 |
| N02 | 真实多机分布式 | R5 边界已写明；需另立方案（多 VM / SSH driver） |
| N03 | TLS / 自签证书体系 | 本地测试收益低；nginx 443 仅用自签占位 |
| N04 | Terraform / Ansible | 纯 compose + 脚本足够；引入会与"数据在仓库内"冲突 |
| N05 | keepalived / VIP | DEC-12 已定 |
| N06 | Redis 可视化 UI（RedisInsight 等） | 目前用 `redis-cli` + Grafana 即可；需要时按 plan §17 追加一栈（`.2.x` 或 `.3.x` 的 `.31` 尾号） |
| N07 | Redis Stack / 模块（JSON、Search、TS） | 与"缓存语义验证"无关，且会替换掉标准 `redis` 镜像 |
| N08 | 真实告警外发（Slack/邮件） | 用 mailpit 本地收信即可验证路由（`alertmanager.localhost` 可查） |
| **N09** | **Jaeger 分布式存储后端（ES/Cassandra）** | 真 HA 需新增 1–2 个域，与 v3.0 缩容方向相背；当前用 Badger + 72h TTL 足够 |
| **N10** | **trace → metrics exemplar / span metrics** | 需在 collector 侧加 spanmetrics connector 并改面板口径，收益低；需要时再开 |

---

## 6. 最小决策集（答这 5 项即可开工 P0）

| ID | 一句话 | 我的推荐 |
|---|---|---|
| **D01** | 镜像怎么来 | D（prepull 脚本），B 可选 |
| **D02** | 版本锁定策略 | B（major.minor） |
| **D03** | 宿主入口端口 | A（80/443，可用 .env 覆盖） |
| **D08** | 时区 | A（Asia/Shanghai） |
| **D31** | Redis 持久化 | A（AOF everysec + RDB 快照） |

其余（D04–D07、D12、D18、D19、D21、D22、D24、D26–D30、D32–D34）我按推荐值先落地，你随时可以改。

---

## 7. 实测数据附录

| 探测 | 命令 | 结果 |
|---|---|---|
| 宿主直连容器 IP | `curl 172.28.0.10:8080` | ✅ 通 |
| 同网络静态 IP 互访 | `wget 172.28.0.10:8080` | ✅ 通 |
| 非 root 绑定 80 | `docker run -p 80:80` | ✅ 通 |
| `include` glob | `include: services/*/compose.yml` | ❌ 不支持 |
| `include` + profiles | `--profile x config --services` | ✅ 透传 |
| 组件内相对路径基准 | `./data` 解析 | ✅ 相对组件目录 |
| 冷拉 alpine:3.20 | `docker pull` | 26.7 s |
| 冷拉 redis:7.4-alpine | `docker pull` | 62.8 s |
| 热拉（已缓存） | `docker pull` | 3.3 s |
| Docker Hub 连通 | `curl registry-1.docker.io/v2/` | 401 @1.7 s（可达，无镜像源） |
| VM 可见内存 | `docker info` | 15.7 GB（物理 48 GB / 14 core） |
