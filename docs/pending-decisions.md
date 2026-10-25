# 待决事项清单（决策清单）

> 配套文档：`docs/plan.md`（**v4.5：15 域，Nacos 3.x（server×3 + console）+ docsify**）。本文件只列**未定案**的问题。
> 每项给出：问题 → 选项 → 我的推荐 → 影响面 → 阻塞阶段。
> **回复格式**：只需写 `D01=A, D31=A` 这样的键值即可；同意的推荐值写 `OK`。
>
> 历史：`docs/archive/pending-decisions-v2.3.md`（13 域原始版）、`docs/archive/pending-decisions-v3.2.md`（缩容版，已撤销）。

---

## 0. 汇总统计

| 类别 | 数量 | 阻塞 |
|---|---|---|
| 阻塞 P0 | **0**（D01–D08 全部落定，P0 可开工） | — |
| 分栈决策（P1–P7） | 11（D09–D16、D18–D19、D36） | 各自所属阶段 |
| 方案缺口 | 16（D20–D34、D37） | 建议 P0/P1 一并定 |
| 明确不做 | 12（N01–N12） | 已排除，供你否决 |
| 已定案 | 36（F01–F36） | 已写入 plan v4.5 |

**最小决策集**：**已清零** —— P0 的 8 项（D01–D08）全部落定，可直接进入 P0 实施（plan §13）。

---

## 1. 已定案（不需再讨论，仅备忘）

