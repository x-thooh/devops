# devops 本地多栈测试环境 · 总体方案 v4.5（15 域，按组件拆目录）

> 单机（macOS + OrbStack）承载 **15 个 IP 域 / 17 个组件目录 / 18 个部署单元**：
> **solo 形态**（单节点，日常调试）与 **ha 形态**（集群/主从，验证台架，≈ 71 容器）双轨并存，
> 全部同一网络且各带固定 IP，配置与运行时数据全部位于本仓库，
> **每个组件（除明确豁免的工具类）的 ha 形态都具备集群或主从**，
> 并统一经 `<服务>.localhost` 子域从宿主访问（§15），指标汇入可观测性域（§16）。
>
> **v4.0 是恢复版本**：v3.x 曾把范围缩到"只保留 Redis"，现按**同一条组件化规则**把 13 个域加回来；
> **v4.1 新增第 14 域 Nacos**（服务注册 + 配置中心，3 节点 + 复用 mysql 栈的库）；
> **v4.2 移除三件接入面工具**（mailpit / adminer / minio），edge 域只保留 nginx：
> 每个产品一个目录（`redis` 是唯一按 §2.1 复合的四条硬条件合并的目录），入口/工具不再挤在 `core/` 里。
> **v4.4 启用第 15 域 `.20.x` docsify**（§17 预留块的第一个）：把仓库 `docs/` 变成可浏览站点，
> 经 `docsify.localhost` 从宿主访问；无状态纯浏览，HA 豁免（DEC-46）。
> **v4.5 不改范围，只改"能不能相信绿色"**：抓取目标按已部署形态过滤（DEC-47）、doctor 增加
> 运行态第 15 项与 daemon 重启恢复口径（DEC-48）、sentinel 口不再进指标（DEC-49）、
> 单栈命令 MODE 缺省沿用当前部署形态（DEC-50）、工具链与依赖由 `mise.toml` + `.venv` 固定（DEC-51）、
> `stack-up` 改为「起容器 → bootstrap → 等健康」两段式（DEC-52）。
> 缩容期的文档归档在 `docs/archive/plan-v3.2-redis-only.md`，13 域时代的原始设计在 `docs/archive/plan-v2.3-13stacks.md`。

---

## 0. 需求追溯

| 需求 | 设计落点 | 章节 |
|---|---|---|
| ① 所有容器同一网络，各自分配 IP | 单一 `devnet` = `172.28.0.0/16`，每服务显式 `ipv4_address`，IP 唯一权威登记在 `stock/network.ini`，`doctor.sh` 双向校验 | §3 §6 |
| ② 配置、运行时数据放 devops | `services/<组件>/config`（入库）+ `services/<组件>/data`（gitignore，`**/.data/` 一条规则） | §4 |
| ③ Redis 集群 + 哨兵 | 独立两块 IP 段（`.2.x` 哨兵、`.3.x` 集群），配置互斥、profile 隔离，状态文件持久化 | §5 §8 |
| ④ PG 主从 + Kafka / MySQL / MongoDB / RocketMQ / RabbitMQ / etcd / Consul / NATS | 13 域块号表 + 身份固化清单 + 统一 bootstrap 契约 + 内存分档 | §3 §5 §8 §10 |
| ⑤ 每个组件都要有集群/主从形态 | §5.2 集群形态选型表（每域最小可用 HA 与理由）；§5.3 工具豁免清单 | §5.2 §5.3 |
| ⑥ 各栈 UI 从宿主访问 + 指标统一归集 | §15 `<svc>.localhost` 子域 + §16 可观测性域（prometheus / alertmanager / grafana / jaeger 四栈） | §15 §16 |
| ⑦ 所有组件按组件拆目录（含入口与工具） | 每个产品一个目录；`services/redis/` 是唯一多 profile 目录（§2.1 复合栈四条硬条件） | §2.1 §4 §8.0.1 |
| ⑧ 链路追踪（Jaeger） | `services/jaeger/`（`.12.32`）：OTLP 接收 + Badger 存储 + UI，Grafana 经 Jaeger 数据源检索 | §16.5 |
| ⑨ **Nacos 3.x**（服务注册 + 配置中心） | 新域 `.13.x`：`nacos-server-1/2/3`（8848 API + 9848/9849 gRPC + 7848 JRaft）+ `nacos-console`（8080，3.x 起控制台独立），**复用 mysql 栈的库** | §5.2 §11 |

### 0.1 版本沿革（避免混淆）

| 版本 | 形态 | 容器 | 内存 | 定位 |
|---|---|---|---|---|
| **v1** | 全单节点（nginx 1、pg 1、redis 1、minio 1、工具若干） | 5–6 | ≈ 0.6 GB | 最小可用基线 |
| **v2** | 全 HA（12 栈集群/主从） | ≈ 61 | ≈ 13.2 GB | 集群验证台架，**日常偏重** |
| **v2.1** | 双形态 solo / ha | 6 / 61 | 0.6 / 13.2 GB | solo 快迭代，ha 做验证 |
| **v2.2** | + observability 栈 + `<svc>.localhost` 入口 | 3 / 65 | 0.6 / 14.35 GB | 补齐监控后端、UI 访问、入口域名 |
| **v2.3** | observability 按组件拆 3 栈 + 三层模型 | 3 / 65 | 0.6 / 14.35 GB | 部署单元边界 |
| **v3.0–v3.2** | 缩容：只保留 Redis + 入口 + 观测（含 jaeger），并把 `core` 拆成 nginx / mailpit | 10 / 22 | 1.0 / 2.2 GB | **已撤销**（归档 `plan-v3.2-redis-only.md`） |
| **v4.0** | **13 域全量恢复**，并按 v3.x 的组件化规则重排：18 目录 / 19 部署单元 / +jaeger | 28 / 72 | 5.2 / 14.6 GB | 回到"多组件验证台架"，但目录结构与拆分判据统一 |
| **v4.1** | v4.0 + **Nacos 域**（`.13.x`，3 节点；配置存 mysql 栈） | 29 / 75 | 5.6 / 15.8 GB | 补上服务注册/配置中心 |
| **v4.2** | v4.1 − **mailpit / adminer / minio**（三个接入面工具），edge 只留 nginx | 26 / 69 | 5.1 / 14.5 GB | 去掉无消费者与可替代的工具；全量 ha 回到 15.7 GB 以内 |
| **v4.3** | v4.2 + **Nacos 升 3.x**：`nacos-server`×3 + **`nacos-console`×1**（控制台独立端口 8080），schema 用 3.x 脚本 | **27 / 70** | **5.3 / 14.7 GB** | 跟官方 3.x 的 server/console 拆分；端口表、路由、身份清单、probe 全部按 3.x 更新 |
| **v4.4（上一版）** | v4.3 + **第 15 域 `.20.x` docsify**（`docsify-1`×1，仓库 `docs/` 只读浏览，`docsify.localhost`） | **28 / 71** | **5.35 / 14.75 GB** | 文档从"打开文件读"变成"站点读"；无状态、HA 豁免，只增 1 容器 / 0.05 GB |
| **v4.5（本版）** | 范围不变；**观测与体检口径修正 + 工具链固定**：抓取目标按已部署形态过滤（DEC-47）、doctor 第 15 项运行态健康 + daemon 重启恢复口径（DEC-48）、sentinel 口不进指标（DEC-49）、`stack.sh` 的 MODE 缺省改为沿用当前部署形态（DEC-50）、Python 由 `mise.toml` + 仓库内 `.venv` 固定（DEC-51）、`stack-up` 两段式启动让恢复口径真能重放（DEC-52） | 28 / 71（不变） | 5.35 / 14.75 GB（不变） | 从"全停也能绿"变成"绿了才算真跑起来"；假 down / 假 `redis_up 0` / 面板未 provision / ha 部署被当 solo 查 / 换个 shell 就选错解释器 / "重跑 stack-up 即恢复"对 mysql 名实不符，六类"看起来正常"均被消除 |

> v3.0 缩容的直接代价是"无法验证跨组件交互"（缓存↔DB、消息堆积→缓存回填），v4.0 把该能力恢复；
> 代价是内存重回 14.7 GB / 可见 15.7 GB —— 六档纪律（§9.1）与 §9.2 限流重新变成硬约束。

---

## 1. 已实测确认的环境事实

| 探测项 | 结果 | 对方案的影响 |
|---|---|---|
| Docker context | `orbstack`（Docker 29.8.2 / Compose v5.5.0） | 入口统一，换运行时需重做方案 |
| **宿主直连容器 IP**（`172.28.0.10:8080`） | ✅ **可达** | 哨兵/集群/PG/MySQL/Router 返回的 `IP:port` 宿主可直接用，**无需端口重映射**，避免 NAT 破坏地址公告 |
| 同网络容器按静态 IP 互访 | ✅ 可达 | 静态 IP 方案成立 |
| `172.28.0.0/16` 与宿主路由 | ✅ 无冲突（宿主已用 `192.168.1.0/24`、`192.168.138.0/23`） | 可直接采用 /16 |
| `include: services/*/compose.yml`（glob） | ❌ 不支持 | 聚合文件用**生成**而非手写清单 |
| `include` + `profiles` 透传 | ✅ 无 profile 时服务为空 | 组件文件必须自带 `profiles` |
| 组件内 `./.data`、`./config` 相对路径基准 | ✅ 以**组件文件所在目录**为基准 | 组件可整体搬迁，高内聚成立 |
| 物理内存 / CPU | 48 GB / 14 core | — |
| Docker VM 可见内存 | **15.7 GB** | 全量 ha **14.75 GB**（余量 ≈ 0.95 GB）→ 装得下，但**仍禁止常驻**（§9.1） |

> ⚠️ 前提声明：宿主免端口映射依赖 OrbStack 的容器 IP 路由（`docker.expose_ports_to_lan: true`）。
> 换到 Colima / Docker Desktop 默认配置时，**Sentinel 公告的主节点 IP、Cluster 的 `nodes.conf` 地址、Patroni/MySQL Router 的选主地址、Kafka 的 `advertised.listeners`** 都会失效（§13 R1）。

---

## 2. 分层原则

**组件内聚（垂直切片）+ 全局不变量集中（水平薄层）。**

| 一起变的东西 | 位置 |
|---|---|
| 某栈的服务定义、配置模板、bootstrap 脚本、运行数据 | `services/<stack>/` 内（删栈 = `rm -rf` 一个目录） |
| 子网、网关、IP 花名册、镜像清单、日志/重启/TZ/健康检查锚点 | `base/` + `stock/`，组件内出现 `subnet:`、`logging:`、字面量 `image:` 一律打回 |
| 跨栈胶水（体检、全量备份、聚合生成） | 顶层 `scripts/` |

### 2.1 三层模型（回答"什么该拆成独立栈"）

| 层 | 单位 | 数量 | 决定什么 |
|---|---|---|---|
| 域（domain） | `/24` IP 块 | 15 | IP 段分配；域内组件共享网关与尾号约定 |
| **组件目录（stack dir）** | `services/<name>/` | **17** | 配置 / 脚本 / 数据的**物理归属**（删栈 = `rm -rf` 一个目录） |
| **部署单元（profile）** | `compose.yml` 里的一组 `profiles` | **18** | 起停 / 重置 / 形态切换的最小单位 |
| 容器（container） | service | 28 / 71 | 进程与资源占用（solo / ha） |

17 个目录 → 18 个部署单元，因为 `services/redis/` 是**复合栈**（一个目录两组互斥 profile）。

**拆分判据（默认拆目录）**：一个目录 = **一个可独立起停、独立重置、独立切 solo/ha 的部署单元**，且配置格式与状态生命周期不与他者耦合。

- ✅ 独立成目录：`nginx`（v3.2 从 `core/` 拆出后仅剩它）、`prometheus` / `alertmanager` / `grafana` / `jaeger`（v2.3 起拆开）。
- ❌ v4.2 删除：`mailpit`（无告警外发需求）、`adminer`（用 `make stack-shell` 代替）、`minio`（无消费者的对象存储）——见 DEC-38。
- ❌ 留在宿主目录内：`pg-dcs`（Patroni 的 DCS，DEC-16：生命周期必须与 PG 绑定）、`pg-haproxy` / `mysql-router`（宿主栈的访问层）、`*-exporter`（随被采对象）、`bootstrap` 一次性容器（幂等子步骤）。

**复合栈例外（`services/redis/`，全项目唯一）**：以下四条同时成立时，允许一个目录装两组 profile：

1. **同一产品、同一镜像**（都是 `redis:7.4`）；
2. **profile 互斥且不同时运行**（哨兵栈与集群栈语义互斥，不会共存）；
3. **共享配置占比高**（`config/base/redis-base.conf`、exporter 定义、`render/status/reset` 脚本骨架均复用）；
4. **状态仍按 profile 物理隔离**（`.data/sentinel/<node>/` vs `.data/cluster/<node>/`）。

> 与观测域的区别：prometheus / alertmanager / grafana / jaeger 是四个不同产品、可同时运行、重置影响面各异，所以必须拆目录（DEC-24）；
> Redis 两套形态是同一产品的两种拓扑且互斥运行。判据看"是否同一产品 + 能否共存 + 配置能否复用"，不是"拓扑有几个"。
>
> 判据可直接验收：`make stack-reset S=grafana` 不该丢 TSDB；`make stack-reset S=redis-sentinel` **只**清 `.data/sentinel/`，不碰 `.data/cluster/`；
> `make stack-reset S=pg` 不该影响 `pg` 的 DCS 之外的任何栈。

---

## 3. 网络与 IP 规划

### 3.1 网络

```yaml
# base/network.yml —— 网络定义的唯一出现处
networks:
  devnet:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
          gateway: 172.28.0.1
```

### 3.2 块号 = 域号（15 块已启用）

| 块 | 域 | 块 | 域 |
|---|---|---|---|
| `172.28.0.0/24` | **edge**（入口：nginx） | `172.28.7.0/24` | rocketmq |
| `172.28.1.0/24` | pg | `172.28.8.0/24` | rabbitmq |
| `172.28.2.0/24` | redis-sentinel | `172.28.9.0/24` | etcd |
| `172.28.3.0/24` | redis-cluster | `172.28.10.0/24` | consul |
| `172.28.4.0/24` | mysql | `172.28.11.0/24` | nats |
| `172.28.5.0/24` | mongo | `172.28.12.0/24` | **observability**（四栈共享） |
| `172.28.6.0/24` | kafka | `172.28.13.0/24` | **nacos** |
| | | `172.28.20.0/24` | **docsify**（§17 预留块 `.20–.29` 首个启用） |
| | | `172.28.21–29.0/24` | 预留 |
| `172.28.99.0/24` | 一次性/工具容器 | | |

### 3.3 块内尾号约定（15 域统一）

