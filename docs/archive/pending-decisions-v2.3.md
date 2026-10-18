# 待决事项清单（决策清单）

> 配套文档：`docs/plan.md`（**v2.3**）。本文件只列**未定案**的问题。
> 每项给出：问题 → 选项 → 我的推荐 → 影响面 → 阻塞阶段。
> **回复格式**：只需写 `D01=A, D03=A, D21=A` 这样的键值即可；同意的推荐值写 `OK`。

---

## 0. 汇总统计

| 类别 | 数量 | 阻塞 |
|---|---|---|
| 阻塞 P0 | 8（D01–D08） | 不答无法开工 |
| 分栈决策 | 11（D09–D19） | 各自所属阶段（P1–P6） |
| 方案缺口 | 11（D20–D30） | 建议在 P0/P1 一并定 |
| 明确不做 | 5（N01–N05） | 已排除，供你否决 |
| **已定案（本轮关闭）** | **3（D18 / D20 / D23）** | 已写入 plan v2.3：§15 统一入口、§16 可观测性域（三组件栈） |

**最小决策集**：只答 **D01 / D02 / D03 / D21 / D08** 五项即可开始 P0。

---

## 1. 已定案（不需再讨论，仅备忘）

| # | 决策 | 出处 |
|---|---|---|
| F01 | 单一网络 `devnet` = `172.28.0.0/16`，网关 `.1` | plan §3.1 |
| F02 | 块号 = 栈号（`.0.x` core … `.11.x` nats，`.99.x` 工具） | plan §3.2 |
| F03 | 块内尾号约定（`.11–19` 核心 / `.21–29` 副本 / `.31–39` 代理与 DCS / `.41–49` exporter / `.51–59` 客户端） | plan §3.3 |
| F04 | 目录按组件内聚，不变量集中 `base/` | plan §2 §4 |
| F05 | 数据放各组件 `data/`，`**/data/` 一条 gitignore | plan §4 |
| F06 | 除 core 外不发布宿主端口（宿主直连容器 IP，已实测） | plan DEC-3 |
| F07 | `stock/network.ini` 单一事实源，compose 由脚本生成 | plan DEC-4 |
| F08 | 每栈双形态 solo / ha，profile 切换 | plan DEC-18 |
| F09 | 演练一律 `docker compose stop` | plan DEC-17 |
| F10 | 不用 keepalived/VIP，nginx 双实例 + 客户端双地址 | plan DEC-12 |
| F11 | RocketMQ 用 DLedger 3 broker；MinIO 4 节点 EC:2；MySQL 用 MGR | plan DEC-14/15/8 |
| **F12** | **新增 observability 域**（块 `172.28.12.x`），域内按组件拆为 3 个独立组件栈 | plan §16 / DEC-20 |
| **F13** | **UI 统一经 `<svc>.localhost` 子域**，路由表进 ini `[routes]` 段 | plan §15 / DEC-21/22 |
| **F14** | **可观测性按组件来**：`services/prometheus/`、`services/alertmanager/`、`services/grafana/` 各自 compose/config/scripts/data + 独立 profile | plan §2.1 §16.1 / DEC-24 |
| **F15** | 三层模型：域（13）/ 组件栈（15）/ 容器（65）；拆分判据 = 可独立起停重置与独立状态 | plan §2.1 |

---

## 2. 阻塞 P0 的决策（必须现在定）

### D01 镜像源与首次拉取策略 🔴

**问题**：实测冷拉 `alpine` 26.7 s、`redis:7.4-alpine` 62.8 s，`docker.json` 为空。61 容器的镜像全量首拉预计 **30–60 分钟**，且 `make stack-up` 会反复卡在拉取上。

| 选项 | 说明 |
|---|---|
| A | 不配，接受慢（首次一次性成本） |
| B | 配 Docker Hub 镜像加速器（写入 daemon `registry-mirrors`） |
| C | 只配 OrbStack 的 proxy 设置（`orb config set docker.proxy`），走系统代理 |
| D | 预拉取清单：`scripts/prepull.sh` 一次性按 ini 拉全镜像并缓存 |

**推荐**：**B + D 组合**（先加速，再提供 prepull 脚本兜底）
**影响**：全部 12 栈的可用性；不涉及容器数/内存
**阻塞**：P0

### D02 镜像版本锁定策略 🔴

**问题**：`latest` 会导致重建后行为漂移，集群身份（clusterId、`nodes.conf`）随之失效。