| # | 决策 | 出处 |
|---|---|---|
| F01 | 单一网络 `devnet` = `172.28.0.0/16`，网关 `.1` | plan §3.1 |
| F02 | 块号 = 域号，14 块全部启用（`.0.x` edge … `.13.x` nacos、`.12.x` obs） | plan §3.2 |
| F03 | 块内尾号约定（`.11–19` 核心 / `.21–29` 副本与哨兵 / `.31–39` 代理、DCS、前端 / `.41–49` exporter / `.51–59` 客户端） | plan §3.3 |
| F04 | 目录按组件内聚，不变量集中 `base/` | plan §2 |
| F05 | 数据放各组件 `data/`，`**/data/` 一条 gitignore | plan §4 |
| F06 | **仅 `[stack.nginx]` 发布宿主端口**（宿主可直连容器 IP，已实测） | plan DEC-3 |
| F07 | `stock/network.ini` 单一事实源，compose 由脚本生成 | plan DEC-4 |
| F08 | 每栈双形态 solo / ha，profile 切换 | plan DEC-18 |
| F09 | 演练一律 `docker compose stop` | plan DEC-17 |
| F10 | 不用 keepalived/VIP，nginx 双实例 + 客户端双地址 | plan DEC-12 |
| F11 | RocketMQ 用 DLedger 3 broker；MySQL 用 MGR + Router（MinIO 已于 v4.2 删除，见 F22） | plan DEC-8/14 |
| F12 | observability 域（`.12.x`）内按组件拆 4 栈：prometheus / alertmanager / grafana / jaeger | plan DEC-20/24/29 |
| F13 | UI 统一经 `<svc>.localhost` 子域，路由表进 ini `[routes]` | plan DEC-21/22 |
| F14 | 可观测性四栈各自带 compose/config/scripts/data | plan §16.1 |
| F15 | 三层模型：域（15）/ 目录（17）/ 部署单元（18）/ 容器（28→71） | plan §2.1 |
| F16 | 块号与 `[stack.*]` 命名不随范围调整删除 | plan DEC-28 |
| F17 | `services/jaeger/`（`.12.32`）：OTLP + Badger + UI；不伪装双实例 HA | plan DEC-29/30 / §16.5 |
| F18 | `redis` 复合栈（一目录两组互斥 profile；数据分 `data/sentinel/`、`data/cluster/`） | plan DEC-31/32 / §8.0.1 |
| F19 | 原 `core/` 拆为 `nginx` / `mailpit` / `adminer` / `minio`（v4.2 后仅剩 nginx，见 F22） | plan DEC-33/38 |
| F20 | **v4.0 恢复 13 域全量**（撤销 v3.0 缩容），目录规则统一 | plan DEC-34 |
| **F21** | **新增 `services/nacos/`（第 14 域 `.13.x`，3 节点）**：配置库复用 mysql 栈（`:6446/nacos_config`）；控制台经 nginx，gRPC 直连节点 | plan DEC-36/37 |
| **F22** | **删除 mailpit / adminer / minio**（`.0.x` 只留 nginx）；告警 receiver 改 `nul`，对象存储列 N12 | plan DEC-38 |
| **F23** | **镜像默认官方源 + 可自定义**：`base/images.yml` 唯一清单，`.env` 的 `IMG_<NAME>` / `IMAGE_PREFIX` 可覆盖；compose 禁止字面量镜像 | plan DEC-39 / §10 |
| **F24** | **版本形态 `X.Y`**（禁止 `latest`）；上游只发 `X.Y.Z` 的按 `X.Y.Z` pin 并注明 | plan DEC-40 |
| **F25** | **Redis 持久化 = AOF everysec + RDB 快照** | plan DEC-41 / D31 |
| **F26** | **宿主入口 `80/443`**，仅 nginx-1 发布，`ENTRY_HTTP_PORT` 可覆盖 | plan DEC-42 / D03 |
| **F27** | **`TZ=Asia/Shanghai`**（只在 `base/anchors.yml` 出现），MySQL/Mongo `utf8mb4` | plan DEC-43 / D08 |
| **F28** | **RabbitMQ 端口含 Erlang 分发段 `35672-35682`**（与 v2.3 一致；doctor 第 3 项按区间校验） | plan §5.1 / §6.2 / Q10 |
| **F29** | **Nacos 升 3.x**：`nacos-server`×3 + `nacos-console`×1（8080，无状态），3.x schema；P5 锁定四项待确认 | plan DEC-44 / D35 / R28 |
| **F30** | **启用第 15 域 `.20.x` docsify**（§17 预留块首个）：仓库 `docs/` 只读挂到 `/docs/content`，站点壳渲染到 `data/site/`，`DOCSIFY_AUTO_INIT=false`；无状态纯浏览，HA 全量豁免 | plan DEC-46 / §5.3 |
| **F31** | **Prometheus 抓取目标按"该栈当前部署形态"过滤**（读 `.mode-<profile>` marker）：未部署的副本不再长期报 `down`，`down` 只表示"该起而没起" | plan DEC-47 / §16.2 |
| **F32** | **`doctor` 增加第 15 项「运行态健康」**；并把"Docker daemon 重启后必须重跑 `make stack-up` 才能恢复集群不变量"写成正式口径（不把 `group_replication_start_on_boot` 改成 `ON`） | plan DEC-48 / §6.3 / §8.4 / R29 |
| **F33** | **redis 的 `/scrape` 中继只列 6379 节点，不列 sentinel（26379）**：中继只有一份共享 `REDIS_PASSWORD`，而 sentinel 自身不设密码（只靠 `auth-pass` 连 master），带密码去连必 AUTH 失败 → `redis_up` 恒 0 而 `up` 仍为 1，又是一个无法与真故障区分的假信号 | plan DEC-49 / §16.2 |
| **F34** | **`stack.sh` 的 MODE 缺省不再写死 solo**：读 `.mode-<profile>` marker 沿用当前部署形态，从没部署过才回退 solo（并打印解析结果）；避免 ha 部署被当 solo 查（MGR 成员表 vs `@@server_id`） | plan DEC-50 / stacks.md 全局约定 |
| **F35** | **工具链固定走 mise**：`mise.toml`（入库）钉 `python = "3.12"`，依赖只进仓库内 `.venv/`（生成物），`make setup` 一键重建；Makefile 与 `scripts/lib.sh` 前置 `.venv/bin` | plan DEC-51 / stacks.md 全局约定 |
| **F36** | **`stack-up` / `stack-reset` 改两段式（起容器 → bootstrap → 等健康），mysql 首次成组前先解 `super_read_only`**：单段 `up -d --wait` 对需要 bootstrap 才转健康的栈是顺序死循环，这让 DEC-48 的"重跑 `make stack-up` 即恢复"对 mysql 名实不符 | plan DEC-52 / §8.4 / stacks.md 全局约定 |

---

## 2. P0 决策（D01–D08 全部落定，供回查）

### D01 镜像源与首次拉取策略 ✅ 已定案

**结论（你选的）**：**默认用官方镜像，但必须可自定义**。

实现口径（已写入 plan DEC-39 / §10）：

1. **唯一清单** `base/images.yml`：组件 → 镜像引用（`nginx:1.27-alpine`、`redis:7.4-alpine`……），官方源。
2. **注入**：`render.sh` 把引用写进各 `compose.yml`；compose 内**禁止**出现字面量 `image:`（doctor 第 4 项判失败）。
3. **可自定义（默认全空 = 官方源）**：
   - `.env` 的 `IMG_<NAME>=<ref>`：逐个覆盖（如 `IMG_redis=registry.example.com/mirror/redis:7.4-alpine`）；
   - `.env` 的 `IMAGE_PREFIX=<mirror>/<ns>/`：整体前缀，一次切换所有镜像；
   - 也可继续用 daemon 级 `registry-mirrors` / `orb config set docker.proxy`，二者与本机制不冲突。