| 尾号 | 角色 |
|---|---|
| `.1` / `.2` | 网关（Docker 自占）/ 仅备用 VIP（可选组件） |
| **`.11–.19`** | 核心成员：primary / leader / broker / 入口 nginx / seed |
| **`.21–.29`** | 副本或次要成员：replica / secondary / sentinel / DLedger broker / controller |
| `.31–.39` | 栈内代理 / 前端 / DCS：haproxy / mysql-router / pg-dcs / grafana / jaeger / nacos-console |
| `.41–.49` | exporter / 观测 |
| `.51–.59` | 临时客户端（redis-cli、kafka CLI、benchmark） |

> **域 ≠ 组件**：域是 **IP 划分单位**（`/24`），可以含 1 个组件，也可以含多个；组件是 **目录/部署单元**单位。
> v4.4 之后只剩 **1 个功能域**（其余 14 个都是单组件域）：
>
> | 功能域 | 成员（组件目录） | 共享理由 |
> |---|---|---|
> | `.12.x` **observability** | `prometheus` `.11–.12`、`alertmanager` `.21`、`grafana` `.31`、`jaeger` `.32` | 观测四栈共享一个观测域，自监控映射表按该块生成 |
>
> `.0.x` 现在只放 `nginx`（入口），已从功能域退化为单组件域。IP 全 ini 唯一，`doctor.sh` 第 1/2 项照常校验。

---

## 4. 目录结构

```text
devops/
├── compose.yml                     # 唯一入口（生成物，见 §10）
├── compose.generated.yml
├── stock/
│   └── network.ini                 # ★ IP/端口/路由唯一权威（17 目录 / 18 部署单元）
├── base/
│   ├── network.yml                 # devnet ipam
│   ├── anchors.yml                 # x-common：logging/restart/TZ/healthcheck 默认
│   ├── images.yml                  # ★ 镜像唯一清单（官方源；.env 可逐个覆盖，DEC-39）
│   └── jvm/heap.env                # 统一 JVM 限堆变量（kafka / rocketmq）
├── services/
│   ├── nginx/                      # 部署单元 nginx：nginx-1 (.0.11, both) + nginx-2 (.0.12, ha)
│   │   ├── compose.yml
│   │   ├── config/nginx.conf       # 主配置（log_format / gzip / connection_upgrade map）
│   │   ├── scripts/{render,status,reset}.sh      # 无 bootstrap（无状态）
│   │   └── .data/conf.d/            # 生成物：每个 [routes] 行 → <host>.conf
│   ├── redis/                      # ★ 复合栈：一个目录，两个互斥 profile
│   │   ├── compose.yml             # profiles: redis-sentinel | redis-cluster
│   │   ├── config/
│   │   │   ├── base/redis-base.conf        # 两组共用（maxmemory / AOF / slowlog）
│   │   │   ├── sentinel/redis.conf         # master / replica 共用
│   │   │   ├── sentinel/sentinel.conf.tpl  # sentinel monitor 由 render 注入
│   │   │   └── cluster/redis.conf.tpl      # cluster-enabled / announce-ip / 总线端口
│   │   ├── scripts/
│   │   │   ├── sentinel/{render,bootstrap,status,reset}.sh   # 1M + 2R + 3S + exporter
│   │   │   └── cluster/{render,bootstrap,status,reset}.sh    # 3M + 3R + 16384 slots
│   │   └── .data/
│   │       ├── sentinel/<node>/    # redis-master / replica-1/2 / sentinel-1/2/3 / solo
│   │       └── cluster/<node>/     # rc-1/2/3 / rc-1r/2r/3r / solo
│   ├── pg/                         # patroni-1..3 (.1.11–13) + pg-dcs-1..3 (.1.31–33) + haproxy×2 (.1.34–35) + exporter (.1.41)
│   │   ├── compose.yml
│   │   ├── config/
│   │   │   ├── patroni.yml.tpl     # scope / restapi / dcs.hosts / bootstrap.dcs（render 注入）
│   │   │   ├── postgresql.conf     # 复制与限流（shared_buffers / wal）
│   │   │   ├── pg_hba.conf
│   │   │   └── haproxy.cfg.tpl     # 5000 主写 / 5001 只读 / 7000 stats
│   │   ├── scripts/{render,bootstrap,status,reset,failover-drill}.sh
│   │   └── .data/
│   │       ├── patroni-{1,2,3}/    # PG 数据 + patroni 状态
│   │       ├── pg-dcs-{1,2,3}/     # etcd 数据（DCS）
│   │       └── solo/
│   ├── mysql/                      # mysql-1..3 (.4.11–13) + router×2 (.4.31–32) + exporter (.4.41)
│   │   ├── compose.yml
│   │   ├── config/{my.cnf.tpl, router.cnf.tpl}
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/{mysql-{1,2,3},router-{1,2},solo}/
│   ├── mongo/                      # mongo-1..3 (.5.11–13) + exporter (.5.41)
│   │   ├── compose.yml
│   │   ├── config/{mongod.conf.tpl, keyfile, rs-init.js.tpl}
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/{mongo-{1,2,3},solo}/
│   ├── kafka/                      # broker×3 (.6.11–13) + controller×3 (.6.21–23) + exporter (.6.41)
│   │   ├── compose.yml
│   │   ├── config/{server.properties.tpl, controller.properties.tpl}
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/{kafka-{1,2,3},ctrl-{1,2,3},solo}/
│   ├── rocketmq/                   # namesrv×2 (.7.11–12) + broker×3 DLedger (.7.21–23) + exporter (.7.41)
│   │   ├── compose.yml
│   │   ├── config/{broker.conf.tpl, dledger.conf.tpl}
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/{broker-{1,2,3},solo}/
│   ├── rabbitmq/                   # rabbit-1..3 (.8.11–13)，quorum queue，原生 :15692 指标
│   │   ├── compose.yml
│   │   ├── config/{rabbitmq.conf.tpl, enabled_plugins, definitions.json}
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/{rabbit-{1,2,3},solo}/
│   ├── etcd/                       # etcd-1..3 (.9.11–13)，原生 :2379/metrics
│   │   ├── compose.yml
│   │   ├── config/etcd.conf.tpl
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/{etcd-{1,2,3},solo}/
│   ├── consul/                     # consul-1..3 (.10.11–13)，原生 :8500/v1/agent/metrics
│   │   ├── compose.yml
│   │   ├── config/consul.hcl.tpl
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/{consul-{1,2,3},solo}/
│   ├── nats/                       # nats-1..3 (.11.11–13) + nats-exporter (.11.41)，JetStream R3
│   │   ├── compose.yml
│   │   ├── config/nats.conf.tpl
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/{nats-{1,2,3},solo}/
│   ├── nacos/                      # 3.x：nacos-server-1..3 (.13.11–13) + nacos-console (.13.32)
│   │   ├── compose.yml             # 两组 service：server×3 + console×1（同属 profile nacos）
│   │   ├── config/
│   │   │   ├── application.properties.tpl  # DB 指向 mysql Router、cluster.conf、auth token、console 端口
│   │   │   ├── cluster.conf.tpl            # 3 个固定 IP（render 注入）
│   │   │   └── mysql-schema.sql            # **3.x** 的 nacos_config 建表脚本（不可混用 2.x）
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/nacos-server-{1,2,3}/     # logs / data（配置与注册数据在 MySQL）
│   ├── prometheus/                 # prometheus-1 (.12.11, both) + prometheus-2 (.12.12, ha)
│   │   ├── compose.yml
│   │   ├── config/
│   │   │   ├── prometheus.yml.tpl  # scrape_configs 由 ini 的 exporter 行 + 原生指标表生成
│   │   │   └── rules/{redis.rules.yml, infra.rules.yml}
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/prometheus-{1,2}/  # TSDB + 渲染后的 prometheus.yml
│   ├── alertmanager/               # alertmanager (.12.21, both)
│   │   ├── compose.yml
│   │   ├── config/alertmanager.yml.tpl     # route / receivers（默认 nul，不外发）
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/alertmanager/      # silences / notify 日志 / 渲染后配置
│   ├── grafana/                    # grafana (.12.31, both)
│   │   ├── compose.yml
│   │   ├── config/provisioning/
│   │   │   ├── datasources/{prometheus.yml,jaeger.yml}
│   │   │   └── dashboards/{provider.yml, redis-sentinel.json, redis-cluster.json, infra.json, obs-self.json}
│   │   ├── scripts/{render,status,reset}.sh
│   │   └── .data/grafana/           # grafana.db（SQLite）
│   ├── jaeger/                     # jaeger (.12.32, both)
│   │   ├── compose.yml
│   │   ├── config/config.yaml      # OTel Collector 格式（OTLP receiver + jaeger_storage）
│   │   ├── config/sampling.json    # 采样策略
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── .data/jaeger/badger/     # trace 存储（TTL 72h）
│   └── docsify/                    # docsify-1 (.20.11, both)：仓库 docs/ 只读浏览，HA 豁免
│       ├── compose.yml             # 嵌套只读挂载：docs/ → /docs/content；.data/site → /docs
│       ├── config/index.html.tpl   # 站点壳模板（@TITLE@ / @BASEPATH@ 由 render 替换）
│       ├── config/assets/          # 从镜像 4.4.4 导出的离线前端资产（升版本时重新导出）
│       ├── scripts/{render,bootstrap,status}.sh   # 无 reset（无状态，走默认清 .data/）
│       └── .data/site/              # 生成物：index.html / assets / _sidebar.md
├── scripts/
│   ├── doctor.sh                   # 15 项体检（§6.3）
│   ├── render-all.sh               # ini → compose.generated.yml + 各栈配置渲染
│   ├── backup-all.sh               # find services -name .data → 归档
│   ├── trace-demo.sh               # 推一条 OTLP trace（§16.5）
│   └── prepull.sh                  # 按 ini 预拉镜像（D01）
├── env/{.env.example, .env}
├── docs/{plan.md, stacks.md, adr.md, archive/}
├── Makefile
├── .gitignore
├── AGENTS.md                       # 仓库操作契约（agent / 协作者）：什么能改、怎么验证
└── README.md
```

```gitignore
**/.data/**
!**/.data/.gitkeep
env/.env
/.generated/
/compose.generated.yml
/compose.yml
/backups/
```

> **`config/` 只放模板，`render.sh` 的产物一律落 `.data/`**（DEC-11）：nginx 的路由 `conf.d/`、prometheus 的 `prometheus.yml`、
> sentinel 的 `sentinel.conf`、kafka 的 `server.properties`、kafka 的 `meta.properties` 都在 `.data/` 下——它们要么运行时重写，要么含渲染出的 IP，不能入库。
> 每个目录的 `scripts/` 按需裁剪：无状态的栈没有 `bootstrap`（nginx / grafana）。
>
> **生成契约（P0 起）**：`services/<stack>/compose.yml` 是**手写骨架**，只写
> `services` / `container_name` / `profiles` / `volumes` / `healthcheck` 与 `x-image`；
> `image`、`restart`、`logging`、`TZ`、`networks` / `ipv4_address` 由 `scripts/render-all.py`
> 从 `base/` 与 `stock/network.ini` 注入。`.generated/<stack>.yml`、根 `compose.yml`、
> `compose.generated.yml` 都是生成物，不提交；只有 `services/*/compose.yml` 是输入，必须提交。
> 这样"组件 compose 里出现字面量 `image:`"与"根 `compose.yml` 是生成物"两条规则不再冲突。

---

## 5. 服务花名册（15 域 / 17 目录 / 18 部署单元）

> 内存为"限堆/限缓存后"稳态估算，非默认值（默认值会 OOM，见 §9.2）。

| 域 | 目录 | 容器（solo → ha） | 形态 | 内存 solo / ha |
|---|---|---|---|---|
| `.0.x` edge | `nginx` | nginx-1 → +nginx-2 | 双入口（无 VIP） | 0.02 / 0.05 GB |
| `.1.x` pg | `pg` | postgres 1 + exporter → patroni×3 + dcs×3 + haproxy×2 + exporter | Patroni 自动故障转移 | 0.33 / 1.28 GB |
| `.2.x` redis-sentinel | `redis` | redis 1 + exporter → 1M + 2R + 3S + exporter | 哨兵自动切换 | 0.10 / 0.34 GB |
| `.3.x` redis-cluster | `redis` | redis 1 + exporter → 3M + 3R + exporter | 分片 + 副本（16384 slots） | 0.10 / 0.48 GB |
| `.4.x` mysql | `mysql` | mysql 1 + exporter → mgr×3 + router×2 + exporter | MGR 单主自动选主 | 0.48 / 1.50 GB |
| `.5.x` mongo | `mongo` | mongo 1 + exporter → RS×3 + exporter | Replica Set 自动选主 | 0.38 / 1.08 GB |
| `.6.x` kafka | `kafka` | broker 1（兼 controller）+ exporter → broker×3 + controller×3 + exporter | KRaft，RF=3 | 1.13 / 3.33 GB |
| `.7.x` rocketmq | `rocketmq` | namesrv 1 + broker 1 + exporter → namesrv×2 + broker×3 + exporter | **DLedger（Raft）** 自动切换 | 0.98 / 2.63 GB |
| `.8.x` rabbitmq | `rabbitmq` | rabbit 1 → rabbit×3 | quorum queue | 0.25 / 0.75 GB |
| `.9.x` etcd | `etcd` | etcd 1 → etcd×3 | Raft quorum | 0.08 / 0.24 GB |
| `.10.x` consul | `consul` | consul 1 → consul×3 | Raft + gossip | 0.06 / 0.18 GB |
| `.11.x` nats | `nats` | nats 1 + exporter → nats×3 + exporter | cluster routes + JetStream R3 | 0.07 / 0.15 GB |
| `.12.x` obs | `prometheus` | prometheus-1 → +prometheus-2 | 冗余采集（非故障转移，§16.3） | 0.30 / 0.85 GB |
| `.12.x` obs | `alertmanager` | alertmanager | 告警路由 | 0.05 / 0.05 GB |
| `.12.x` obs | `grafana` | grafana | 面板（provisioning） | 0.25 / 0.25 GB |
| `.12.x` obs | `jaeger` | jaeger | 链路追踪（OTLP + Badger + UI） | 0.15 / 0.15 GB |
| `.13.x` nacos | `nacos` | server 1 + console 1 → server×3 + console×1 | 服务注册 + 配置中心（3.x server/console 拆分；库复用 mysql 栈） | 0.55 / 1.35 GB |
| `.20.x` docs | `docsify` | docsify-1（两形态同一节点） | 仓库 `docs/` 只读浏览（无状态，HA 豁免，DEC-46） | 0.05 / 0.05 GB |
| **合计** | **17 目录 / 18 单元** | **28 → 71 个容器** | | **5.35 / 14.75 GB** |

> `redis-sentinel` 与 `redis-cluster` **同属 `services/redis/`**（复合栈，§2.1），两个 profile 互斥；
> 其余每行 = 一个目录。`.0.x` 只剩 `nginx`（v3.2 从原 `core/` 拆出四个，v4.2 删掉其中三个工具）。

### 5.1 `stock/network.ini`（唯一权威）

行格式：`name | ip | ports | role | mode`，竖线分隔便于 `awk -F'|'` 零依赖解析。

**`mode` 列默认值为 `ha`**（省略即 ha），取值：