| 选项 | 说明 |
|---|---|
| A | 精确 pin 到 minor（`postgres:17.2`、`redis:7.4.2`），版本表集中 `base/images.yml` |
| B | major.minor（`postgres:17`、`redis:7.4`），随补丁自动更新 |
| C | `latest` |

**推荐**：**B**（major.minor）—— 补丁自动、跨大版本不漂移；MiNIO/Kafka 例外用 A（见 D19/D13）
**影响**：全部；决定 `base/images.yml` 是否存在
**阻塞**：P0

### D03 宿主入口端口 🔴

**问题**：nginx 用 `80/443` 还是 `8080/8443`？

**实测**：非 root 绑定 80 ✅ 可用（OrbStack 代理）。

| 选项 | 说明 |
|---|---|
| A | `80/443`（最短 URL，`http://localhost` 即入口） |
| B | `8080/8443`（避开与宿主其他服务冲突） |

**推荐**：**A**，但**保留 B 作为 `.env` 可覆盖项**（`ENTRY_HTTP_PORT=80`）
**影响**：仅在 `[stack.core]`
**阻塞**：P0

### D04 凭据策略 🔴

**问题**：12 栈有密码（PG/MySQL/Mongo/Redis/RabbitMQ/MinIO/Consul ACL…）。

| 选项 | 说明 |
|---|---|
| A | 单一 `env/.env`，`scripts/gen-secrets.sh` 首次生成随机强密码（chmod 600，gitignore） |
| B | 统一简单密码（如 `devops123`），方便手敲/贴连接串 |
| C | Docker secrets（Swarm 才完整，`compose` 下退化为文件挂载） |

**推荐**：**A**，并在 `env/.env.example` 给出变量名清单；测试期允许 `make secrets-show` 打印
**影响**：全部栈；决定是否需要 `gen-secrets.sh`
**阻塞**：P0

### D05 共享配置注入机制 🔴

**问题**：`logging` / `restart` / `TZ` / 健康检查默认值如何复用到 12 个组件文件？

**实测背景**：`include` 只合并 project，**YAML 锚点不跨文件继承**。

| 选项 | 说明 |
|---|---|
| A | `base/anchors.yml` 定义 `x-common:`，渲染时由 `render-all.sh` 展开写入各 compose |
| B | 每个组件 `compose.yml` 顶部 `extends: ../base/base-service.yml` |
| C | 在每个组件文件内重复写 5 行（放弃复用） |

**推荐**：**A**（生成期展开，最可控；且 compose 原生 `x-` 字段不生效于服务默认值）
**影响**：`render-all.sh` 复杂度；不影响运行时
**阻塞**：P0

### D06 `compose.yml` 生成 vs 手写 🔴

| 选项 | 说明 |
|---|---|
| A | 全生成（`render-all.sh` 扫 `services/*/compose.yml`） |
| B | 手写 include 列表（13 行），靠 `doctor.sh` 检查漏登记 |

**推荐**：**A**；`compose.generated.yml` 标记为生成物，禁止手改
**阻塞**：P0

### D07 `stock/network.ini` 格式确认 🔴

现方案：竖线分隔 5 列 `name | ip | ports | role | mode`，`awk -F'|'` 解析，`mode` 缺省 = `ha`。

| 选项 | 说明 |
|---|---|
| A | 保持竖线 5 列（零依赖 awk） |
| B | 改 TOML/JSON（需 `jq`/python 依赖） |
| C | 改 YAML（需解析器，或用 `yq`） |

**推荐**：**A**
**阻塞**：P0

### D08 时区与字符集 🔴

| 选项 | 说明 |
|---|---|
| A | `TZ=Asia/Shanghai`，MySQL/Mongo 字符集 `utf8mb4` |
| B | `UTC`（跨时区协作/日志对齐更方便） |

**推荐**：**A**（与你的使用场景一致）；日志时间统一由 nginx/loki 层转换
**阻塞**：P0（影响所有配置模板）

---

## 3. 分栈决策（P1–P6 逐期确认）

### D09 PostgreSQL 版本与访问层

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | 16 / **17** | 17 |
| 访问层 | (a) HAProxy×2 读写分离端口 5000/5001 (b) pgpool-II (c) 直连 Patroni REST 选主 | **(a)**，pgpool 留作可选 profile |
| 连接池 | (a) 不单独做（HAProxy 仅转发）(b) 加 pgbouncer×2 | **(a)**，P2 后再评估 |