4. **预拉取**：保留 `scripts/prepull.sh`（读 `images.yml` 按档位预热），仅作为"首次变快"的可选手段，**不改变镜像来源**。

**影响**：全部 14 域；不涉及容器数/内存。首次冷拉仍是 30–60 分钟，可用 prepull 分档预热。
**阻塞**：无（P0 可直接按此落地）

### D02 镜像版本锁定策略 ✅ 已定案（B）

**结论**：**默认为 `X.Y`（major.minor），禁止 `latest`**；上游只发 `X.Y.Z` 的镜像按 `X.Y.Z` pin 并注明原因（plan DEC-40）。

| 形态 | 规则 |
|---|---|
| `X.Y` | 默认。补丁自动跟随、跨大版本不漂移（`redis:7.4`、`postgres:17.5`、`nginx:1.27-alpine`） |
| `X.Y.Z` | 仅当上游不提供 `X.Y` 标签时（Kafka、多数 exporter、RabbitMQ 之外的若干项目）；比 `X.Y` 更可复现 |
| `latest` / `X` 单独 | ❌ 禁止。大版本升级必须手改 `images.yml`（集群身份文件与版本行为绑定） |

**影响**：`base/images.yml` 成为唯一版本表；`doctor.sh` 第 4 项禁止 compose 内出现字面量镜像
**阻塞**：无（P0 按此落地）

### D03 宿主入口端口 ✅ 已定案（A）

**结论**：**`80/443`**（实测非 root 绑定 80 可用，OrbStack 代理），保留 B 作为 `.env` 覆盖项（plan DEC-42）。

- 只有 `nginx-1` 声明 `ports:`，默认映射 `80:80`；`ENTRY_HTTP_PORT=8080` 可整体改到高位端口，**不需要改任何 compose**。
- `443` 暂不启用（自签 TLS 列 N03），但端口位与 `listen 443 ssl` 占位保留在 `config/nginx.conf` 的注释里。
- `nginx-2` 不发布宿主端口，仍可在容器网络内以 `172.28.0.12:80` 访问（"双地址"验证用）。

**影响**：仅 `[stack.nginx]`
**阻塞**：无（P0 按此落地）

### D04 凭据策略 ✅ 已定案（A）

**结论**：**A**。`scripts/gen-secrets.sh` 首次生成 `env/.env`（随机密码，chmod 600，gitignore）；`make secrets-show` 查看，缺失时 Makefile / `stack.sh` 自动生成。Redis 两组 profile 的 `requirepass` / `masterauth` 必须同源。

| 选项 | 说明 |
|---|---|
| A | 单一 `env/.env`，`scripts/gen-secrets.sh` 首次生成随机强密码（chmod 600，gitignore） |
| B | 统一简单密码（如 `devops123`），方便手敲/贴连接串 |
| C | Docker secrets（compose 下退化为文件挂载） |

**影响**：13 域全部（PG/MySQL/Mongo/Redis/RabbitMQ/Consul ACL/Grafana/Nacos token）
**阻塞**：无（P0 已按 A 落地，DEC-45）

### D05 共享配置注入机制 ✅ 已定案（A）

**结论**：**A**。`base/anchors.yml` 定义 `x-common:`，`render-all.py` 在生成期展开为各 service 的 `logging` / `restart` / `TZ` / 健康检查默认值；组件骨架内出现同类字段即判失败。

**问题**：`logging` / `restart` / `TZ` / 健康检查默认值如何复用到 18 个目录？

**实测背景**：`include` 只合并 project，**YAML 锚点不跨文件继承**。

| 选项 | 说明 |
|---|---|
| A | `base/anchors.yml` 定义 `x-common:`，渲染时由 `render-all.sh` 展开写入各 compose |
| B | 每个组件 `compose.yml` 顶部 `extends: ../base/base-service.yml` |
| C | 在每个组件文件内重复写 5 行 |

**阻塞**：无（P0 已按 A 落地，DEC-45）

### D06 `compose.yml` 生成 vs 手写 ✅ 已定案（A）

**结论**：**A 的变体：手写骨架 + 全生成聚合**。`services/<stack>/compose.yml` 是入库的手写骨架（只写 services / profiles / volumes / healthcheck / `x-image`）；`render-all.py` 扫描骨架并注入 base 与 ini，生成 `.generated/<stack>.yml`、根 `compose.yml`、`compose.generated.yml`（均不入库）。

| 选项 | 说明 |
|---|---|
| A | 全生成（`render-all.sh` 扫 `services/*/compose.yml`） |
| B | 手写 include 列表（19 行），靠 `doctor.sh` 检查漏登记 |

**阻塞**：无（P0 已按此落地，DEC-45）

### D07 `stock/network.ini` 格式确认 ✅ 已定案（A）