| mode | 含义 |
|---|---|
| `ha` | 仅属于集群/主从拓扑（默认） |
| `both` | solo 与 ha 共用同一节点身份（solo 时的单实例就是它） |
| `solo` | 仅属于 solo 拓扑（当前无此类行；保留语义） |

> 行内只写 4 列（`name | ip | ports | role`）= **省略 mode，即 mode=ha**；本表 43 行如此（其余 28 行为 `both`），只有 `both` 节点才写第 5 列。
> 这样写是为了让"ha-only 成员"成为默认，减少一处手工维护。

**solo 复用该栈 `.11` 节点的 IP**（两形态互斥、不同时运行），但**配置模板与数据目录独立**（`config/solo/`、`.data/<group>/solo/`），互不污染。

```ini
[global]
subnet  | 172.28.0.0/16 | |
gateway | 172.28.0.1    | |

[stack.nginx]
# 只有 nginx-1 在 compose 里声明 ports:（宿主发布，ENTRY_HTTP_PORT 可覆盖）；nginx-2 仅容器内监听
nginx-1          | 172.28.0.11 | 80,443     | entry | both
nginx-2          | 172.28.0.12 | 80,443     | entry

[stack.pg]
patroni-1        | 172.28.1.11 | 5432,8008  | leader  | both
patroni-2        | 172.28.1.12 | 5432,8008  | replica
patroni-3        | 172.28.1.13 | 5432,8008  | replica
pg-dcs-1         | 172.28.1.31 | 2379,2380  | dcs
pg-dcs-2         | 172.28.1.32 | 2379,2380  | dcs
pg-dcs-3         | 172.28.1.33 | 2379,2380  | dcs
pg-haproxy-1     | 172.28.1.34 | 5000,5001,7000 | proxy
pg-haproxy-2     | 172.28.1.35 | 5000,5001,7000 | proxy
pg-exporter      | 172.28.1.41 | 9187       | exporter | both

# 下面两个 [stack.*] 同属 services/redis/（复合栈，§2.1）：profile 互斥，不同时运行
[stack.redis-sentinel]
redis-master     | 172.28.2.11 | 6379       | master   | both
redis-replica-1  | 172.28.2.12 | 6379       | replica
redis-replica-2  | 172.28.2.13 | 6379       | replica
sentinel-1       | 172.28.2.21 | 26379      | sentinel
sentinel-2       | 172.28.2.22 | 26379      | sentinel
sentinel-3       | 172.28.2.23 | 26379      | sentinel
redis-sentinel-exporter | 172.28.2.41 | 9121 | exporter | both

[stack.redis-cluster]
rc-1             | 172.28.3.11 | 6379,16379 | master   | both
rc-2             | 172.28.3.12 | 6379,16379 | master
rc-3             | 172.28.3.13 | 6379,16379 | master
rc-1r            | 172.28.3.21 | 6379,16379 | replica
rc-2r            | 172.28.3.22 | 6379,16379 | replica
rc-3r            | 172.28.3.23 | 6379,16379 | replica
redis-cluster-exporter  | 172.28.3.41 | 9121       | exporter | both

[stack.mysql]
mysql-1          | 172.28.4.11 | 3306,33061 | mgr-member | both
mysql-2          | 172.28.4.12 | 3306,33061 | mgr-member
mysql-3          | 172.28.4.13 | 3306,33061 | mgr-member
mysql-router-1   | 172.28.4.31 | 6446,6447  | proxy
mysql-router-2   | 172.28.4.32 | 6446,6447  | proxy
mysql-exporter   | 172.28.4.41 | 9104       | exporter | both

[stack.mongo]
mongo-1          | 172.28.5.11 | 27017      | primary   | both
mongo-2          | 172.28.5.12 | 27017      | secondary
mongo-3          | 172.28.5.13 | 27017      | secondary
mongo-exporter   | 172.28.5.41 | 9216       | exporter  | both

[stack.kafka]
kafka-1          | 172.28.6.11 | 9092       | broker     | both
kafka-2          | 172.28.6.12 | 9092       | broker
kafka-3          | 172.28.6.13 | 9092       | broker
kafka-ctrl-1     | 172.28.6.21 | 9093       | controller
kafka-ctrl-2     | 172.28.6.22 | 9093       | controller
kafka-ctrl-3     | 172.28.6.23 | 9093       | controller
kafka-exporter   | 172.28.6.41 | 9308       | exporter   | both

[stack.rocketmq]
rmq-namesrv-1    | 172.28.7.11 | 9876       | namesrv  | both
rmq-namesrv-2    | 172.28.7.12 | 9876       | namesrv
rmq-broker-1     | 172.28.7.21 | 10911,10909| dledger  | both
rmq-broker-2     | 172.28.7.22 | 10911,10909| dledger
rmq-broker-3     | 172.28.7.23 | 10911,10909| dledger
rmq-exporter     | 172.28.7.41 | 5557       | exporter | both

[stack.rabbitmq]
rabbit-1         | 172.28.8.11 | 5672,15672,15692,4369,25672,35672-35682 | seed   | both
rabbit-2         | 172.28.8.12 | 5672,15672,15692,4369,25672,35672-35682 | member
rabbit-3         | 172.28.8.13 | 5672,15672,15692,4369,25672,35672-35682 | member

[stack.etcd]
etcd-1           | 172.28.9.11 | 2379,2380  | member | both
etcd-2           | 172.28.9.12 | 2379,2380  | member
etcd-3           | 172.28.9.13 | 2379,2380  | member

[stack.consul]
consul-1         | 172.28.10.11 | 8500,8300,8301,8302,8600 | bootstrap | both
consul-2         | 172.28.10.12 | 8500,8300,8301,8302,8600 | server
consul-3         | 172.28.10.13 | 8500,8300,8301,8302,8600 | server

[stack.nats]
nats-1           | 172.28.11.11 | 4222,6222,8222 | member   | both
nats-2           | 172.28.11.12 | 4222,6222,8222 | member
nats-3           | 172.28.11.13 | 4222,6222,8222 | member
nats-exporter    | 172.28.11.41 | 7777           | exporter | both

[stack.nacos]
nacos-server-1   | 172.28.13.11 | 8848,9848,9849,7848 | server  | both
nacos-server-2   | 172.28.13.12 | 8848,9848,9849,7848 | server
nacos-server-3   | 172.28.13.13 | 8848,9848,9849,7848 | server
nacos-console    | 172.28.13.32 | 8080                | console | both

# observability 域（§16）：四栈共享 172.28.12.0/24，各自有目录/profile/.data
[stack.prometheus]
prometheus-1     | 172.28.12.11 | 9090 | metrics | both
prometheus-2     | 172.28.12.12 | 9090 | metrics

[stack.alertmanager]
alertmanager     | 172.28.12.21 | 9093 | alerts | both

[stack.grafana]
grafana          | 172.28.12.31 | 3000 | ui | both

[stack.jaeger]
jaeger           | 172.28.12.32 | 16686,4317,4318,8888,13133 | trace | both

# docs 域（§17 预留块 .20–.29 启用的第一个）：仓库 docs/ 的只读浏览入口
[stack.docsify]
docsify-1        | 172.28.20.11 | 3000      | docs  | both

# 宿主访问入口（§15）：host | upstream_ip | port | base-path 能力
[routes]
rabbitmq.localhost     | 172.28.8.11  | 15672 | path-ok
consul.localhost       | 172.28.10.11 | 8500  | subdomain-only
grafana.localhost      | 172.28.12.31 | 3000  | subdomain-only
prometheus.localhost   | 172.28.12.11 | 9090  | path-ok
alertmanager.localhost | 172.28.12.21 | 9093  | path-ok
jaeger.localhost       | 172.28.12.32 | 16686 | subdomain-only
nacos.localhost        | 172.28.13.32 | 8080  | subdomain-only
docsify.localhost      | 172.28.20.11 | 3000  | subdomain-only
```

### 5.2 集群形态选型表（需求⑤的核心）

| 组件 | 最小 HA 拓扑 | 选型理由 | 关键机制 / 身份文件 |
|---|---|---|---|
| **nginx** | ×2（`.0.11/.12`），各自独立 IP | 单机无共享存储，做 VIP 是伪需求；**客户端用双地址 + 健康探测**即可 | `server_name` 按 `[routes]` 生成；`keepalived` 仅作可选 profile |
| **postgres** | Patroni ×3 + **自带 etcd DCS ×3** + HAProxy ×2 | 只有流复制是"主从"，没有故障转移；Patroni 是流复制的事实标准 | `patroni.yml`（`bootstrap.dcs`、`pg_hba`）；DCS 内 `/service/pg/leader` |
| **redis** | 哨兵 1M+2R+3S / 集群 3M+3R | 两种语义不同，都要有（同一目录两组互斥 profile，§2.1） | `sentinel.conf`（运行时重写）、`nodes.conf` |
| **mysql** | MGR ×3 + Router ×2 | 异步主从切换要人工；MGR 单主自动选主 + Router 自动感知 | `server_id` 唯一、GTID、`group_replication_group_seeds` |
| **mongo** | RS ×3（1P+2S） | 副本集奇数人数才能形成多数派 | `--replSet` + `rs.initiate` 固定 IP、keyfile |
| **kafka** | broker ×3 + controller ×3（KRaft） | RF=3 + `min.insync.replicas=2`，controller 仲裁与数据面分离 | `advertised.listeners`、`meta.properties` |
| **rocketmq** | namesrv ×2 + broker ×3 **DLedger** | 原生主从是异步复制且**切换需人工**；DLedger(Raft) 才具备自动切换 | `enableDLegerCommitLog`、`dLegerPeers`、`dLegerSelfId` |
| **rabbitmq** | ×3 | quorum queue 需要 3 副本；2 节点无法形成多数派 | `hostname` 固定、erlang cookie、peer discovery |
| **etcd** | ×3 | Raft 奇数成员 | `--initial-cluster`、`--initial-cluster-token` |
| **consul** | ×3 | `bootstrap_expect 3` | `retry_join`、gossip key |
| **nats** | ×3 | 路由全互联 + JetStream R3 | `server_name`、`--routes` |
| **nacos** | server ×3 + console ×1（3.x 起控制台独立）+ **复用 mysql 栈的库**（Router `:6446`） | 集群模式必须共享一份配置库（内嵌 Derby 不支持多节点共享）；3.x 把控制台拆成无状态前端，1 个 console 指向 3 个 server 即可；复用 mysql 避免再建数据库域（DEC-36） | `cluster.conf` 3 个固定 IP、`token.secret.key` 三节点一致、**3.x 的** `mysql-schema.sql`、`nacos.console.port=8080` |
| **prometheus** | 单实例（solo）/ ×2 冗余采集（ha） | 拉模式无共识，HA 语义 = 冗余采集而非故障转移 | `.data/prometheus-N/`（TSDB）、`prometheus.yml`（由 ini 生成） |
| **alertmanager** | 单实例 | 告警路由无状态（silence 落盘） | `config/alertmanager.yml`、`.data/alertmanager/` |
| **grafana** | 单实例 | 无状态，dashboard/数据源全部走 provisioning | `config/provisioning/**`、`.data/grafana/` |
| **jaeger** | 单实例（**豁免**） | 本地 Badger 是单写者，双实例无法共享；真 HA 需 ES/Cassandra → N09 | `config/config.yaml`、`.data/jaeger/badger/` |
| **docsify** | 单实例（**豁免**） | 纯静态浏览，无状态、无成员关系；内容就是仓库 `docs/`，多实例只会得到同一个只读目录 | `config/index.html.tpl`、`.data/site/`（渲染物）、`[routes]` 的 `docsify.localhost` |

> 表中 17 个组件 ↔ 18 个部署单元：`redis` 一行对应 `redis-sentinel` / `redis-cluster` 两个互斥 profile。

### 5.3 豁免清单（不为 HA 而 HA）

| 组件 | 豁免理由 |
|---|---|
| exporter（pg / mysql / mongo / kafka / rocketmq / redis） | 无状态只读，重启无影响 |
| bootstrap 一次性容器（如 MySQL Router 引导） | 天然幂等，不参与拓扑 |
| nginx VIP（keepalived） | **默认不启用**：单机故障域相同，VRRP 无法验证真实切换，只增加调试噪音 |
| prometheus / alertmanager / grafana | **部分豁免**：Prom 双实例是冗余采集（无状态同步），Grafana 无状态（provisioning 即恢复），AM 单实例；真 HA（Thanos/VictoriaMetrics、AM gossip ×3）列入 N 级（§16.3） |
| jaeger | **存储侧豁免**：Badger 单写者；采集侧虽无状态，但两份不共享存储只会得到互不可见的 trace（假 HA，比明确单实例更危险） |
| docsify | **全量豁免**：只读静态浏览，内容就是仓库 `docs/`；双实例得同一份数据，无故障转移可言。`mode=both` 使 solo / ha 完全相同（见 §5.5） |

### 5.4 单机"集群"的诚实边界

71 个容器共享**同一内核、同一磁盘、同一时钟**，因此本环境可验证：

- ✅ 拓扑配置是否正确（成员身份、quorum、seeds、公告地址、slot 分布）
- ✅ 协议行为是否正确（复制、选主、消费位点、重定向）
- ✅ 故障转移**脚本与流程**是否可执行（`make failover-drill`）

不可验证：

- ❌ 网络分区（脑裂）、跨机时钟漂移、真实磁盘/主机故障
- ❌ 跨机网络延迟对 quorum / `down-after-milliseconds` 的影响

→ 本环境定位是"配置与流程的正确性台架"，生产前仍需多机验证。

### 5.5 双形态：solo 与 ha

同一栈用 profile 切换，**IP 身份不变、数据目录隔离**：

| 部署单元 | solo 拓扑 | solo 内存 | ha 内存 | 适用场景 |
|---|---|---|---|---|
| nginx | nginx 1 | 0.02 | 0.05 | solo：本地入口；ha：验证双入口 |
| pg | postgres 1 + exporter | 0.33 | 1.28 | solo：写 SQL；ha：验证 Patroni 切换 |
| redis-sentinel | redis 1 + exporter | 0.10 | 0.34 | solo：缓存调试；ha：验证哨兵 |
| redis-cluster | redis 1（cluster 关闭）+ exporter | 0.10 | 0.48 | solo：key 设计；ha：验证 slot |
| mysql | mysql 1 + exporter | 0.48 | 1.50 | solo：建表导入；ha：验证 MGR |
| mongo | mongo 1 + exporter | 0.38 | 1.08 | solo：文档模型；ha：验证 RS |
| kafka | broker 1（兼 controller）+ exporter | 1.13 | 3.33 | solo：生产/消费；ha：验证 RF=3 |
| rocketmq | namesrv 1 + broker 1 + exporter | 0.98 | 2.63 | solo：消息语义；ha：验证 DLedger |
| rabbitmq | 1 节点 | 0.25 | 0.75 | solo：队列语义；ha：验证 quorum |
| etcd / consul | 1 节点 | 0.08 / 0.06 | 0.24 / 0.18 | 单节点足够验证 API |
| nats | nats 1 + exporter | 0.07 | 0.15 | 单节点足够验证 API；exporter 常驻 |
| prometheus | 1 实例 | 0.30 | 0.85 | solo：看指标；ha：双实例冗余 |
| nacos | server 1 + console 1 | 0.55 | 1.35 | solo：单机注册+配置；ha：验证 3 节点与集群一致性 |
| alertmanager / grafana / jaeger | 1 实例 | 0.05 / 0.25 / 0.15 | 同左 | 豁免栈，两形态相同 |
| docsify | 1 实例 | 0.05 | 同左 | 豁免栈，两形态相同（内容只读 = 仓库 `docs/`） |