**影响**：haproxy×2 已计入 1.25 GB；加 pgbouncer 再 +0.1 GB

### D10 MySQL 版本与 Router

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | 8.0 / **8.4 LTS** | 8.4 LTS |
| Router | (a) Router×2 (b) 直连 MGR primary（客户端自己感知） | **(a)**，验证"客户端无感切换"才有意义 |
| Router 引导 | (a) `bootstrap` 一次性容器 (b) 手写 router 配置 | **(a)** |

### D11 MongoDB 形态

| 选项 | 说明 | 影响 |
|---|---|---|
| A | **Replica Set ×3**（1P2S） | 1.05 GB，已计入 |
| B | RS×3 + Sharded（+config×3 + mongos×2） | +1.3 GB，仅当你要验证分片 |

**推荐**：**A**；分片留作可选 profile（`--profile mongo-shard`）

### D12 Redis 版本

| 选项 | 说明 | 推荐 |
|---|---|---|
| A | `redis:7.4`（稳，Sentinel/Cluster 生态成熟） | ✅ |
| B | `redis:8.x`（新特性，部分客户端未适配） | — |

**影响**：哨兵 0.33 GB / 集群 0.48 GB 不变

### D13 Kafka 版本与附加件

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | 3.9（KRaft 成熟）/ **4.0**（纯 KRaft，移除 ZK） | 3.9（保守） |
| exporter | 要 / 不要 | **要**（已计入 0.05 GB） |
| UI | kafka-ui（+0.4 GB）/ 不要 | 先不要 |

### D14 RocketMQ 版本与架构

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | **5.3** | 5.3 |
| 复制 | **DLedger(Raft) 3 broker** | 已定（F11） |
| Proxy | 5.x gRPC proxy（+0.6 GB）/ 不用（走 remoting 4.x 协议） | **不用**，先用原生 remoting |

### D15 RabbitMQ 版本与队列语义

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | 3.13 / **4.x** | 4.x（quorum 成熟） |
| 队列默认 | classic / **quorum** | **quorum**（否则 3 节点无意义） |
| mgmt UI | 经 nginx 暴露 / 仅内网 IP | 经 nginx |

### D16 etcd / Consul / NATS 版本与安全

| 项 | 选项 | 推荐 |
|---|---|---|
| etcd | 3.5 / **3.6** | 3.6 |
| consul | **1.20**；ACL 开启吗？(a) 关（测试快）(b) 开 ACL + gossip 加密（贴近生产） | **(a)**，避免客户端到处配 token |
| nats | **2.11**；JetStream (a) 开 R3 (b) 单副本 | **(a)** R3 才有意义 |

### D17 MinIO 版本与容量

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | `RELEASE.2025-xx-xx`（必须 pin 到日期，minio 无稳定 tag） | pin 具体日期 |
| 部署 | 4 节点 × 1 盘 EC:2（1.35 GB）/ 4 节点 × 4 盘（+12 目录，更强） | **4×1 EC:2** |
| 是否设 `MINIO_CI_CD=1` | 是 / 否 | 是（本地测试降噪） |

### D18 nginx 版本与统一入口范围 ✅ 已定案

**已定**（plan DEC-21 / §15）：全部 UI 经 nginx，**用子域 `<svc>.localhost`**，不用子路径。
原因：MinIO console 与 Consul UI 不支持自定义 base-path，子路径方案会直接失效。
仅剩子项待定：nginx 版本 **1.27 mainline**（推荐）vs 1.26 stable。

| 项 | 选项 | 推荐 |
|---|---|---|
| nginx 版本（唯一剩余子项） | **1.27** (mainline) / 1.26 (stable) | 1.27 |

> 原子项已关闭：「是否统一入口」= 是；「路由命名」= 子域（原先推荐的路径前缀已被否，见上方原因）。

### D19 镜像版本总表

**问题**：D02 定了策略后，需要一张具体的 `base/images.yml`。待你确认后才写。

| 组件 | 候选 |
|---|---|
| nginx | 1.27-alpine |
| minio | RELEASE.2025-04-22T22-12-26Z（或你指定） |
| postgres | 17 |
| patroni | 4.x |
| haproxy | 3.0-alpine |
| redis | 7.4-alpine |
| mysql | 8.4 |
| mysql-router | 8.4 |
| mongo | 7.0 / 8.0 |
| kafka | 3.9.x（apache/kafka） |
| rocketmq | 5.3.x |
| rabbitmq | 4.0-management |
| etcd | 3.6 |
| consul | 1.20 |
| nats | 2.11-alpine |