**结论**：**A**。竖线分隔 5 列 `name | ip | ports | role | mode`；`mode` 缺省 = `ha`；`scripts/ini.py` 零依赖解析并校验 71 行 / 18 profile。

现方案：竖线分隔 5 列 `name | ip | ports | role | mode`，`awk -F'|'` 解析，`mode` 缺省 = `ha`。

| 选项 | 说明 |
|---|---|
| A | 保持竖线 5 列（零依赖 awk） |
| B | 改 TOML/JSON（需 `jq`/python） |
| C | 改 YAML（需 `yq`） |

**阻塞**：无（P0 已按 A 落地，DEC-45）

### D08 时区与字符集 ✅ 已定案（A）

**结论**：**`TZ=Asia/Shanghai`**，MySQL/Mongo 统一 `utf8mb4`（plan DEC-43）。

- `TZ` 只出现在 `base/anchors.yml`（铁律一），由 `render-all.sh` 展开进各 compose；组件内出现 `TZ=` 一律打回。
- MySQL：`character-set-server=utf8mb4` + `collation-server=utf8mb4_0900_ai_ci`；Mongo 默认即 UTF-8，只需在连接串显式 `?charset=utf8mb4` 以便客户端一致。
- 日志时间戳统一为本地时间（+08:00）；跨时区协作时如需 UTC，改 `base/anchors.yml` 一处即可。
- P0 验收：任一容器内 `date` 显示 `CST +0800`。

**影响**：全部 18 个部署单元的日志与时间字段
**阻塞**：无（P0 按此落地）

---

## 3. 分栈决策（P1–P7 逐期确认）

### D09 PostgreSQL 版本与访问层

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | 16 / **17** | 17 |
| 访问层 | (a) HAProxy×2 读写分离 5000/5001 (b) pgpool-II (c) 直连 Patroni REST | **(a)**，pgpool 留可选 profile |
| 连接池 | (a) 不单独做 (b) 加 pgbouncer×2 | **(a)**，P2 后再评估 |

**影响**：pg ha 1.28 GB（含 exporter）；加 pgbouncer 再 +0.1 GB

### D10 MySQL 版本与 Router

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | 8.0 / **8.4 LTS** | 8.4 LTS |
| Router | (a) Router×2 (b) 直连 MGR primary | **(a)**，验证"客户端无感切换"才有意义 |
| Router 引导 | (a) `bootstrap` 一次性容器 (b) 手写配置 | **(a)** |

### D11 MongoDB 形态

| 选项 | 说明 | 影响 |
|---|---|---|
| A | **Replica Set ×3**（1P2S） | 1.08 GB（含 exporter） |
| B | RS×3 + Sharded（+config×3 + mongos×2） | +1.3 GB，仅当要验证分片 |

**推荐**：**A**；分片留可选 profile（`--profile mongo-shard`）

### D12 Redis 版本

| 选项 | 说明 | 推荐 |
|---|---|---|
| A | `redis:7.4`（Sentinel/Cluster 生态成熟） | ✅ |
| B | `redis:8.x` | — |

**影响**：两组 profile 必须同版本（`services/redis/config/base/redis-base.conf` 共用）

### D13 Kafka 版本与附加件

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | **3.9**（KRaft 成熟）/ 4.0（纯 KRaft） | 3.9（保守） |
| exporter | 要 / 不要 | **要**（已计入 0.03 GB） |
| UI | kafka-ui（+0.4 GB）/ 不要 | 先不要 |

### D14 RocketMQ 版本与架构

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | **5.3** | 5.3 |
| 复制 | **DLedger(Raft) 3 broker** | 已定（F11） |
| Proxy | 5.x gRPC proxy（+0.6 GB）/ 不用 | **不用**，走原生 remoting |
| exporter | 要 / 不要 | **要**（`rocketmq-exporter`，`.7.41:5557`） |

### D15 RabbitMQ 版本与队列语义

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | 3.13 / **4.x** | 4.x（quorum 成熟） |
| 队列默认 | classic / **quorum** | **quorum**（否则 3 节点无意义） |
| 指标 | 原生 `rabbitmq_prometheus`（`:15692`）/ 额外 exporter | **原生**（DEC-35） |

### D16 etcd / Consul / NATS 版本与安全

| 项 | 选项 | 推荐 |
|---|---|---|
| etcd | 3.5 / **3.6** | 3.6 |
| consul | **1.20**；ACL：(a) 关（测试快）(b) 开 ACL + gossip 加密 | **(a)**，避免客户端到处配 token |
| nats | **2.11**；JetStream (a) R3 (b) 单副本 | **(a)** |
| nats 指标 | `nats-exporter`（`.11.41:7777`）/ 只抓 /varz | **exporter**（`/varz` 是 JSON，Prom 不能直抓） |