#### 5.5.1 命令

```bash
make stack-up S=pg MODE=solo   # 单节点（v1 形态）
make stack-up S=pg MODE=ha     # Patroni 三节点（v2 形态）
make stack-switch S=pg MODE=ha # 先停当前形态再起目标形态（数据目录不互通，会提示）
```

> `S` 取的是**部署单元名（= profile 名）**，不是目录名：`services/redis/` 下有两个部署单元
> `redis-sentinel` / `redis-cluster`；`S=redis` 会报错并列出合法值。

#### 5.5.2 纪律

1. `MODE=solo` 只启动 `mode IN (solo,both)` 的节点；`MODE=ha` 只启动 `mode IN (ha,both)`。
2. 两形态**数据目录物理隔离**（`.data/<group>/solo/` vs `.data/<group>/<node>/`；普通栈为 `data/solo/` vs `.data/<node>/`），禁止直接互相搬运（集群元数据不兼容）。
3. `render.sh` 同时生成两套配置，`doctor.sh` 第 13 项校验 profile 与 ini `mode` 一致。
4. solo 是**取巧的简化**，**solo 的结论不是集群的结论**——`docs/stacks.md` 每栈标注语义差异。逐栈的简化方式：

| 栈 | solo 简化 | 由此**不能**从 solo 得出的结论 |
|---|---|---|
| pg | 不起 Patroni/DCS/HAProxy，只起单实例 postgres（`.1.11`） | 主从、选主、`patronictl` 行为 |
| mysql | 不起 MGR/Router，只起单实例（`.4.11`） | 组复制、Router 跟随、`ONLINE` 判定 |
| mongo | 不起副本集（无 `--replSet`） | 选主、多数派、写关注 |
| kafka | 单节点 broker **兼 controller**（`kafka-ctrl-*` 不启动） | RF=3、`min.insync.replicas`、controller 仲裁 |
| redis-cluster | `cluster-enabled no`，单实例 | slot 分布、`MOVED`/`ASK`、副本对应 |
| redis-sentinel | 不起哨兵 | 切主、`sentinel monitor` 判定 |
| nacos | 单节点 server（`cluster.conf` 只有一个 IP）+ 1 个 console | raft、配置推送跨节点一致性 |
| nats | 单节点（JetStream 副本降为 R1） | R3 副本、quorum |
| 观测四栈 | Prometheus 单实例 / AM、Grafana、Jaeger 本来就单实例 | 冗余采集（`prometheus-2`） |

> **跨形态的渲染差异**：`nacos` 的 `db.url` 在 ha 指向 `mysql-router-1`（`.4.31:6446`），在 solo 指向 `mysql-1`（`.4.11:3306`）——因为 Router 本身是 ha-only。
> 凡"指向代理/路由"的引用（pg→haproxy、mysql→router、nacos→router），都必须按形态切换目标，由 `render.sh` 统一处理。

---

## 6. 三大铁律与校验

### 6.1 铁律一：不变量不下沉

`subnet` / `gateway` / `logging` / `restart` / `TZ` 只允许出现在 `base/`。组件内出现即 review 打回。

### 6.2 铁律二：端口按"同一 IP 内不重复"校验

单网络 + 静态 IP 下，`5432`（PG）、`3306`（MySQL）、`6379`（Redis）各栈同时存在**不冲突**——不同 IP。
真正的冲突对象是"一个容器 IP 的端口集"。宿主端口冲突在"仅 `[stack.nginx]` 发布"策略下自然消失。

多端口栈需特别标注：

| 栈 | 除主端口外的隐式端口 |
|---|---|
| redis-cluster | `16379`（总线 = 端口 + 10000） |
| redis-sentinel | `26379`（哨兵自身） |
| kafka | `9093`（KRaft controller） |
| rocketmq | `10909`（VIP 通道）+ `10911` |
| rabbitmq | `4369` epmd、`25672`、`15692`（原生指标）、`35672-35682`（Erlang 分发动态段） |
| mysql | `33061`（MGR）、router `6446/6447` |
| pg | haproxy `5000/5001/7000`、DCS `2379/2380`、Patroni REST `8008` |
| etcd | `2380`（peer） |
| consul | `8300/8301/8302` + `8600`（TCP 与 UDP 各一） |
| nats | `6222`（cluster routes）、`8222`（监控） |
| jaeger | `4317`（OTLP gRPC）/ `4318`（OTLP HTTP）/ `8888`（自身指标）/ `13133`（health） |
| nacos | server：`8848`（HTTP API）、`9848`（客户端 gRPC = 8848+1000）、`9849`（服务端 gRPC）、`7848`（JRaft/集群通信）；console：`8080` |

### 6.3 铁律三：`doctor.sh` 十五项体检

| # | 检查 | 失败处理 |
|---|---|---|
| 1 | ini 内 IP 均在 `/16` 内，非 `.0`/`.1`/`.255` | 报错并列出 |
| 2 | ini 内 IP 无重复 | 报错并给出重复项 |
| 3 | 同一 IP 的端口集无重复（支持 `a-b` 范围写法，按区间展开后比较） | 报错 |
| 4 | 各组件 `compose.yml` 的 `ipv4_address` ⊆ ini 且一致（防手写漂移）；**镜像引用必须来自 `base/images.yml`**（出现字面量 `image:` 即失败） | IP 漂移 → 提示重跑 `render-all`；字面量镜像 → 提示改 `images.yml` |
| 5 | 每个 service 均声明 `profiles`（无 profile 的服务会被任何 `up` 起，破坏复合栈互斥） | 失败 |
| 6 | 宿主端口仅出现在 `[stack.nginx]` 且**只有 `nginx-1`** 声明 `ports:`（nginx-2 不得发布） | 失败 |
| 7 | `docker context` 必须是 `orbstack`（方案前提） | 失败并解释原因 |
| 8 | `172.28.0.0/16` 与宿主路由无重叠 | 失败 |
| 9 | `env/.env` 存在且权限 `600` | 提示 |
| 10 | 各栈 `.data/<node>` 存在且属主正确（uid 999：pg / redis / mysql / mongo） | 提示修复命令 |
| 11 | **HA 拓扑完整性**：每域成员数与 ini 一致，且为奇数法定人数（etcd/consul/mongo/rabbit）；哨兵 3；cluster 3M3R 覆盖 16384 slots；豁免栈不得声明多余副本 | 失败 |
| 12 | **演练保护**：`restart: unless-stopped` 存在时，演练必须走 `stop` 而非 `kill` | 提示 |
| 13 | **双形态一致性**：profile 与 ini `mode` 一致；`.data/<group>/solo` 与 `.data/<group>/<node>` 不混用 | 失败 |
| 14 | **路由与引用校验**：`[routes]` host 唯一、upstream IP 属于已启用块；观测四栈跨栈引用（Grafana→Prometheus、Grafana→Jaeger、Prom→AM）、`render.sh` 注入的其它地址（Kafka `advertised.listeners`、Patroni DCS、Router seeds、**nacos→mysql `db.url.0`**）都必须在 ini 中存在且对应域 mode 已启用 | 失败 |
| 15 | **运行态健康**：按 `.data/.mode-*` marker 算出"该在跑的容器"，逐个查 `running` + `healthy`；`restarting` / `unhealthy` = FAIL，已部署但未在跑 = WARN（并提示 daemon 重启后需重跑 `make stack-up`）。`RestartCount` 只当线索报在 PASS 详情里，不单独判 WARN（它不会自动清零） | 失败 / 提示 |

> 第 4/5/10/13 项按"**已启用的栈**"取集合：P0–P6 期只校验已存在的目录与 `.data/` 子树，未开工的栈不参与判定；
> 全部 18 个部署单元建完后（P7）才要求全量通过。这样 `make doctor` 在每一期都能作为"本期绿灯"使用，而不是等到最后才全绿。
>
> 第 1–14 项全部是**静态校验**（ini / compose / 脚本 / 宿主路由），它们能在全停时跑通；
> 第 15 项是唯一的**运行态**校验，用来接住"体检全绿但容器在 crash loop"这类事（DEC-48）。

---

## 7. 身份固化清单（真实痛点）

| 栈 | 必须写死 | 必须持久化的状态文件 | 搞错的症状 |
|---|---|---|---|
| nginx | 两实例 `server_name` / 监听端口错开；`[routes]` 生成的 upstream | 无状态 | 后端全挂时无法判断入口是否存活 |
| pg (Patroni) | `scope`、`name`、`restapi`、`dcs.etcd3.hosts`、`bootstrap.dcs` | `.data/patroni-N/`（含 `postgresql0/`）、DCS 数据 | 重启后 leader 丢失 / split-brain |
| redis-sentinel | `sentinel monitor devmaster 172.28.2.11 6379 2`；`requirepass` 与 `masterauth` **必须一致** | `.data/sentinel/sentinel-N/sentinel.conf`（**运行时重写**）、`.data/sentinel/redis-master/appendonlydir` | 切主后新主拒绝写入 |
| redis-cluster | `cluster-enabled yes`；总线端口 = 端口 +10000；`cluster-announce-ip` = 容器 IP | `.data/cluster/<node>/nodes.conf`、AOF/RDB | 重启后忘记集群身份，需整栈重建 |
| mysql | `server_id` 唯一、`gtid_mode=ON`、`group_replication_group_seeds` | `.data/mysql-N/`、Router 的元数据缓存 | MGR 加入失败 / Router 指向旧主 |
| mongo | `--replSet`、`rs.initiate` 成员地址、keyfile | `.data/mongo-N/db` | rs 地址与实际不符，选主失败 |
| kafka | `advertised.listeners` = 容器 IP；`controller.quorum.voters` = 3 固定 IP；`clusterId` | `.data/kafka-N/meta.properties` | 客户端拿到不可达地址；clusterId 漂移需重新 format |
| rocketmq | **`brokerIP1`**、`namesrvAddr`、`dLegerPeers` / `dLegerSelfId` | `.data/broker-N/store`（DLedger 含 `dledgerconfig`） | 消费者连不上；成员 ID 重复导致选主失败 |
| rabbitmq | `hostname:` 固定且唯一、erlang cookie 一致 | `.data/rabbit-N/mnesia` | 节点名变化 → 集群分裂、数据看似丢失 |
| etcd | `--initial-cluster` peer URL、`--initial-cluster-token` | `.data/etcd-N/` | 重启后无法重组 |
| consul | `-node` 名、`retry_join` 静态 IP、gossip key | `.data/consul-N/` | 节点重名 / gossip 失败 |
| nats | `server_name`、`--routes` 静态 IP | `.data/nats-N/jetstream` | 路由不通、JetStream 副本不达 quorum |
| prometheus | `--web.external-url`、`--storage.tsdb.retention.time`、`scrape_configs` 由 ini 生成 | `.data/prometheus-N/`（TSDB chunk/WAL） | 手改 `prometheus.yml` 导致目标漂移 |
| alertmanager | `--web.external-url`、`route` / `receivers`（默认 `nul`，不外发） | `.data/alertmanager/`（`silences`、`notify`） | 静默丢失；告警重复或静默失效 |
| grafana | `root_url=http://grafana.localhost/`、`GF_PATHS_PROVISIONING`、数据源指向 `172.28.12.11:9090` 与 `172.28.12.32:16686` | `.data/grafana/`（SQLite） | 面板丢配置（未走 provisioning）；数据源指向旧 Prom / 旧 Jaeger |
| jaeger | `jaeger_storage.badger.directory`（= `.data/jaeger/badger`）、OTLP 监听 `0.0.0.0:4317/4318`、`jaeger_query.base_path`、采样策略文件 | `.data/jaeger/badger/`（trace 存储）、`config/sampling.json` | 改了 `data/` 路径 → 历史 trace "消失"；采样写错 → UI 有服务无链路 |
| **nacos-server** | `spring.sql.init.platform=mysql` + `db.url.0` 指向 `172.28.4.31:6446/nacos_config`；`cluster.conf` 3 个固定 IP；`token.secret.key`（**若开启鉴权（D36=A）则三节点必须一致**）；`nacos.inetutils.ip-address` = 容器 IP；**schema 必须是 3.x 的 `mysql-schema.sql`** | **数据在 MySQL**（`nacos_config` 库）；`.data/nacos-server-N/logs/` | token 不一致 → 节点互踢/403；IP 推断错 → gRPC 拿到不可达地址；用 2.x schema → 启动期建表冲突 |
| **nacos-console** | `nacos.console.port=8080`、指向 server 列表（`172.28.13.11:8848` 等，由 render 注入） | 无状态（不落盘） | console 指向旧 server / 端口未对齐 → 打开空白或 502 |
| **docsify** | `[routes]` 的 `docsify.localhost -> 172.28.20.11:3000`；站点壳（`index.html` / `_sidebar.md` / `assets/`）由 render 生成 | 无状态：内容就是仓库 `docs/`（只读挂载），`.data/site/` 全部可重建 | 把内容目录做成可写挂载 → 镜像自举会往 `docs/` 里脚手架（已用 `DOCSIFY_AUTO_INIT=false` + `:ro` 双保险）；`_sidebar.md` 只在 render 时生成，新增 md 不重渲染就不进侧栏 |

**这些文件全部落在 `services/<stack>/data/` 下（复合栈再加一层 profile：`services/redis/.data/<group>/<node>/`）→ `backup-all.sh` 一并归档 → 恢复即恢复身份。**

---

## 8. 组件契约（17 目录 / 18 部署单元）

### 8.0 普通目录（16 个）

> 逐目录的实际文件清单见 §4；本节只约定"契约形状"。`scripts/` 按需裁剪（无 `bootstrap` 或整组省略），
> 目录里出现什么由职责决定，不是套模板。

```text
services/<stack>/
├── compose.yml        # 每个 service 都带 profiles: ["<profile>"]
├── config/            # 模板（入库），以 :ro 挂载
├── scripts/
│   ├── render.sh      # stock/network.ini → .data/ 下真实配置
│   ├── bootstrap.sh   # 幂等：先探测状态，已完成则 exit 0
│   ├── status.sh      # 成员/quorum/复制状态
│   └── reset.sh       # 停容器 → 删本 profile 的 .data/ 子树 → 重新 bootstrap
└── .data/<node>/       # 运行时（忽略入库）
```

### 8.0.1 复合栈 `services/redis/`（唯一）