---

## 4. 方案缺口（梳理时发现，建议一并定）

### D20 监控后端（最大缺口） ✅ 已定案

**已定**（plan DEC-20 / DEC-24 / §16）：新增 observability **域**（块 `172.28.12.x`），并按组件拆为 3 个独立组件栈：

| 组件栈 | 目录 | 容器 | IP | 内存 solo / ha |
|---|---|---|---|---|
| prometheus | `services/prometheus/` | `prometheus-1` / `prometheus-2`(ha) | `.12.11` / `.12.12` | 0.30 / 0.85 GB |
| alertmanager | `services/alertmanager/` | `alertmanager` | `.12.21` | 0.05 / 0.05 GB |
| grafana | `services/grafana/` | `grafana` | `.12.31` | 0.25 / 0.25 GB |

合计 solo 0.60 GB / ha 1.15 GB（与拆分前一致，容器数仍为 65）；抓取目标由 ini 的 `exporter` 角色自动生成；
跨栈引用（Grafana 数据源、Prom→AM 地址）由 `render.sh` 从 ini 注入（DEC-25）。
仅剩子项待定：① 是否后续上 Thanos + MinIO；② 是否加 Loki/Promtail；③ 容器指标来源（D30）。

**问题**：每栈都规划了 exporter，但**没有任何存储/展示后端**——指标采了没人收。plan 里也没有 observability 域。

| 组成 | 容器 | 内存 |
|---|---|---|
| **Prometheus×2 + Grafana + Alertmanager**（已定，3 个组件栈） | 4（solo 时 3） | ha 1.15 / solo 0.60 GB |
| ∟ 日志聚合 Loki + Promtail（**仅此项待定**） | +2（各一栈） | +0.3 GB |

**唯一待定子项**：是否加 Loki（与 D26 合并决策）；容器指标来源（D30）。
**已否决**：不做的选项（C）—— 每栈 exporter 已规划，无后端等于白采。
**已否决**：合成单目录 `services/observability/` —— 三个产品配置格式与状态生命周期不同，合并后 `stack-reset` 会连带删 TSDB，也无法单独升起某一组件（plan §2.1 拆分判据）。

### D21 solo↔ha 切换的数据处理

**问题**：两形态数据目录隔离（`data/solo/` vs `data/<node>/`），切换时默认**不迁移**。

| 选项 | 说明 |
|---|---|
| A | 不迁移，切换提示"数据不互通"（最快，适合测试） |
| B | 提供 `stack-switch --migrate`：solo → ha 走 `pg_basebackup`/`mysqldump` 导入 |
| C | 禁用手动切换，只能 `stack-reset`（最安全） |

**推荐**：**A**，P2 之后再考虑 B
**阻塞**：P0（决定 `stack-switch` 是否有 `--migrate` 分支）

### D22 资源硬限额

**问题**：是否给每容器设 `deploy.resources.limits`（单栈吃满 VM 时会拖垮全部）。

| 选项 | 说明 |
|---|---|
| A | 设 limits（cpus + memory），值由 §9.2 估算 ×1.5 |
| B | 不设，靠 `maxmemory`/`-Xmx` 等应用层限制 |
| C | 只给 JVM 类设 |

**推荐**：**C → 逐步到 A**（P0 先不设，避免调试期误杀；P6 完成后统一切 A）

### D23 人类可读域名 ✅ 已定案

**已定**（plan DEC-21 / §15.5）：`<svc>.localhost`（macOS 原生解析，不改 `/etc/hosts`）；
容器内禁止用 `.localhost`，一律 IP/服务名。

| 选项 | 结论 |
|---|---|
| A 路径前缀 `localhost/adminer` | ❌ 已否（MinIO/Consul 不支持 base-path） |
| **B `*.localhost`** | ✅ **采用**（零配置 + 消除 base-path 问题） |
| C `*.orb.local` | ❌（与 F06 不匹配，换运行时域名失效） |
| D 写 `/etc/hosts` | ❌（需维护，且与 B 重复） |

### D24 备份策略

| 项 | 选项 | 推荐 |
|---|---|---|
| 形式 | (a) tar 冷备（停栈） (b) 逻辑导出（pg_dump/mongodump）+ 状态文件 | **(b)** |
| 存放 | `data/backups/`（仓库内）/ 仓库外 | **仓库内**（符合需求②），但 gitignore |
| 保留 | 最近 5 份 / 按日期 | 最近 5 份 |
| 异地 | 要 / 不要（restic → 外部） | P6 后再议 |