### D17 MinIO 版本与容量 ⛔ 作废

v4.2 删除 minio（DEC-38，无消费者）。若将来需要对象存储（应用 S3 / Thanos），按 plan §17 追加新域，届时应重新回答版本 pin、4×1 还是 4×4 盘、是否 `MINIO_CI_CD=1`。

### D18 nginx 版本

| 项 | 选项 | 推荐 |
|---|---|---|
| 版本 | **1.27**（mainline）/ 1.26（stable） | 1.27 |

> 已定：统一入口 + 子域 `<svc>.localhost`（F13 / DEC-21）。

### D19 镜像版本总表（= `base/images.yml` 初始内容）

**前提**：D01 = 官方源 + 可自定义；D02 = 默认 `X.Y`，上游不发 `X.Y` 的按 `X.Y.Z` pin。
**说明**：下表给的是**候选与 tag 形态**；具体补丁号在 P0 首次 `make prepull` 时锁定并写死（`X.Y` 形态的镜像不写补丁）。

| 组件 | 镜像（候选） | tag 形态 | 备注 |
|---|---|---|---|
| nginx | `nginx:1.27-alpine` | `X.Y` | |
| postgres | `postgres:17.5` | `X.Y` | 大版本 17 |
| patroni | `ghcr.io/zalando/spilo-17:4.0-p3` | 上游自有 | spilo 打包 PG+Patroni，tag 不由我们控制 |
| haproxy | `haproxy:3.0-alpine` | `X.Y` | |
| redis | `redis:7.4-alpine` | `X.Y` | 两组 profile 必须同版本 |
| redis_exporter | `oliver006/redis_exporter:v1.67.0` | `X.Y.Z` | 小版本会改指标名 |
| mysql | `mysql:8.4` | `X.Y` | LTS |
| mysql-router | `mysql/mysql-router:8.4` | `X.Y` | 与 mysql 同版本 |
| mongo | `mongo:7.0` | `X.Y` | 保守选 7.0；要 8.0 需先验证 `rs.initiate` 脚本 |
| mongodb_exporter | `percona/mongodb_exporter:0.43` | `X.Y` | |
| kafka | `apache/kafka:3.9.0` | `X.Y.Z` | 上游不发 `X.Y` 标签 |
| kafka-exporter | `danielqsj/kafka-exporter:v1.8.0` | `X.Y.Z` | 上游不发 `X.Y` |
| rocketmq | `apache/rocketmq:5.3.1` | `X.Y.Z` | 上游不发 `X.Y` |
| rocketmq-exporter | `apacherocketmq/rocketmq-exporter:0.0.5` | `X.Y.Z` | 上游不发 `X.Y` |
| rabbitmq | `rabbitmq:4.0-management` | `X.Y` | |
| etcd | `quay.io/coreos/etcd:v3.6.0` | `X.Y.Z` | 官方在 quay；tag 无 `X.Y` |
| consul | `hashicorp/consul:1.20` | `X.Y` | |
| nats | `nats:2.11-alpine` | `X.Y` | |
| nats-exporter | `natsio/prometheus-nats-exporter:0.16.0` | `X.Y.Z` | 上游不发 `X.Y` |
| prometheus | `prom/prometheus:v3.5.0` | `X.Y.Z` | v3 待确认（见下） |
| alertmanager | `prom/alertmanager:v0.28.1` | `X.Y.Z` | 0.x 阶段只有 `X.Y.Z` |
| grafana | `grafana/grafana:11.6.0` | `X.Y.Z` | 上游主推 `X.Y.Z` |
| nacos-server | `nacos/nacos-server:v3.x` | `X.Y.Z` | 3.x 线；具体补丁 P5 锁定（R28） |
| nacos-console | `nacos/nacos-console:v3.x`（若 3.x 未拆镜像则复用 server 镜像） | `X.Y.Z` | P5 确认打包方式（R28 锁定四项之一） |
| jaeger | `jaegertracing/jaeger:2.6.0` | `X.Y.Z` | 上游只发 `X.Y.Z` |

**待你确认（不阻塞 P0）**：Prometheus 是否直接上 **v3**（3.x 破坏性变更集中在 PromQL/API/UI 与 `--enable-feature`；TSDB 仍可读 2.x 数据，降级需先验证）。
**推荐**：上 v3（本项目无历史数据包袱），并在 `docs/stacks.md` 记录"降级需重灌数据"。

### D35 Nacos 版本与库的归属 ✅ 已定案（B = 3.x）

**结论**：**Nacos 3.x**，库仍复用 mysql 栈（plan DEC-44）。由此带来的结构性变化：