```text
services/redis/
├── compose.yml                    # 两个互斥 profile：redis-sentinel / redis-cluster
├── config/
│   ├── base/redis-base.conf       # 共用段（maxmemory / appendonly / slowlog）
│   ├── sentinel/                  # redis.conf + sentinel.conf.tpl
│   └── cluster/                   # redis.conf.tpl（cluster-enabled / announce-ip）
├── scripts/
│   ├── sentinel/{render,bootstrap,status,reset}.sh
│   └── cluster/{render,bootstrap,status,reset}.sh
└── .data/
    ├── sentinel/<node>/           # solo：.data/sentinel/solo/
    └── cluster/<node>/            # solo：.data/cluster/solo/
```

四条硬约束（不满足就不该继续用复合形式，应拆回两个目录）：

1. `compose.yml` 里**每个 service 必须带 profile**（`redis-sentinel` 或 `redis-cluster`），禁止无 profile 的服务（否则 `down` 会误删另一组）。
2. `reset.sh` **只能删本组子树**（`.data/sentinel/` 或 `.data/cluster/`）。
3. `render.sh` 两组各自独立，但共用 `config/base/redis-base.conf` 的 include（单一事实源）。
4. `doctor.sh` 按 ini 的 `[stack.*]` 段（而不是目录）校验 profile 与 `mode`，因此第 4/5/13 项不需特殊处理。

### 8.1 统一命令

```bash
make stack-up S=kafka      # render → compose --profile kafka up -d → bootstrap → 等 healthy（DEC-52）
make stack-status S=kafka
make stack-reset S=kafka

# 观测域是 4 个部署单元（§16.1），因此多一层"组"语法：组 = 多个部署单元的有序集合（定义在 Makefile，不入 ini）
make group-up     G=observability MODE=solo   # 依次 prometheus → alertmanager → jaeger → grafana
make group-status G=observability
make obs / make obs-ha                        # = group-up G=observability MODE=solo 或 ha 的简写
```

> 组只用于**日常一键起齐**；永久态仍以"部署单元（profile）"为单位。`S` 一律填 profile 名，没有 `S=redis`。

### 8.2 幂等探测（bootstrap 的判定条件）

| 栈 | 探测命令 | 通过条件 |
|---|---|---|
| etcd | `etcdctl endpoint health` | 3 个 endpoint 全 healthy |
| pg | `patronictl list` | 1 Leader + 2 Replica，`Lag` ≈ 0 |
| redis-sentinel | `redis-cli -p 26379 sentinel get-master-addr-by-name devmaster` | 返回 `172.28.2.11 6379` |
| redis-cluster | `redis-cli -c cluster info` / `cluster nodes` | `cluster_state:ok`，3M3R，16384 slots |
| mysql | `SELECT * FROM performance_schema.replication_group_members` | 3 成员 `ONLINE` |
| mongo | `rs.status().ok` | `1`，1P+2S |
| kafka | `kafka-metadata-quorum describe --status` | leader + 3 voters |
| rocketmq | `mqadmin clusterList` | 3 broker 均为 `SYNC_MASTER`（DLedger） |
| rabbitmq | `rabbitmqctl cluster_status` | 3 节点 running |
| consul | `consul members` | 3 alive |
| nats | `nats server report jetstream` | 3 节点，stream R3 |
| prometheus | `curl -sf :9090/-/ready` | Ready |
| alertmanager | `curl -sf :9093/-/ready` | 200 |
| grafana | `curl -sf :3000/api/health` | `{"database":"ok"}` |
| jaeger | `curl -sf :8888/metrics` / `:16686/api/services` | 200 |
| nginx | `curl -sf -H 'Host: grafana.localhost' 127.0.0.1/` | 200（路由打通） |
| nacos-server | `curl -sf :8848/nacos/v1/console/health/readiness`（3.x 若迁到 actuator 则用 `/nacos/actuator/health`）+ `/nacos/v1/ns/operator/metrics` | readiness `UP`；raft 有 leader；`/nacos/v1/ns/service/list` 可用 |
| nacos-console | `curl -sf :8080/` | 200（控制台根路径） |
| docsify | `curl -sf :3000/` + `curl -sf :3000/content/plan.md` | 两者都 200（内容 404 = `docs/` 未挂上或 render 未跑） |

> 上表是 **ha 形态**的判定条件。**solo 形态**用简化探测（因为对应拓扑根本不存在）：pg `pg_isready`、mysql `mysqladmin ping`、
> mongo `mongosh --eval 'db.runCommand({ping:1})'`、redis `redis-cli ping`、kafka `kafka-topics.sh --list`、nacos `readiness`。
> **3.x 待锁定项**（P5 首次启动确认后写进 `docs/stacks.md`）：console 是否独立镜像/端口、health 与 metrics 的准确路径、schema 文件名。

### 8.3 演练保护（重要）

`restart: unless-stopped` 会让"被杀"的容器自动复活，**直接破坏故障转移演练的观察窗口**。约定：

```bash
# 演练：用 stop（不触发 restart 策略）
docker compose stop patroni-1        # 观察 DCS 选出新 leader
docker compose start patroni-1       # 观察旧主以 replica 身份回归

# 禁止在演练中用：docker kill / docker rm
make failover-drill S=pg             # Makefile 内部已强制走 docker compose stop
make failover-drill S=redis-sentinel
make failover-drill S=redis-cluster
make failover-drill S=mysql
make failover-drill S=mongo
make failover-drill S=kafka          # 停 controller / 停 broker 两种剧本
make failover-drill S=rocketmq
```

### 8.4 宕机与 daemon 重启后的恢复（重要）

`restart: unless-stopped` 只保证**容器**活回来，**不保证集群不变量活回来**。典型链条：

```text
OrbStack / 宿主重启
  → 容器全部 running（restart 策略生效）
  → mysql 三节点 MGR 停在 OFFLINE（group_replication_start_on_boot=OFF，防自动裂脑）
  → nacos_config 库在成组后才会被创建 → 不存在
  → nacos-server ×3 进 crash loop（restart=unless-stopped 会把它一直撞回来）
```

恢复口径：**按栈重跑幂等引导，不碰数据**（`bootstrap.sh` 已写成"已成组只修离队节点"）：

```bash
make doctor                              # 第 15 项会直接报出哪些容器在 crash loop / 没在跑
make stack-up S=mysql                    # 省略 MODE 即沿用 ha（marker，DEC-50）：重成 MGR + 重建 nacos_config + router 接管
make stack-up S=nacos                    # 库好了才能起；依赖链见 R25
make tier-s                              # 或者按档一键重放（该档已部署的栈都会重跑一遍 bootstrap）
```

> 该口径在 v4.5 之前对 mysql 是**假**的，一次全量 `down` 后复现出两道坑（DEC-52）：
> ① `stack-up` 旧顺序是 `up -d --wait` 再 `bootstrap`，而 `--wait` 要等 Router 健康；
> Router 只在 metadata cache 看到 ONLINE primary 后才监听 6446 —— 成组本来就是 bootstrap 的
> 职责，于是 `--wait` 超时失败 → bootstrap 永远轮不到（实测三个节点停在 `OFFLINE`、两台 Router
> `unhealthy`、下游 nacos 跟着 crash loop）。② 解锁后 bootstrap 走到"首次成组"分支时，`CREATE
> USER 'repl'` 直接撞 `ERROR 1290`：单主 MGR 重启后节点带 `super_read_only=ON` 回来（运行时值，
> 不落 `mysqld-auto.cnf`），而成组前必须建 repl 用户。
> 现在：`up` / `reset` 均为两段式（起容器 → bootstrap → 等健康），且成组前先 `SET GLOBAL
> super_read_only=OFF`（join 后 MGR 会把 SECONDARY 置回 ON，不破坏单主语义）。

设计决定：**不把 start_on_boot 改成 ON**。自动成组在单机重启场景下看似方便，但它会让
"手工 bootstrap 才能建组"这条防裂脑约束失效（DEC-8 / DEC-17 同一取向）；正确的补偿是**可观察**
（§6.3 第 15 项）与**可重放**（`stack-up` 幂等），而不是把风险交给镜像默认值。另：跨栈依赖
（nacos→mysql）必须按 §8.4 的顺序恢复，先 mysql 后 nacos；反序不会损坏数据，但会白等一轮 crash loop。

---

## 9. 资源纪律

### 9.1 档位（`make` 目标，禁止手起全量）

| 档 | 组合 | 估算 |
|---|---|---|
| **A 日常**（数据库 + HA 验证） | nginx + pg + redis-sentinel + obs(solo) | ≈ 2.4 GB |
| **B 消息** | nginx + kafka + rabbitmq + obs(solo) | ≈ 4.9 GB |
| **C 重栈** | nginx + rocketmq + mysql + obs(solo) | ≈ 4.9 GB |
| **D 组合** | nginx + redis-cluster + kafka + obs(solo) | ≈ 4.6 GB |
| **E 共识** | nginx + etcd + consul + nats + obs(solo) | ≈ 1.4 GB |
| **F 注册配置** | nginx + **nacos**（server×3 + console）+ **mysql** + obs(solo)（nacos 的库在 mysql；两者必须同起） | ≈ 3.7 GB |
| **S 单人日常（solo 全栈）** | 18 个部署单元全部 solo（28 容器） | ≈ 5.35 GB |
| ❌ 全量 ha | 18 个部署单元全部 ha（71 容器） | **≈ 14.75 GB / 可见 15.7 GB**（余量 ≈ 0.95 GB），**禁止常驻** |

> A–F 与 S 档可常驻；全量 ha（14.75 GB）仅在"一次性全链路演练"时临时起，做完 `make down`。

### 9.2 硬性限流（不做就会炸）

| 组件 | 必设 |
|---|---|
| rocketmq broker | `-Xms512m -Xmx512m`（默认 `-Xms8g`，直接拖垮 VM） |
| kafka | `KAFKA_HEAP_OPTS=-Xmx512m` |
| mongo | `--wiredTigerCacheSizeGB 0.25` |
| mysql | `innodb_buffer_pool_size=128M`；MGR `group_replication_message_cache_size=64M` |
| redis（所有实例） | `maxmemory 256mb` + `maxmemory-policy noeviction`；**AOF `appendfsync everysec` + RDB 快照**（DEC-41）；`slowlog-log-slower-than 10000` |
| prometheus | `--storage.tsdb.retention.time=15d --storage.tsdb.retention.size=2GB` |
| grafana | `GF_ANALYTICS_CHECK_FOR_UPDATES=false`、`GF_USERS_ALLOW_SIGN_UP=false` |
| jaeger | Badger `ttl: 72h`；`ephemeral: false` |
| nacos-server | JVM `-Xms384m -Xmx384m`（默认会按宿主内存起大堆）；`nacos.naming.expireInstance=true`；关闭内嵌 Derby（`spring.sql.init.platform=mysql`） |
| nacos-console | JVM `-Xms192m -Xmx192m`（无状态前端，不需要大堆） |
| docsify | `mem_limit: 128m` + `cpus: 0.5`（Node LTS 空转约 40–60 MB，不设限会与业务栈抢内存） |
| 全栈 | `logging: json-file max-size=10m max-file=3` |

可选：`orb config set memory_mib 24576`（物理 48 GB，安全），但**不改档位纪律**（D29）。

---

## 10. 聚合与入口

```yaml
# compose.yml（生成物）—— 显式列举，因 include 不支持 glob
include:
  - base/network.yml
  - services/nginx/compose.yml
  - services/pg/compose.yml
  - services/redis/compose.yml          # 一个文件装两个 profile（复合栈）
  - services/mysql/compose.yml
  - services/mongo/compose.yml
  - services/kafka/compose.yml
  - services/rocketmq/compose.yml
  - services/rabbitmq/compose.yml
  - services/etcd/compose.yml
  - services/consul/compose.yml
  - services/nats/compose.yml
  - services/nacos/compose.yml
  - services/prometheus/compose.yml
  - services/alertmanager/compose.yml
  - services/grafana/compose.yml
  - services/jaeger/compose.yml
  - services/docsify/compose.yml
```

- `render-all.sh` 扫描 `services/*/compose.yml` 生成该文件（复合栈只产生 1 行 include）。
- **镜像来源唯一**：`base/images.yml` → `render.sh` 注入各 compose（DEC-39）；`.env` 支持 `IMG_<NAME>=<ref>` 逐个覆盖、`IMAGE_PREFIX=<mirror>/<ns>/` 整体前缀，默认空 = 官方源。
- **版本形态**：默认 `X.Y`（DEC-40），大版本升级只能手改 `images.yml`；上游只发 `X.Y.Z` 的镜像按 `X.Y.Z` pin，并在行尾注明。

```yaml
# base/images.yml（节选：形态 + 为什么这么钉）
nginx: nginx:1.27-alpine            # X.Y
redis: redis:7.4-alpine             # X.Y（两组 profile 必须同版本）
postgres: postgres:17.5             # X.Y
kafka: apache/kafka:3.9.0           # X.Y.Z：上游不发 X.Y 标签
redis_exporter: oliver006/redis_exporter:v1.67.0  # X.Y.Z：小版本会改指标名
```

- **唯一入口**：`make` 或 `docker compose -f compose.yml`。组件文件脱离入口会报 `undefined network devnet`（已实测），属预期行为。
- 组件目录内禁止 `../` 跨栈引用；跨栈共享片段放 `base/`，同一目录内的复用放该目录 `config/base/`。

---

## 11. 决策记录（ADR 摘要）

### 11.1 有效决策