### D25 CI

| 选项 | 说明 | 推荐 |
|---|---|---|
| A | GitHub Actions：`doctor.sh` + `compose config` + yamllint + markdownlint | ✅ 便宜 |
| B | A + 夜间跑 `failover-drill`（需 Linux runner 支持特权，成本高） | — |
| C | 不做 | — |

**推荐**：**A**（只做静态校验，不跑容器）

### D26 日志去向

| 选项 | 说明 |
|---|---|
| A | 各栈 `data/<node>/logs/` + json-file 限流（plan 现状） |
| B | A + 统一到 `data/_logs/` 软链，便于 `make logs-all` |
| C | A + Loki（依赖 D20=B） |

**推荐**：**B**

### D27 首次拉取与建栈总耗时预算

**问题**：61 容器首次 `stack-up` 全量（拉镜像 + 初始化 + bootstrap）预计 **1.5–2 小时**。

**需要你确认**：是否接受"分档预热"（`make prepull` 按档位分批，先 A 档 → 再 B/C/D/E）

**推荐**：接受，写成 `docs/stacks.md` 的"首次使用"章节

### D28 故障演练的范围与频率

| 选项 | 说明 |
|---|---|
| A | 每栈一个 `failover-drill`，手动按需跑 |
| B | A + `make drill-all` 顺序跑全部（约 20 min） |
| C | 纳入 CI 定时跑 |

**推荐**：**A + B**（不纳入 CI，见 D25）

### D29 OrbStack VM 内存

| 选项 | 说明 |
|---|---|
| A | 保持自动（当前可见 15.7 GB），严格按档位 |
| B | `orb config set memory_mib 24576`（物理 48 GB，安全） |

**推荐**：**B**，但仍保留档位纪律（内存大 ≠ 该全量起）
**需你授权**：改的是全局运行时配置，会影响你其他 Docker 项目

### D30 容器资源指标来源（拆栈后新暴露的缺口）

**问题**：plan §16.4 第一张面板是"容器资源总览"，但**之前没有对应的采集组件**（既无 cadvisor 也无 node-exporter）。按 F14/F15 的拆分判据，它要么是独立组件栈，要么就不做。

| 选项 | 说明 | 成本 |
|---|---|---|
| A | `services/cadvisor/` 独立栈（`.12.41`，`role=exporter`，profile `cadvisor`） | +0.10 GB / +1 容器；面板开箱有数 |
| B | 不新增组件，改用 Docker daemon metrics（`metrics-addr`，需改 OrbStack daemon 配置） | 0 容器；改全局 daemon，与 R1 同类风险 |
| C | 不做容器级面板，只保留"全栈 up/down" | 0；容器资源只能 `docker stats` 手看 |

**推荐**：**A**（符合"按组件来"：一个采集器 = 一个组件栈；且不动 daemon 全局配置）
**影响**：容器数 65 → 66，内存 14.35 → 14.45 GB；P7 验收面板多一项
**阻塞**：P7（可与 D20 一并确认）

---

## 5. 明确不做（供你否决）

| # | 项 | 理由 |
|---|---|---|
| N01 | Kubernetes / k3s | 本方案目标是"多组件栈"，不是容器编排平台验证；OrbStack k8s 保持关闭 |
| N02 | 真实多机分布式 | R5 边界已写明；需另立方案（多 VM / SSH driver） |
| N03 | TLS / 自签证书体系 | 本地测试收益低；nginx 443 仅用自签占位 |
| N04 | Terraform / Ansible | 纯 compose + 脚本足够；引入会与"数据在仓库内"冲突 |
| N05 | keepalived / VIP | DEC-12 已定 |

---

## 6. 最小决策集（答这 5 项即可开工 P0）

| ID | 一句话 | 我的推荐 |
|---|---|---|
| **D01** | 镜像拉取太慢怎么办 | B+D（配加速器 + prepull 脚本） |
| **D02** | 版本锁定策略 | B（major.minor） |
| **D03** | 宿主入口端口 | A（80/443，可用 .env 覆盖） |
| **D08** | 时区 | A（Asia/Shanghai） |
| **D21** | solo↔ha 是否迁移数据 | A（不迁移） |

其余（D04–D07、D20、D23）我按推荐值先落地，你随时可以改。

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