| 项 | 2.x | **3.x（本方案）** |
|---|---|---|
| 控制台 | 与 server 同端口 `8848`，路径 `/nacos` | **独立前端 `nacos-console`，`8080`，根路径** |
| 容器 | server ×3 | **server ×3 + console ×1**（26→27 solo、69→70 ha） |
| 端口 | 8848 / 9848 / 9849 / 7848 | 同上 + **8080**（console） |
| schema | 2.x `mysql-schema.sql` | **3.x** 的脚本（不可混用，且不跨大版本恢复） |
| 内存 | 0.40 / 1.20 GB | **0.55 / 1.35 GB**（server 384m×3 + console 192m） |

**P5 首次启动必须锁定的四项**（写进 `docs/stacks.md`，风险登记为 R28）：
① console 是否独立镜像/端口；② health 与 metrics 的准确路径；③ 3.x schema 文件名；④ 鉴权是否默认开启。
**阻塞**：P5

### D36 Nacos 鉴权与命名空间策略 🆕（3.x 语境已更新）

**背景**：3.x 与 2.x 的鉴权默认值不同（属 R28 的"锁定四项"之一），所以这一项要等 P5 首次启动确认默认值后再拍。

| 选项 | 说明 |
|---|---|
| A | **保持/开启鉴权**：`token.secret.key` 三节点一致 + 初始化 admin 密码；命名空间 `public` + 一个 `dev` |
| B | 关鉴权（本地测试最省事，客户端不用带凭证） |
| C | 开鉴权 + 每栈一个命名空间（edge / pg / kafka …） |

**推荐**：**A**（顺带验证「token 不一致 → 节点互踢」这个真实坑，成本几乎为零）
**影响**：客户端需带 `username/password`；token 存 `.env`（不入 `data/` 备份）；console 登录依赖 admin 初始化
**阻塞**：P5（与 R28 的四项一起确认）

---

## 4. 方案缺口

### D20 监控后端 ✅ 已定案

**已定**（plan DEC-20/24/29 / §16）：observability 域（块 `172.28.12.x`），按组件拆 4 栈：
`prometheus`（0.30/0.85）· `alertmanager`（0.05）· `grafana`（0.25）· `jaeger`（0.15）；合计 solo 0.75 / ha 1.30 GB。
抓取目标双来源（DEC-35）：`role=exporter` 行 + 原生 `/metrics` 映射表；
目标集再按各栈当前部署形态过滤（DEC-47 / F31）——否则 solo 形态的栈会把不存在的副本
长期报成 `down`（实测反例：consul 跑 solo 时 `consul-2/3` 常年在 2 个 down 里）。
仅剩子项：Thanos（N 级）、Loki（D26）、容器指标（D30）。

### D21 solo↔ha 切换的数据处理

| 选项 | 说明 |
|---|---|
| A | 不迁移，切换提示"数据不互通"（最快） |
| B | `stack-switch --migrate`：solo → ha 走逻辑导出（pg_basebackup / mysqldump / DUMP+RESTORE） |
| C | 禁用手动切换，只能 `stack-reset` |

**推荐**：**A**，P5 之后再考虑 B
**阻塞**：P0（决定 `stack-switch` 是否有 `--migrate` 分支）

### D22 资源硬限额

| 选项 | 说明 |
|---|---|
| A | 设 `deploy.resources.limits`（cpus + memory） |
| B | 不设，靠应用层限制（`maxmemory` / `-Xmx` / `innodb_buffer_pool_size`） |
| C | 只给 JVM 类设 |

**推荐**：**C → 逐步到 A**（P0 先不设避免调试期误杀；P6 完成后统一切 A）

### D23 人类可读域名 ✅ 已定案

`<svc>.localhost`（macOS 原生解析）；容器内禁止 `.localhost`，一律 IP/服务名。

### D24 备份策略

| 项 | 选项 | 推荐 |
|---|---|---|
| 形式 | (a) tar 冷备（停栈） (b) 逻辑导出 + 状态文件 | **(b)** |
| 存放 | `data/backups/`（仓库内，gitignore）/ 仓库外 | **仓库内** |
| 保留 | 最近 5 份 / 按日期 | 最近 5 份 |
| 异地 | restic → 外部 / 不要 | P7 后再议 |

### D25 CI

| 选项 | 说明 | 推荐 |
|---|---|---|
| A | GitHub Actions：`doctor.sh` + `compose config` + yamllint + markdownlint | ✅ |
| B | A + 夜间跑 `failover-drill`（需特权 runner） | — |
| C | 不做 | — |

**推荐**：**A**

### D26 日志去向

| 选项 | 说明 |
|---|---|
| A | 各栈 `data/<node>/logs/` + json-file 限流 |
| B | A + 统一到 `data/_logs/` 软链，便于 `make logs-all` |
| C | A + Loki（+2 容器 / +0.3 GB） |