| # | 决策 | 理由 |
|---|---|---|
| DEC-1 | 单网络 `172.28.0.0/16`，不拆多网络 | 同端口不同 IP 天然隔离；/24 容量不足 |
| DEC-2 | 按组件分目录（非技术分层）；同一产品的互斥拓扑可合为复合栈 | 改一个栈只动一个目录；删栈无孤儿数据 |
| DEC-3 | 除 nginx 外不发布宿主端口 | 宿主可直连容器 IP（实测），消除 NAT 破坏地址公告的风险 |
| DEC-4 | `stock/network.ini` 单一事实源 + 生成 compose | IP 手写必漂移；doctor 可双向校验 |
| DEC-5 | ini 用竖线分隔 | `awk -F'\|'` 零依赖解析 |
| DEC-6 | profiles 强隔离 | 单栈可独立起停；15.7 GB 装不下全量常驻 |
| DEC-7 | Kafka 用 KRaft（无 ZK） | 少 3 个容器，官方方向 |
| DEC-8 | MySQL 基线用 MGR（单主自动选主）+ Router | 需求⑤：异步主从切换需人工 |
| DEC-9 | RabbitMQ 集群基线 3 节点，队列语义由声明决定 | quorum 需要 3 副本；测试需要灵活性 |
| DEC-10 | 数据放组件内 `data/`，不集中根目录 | 生命周期与组件一致；`**/.data/` 一条 gitignore |
| DEC-11 | Sentinel conf / `nodes.conf` / 渲染产物放 `.data/`，config 只存模板 | 运行时重写或含渲染 IP，只读挂载必然失败 |
| DEC-12 | 不默认使用 keepalived/VIP，nginx 双实例 + 客户端双地址 | 单机 VRRP 无法验证真实切换 |
| DEC-13 | edge 域不放数据库 | DB 由各自 HA 栈提供，避免双份配置漂移 |
| DEC-14 | RocketMQ 用 DLedger（Raft）3 broker | 原生主从切换需人工 |
| DEC-16 | 各栈自带 DCS/元数据（pg 自带 etcd ×3） | 生命周期解耦：关掉 etcd 域不能拖垮 PG 选主 |
| DEC-17 | 演练一律 `docker compose stop` | `restart: unless-stopped` 会复活被杀容器 |
| DEC-18 | 每栈双形态（solo / ha），profile 切换 | solo 日常快迭代；ha 仅作验证台架 |
| DEC-19 | solo 复用 `.11` IP，但配置与数据目录隔离 | 身份一致便于客户端不变 |
| DEC-20 | observability 域（`172.28.12.0/24`），域内按组件拆栈 | 每栈都有 exporter 却无归集后端 = 指标白采 |
| DEC-21 | UI 统一经 `<svc>.localhost` 子域 | 历史原因：MinIO/Consul 子路径会失效；子域零配置（MinIO 已于 v4.2 移除，规则对 Consul 仍必要） |
| DEC-22 | 路由表进 ini `[routes]`，nginx 配置由此生成 | 与 IP 同源，避免"IP 改了忘改 nginx" |
| DEC-23 | Prometheus 抓取目标由 ini + 原生指标表生成 | 新增栈自动纳入监控 |
| DEC-24 | 可观测性按组件拆栈（prometheus / alertmanager / grafana / jaeger） | 配置格式、状态生命周期、重置影响面不同 |
| DEC-25 | 观测栈及其它跨栈引用全部由 `render.sh` 从 ini 注入 | 拆栈后的主要风险是"引用漂移"，doctor 第 14 项兜底 |
| DEC-28 | 块号与 `[stack.*]` 命名不随范围调整而删除 | 追加/恢复域时按原块号回填，避免全表重编号 |
| DEC-29 | 新增 `services/jaeger/`（Badger 存储） | 三支柱缺 traces；不为此再加存储域 |
| DEC-30 | Jaeger 不伪装成双实例 HA | Badger 单写者；假 HA 比明确单实例更危险 |
| DEC-31 | `redis` 用复合栈（一个目录两组 profile） | 同一产品 + 互斥 + 配置高复用（§2.1 四条硬条件） |
| DEC-32 | `redis-base.conf` 放 `services/redis/config/base/` | 只被一个目录使用，不属于跨栈共享 |
| DEC-33 | 拆 `core/` → `nginx` + `mailpit` + `adminer` + `minio`（v4.2 后仅剩 nginx，见 DEC-38） | 四个不同产品、可同时运行、重置影响面不同 |
| DEC-34 | **恢复 13 域全量**（撤销 v3.0 缩容） | 缩容期间失去"跨组件交互验证"能力（缓存↔DB、消息→缓存回填）；目录规则已统一，恢复不再引入结构债 |
| DEC-35 | 指标抓取分两类来源：`role=exporter` 行（独立 exporter 容器：pg / mysql / mongo / kafka / rocketmq / redis×2 / nats）与**原生 `/metrics` 映射表**（etcd / consul / rabbitmq / nacos / obs 四栈） | 原生 HTTP 指标不值得再套一个 exporter 容器；两类都在 `render.sh` 里统一生成，仍满足"新增栈自动纳入" |
| DEC-36 | **新增 `services/nacos/`（第 14 域 `.13.x`）**，配置库**复用 mysql 栈**（`172.28.4.31:6446/nacos_config`），不新建数据库域 | Nacos 集群模式必须共享一份配置库（内嵌 Derby 不支持多节点共享）；再建一个 MySQL 就是 DEC-13 禁止的"重复数据库"。代价是跨栈依赖，显式登记为 R25 |
| DEC-37 | Nacos **控制台经 nginx（HTTP）**，**SDK / gRPC（9848/9849）直连节点 IP** | 9848 是长连接 gRPC，走 nginx 需要 stream + 粘性，且 Nacos 客户端会自行选择节点；直连固定 IP 与本环境"宿主可直连容器 IP"的前提一致 |
| DEC-38 | **删除 mailpit / adminer / minio**，`.0.x` edge 只保留 nginx | mailpit 只服务"邮件外发演示"（告警在 AM UI 即可看）；adminer 可用 `make stack-shell` 替代；minio 当时**没有任何消费者**（Jaeger 用 Badger、备份走逻辑导出、Thanos 列 N 级）。三者合计 6 容器 / 1.30 GB，删掉后全量 ha 从 15.8 GB 回到 14.5 GB |
| DEC-39 | **镜像一律来自官方源，但可自定义**：唯一清单 `base/images.yml`；`render.sh` 注入各 compose；`.env` 的 `IMG_<NAME>` 可逐个覆盖，`IMAGE_PREFIX` 可整体前缀（镜像加速器/私有仓库），三者默认都为空 → **默认就是官方镜像** | 官方镜像可审计、无供应链惊喜；但国内拉取慢/企业内网需要私有仓库，所以把"换源"做成一处配置而不是散落在 16 个 compose 里。compose 内禁止字面量镜像（doctor 第 4 项） |
| DEC-40 | **版本粒度 = `X.Y`（major.minor）**，禁止 `latest`；上游只发 `X.Y.Z` 的镜像（Kafka、各 exporter、RabbitMQ 之外的多数项目）按 `X.Y.Z` pin，并在 `images.yml` 备注原因 | `X.Y` 让补丁自动跟随、跨大版本不漂移；但集群身份文件（`nodes.conf`、`meta.properties`）与版本行为绑定，所以**大版本必须人工升级**。对上游不提供 `X.Y` 标签的镜像，退化为 `X.Y.Z` 反而比 `X.Y` 更可复现 |
| DEC-41 | **Redis 持久化 = AOF(`everysec`) + RDB 快照并存**（两组 profile 共用 `config/base/redis-base.conf`） | AOF 保证"哨兵切主/节点重启不丢写"，RDB 便于 `backup-all.sh` 在线导出与快速恢复；只开 RDB 会丢最后一次快照之后的写，只开 AOF 则备份/迁移只能靠 `BGREWRITEAOF` 拷贝，体积大且慢 |
| DEC-42 | **宿主入口 `80/443`**，只有 `nginx-1` 发布；`.env` 的 `ENTRY_HTTP_PORT` 可把宿主侧整体换到高位端口 | 实测非 root 绑定 80 可用（OrbStack 代理），最短 URL 对日常使用收益最大；但 macOS 上 80 可能被其他常驻服务占用，所以把宿主端口做成一个变量，而不是写死在 compose 里 |
| DEC-43 | **`TZ=Asia/Shanghai`**，只写 `base/anchors.yml` 一处；MySQL / Mongo 统一 `utf8mb4` | 本地调试看日志/写 SQL 时不用心算时区；集中一处才能在需要时整体切 UTC（跨时区协作只有这一个开关）。组件内出现 `TZ=` 违反铁律一 |
| **DEC-44** | **Nacos 直接上 3.x**（D35=B）：`nacos-server`×3 + **`nacos-console`×1**（控制台独立、8080、无状态），schema 用 **3.x** 的 `mysql-schema.sql`；端口表/路由/身份清单/probe 全部按 3.x 更新 | 3.x 是官方方向，2.x 已进入维护期；控制台拆成无状态前端后，1 个 console 指向 3 个 server 即可（少 2 个容器、少 2 份状态）。代价是**端口与 schema 与 2.x 不兼容**，且 3.x 资料较新 → 把"console 打包方式 / health 与 metrics 路径 / schema 文件名 / 鉴权默认"列为 P5 首次启动的**锁定四项**（R28） |
| **DEC-45** | **P0 生成与运行契约**（D04–D07 全部取 A）：凭据用 `env/.env` + `scripts/gen-secrets.sh`（chmod 600，gitignore）；`base/anchors.yml` 由 `render-all.py` 在生成期展开；`services/*/compose.yml` 只作手写骨架，渲染器生成 `.generated/<stack>.yml` 与根聚合 compose；ini 保持竖线 5 列、`mode` 缺省 `ha` | 四项都是 P0 阻塞项，共同理由是"唯一输入 + 生成物可丢弃"：IP/镜像/锚点/凭据各只有一个事实源，根 compose 与 `.generated/` 可随时重建。代价是不能手改生成物，且每次改 ini/base 后必须 `make render`；doctor 第 4/5/13 项兜底 |
| **DEC-46** | **启用第 15 域 `.20.x` docsify**（`services/docsify/`，`docsify-1`×1，`172.28.20.11:3000`，`role=docs`、`mode=both`）：用 `rockben/docsify-server` 把仓库 `docs/` 变成可浏览站点，经 `docsify.localhost` 从宿主访问；**内容以只读嵌套挂载挂到 `/docs/content`**，站点壳（`index.html` / `assets/` / `_sidebar.md`）渲染到 `.data/site/`；`DOCSIFY_AUTO_INIT=false` 关掉镜像自举；HA 全量豁免（§5.3） | 文档体量（plan.md 1200+ 行）已不适合直读文件；docsify 无需构建、挂载即跑，符合"配置与数据全部位于本仓库"。只读挂载 + 关自举是为了不让容器回写 `docs/`（否则违反"`config/` 只放模板、产物落 `.data/`"）。代价：多 1 容器 / 0.05 GB，占用预留块 `.20`（后续新域从 `.21` 取） |
| **DEC-47** | **Prometheus 抓取目标按"该栈当前部署形态"过滤**：`hosts_of` / `redis_targets` 不再返 ini 全量，而是用 `services_of <profile> <deployed_mode>`（读 `.data/.mode-*`，无 marker 回退 ha）只列真会起的节点；`job_name: prometheus` 自身按本次 `MODE` 参数取 | 实测反例：consul 跑 solo 时，prometheus 仍把 consul-2/3 列为目标并长期 `down`——`count(up==0)` 不是 0 就分不清"真故障"与"根本没部署这个副本"，`tier-s`（全 solo）会造出十多个假 down。保留 DEC-23 的"新栈自动纳入"：只要该栈被起过就会按当前形态出现；代价是**改形态后要 `make render` + reload** 才同步（已写进 §14 与 stacks.md） |
| **DEC-48** | **doctor 增加第 15 项「运行态健康」**，并把"Docker daemon 重启后必须重跑 `make stack-up`（或 `make tier-*`）才能恢复集群不变量"写成正式口径（§6.3 / §8.4 / stacks.md 全局约定） | 真实事故链：daemon 重启 → `restart: unless-stopped` 只复活容器 → mysql 因为 `group_replication_start_on_boot=OFF` 停在 OFFLINE → `nacos_config` 库（成组后才建）不存在 → nacos ×3 进 crash loop（restart=50）——而 `make doctor` 当时 **14/14 PASS**。前 14 项全为静态校验，结构性看不见这一层。代价：doctor 从"全停也能绿"变成第 15 项依赖 daemon；已用 WARN（而非 FAIL）包住"未部署/没在跑"，保证没起东西时不会喷 FAIL |
| **DEC-49** | **redis 的 `/scrape` 中继只列 6379 节点，不列 sentinel（26379）**：`redis_targets()` 跳过 `role=sentinel` | 实测：中继型 exporter 只能带一份全局 `REDIS_PASSWORD`，而 sentinel 自身不设密码（只用 `sentinel auth-pass` 连 master），带密码去连会 AUTH 失败；更坑的是 `up` 仍为 1（中继永远回 200），真正失败的是指标里的 `redis_up 0`——三个 sentinel 存活却长期报 0，与 DEC-47 要消除的假故障同一类（已用一个不带密码的临时 exporter 对照证实：同一 sentinel 目标 `redis_up 1`，加上 `REDIS_PASSWORD` 就变 0）。控制面健康本来就不靠指标：`make stack-status` 比三台 `get-master-addr-by-name` 是否一致，加 `make failover-drill`；主从切换在指标上体现为 `redis_role` 在两个 instance 间互换。代价：拿不到 sentinel 自身的 INFO 指标（想拿要先给 sentinel 设密码，已列为 D37） |
| **DEC-50** | **`stack.sh` 的 MODE 缺省不再写死 solo，而是读 `.mode-<profile>` marker 沿用当前部署形态**（无 marker = 从没部署过才回退 solo） | 实测：`make stack-status S=mysql`（Makefile 旧默认 `MODE=solo`）在一个 **ha 部署**上走的是 solo 分支，打 `@@server_id / @@gtid_mode / @@version` 而**不是** MGR 成员表——看起来输出了东西、实际验的是另一个形态，跟 DEC-48 要消除的"绿色说谎"同类。marker 是唯一事实源（DEC-47/48 已用），`deployed_mode <profile> [fallback]` 加一个可选回退参数而不是再造一份读取逻辑。附带收益：DEC-48 的恢复口径"重跑 `make stack-up`"不带 MODE 时不会再把 ha 部署静默改成 solo。代价：`make stack-up S=<p>` 省略 MODE 的语义从"起 solo"变成"沿用当前形态"（要显式换形态必须写 `MODE=solo\|ha`），脚本每次会打印 `# MODE 未指定 -> <mode>` 以免误以为还是旧默认 |
| **DEC-51** | **工具链与依赖不进宿主：`mise.toml`（入库输入）钉 `python = "3.12"`，依赖只装仓库内 `.venv/`（生成物，gitignore），`make setup` 一键重建**；Makefile 前置 `.venv/bin` 到 PATH，`scripts/lib.sh` 同效（覆盖不走 make 的直接调用） | 直接诱因：一次 `make render` / `stack-up` 报 `ModuleNotFoundError: No module named 'yaml'`。根因不是版本旧，而是**宿主同时存在三个 `python3`**（uv 的 3.12 / mise 的 shims / Apple 的 `/usr/bin/python3` 3.9.6），而 `.zshrc` 把 `~/.local/bin` 前置在 `mise activate` **之后**，于是交互式 zsh 与 `bash -lc` / cron / IDE Run Config 解析到不同解释器（实测：`zsh -ic` 得 3.12，`zsh -lc` / `bash -lc` / `env -i` 得 3.9.6）。"升级系统 Python"不是选项：`/usr/bin/python3` 由 Apple 随 Command Line Tools 分发（root:wheel、SIP 保护，下次 CLT 更新会覆盖）。选 mise 而非手建 venv：宿主已用 mise 管 go/golangci-lint/lefthook（既有约定优先），且 mise 的 python 是预编译包（`cpython-3.12.15+…-install_only_stripped.tar.gz`，实测 13.5 s 装好，与 uv 同源）。代价：多一个根级输入文件 `mise.toml` 与一个生成物 `.venv/`；`make setup` 成为首次与换机器的必填项；宿主没装 mise 时需要提示（脚本已回退宿主 `python3`，不会硬坏）；另外要回收本轮临时用 `--break-system-packages` 塞进解释器的 PyYAML |
| **DEC-52** | **`stack.sh` 的 `up` / `reset` 改为两段式：`up -d`（不等健康）→ `bootstrap` → `up -d --wait`**；同时 mysql 的 `bootstrap.sh` 在首次成组前先解开 `super_read_only` | 真实事故链（一次全量 `down` 后按§8.4 口径恢复）：`mysql-router-1/2` 一直 `unhealthy` → `up -d --wait` 超时失败 → **`bootstrap` 根本没执行** → MGR 停在 `OFFLINE`。根因是顺序死锁：`--wait` 要等 Router 健康，Router 只在 metadata cache 里看到 ONLINE primary 才监听 6446，而成组本来就是 bootstrap 的职责 —— "先等健康再引导"对**任何一个需要 bootstrap 才转健康的栈**都是死循环（DEC-48 写的"重跑 `make stack-up` 即恢复"对 mysql 名实不符）。bootstrap 自己带就绪轮询（各栈 20–60 次），所以第一段不等健康是安全的；第二段才把"真的健康"作为终态。第二道坑：解锁后 `CREATE USER 'repl'` 报 `ERROR 1290`，单主 MGR 重启后节点带 `super_read_only=ON` 回来（运行时值，不落 `mysqld-auto.cnf`），而在成组前必须建 repl 用户；首次成组分支里逐节点 `SET GLOBAL super_read_only=OFF`（只在这个分支！"已成组"分支里 SECONDARY 的只读是单主语义本身，不能解）。实测（`stack.sh rm mysql ha` 后重建容器）11.7 s：MGR 3 `ONLINE`（1P2S）+ 两台 Router `6446/6447 ok`，`nacos_config` 的 10 张表完好 |

### 11.2 历史（已被取代，留档）

| # | 原决策 | 现状 |
|---|---|---|
| DEC-26 | 只保留 Redis（移出 10 域） | **已撤销**（DEC-34 恢复）；缩容文档见 `docs/archive/plan-v3.2-redis-only.md` |
| DEC-15 | MinIO 4 节点分布式（EC:2） | **已撤销**（DEC-38 删除 minio）：无消费者；需要对象存储时按 §17 重新追加（N12） |
| DEC-27 | 最小入口 core + 观测栈 | **已撤销**：入口/工具按 DEC-33 拆成四个目录；观测四栈保留 |
| DEC-8/9/13/14/16 | 曾于 v3.0 标注"撤销（域移出）" | **已恢复为有效**（见 11.1）；DEC-15（MinIO）例外：v4.2 删除 minio 后仍为撤销 |

---

## 12. 风险登记册

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | "宿主免端口映射"依赖 OrbStack | 换 Colima/Docker Desktop → Sentinel/Cluster/Patroni/Router/Kafka 地址公告失效 | `doctor.sh` 第 7 项卡死 context；README 顶部写前提；换运行时按 §1 重新评估 |
| R2 | 71 容器 / 14.75 GB（余量 ≈ 0.95 GB） | OOM / 宿主卡顿 | 六档纪律（§9.1）+ §9.2 限流；全量 ha 不常驻；`make size` 监控 |
| R3 | 身份状态文件丢失 | 集群不可恢复（需重建 + 数据丢失） | 状态文件全在 `.data/` → `backup-all.sh`；`stack-reset` 前强制备份 |
| R4 | macOS bind mount 权限 | PG/Redis/MySQL/Mongo 启动失败 | `bootstrap.sh` 对齐 uid（999）；`PGDATA` 用子目录避开 lost+found |
| R5 | 单机模拟集群 ≠ 真分布式 | 无法复现脑裂/时钟/跨机延迟 | §5.4 明确边界；多机验证另立方案（N02） |
| R6 | JVM 默认堆 | RocketMQ/Kafka 吃满 VM | `base/jvm/heap.env` 统一注入（§9.2） |
| R7 | 重启顺序依赖 | bootstrap 逆序导致成员无法加入 | `render.sh` 固定依赖顺序；`stack-up` 内置等待 healthy |
| R8 | `include` 无 glob | 新增/恢复域漏登记 | `render-all.sh` 生成，不手写 |
| R10 | MGR/DLedger/Patroni 均依赖"初始种子 + 整栈重建" | 单节点 reset 会导致集群无法恢复 | `reset.sh` 强制整栈；`doctor.sh` 第 11 项校验法定人数 |
| R11 | 容器命名/日志量 | 71 个容器日志炸盘 | 统一命名 `<stack>-<node>`；日志限 10m×3 |
| R12 | `restart` 策略干扰演练 | 误判"切换成功" | `doctor.sh` 第 12 项 + §8.3 |
| R13 | 双形态配置漂移 | solo 行为被误当集群结论 | 两形态共用同一份模板渲染；`docs/stacks.md` 标注语义差异 |
| R14 | 两形态/两 profile 数据目录误用 | 用 solo 数据启动 ha 节点 → `nodes.conf` / MGR 元数据损坏 | `render.sh` 生成不同 `dir`；`stack-switch` 强制提示；`.data/<group>/` 分层 |
| R15 | `*.localhost` 只在宿主生效 | 容器内访问 `grafana.localhost` 失败 | 容器间一律用 IP/服务名 |
| R16 | 观测四栈的常驻成本（0.75 / 1.30 GB） | 挤占其他栈的内存预算 | `obs(solo)` 是常驻层；`obs-ha` 仅排障时起；Prometheus 保留期与 TSDB size 上限见 §9.2 |
| R17 | Grafana 单点 | 面板不可用（指标仍在） | 接受：无状态 + provisioning，独立栈级重建 |
| R18 | 跨栈引用漂移 | 面板无数据 / 告警不发 / 客户端连不上 | DEC-25：引用由 `render.sh` 注入；`doctor.sh` 第 14 项校验 |
| R19 | 观测四栈 `render.sh` 执行顺序 | Grafana 先起时短暂 `No data` | 组内固定顺序 prometheus → alertmanager → jaeger → grafana |
| R22 | Jaeger 存储为单实例本地 Badger | 无法验证 trace 存储 HA；磁盘增长 | TTL 72h；`.data/jaeger` 计入 `make size` 与备份；真 HA 列入 N09 |
| R23 | trace 与指标的关联依赖数据源配置 | 面板上看不到 trace 跳转 | 数据源与 `traceToMetrics` 全走 provisioning（DEC-25），doctor 第 14 项兜底 |
| R24 | 复合栈的作用域误伤：`reset/down` 没带 profile | 误删哨兵栈数据 / 误停集群栈 | §8.0.1 四条硬约束；`doctor.sh` 第 5 项把"无 profile 的服务"判失败 |
| R25 | **nacos 依赖 mysql 栈**（库在 mysql Router） | mysql 域未起/切主中 → nacos 启动失败或配置读写 503 | `bootstrap.sh` 先探 `mysql-router-1:6446` 再启；`doctor.sh` 第 14 项校验该引用；F 档把两者绑定；文档标注"nacos 不能脱离 mysql 单独起" |
| R26 | Nacos 的 gRPC（9848/9849）**不经 nginx** | 容器/宿主能连 8848 却连不上 9848 → 客户端注册成功但推送失败 | 客户端配置节点固定 IP（DEC-3 前提）；`nginx` 只代理控制台；换运行时见 R1 |
| R27 | **删掉 mailpit / minio 后的能力缺口**：没有邮件外发通道、没有 S3 兼容存储 | 告警只能看 AM UI；应用若需要对象存储则没地方放 | 告警改用 `receivers: nul`（Grafana/AM UI 查看）；对象存储需要时按 §17 追加（N12） |
| R28 | **Nacos 3.x 与 2.x 不兼容**：控制台端口、schema、鉴权默认值都可能不同；3.x 资料较新 | 按 2.x 经验配 → 控制台打不开 / 建表冲突 / 客户端 403 | P5 首次启动锁定四项并写进 `docs/stacks.md`：console 是否独立镜像与端口、health/metrics 路径、3.x schema 文件名、鉴权是否默认开启；`backup-all` 不跨大版本恢复（R3） |
| R29 | **宿主 / Docker daemon 重启后集群不变量不恢复**（MGR `start_on_boot=OFF`、Patroni/DLedger 需重加入），而 `restart` 只复活容器 → 跨栈依赖（nacos→mysql）连环 crash loop | 重启后"看起来全在跑"，实际集群未成组、上层栈持续重启 | §8.4 恢复口径（按依赖顺序重跑幂等的 `make stack-up`）；§6.3 第 15 项把运行态纳入体检（crash loop = FAIL，已部署未跑 = WARN）；DEC-48；两段式启动 + 解只读让这条口径真能重放（DEC-52） |

> 编号 R9（MinIO 一致性）、R20（缩容期"覆盖不足"）、R21（Redis 单机 maxmemory）已随范围调整移除；编号不复用，避免与历史文档/提交记录错位。

---

## 13. 实施路线

| 期 | 内容 | 验收 |
|---|---|---|
| **P0 地基** | `base/`、`stock/network.ini`（14 域花名册）、`services/nginx`（solo + ha）、`doctor.sh`、`render-all.sh`、`Makefile`、`.gitignore`、`env/` | `make doctor` 15 项全绿；`MODE=solo` 起 1 容器、`MODE=ha` 起 2 容器；容器内 `date` 显示 `CST +0800`；`grafana.localhost` 的 502 能说明路由已通（观测栈未起）；`git status` 不含 `.data/`、`.env` |
| **P1 etcd** | 最轻的共识栈，把 bootstrap 契约打磨成型 | 3 节点 `endpoint health` 全 ok；停 1 节点仍可写；恢复后成员自动回归 |
| **P2 pg（Patroni）** | patroni×3 + DCS×3 + haproxy×2 + exporter | `patronictl list` 1L2R；`make failover-drill S=pg` → leader 在 30s 内转移，旧主回归为 replica |
| **P3 redis** | 复合栈两组：哨兵（1M+2R+3S）与集群（3M+3R） | 哨兵：`get-master-addr-by-name` 正确、10s 内切主；集群：`cluster_state:ok`、3M3R、16384 slots；`stack-reset S=redis-sentinel` 不影响 `.data/cluster/` |
| **P4 consul / nats** | 与 etcd 同构，复制改参 | 3 成员 alive；nats JetStream 副本 R3 |
| **P5 mysql MGR / mongo RS / nacos 3.x** | 3 节点 + Router×2 / RS×3 / nacos-server×3 + console×1（依赖 mysql） | MGR 3 成员 `ONLINE`，杀 primary 自动选主且 Router 跟随；`rs.status()` 1P2S 并完成一次自动选主；nacos raft 有 leader，注册一个实例在 3 个 server 都查得到，改一条配置能推送到客户端，`nacos.localhost` 控制台可登录 |
| **P6 kafka / rabbitmq / rocketmq** | 最重，最后 | offset 三副本、`min.insync.replicas=2`；quorum queue 3 副本；DLedger 3 broker 自动切换 |
| **P7 观测 + 入口** | 观测四栈（prom / am / grafana / jaeger）；nginx `[routes]` 生成；面板（清单 §16.4） | 四栈可独立起停；全栈 `/metrics` `up=1`；`grafana.localhost` 面板有数；`alertmanager.localhost` 能看到一条测试告警；`jaeger.localhost` 能搜到 `make trace-demo` 推的 trace |

**每期统一节奏**：先 `MODE=solo` 打通（快速验证镜像/配置/连通），再 `MODE=ha` 上集群并做故障演练。solo 只证明"能跑"，ha 才证明"集群成立"。

每期结束更新 `docs/stacks.md`（起停、验证命令、演练脚本、重置步骤、solo↔ha 语义差异、坑）。

---

## 14. 命令速查（目标契约）

```bash
make doctor                    # 15 项体检
make render                    # ini → compose.generated.yml + 各栈配置
make prepull [TIER=a|b|c|d|e|f] # 按 images.yml 预拉镜像（D01/D27，可选）
make up                        # 起当前档位（默认 A）
make down                      # 停全部（按 profile，不漏组）
make ps / make size            # 状态 / 磁盘占用（含各栈 .data/）
make tier-s                    # solo 全栈（28 容器，≈ 5.35 GB）
make tier-a|tier-b|tier-c|tier-d|tier-e|tier-f
make stack-up     S=pg MODE=solo|ha
make stack-switch S=pg MODE=ha
make stack-status S=pg
make stack-reset  S=pg          # 整栈重建，强制备份
make stack-shell  S=pg N=patroni-1
make stack-host   S=pg N=patroni-1   # 宿主侧用固定 IP 直连
make backup                    # 归档所有栈 .data/ + 状态文件
make failover-drill S=pg|redis-sentinel|redis-cluster|mysql|mongo|kafka|rocketmq
make ui-open S=grafana|jaeger|rabbitmq|consul|prometheus|alertmanager|nacos|docsify
make routes                    # 打印全部 <svc>.localhost 入口
make obs / make obs-ha         # = group-up G=observability MODE=solo 或 ha
make trace-demo                # 向 jaeger 推一条 OTLP trace
```

---

## 15. 统一入口与路由（需求⑥ / DEC-21 + DEC-22）

### 15.1 问题背景

铁律 F06 是"除 nginx 外不发布宿主端口"，而各栈控制台（RabbitMQ Mgmt / Consul UI / Grafana / Prometheus / Alertmanager / Jaeger / Nacos / docsify）都在非 edge 的域里。
不管的话这些 UI 从宿主一律打不开。

### 15.2 为什么用子域而不是子路径

| 组件 | 子路径（`/svc/`） | 子域（`svc.localhost`） | 说明 |
|---|---|---|---|
| Adminer | ✅ | ✅ | 两种都可用 |
| Mailpit | ✅ | ✅ | 收件箱在 `/` |
| RabbitMQ Mgmt | ✅ `management.path_prefix` | ✅ | 需 WebSocket 升级头 |
| Prometheus | ✅ `--web.external-url` | ✅ | |
| Alertmanager | ✅ `--web.external-url` | ✅ | |
| Grafana | ✅ `root_url` 含子路径 | ✅ | 子路径需同步 `serve_from_sub_path`，易错 |
| Jaeger | ⚠️ 支持 `--query.base-path` | ✅ | 子路径需同步 `JAEGER_UI_BASE_PATH` |
| **Consul UI** | ⚠️ 固定 `/ui`，不支持自定义前缀 | ✅ | |
| **Nacos Console** | 3.x 控制台独立（`8080`，根路径）；2.x 才是 `/nacos` 前缀 | ✅ | 子域下直接 `http://nacos.localhost/`（3.x） |
| **docsify** | ⚠️ 需 `window.$docsify` 的 `homepage` / `loadSidebar` / 资产路径全部改成相对 base，易漏 | ✅ | 站内 markdown 链接是相对路径，子路径下会算错基址（DEC-46） |

→ **统一走子域**：路由表在 `stock/network.ini` 的 `[routes]`（DEC-22），nginx 配置由此生成。

### 15.3 路由表

> 下面这段是 §5.1 `stock/network.ini` 中 `[routes]` 段的**摘录**，不是第二份事实源：改路由只改 ini（DEC-22）。