**推荐**：**B**（13 域 71 容器下，`make logs-all` 已成刚需）

### D27 首次拉取与建栈总耗时预算

**问题**：13 域全量首次 `stack-up`（拉 24 个镜像 + 初始化 + bootstrap）预计 **1.5–2 小时**。

**需要你确认**：接受"分档预热"（`make prepull` 按档位分批：A → B/C/D/E）
**推荐**：接受，并写进 `docs/stacks.md` 的"首次使用"

### D28 故障演练的范围与频率

| 选项 | 说明 |
|---|---|
| A | 每栈一个 `failover-drill`，手动按需跑 |
| B | A + `make drill-all` 顺序跑全部可演练栈（pg / redis×2 / mysql / mongo / kafka / rocketmq，约 20 min） |
| C | 纳入 CI 定时跑 |

**推荐**：**A + B**（不纳入 CI，见 D25）

### D29 OrbStack VM 内存

| 选项 | 说明 |
|---|---|
| A | 保持自动（可见 15.7 GB），严格按档位 |
| B | `orb config set memory_mib 24576`（物理 48 GB） |

**推荐**：**B（可选）**——v4.2 删掉三个工具后全量 ha 为 **14.5 GB**，默认配置装得下（余量 ≈ 1.2 GB）；提高 VM 内存只是为了给"临时全量演练 + 未来追加域"留缓冲
**需你授权**：改的是全局运行时配置

### D30 容器资源指标来源

| 选项 | 说明 | 成本 |
|---|---|---|
| A | `services/cadvisor/` 独立目录（`.12.41`，`role=exporter`，profile `cadvisor`） | +0.10 GB / +1 容器（69 → 70） |
| B | Docker daemon metrics（`metrics-addr`，改 OrbStack daemon） | 0 容器；改全局配置 |
| C | 不做容器级面板，只留"全栈 up/down" | 0 |

**推荐**：**A**（符合"按组件来"；不动 daemon）
**影响**：容器 69 → 70，内存 14.5 → 14.6 GB

### D31 Redis 持久化组合 ✅ 已定案（A）

**结论**：**AOF(`everysec`) + RDB 快照并存**（plan DEC-41），两组 profile 共用 `services/redis/config/base/redis-base.conf`。

- AOF：`appendonly yes` + `appendfsync everysec` → 哨兵切主/节点重启不丢写；
- RDB：保留默认 `save` 策略 → `backup-all.sh` 可在不停栈的情况下 `BGSAVE` 导出（D24）；
- 两者同时存在时，**重启优先加载 AOF**（这是预期行为，`docs/stacks.md` 要写明）。

**影响**：`data/<group>/<node>/appendonlydir` 与 `dump.rdb` 都会出现在 `data/`，备份体积略增
**阻塞**：无（P3 按此渲染 `redis-base.conf`）

### D32 Redis 内存档位与淘汰策略

| 选项 | 说明 |
|---|---|
| A | `256mb` + `noeviction`（写满即报错，问题显性） |
| B | `512mb` + `allkeys-lru`（贴近生产缓存行为） |
| C | 两组分档：哨兵组 A、集群组 B |

**推荐**：**C**（一次覆盖两种真实场景）
**阻塞**：P3

### D33 Jaeger 版本、存储与保留

| 选项 | 说明 |
|---|---|
| A | `jaeger:2.x`（OTel Collector 发行版）+ Badger，TTL 72h |
| B | `jaegertracing/all-in-one:1.6x`（v1，官方已宣布 EOL 路线） |
| C | Jaeger + Elasticsearch/Cassandra（真 HA，需再加存储域） |

**推荐**：**A**（ES 后端列 N09）
**阻塞**：P7

### D34 谁来产生 trace（验收口径）

| 选项 | 说明 | 成本 |
|---|---|---|
| A | 只提供接入点，trace 由你的应用推 | 0；P7 验收无法自动化 |
| B | `make trace-demo`：curl 向 `:4318/v1/traces` 推一条固定 trace | 约 30 行脚本 |
| C | 新增常驻 `services/otel-demo/`（持续发 trace） | +0.2 GB / +1 容器 / +1 目录 |

**推荐**：**B**
**阻塞**：P7

### D37 sentinel 是否设密码以进指标 🆕

**背景**：DEC-49 已把 sentinel 口（26379）从 `/scrape` 中继的目标里剔除。剔除后 `redis-sentinel` profile 的指标面只剩 3 个 6379 节点；主从切换本身仍可通过 `redis_role` 在两个 instance 间互换成像观测，但**拿不到 sentinel 自身的 INFO 指标**（`sentinel_masters` / `sentinel_active_instances` / 已故障转移次数等）。

| 选项 | 说明 | 代价 |
|---|---|---|
| A | **不设密码，不进指标**（现状，推荐） | 缺 sentinel 控制面指标；sentinel 健康改由 `make stack-status` + `failover-drill` 举证 |
| B | 给三台 sentinel 也 `requirepass`（同集群密码），中继带密码即可采到 | 需重测 sentinel 互联与 quorum 鉴权路径、切主后的 `sentinel.conf` 重写、`auth-pass` 与自身密码同名带来的歧义 |

**推荐**：**A**。理由：本仓库 sentinel 的角色是"验证切换语义"而不是"长期值守"，控制面健康由脚本举证比多一个指标更直接；B 会改动已实测通过的切主路径，风险收益比不划算。
**影响**：仅 `redis-sentinel` profile（`services/redis/compose.yml` 的 sentinel 段 + `services/prometheus/scripts/render.sh` 的 `redis_targets()`）
**阻塞**：无

---

## 5. 明确不做（供你否决）

| # | 项 | 理由 |
|---|---|---|
| N01 | Kubernetes / k3s | 目标是"多组件栈验证"，不是编排平台验证；OrbStack k8s 保持关闭 |
| N02 | 真实多机分布式 | R5 边界已写明；需另立方案（多 VM / SSH driver） |
| N03 | TLS / 自签证书体系 | 本地测试收益低；nginx 443 仅用自签占位 |
| N04 | Terraform / Ansible | 纯 compose + 脚本足够；引入会与"数据在仓库内"冲突 |
| N05 | keepalived / VIP | DEC-12 已定 |
| N06 | Redis 可视化 UI（RedisInsight 等） | 用 `redis-cli` + Grafana 即可；需要时按 §17 追加一栈 |
| N07 | Redis Stack / 模块（JSON、Search、TS） | 与缓存语义验证无关，且会替换标准 `redis` 镜像 |
| N08 | 真实告警外发（Slack/邮件） | mailpit 已于 v4.2 删除；告警在 `alertmanager.localhost` 与 Grafana 查看，`receivers` 为 `nul` |
| N09 | Jaeger 分布式存储后端（ES/Cassandra） | 真 HA 需再加 1–2 个域；当前 Badger + 72h TTL 足够 |
| N10 | trace → metrics exemplar / span metrics | 需 collector 侧 spanmetrics connector 并改面板口径，收益低 |
| N11 | Nacos 独立数据库（自带 MySQL / Derby 集群） | 集群模式必须共享库；再建一个 MySQL 违反 DEC-13，复用 mysql 栈即可 |
| N12 | 对象存储（MinIO / SeaweedFS / S3）与邮件外发（mailpit） | v4.2 按"无消费者"删除（DEC-38）；应用真需要 S3 或告警外发时，按 plan §17 各追加一个域，不要复活旧目录 |

---

## 6. P0 已解锁

P0 的 8 项决策全部落定，可以直接进入 `plan §13` 的 P0 实施：

| ID | 结论 | 落点 |
|---|---|---|
| D01 | 官方镜像 + 可自定义（`images.yml` + `.env` 覆盖） | DEC-39 |
| D02 | 版本粒度 `X.Y`，禁止 `latest` | DEC-40 |
| D03 | 入口 `80/443`，仅 nginx-1 发布，`ENTRY_HTTP_PORT` 可覆盖 | DEC-42 |
| D04 | 单一 `env/.env` + `gen-secrets.sh`，`make secrets-show` 可打印（按推荐） | — |
| D05 | `base/anchors.yml` 生成期展开（按推荐） | — |
| D06 | compose 全生成，不手写 include（按推荐） | — |
| D07 | ini 保持竖线 5 列（按推荐） | — |
| D08 | `TZ=Asia/Shanghai`，MySQL/Mongo `utf8mb4` | DEC-43 |

**P0 交付物**（plan §13）：`base/`（network / anchors / images / jvm）、`stock/network.ini`（14 域花名册）、`services/nginx`、`doctor.sh`、`render-all.sh`、`Makefile`、`.gitignore`、`env/`。

**P0 验收**：`make doctor` 15 项全绿（按"已启用的栈"取集合）；`MODE=solo` 起 1 容器、`MODE=ha` 起 2 容器；容器内 `date` 显示 `CST +0800`；`git status` 不含 `data/`、`.env`。

**其余待答（都不阻塞 P0）**：D09–D19（各栈版本/形态，按推荐落地）、D21–D34（方案缺口；D20 已定，仅剩子项）、D36（Nacos 鉴权，P5 与 R28 一起确认）、D37（sentinel 是否设密码以进指标，P3 语境）。

> Q10（RabbitMQ 端口段）已按推荐落地（F28）：`35672-35682` 写进 ini，doctor 第 3 项按区间展开校验；若不需要可删该段。

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