```ini
[routes]
rabbitmq.localhost     | 172.28.8.11  | 15672 | path-ok
consul.localhost       | 172.28.10.11 | 8500  | subdomain-only
grafana.localhost      | 172.28.12.31 | 3000  | subdomain-only
prometheus.localhost   | 172.28.12.11 | 9090  | path-ok
alertmanager.localhost | 172.28.12.21 | 9093  | path-ok
jaeger.localhost       | 172.28.12.32 | 16686 | subdomain-only
nacos.localhost        | 172.28.13.32 | 8080  | subdomain-only
docsify.localhost      | 172.28.20.11 | 3000  | subdomain-only
```

> 只有 `nginx-1` 把 `80` 发布到宿主（`ENTRY_HTTP_PORT` 可覆盖）；`nginx-2` 不发布，供"双地址"验证。
> 其余 UI 一律经 nginx，不直接发布端口（DEC-3）。

### 15.4 nginx 生成规则

`render.sh` 为每个 `[routes]` 行生成一个 `server` 块（`services/nginx/.data/conf.d/<host>.conf`，`config/` 只放模板），固定包含：

```nginx
server {
    listen 80;
    server_name <host>;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;      # RabbitMQ Mgmt 必需
    proxy_set_header Connection $connection_upgrade;
    proxy_buffering off;                          # 长连接/SSE
    location / { proxy_pass http://<upstream_ip>:<port>; }
}
```

nginx 两个实例生成**完全相同的配置**（DEC-12：双入口、无 VIP，客户端可任选一个 IP）。

### 15.5 域名解析边界

| 场景 | 解析方式 |
|---|---|
| 宿主浏览器 | `*.localhost` 自动 → `127.0.0.1`（macOS 原生，**不改 `/etc/hosts`**） |
| 容器之间 | **禁止**用 `.localhost`；一律用容器 IP 或服务名（R15） |
| 端口 | 仅 `80`（nginx-1）；`443` 保留给后续自签 TLS；宿主侧端口由 `.env` 的 `ENTRY_HTTP_PORT` 决定（默认 80） |

---

## 16. 可观测性域（需求⑥⑦⑧ / DEC-20 + DEC-24 + DEC-29）

> 本域**不是一个大杂烩目录**，而是 4 个组件目录共享一个 `/24`：每个观测组件在 `services/` 下拥有自己的
> `compose.yml` / `config/` / `scripts/` / `.data/`，独立 profile、独立起停、独立重置、独立切 solo/ha（§2.1）。

### 16.1 四个组件栈

| 组件栈 | 目录 | 容器（solo → ha） | IP | 作用 | profile | 内存 solo / ha |
|---|---|---|---|---|---|---|
| **prometheus** | `services/prometheus/` | `prometheus-1` → `+prometheus-2` | `.12.11` / `.12.12` | 指标采集与 TSDB | `prometheus` | 0.30 / 0.85 GB |
| **alertmanager** | `services/alertmanager/` | `alertmanager`（两形态相同） | `.12.21` | 告警路由 | `alertmanager` | 0.05 / 0.05 GB |
| **grafana** | `services/grafana/` | `grafana`（两形态相同） | `.12.31` | 面板 + 数据源（provisioning 入库） | `grafana` | 0.25 / 0.25 GB |
| **jaeger** | `services/jaeger/` | `jaeger`（两形态相同） | `.12.32` | 链路追踪：OTLP 接收 + Badger 存储 + 查询 UI | `jaeger` | 0.15 / 0.15 GB |
| | | | | | **合计** | **0.75 / 1.30 GB** |

> 为什么不合成一个 `services/observability/`：四者配置格式、状态生命周期、重置影响面完全不同。
> 合并后 `stack-reset S=observability` 会同时删掉面板配置、TSDB 与 trace，且无法单独升起某一组件（§2.1）。

### 16.1.1 启动顺序与跨栈引用（DEC-25）

四栈之间**无启动依赖**（被采对象不在线也能起，只是 `up=0`），但**引用必须由 `render.sh` 从 ini 注入**，禁止手写 IP：

| 顺序 | 组件栈 | 引用点 | 取值来源 |
|---|---|---|---|
| 1 | prometheus | `alertmanager` 静态目标、`scrape_configs` | ini `[stack.alertmanager]` + 全部 `role=exporter` 行 + 原生指标表 |
| 2 | alertmanager | `receivers`（默认 `nul`，不外发；告警在 AM UI / Grafana 查看） | 无外部 IP 引用（v4.2 删除 mailpit 后不再注入 SMTP 地址） |
| 3 | jaeger | 无外部引用（只监听 OTLP；采样策略读本地文件） | ini `[stack.jaeger]` 仅用于生成 `base_path` 与路由 |
| 4 | grafana | 数据源 URL：`http://172.28.12.11:9090`（Prom）、`http://172.28.12.32:16686`（Jaeger） | ini `[stack.prometheus] prometheus-1` / `[stack.jaeger]` |

> 顺序只影响"组起"时的短暂 `No data`；单栈重启不牵连他栈。

### 16.1.2 拆栈后的可操作边界（P7 验收项）

| 场景 | 命令 | 影响面 |
|---|---|---|
| 只要指标，不要告警 | `make stack-up S=prometheus`（+ `S=grafana`） | 不起 alertmanager，省 0.05 GB |
| 升 Grafana / 换面板 | `make stack-reset S=grafana` | TSDB、告警静默、trace **均不受影响** |
| 改采集目标 / 保留期 | `make render && make stack-up S=prometheus` | Grafana 无需重启 |
| 改告警 receiver | `make stack-up S=alertmanager` | 采集与面板零中断 |
| 全量重建指标 | `make stack-reset S=prometheus` | 面板配置仍在（provisioning），历史数据清空 |
| 清空 trace / 改采样 | `make stack-reset S=jaeger` | 指标、面板、告警不受影响 |

### 16.2 抓取目标自动生成（DEC-23 + DEC-35）

`render.sh` 生成 `prometheus.yml`，目标分两类来源：

**① `role=exporter` 行 → 独立 exporter 容器**

```yaml
scrape_configs:
  - job_name: pg
    static_configs:
      - targets: ['172.28.1.41:9187']
  # redis 的两组用多目标模式：targets 是 redis 节点，真正的请求发往 .41 的 exporter
  - job_name: redis-sentinel
    metrics_path: /scrape
    static_configs:
      - targets:
          - '172.28.2.11:6379'   # master
          - '172.28.2.12:6379'
          - '172.28.2.13:6379'
          # sentinel-1..3（.21-.23:26379）不抓（DEC-49）：中继只有一份共享密码，
          # sentinel 自己不设密码 → AUTH 失败 → redis_up 恒 0（假故障）
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: '172.28.2.41:9121'
  - job_name: redis-cluster
    metrics_path: /scrape
    static_configs:
      - targets:
          - '172.28.3.11:6379'
          - '172.28.3.12:6379'
          - '172.28.3.13:6379'
          - '172.28.3.21:6379'
          - '172.28.3.22:6379'
          - '172.28.3.23:6379'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: '172.28.3.41:9121'
  - job_name: mysql
    static_configs:
      - targets: ['172.28.4.41:9104']
  - job_name: mongo
    static_configs:
      - targets: ['172.28.5.41:9216']
  - job_name: kafka
    static_configs:
      - targets: ['172.28.6.41:9308']
  - job_name: rocketmq
    static_configs:
      - targets: ['172.28.7.41:5557']
  - job_name: nats
    static_configs:
      - targets: ['172.28.11.41:7777']
```

**② 原生 `/metrics` → 固定映射表（脚本内一张 8 行表，IP 仍取自 ini）**

| 栈 | 端点 | 备注 |
|---|---|---|
| etcd | `172.28.9.11:2379/metrics` | 3 节点逐个抓 |
| consul | `172.28.10.11:8500/v1/agent/metrics` | `format=prometheus` |
| rabbitmq | `172.28.8.11:15692/metrics` | `rabbitmq_prometheus` 插件 |
| prometheus | `172.28.12.11:9090/metrics` | 自监控 |
| alertmanager | `172.28.12.21:9093/metrics` | |
| grafana | `172.28.12.31:3000/metrics` | |
| jaeger | `172.28.12.32:8888/metrics` | |
| nacos-server | `172.28.13.11:8848/nacos/actuator/prometheus` | 3 个 server 逐个抓（`management.endpoints.web.exposure.include=prometheus`）；console 不出指标 |

> **注**：NATS 的 `/varz` 是 JSON，Prometheus 不能直接抓 —— 因此 nats 域自带一个 `nats-exporter`（`.11.41:7777`，`role=exporter`，两形态常驻）。
> 若后续要 RocketMQ 原生指标，可去掉 `rocketmq-exporter` 改走 proxy 的 OpenTelemetry 端点。

**效果**：加一个栈 → `make render` → 监控自动纳入，不会出现"新栈没人监控"。

**DEC-47**：目标只列**该栈当前部署形态真会起的节点**（读 `.data/.mode-*`）。否则会长期出现
"solo 栈的副本节点永远 down"这种假故障；改形态后要 `make render && curl -X POST :9090/-/reload` 才同步。

**DEC-49**：redis 的 `/scrape` 中继**不列 sentinel 口**（只列 6379）。同一取向的另一半：
中继只能带一份密码，sentinel 不设密码，带密码去连会 AUTH 失败而 `up` 仍为 1（中继永远回 200），
只剩一个无法区分的 `redis_up 0`。sentinel 健康靠 `make stack-status S=redis-sentinel`（三台
`get-master-addr-by-name` 必须一致）与切主演练；要在指标里看主从切换，查 `redis_role` 在
两个 instance 间互换。想让 sentinel 也进指标需先给它设密码（D37，未定）。

> 上面两个 redis job 是**完整可用的写法**（`metrics_path: /scrape` + 三条 relabel），不是示意：
> `targets` 填 redis 节点、`__address__` 被改写到 exporter，`instance` 还原成真实节点地址 —— 这样每栈只占 1 个 exporter 容器、
> 1 个 `.41` 尾号，就能覆盖该栈全部 6 个节点，且面板里能按节点拆分。
> `nats-exporter` 是例外：它在启动时就被指定要抓的 NATS 节点，所以 Prometheus 侧只写单个 target（`:7777/metrics`）。

### 16.3 为什么这里是"冗余采集"而不是"故障转移"

Prometheus 是**拉模式、无共识、本地 TSDB**，不存在"主"的概念，因此：

| 做法 | 效果 | 本方案 |
|---|---|---|
| Prometheus×2 同 targets | 两份独立数据，任一存活即可查 | ✅ ha 形态 |
| Thanos / VictoriaMetrics 集群 | 真正的多副本 + 长期存储（需对象存储；minio 已删，需先按 §17 追加） | ❌ 列为 N 级扩展 |
| Grafana 多副本 | 无状态，重建即恢复（provisioning） | 单实例足够（R17） |
| Alertmanager gossip ×3 | 真 HA 告警路由 | ❌ N 级（单机无收益） |

> 诚实标注：本环境能验证"采集与面板正确"，**不能**验证"监控系统自身高可用"。需要时再追加对象存储域 + Thanos。

### 16.4 预置面板（P7 交付物）

| 面板 | 数据源 |
|---|---|
| 容器资源总览 | cadvisor（若启用，独立目录 `services/cadvisor/`，`.12.41`，见 D30） |
| PG 复制延迟 / leader 变更 | `pg-exporter` + Patroni |
| Redis 哨兵切换 / 集群 slot | `redis_exporter`（主从节点；sentinel 口不抓，DEC-49；切换看 `redis_role` 互换） |
| MySQL MGR 成员状态 | `mysqld_exporter` |
| Mongo RS 成员状态 | `mongodb_exporter` |
| Kafka lag / 副本同步 | `kafka-exporter` |
| RocketMQ DLedger 角色与堆积 | `rocketmq-exporter` |
| RabbitMQ quorum queue | 原生 `:15692` |
| etcd / Consul Raft 健康 | 原生 `/metrics`、`/v1/agent/metrics` |
| NATS JetStream 副本 | `nats-exporter` |
| Nacos 服务实例数 / 配置变更推送 / raft leader | 原生 `/nacos/actuator/prometheus` |
| 全栈 up/down 总览 | Prometheus `up` |
| trace 检索 / 慢调用 / 服务依赖 | **Jaeger UI**（`jaeger.localhost`），不在 Grafana 重建 |

### 16.5 追踪：jaeger 组件栈（需求⑧ / DEC-29）

| 项 | 设计 |
|---|---|
| 镜像 | `jaegertracing/jaeger:2.x`（v2 = OTel Collector 发行版；v1 已进入官方 EOL 路线）—— 见 D33 |
| 存储 | **Badger**（`.data/jaeger/badger`），TTL 72h；不引入 ES/Cassandra（N09） |
| 接入点 | OTLP gRPC `172.28.12.32:4317`、OTLP HTTP `172.28.12.32:4318`（应用只需配 `OTEL_EXPORTER_OTLP_ENDPOINT`） |
| UI | `http://jaeger.localhost`（nginx 子域转发 `:16686`） |
| 采样 | `config/sampling.json`，默认 `parentbased_ratelimited`（1 trace/s/服务）；验收时改 `always_on` |
| 与 Grafana 关联 | Jaeger 数据源 + dashboard 里 `trace_id` → Jaeger 跳转（provisioning 的 `links`） |
| 谁产生 trace | 本环境无业务应用：`make trace-demo`（curl 推 OTLP）验收；真实 trace 由你的应用推送 |
| 保留与体积 | 72h TTL，演示量级 < 200 MB；计入 `make size` 与备份 |
| 不可验证 | collector 多副本、trace 存储高可用、跨服务延迟分析 |

---

## 17. 如何追加一个新域（机制保持可逆）

v4.0 已把 13 个域全部纳入，v4.4 已动用预留块 `.20`（docsify）；将来加下一个域（例如 Elasticsearch、Pulsar、TiDB）时步骤固定：

1. `stock/network.ini` 取一个预留块（`.21–.29`），加 `[stack.<name>]`，每行写 `role` 与 `mode`。
2. `services/<name>/`：照 §8 契约建 `compose.yml` + `config/` + `scripts/` + `.data/`。
   仅当满足 §2.1 的四条"复合栈"条件时，才允许与已有栈同目录。
3. `bash scripts/render-all.sh`：`compose.generated.yml` 自动 include；`prometheus.yml` 自动纳入（`role=exporter` 或原生指标表）。
4. 若要 UI：`[routes]` 加一行，nginx 配置自动生成。
5. `doctor.sh` 无需改 —— 第 1–5/11/13/14 项按 ini 通用校验（法定人数、IP 一致性、双形态、路由/引用）会自动覆盖；第 15 项按 `.data/.mode-<profile>` marker 自动把新栈的运行态纳入校验，`prometheus` 目标也按 marker 自动只列真会起的节点（DEC-47）。

> 追加哪一个，就同时补 `docs/stacks.md` 的对应章节；不要"只起容器不写验证口径"。
