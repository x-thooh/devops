# devops 本地测试环境 · 总体方案 v3.2（只保留 Redis + 可观测性）

> 单机（macOS + OrbStack）只保留 **Redis 的两套形态**：
> **哨兵主从**（`redis-sentinel`：1M + 2R + 3S）与 **分片集群**（`redis-cluster`：3M + 3R），
> **solo 形态**（单节点，日常调试）与 **ha 形态**（集群/主从，验证台架）双轨并存，
> 全部同一网络且各带固定 IP，配置与运行时数据全部位于本仓库；
> 另保留**最小入口**（nginx×2 + mailpit）与**可观测性域**（prometheus / alertmanager / grafana / **jaeger** 四个独立组件栈），
> 统一经 `<服务>.localhost` 子域从宿主访问（§15），Redis 指标经 `redis_exporter` 汇入（§16），链路追踪经 OTLP 汇入 Jaeger（§16.5）。
>
> **v3.0 是缩容版本**：v2.3 的 10 个组件域（PG / MySQL / Mongo / Kafka / RocketMQ / RabbitMQ / etcd / Consul / NATS / MinIO）
> 全部移出范围，全文归档在 `docs/archive/plan-v2.3-13stacks.md`；重新追加的路径固化为 §17。
> **v3.1 新增追踪**：`services/jaeger/`（单实例 + Badger 持久化，不引入新的存储域）。

---

## 0. 需求追溯

| 需求 | 设计落点 | 章节 |
|---|---|---|
| ① 所有容器同一网络，各自分配 IP | 单一 `devnet` = `172.28.0.0/16`，每服务显式 `ipv4_address`，IP 唯一权威登记在 `stock/network.ini`，`doctor.sh` 双向校验 | §3 §6 |
| ② 配置、运行时数据放 devops | `services/<组件>/config`（入库）+ `services/<组件>/data`（gitignore，`**/data/` 一条规则） | §4 |
| ③ **Redis 集群 + 哨兵**（唯一保留的组件） | 独立两块 IP 段（`.2.x` 哨兵、`.3.x` 集群），配置互斥、profile 隔离，状态文件持久化 | §5 §7 |
| ④ 只保留 Redis，其余域移出 | 目录 / IP 域 / 档位 / 体检项全部收敛；追加方式固化为 §17 | §17 |
| ⑤ 每个保留组件都要有集群/主从形态 | Redis 两组 profile 均为 ha；入口与观测按 §5.3 豁免清单豁免 | §5.2 §5.3 |
| ⑥ 各栈 UI 从宿主访问 + 指标统一归集 | §15 `<svc>.localhost` 子域 + §16 可观测性域（四组件栈） | §15 §16 |
| ⑦ 所有组件按组件拆分（含入口与工具） | 每个产品一个目录：`nginx` / `mailpit` / `redis`（复合栈，两组 profile）/ `prometheus` / `alertmanager` / `grafana` / `jaeger`；唯一的多 profile 目录是 `redis`（§2.1） | §2.1 §16.1 |
| **⑧ 链路追踪（Jaeger）** | 观测域第 4 个组件栈 `services/jaeger/`（`.12.32`）：OTLP 接收入口 + 查询 UI，Badger 落 `data/`；Grafana 通过 Jaeger 数据源做 trace 检索 | **§16.5** |

### 0.1 版本沿革（避免混淆）

| 版本 | 形态 | 容器 | 内存 | 定位 |
|---|---|---|---|---|
| **v1** | 全单节点（nginx 1、pg 1、redis 1、minio 1、工具若干） | 5–6 | ≈ 0.6 GB | 最小可用基线 |
| **v2** | 全 HA（12 栈集群/主从） | ≈ 61 | ≈ 13.2 GB | 集群验证台架，**日常偏重** |
| **v2.1** | 双形态：solo = v1 形态；ha = v2 形态，同栈切换 | 6 / 61 | 0.6 / 13.2 GB | 日常用 solo 快迭代，验证用 ha |
| **v2.2** | v2.1 + observability 栈 + `<svc>.localhost` 入口 | 3 / 65 | 0.6 / 14.35 GB | 补上监控后端、UI 访问、入口域名 |
| **v2.3** | v2.2 + observability 按组件拆 3 栈 + 三层模型 | 3 / 65 | 0.6 / 14.35 GB | 部署单元边界（重置面板不丢 TSDB） |
| **v3.0** | **只保留 Redis**（哨兵 + 集群）+ 最小入口 + 观测三栈；10 域移出 | 9 / 21 | 0.85 / 2.05 GB | 收敛到"日常真会用"的最小集：内存余量充足，ha 可常驻 |
| **v3.1** | v3.0 + **jaeger**（观测域第 4 栈）：OTLP 接收 + Badger 存储 + UI | 10 / 22 | 1.00 / 2.20 GB | 补齐可观测三支柱（metrics / logs / **traces**），且不新增存储域 |
| **v3.2（本版）** | **拆掉最后一个多产品目录**：`core` → `services/nginx/` + `services/mailpit/`；`.0.x` 域更名 `edge` | **10 / 22** | **1.00 / 2.20 GB** | 入口与收件箱可独立重置；宿主端口只剩 nginx 一处；计数不变（只改归属） |

---

## 1. 已实测确认的环境事实

| 探测项 | 结果 | 对方案的影响 |
|---|---|---|
| Docker context | `orbstack`（Docker 29.8.2 / Compose v5.5.0） | 入口统一，换运行时需重做方案 |
| **宿主直连容器 IP**（`172.28.0.10:8080`） | ✅ **可达** | 哨兵/集群返回的 `IP:port` 宿主可直接用，**无需端口重映射**，避免 NAT 破坏地址公告 |
| 同网络容器按静态 IP 互访 | ✅ 可达 | 静态 IP 方案成立 |
| `172.28.0.0/16` 与宿主路由 | ✅ 无冲突（宿主已用 `192.168.1.0/24`、`192.168.138.0/23`） | 可直接采用 /16 |
| `include: services/*/compose.yml`（glob） | ❌ 不支持 | 聚合文件用**生成**而非手写清单 |
| `include` + `profiles` 透传 | ✅ 无 profile 时服务为空 | 组件文件必须自带 `profiles` |
| 组件内 `./data`、`./config` 相对路径基准 | ✅ 以**组件文件所在目录**为基准 | 组件可整体搬迁，高内聚成立 |
| 物理内存 / CPU | 48 GB / 14 core | — |
| Docker VM 可见内存 | **15.7 GB** | v3.1 全量仅 2.20 GB，**档位纪律不再紧张**（见 §9） |

> ⚠️ 前提声明：宿主免端口映射依赖 OrbStack 的容器 IP 路由（`docker.expose_ports_to_lan: true`）。
> 换到 Colima / Docker Desktop 默认配置时，**Sentinel 公告的主节点 IP、Cluster 的 `nodes.conf` 地址**会失效（§12 R1）。

---

## 2. 分层原则

**组件内聚（垂直切片）+ 全局不变量集中（水平薄层）。**

| 一起变的东西 | 位置 |
|---|---|
| 某栈的服务定义、配置模板、bootstrap 脚本、运行数据 | `services/<stack>/` 内（删栈 = `rm -rf` 一个目录） |
| 子网、网关、IP 花名册、日志/重启/TZ/健康检查锚点 | `base/` + `stock/`，组件内出现 `subnet:`、`logging:` 一律打回 |
| 跨栈胶水（体检、全量备份、聚合生成） | 顶层 `scripts/` |

### 2.1 三层模型（回答"什么该拆成独立栈"）

| 层 | 单位 | 数量 | 决定什么 |
|---|---|---|---|
| 域（domain） | `/24` IP 块 | 4 | IP 段分配；域内组件共享网关与尾号约定 |
| **组件目录（stack dir）** | `services/<name>/` | **7** | 配置 / 脚本 / 数据的**物理归属**（删栈 = `rm -rf` 一个目录） |
| **部署单元（profile）** | `compose.yml` 里的一组 `profiles` | **8** | **起停 / 重置 / 形态切换的最小单位** |
| 容器（container） | service | 10 / 22 | 进程与资源占用（solo / ha） |

7 个目录 → 8 个部署单元，因为 `services/redis/` 是**复合栈**（见下）。

**拆分判据（默认拆目录）**：一个目录 = **一个可独立起停、独立重置、独立切 solo/ha 的部署单元**，且配置格式与状态生命周期不与他者耦合。

- ✅ 独立成目录：`nginx` 与 `mailpit`（不同产品、可同时运行、重置互不影响 —— v3.2 把原 `core` 拆开）、`prometheus`（TSDB 生命周期最长）、`grafana`（无状态，随时可重置）、`alertmanager`（重启不打断采集）、`jaeger`（trace 存储与 UI，重置不牵动指标/面板）。
- ❌ 留在宿主目录内：`redis_exporter`（随被采对象）、`bootstrap` 一次性容器（幂等子步骤）。

**复合栈例外（`services/redis/`，全项目唯一）**：以下四条同时成立时，允许**一个目录装两组 profile**，而不是拆成两个目录：

1. **同一产品、同一镜像**（都是 `redis:7.4`）；
2. **profile 互斥且不同时运行**（哨兵栈与集群栈语义互斥，不会共存）；
3. **共享配置占比高**（`config/base/redis-base.conf`、exporter 定义、`render/status/reset` 脚本骨架均复用）；
4. **状态仍按 profile 物理隔离**（`data/sentinel/<node>/` vs `data/cluster/<node>/`）。

> 与观测域的区别：prometheus / alertmanager / grafana / jaeger 是**四个不同产品**、**可以同时运行**、**重置影响面各异**，所以必须拆目录（DEC-24）；
> 而 Redis 两套形态是同一产品的两种拓扑，且互斥运行。判据看的是"是否同一产品 + 能否共存 + 配置能否复用"，不是"拓扑有几个"。
>
> 判据可直接验收：`make stack-reset S=grafana` 不该丢 TSDB；`make stack-reset S=redis-sentinel` **只**清 `data/sentinel/`，不碰 `data/cluster/`；改告警路由不该中断采集。

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

### 3.2 块号 = 域号（13 块规划中只启用 4 块）

| 块 | 域 | 状态 | 块 | 域 | 状态 |
|---|---|---|---|---|---|
| `172.28.0.0/24` | **edge**（入口/工具，原 core） | ✅ 启用 | `172.28.6.0/24` | kafka | ⏸ 已释放 |
| `172.28.1.0/24` | pg | ⏸ 已释放 | `172.28.7.0/24` | rocketmq | ⏸ 已释放 |
| **`172.28.2.0/24`** | **redis-sentinel** | ✅ 启用 | `172.28.8.0/24` | rabbitmq | ⏸ 已释放 |
| **`172.28.3.0/24`** | **redis-cluster** | ✅ 启用 | `172.28.9.0/24` | etcd | ⏸ 已释放 |
| `172.28.4.0/24` | mysql | ⏸ 已释放 | `172.28.10.0/24` | consul | ⏸ 已释放 |
| `172.28.5.0/24` | mongo | ⏸ 已释放 | `172.28.11.0/24` | nats | ⏸ 已释放 |
| **`172.28.12.0/24`** | **observability**（四栈共享） | ✅ 启用 | `172.28.20–29.0/24` | 预留 | — |
| `172.28.99.0/24` | 一次性/工具容器 | — | | | |

> 「已释放」= **编号保留、地址不分配**（§17 追加时按原块号回填，避免全表重编号）。
> `doctor.sh` 只校验"已启用块内"的 IP 唯一性与一致性。

### 3.3 块内尾号约定（统一）

| 尾号 | 角色 |
|---|---|
| `.1` / `.2` | 网关（Docker 自占）/ 仅备用 VIP（可选组件） |
| **`.11–.19`** | 核心成员：master / rc-1..3 / 入口 nginx |
| **`.21–.29`** | 副本或次要成员：replica / sentinel / rc-1r..3r / 面板类前端 |
| `.31–.39` | 栈内代理与工具：adminer-like、grafana |
| `.41–.49` | exporter / 观测 |
| `.51–.59` | 临时客户端（redis-cli、redis-benchmark） |

> 唯一「多组件共享一个域」的例外：`172.28.12.0/24`（observability）。
> `prometheus` 占 `.11–.12`、`alertmanager` 占 `.21`、`grafana` 占 `.31`、`jaeger` 占 `.32`，语义与上表一致。IP 全 ini 唯一。

---

## 4. 目录结构

```text
devops/
├── compose.yml                     # 唯一入口（生成物，见 §10）
├── compose.generated.yml
├── stock/
│   └── network.ini                 # ★ IP/端口/路由唯一权威（7 目录 / 8 部署单元）
├── base/
│   ├── network.yml                 # devnet ipam
│   └── anchors.yml                 # x-common：logging/restart/TZ/healthcheck 默认
├── services/
│   ├── nginx/                      # 部署单元 nginx：nginx-1 (.0.11, both) + nginx-2 (.0.12, ha)
│   │   ├── compose.yml
│   │   ├── config/nginx.conf       # 主配置（log_format / gzip / connection_upgrade map）
│   │   ├── scripts/{render,status,reset}.sh      # 无 bootstrap（无状态）
│   │   └── data/conf.d/            # 生成物：每个 [routes] 行 → <host>.conf
│   ├── mailpit/                    # 部署单元 mailpit：mailpit (.0.32, both)
│   │   ├── compose.yml
│   │   ├── config/mailpit.env      # MP_MAX_MESSAGES / MP_SMTP_AUTH_ACCEPT_ANY
│   │   └── data/                   # 默认不落盘（重启即清空，§7）
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
│   │   └── data/
│   │       ├── sentinel/<node>/    # redis-master / replica-1/2 / sentinel-1/2/3 / solo
│   │       └── cluster/<node>/     # rc-1/2/3 / rc-1r/2r/3r / solo
│   ├── prometheus/                 # 部署单元 prometheus：prometheus-1 (.12.11, both) + prometheus-2 (.12.12, ha)
│   │   ├── compose.yml
│   │   ├── config/
│   │   │   ├── prometheus.yml.tpl  # scrape_configs 由 ini 的 exporter 行生成
│   │   │   └── rules/redis.rules.yml
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── data/prometheus-{1,2}/  # TSDB + 渲染后的 prometheus.yml
│   ├── alertmanager/               # 部署单元 alertmanager：alertmanager (.12.21, both)
│   │   ├── compose.yml
│   │   ├── config/alertmanager.yml.tpl     # route / receivers（mailpit 地址由 render 注入）
│   │   ├── scripts/{render,bootstrap,status,reset}.sh
│   │   └── data/alertmanager/      # silences / notify 日志 / 渲染后配置
│   ├── grafana/                    # 部署单元 grafana：grafana (.12.31, both)
│   │   ├── compose.yml
│   │   ├── config/provisioning/
│   │   │   ├── datasources/{prometheus.yml,jaeger.yml}
│   │   │   └── dashboards/{provider.yml,redis-sentinel.json,redis-cluster.json,obs-self.json}
│   │   ├── scripts/{render,status,reset}.sh
│   │   └── data/grafana/           # grafana.db（SQLite）
│   └── jaeger/                     # 部署单元 jaeger：jaeger (.12.32, both)
│       ├── compose.yml
│       ├── config/config.yaml      # OTel Collector 格式（OTLP receiver + jaeger_storage）
│       ├── config/sampling.json    # 采样策略
│       ├── scripts/{render,bootstrap,status,reset}.sh
│       └── data/jaeger/badger/     # trace 存储（TTL 72h）
├── scripts/
│   ├── doctor.sh                   # 14 项体检（§6.3）
│   ├── render-all.sh               # ini → compose.generated.yml + 各栈配置渲染
│   ├── backup-all.sh               # find services -name data → 归档
│   ├── trace-demo.sh               # 推一条 OTLP trace（§16.5）
│   └── prepull.sh                  # 按 ini 预拉镜像（D01）
├── env/{.env.example, .env}
├── docs/{plan.md, stacks.md, adr.md, archive/}
├── Makefile
├── .gitignore
└── README.md
```

```gitignore
**/data/
!**/data/.gitkeep
env/.env
```

> `base/jvm/` 已随 JVM 类组件（Kafka/RocketMQ）一并移除；
> `redis-base.conf` 已从 `base/redis/` **下沉到 `services/redis/config/base/`** —— 它只被一个组件目录使用，不再属于"跨栈共享"。
>
> **`config/` 只放模板，`render.sh` 的产物一律落 `data/`**（DEC-11）：所以 nginx 的路由 `conf.d/`、prometheus 的 `prometheus.yml`、
> sentinel 的 `sentinel.conf` 都在 `data/` 下——它们要么运行时重写，要么含渲染出的 IP，不能入库。
> 每个目录的 `scripts/` 按需裁剪：无状态的栈没有 `bootstrap`（nginx / grafana），纯工具栈没有 `scripts`（mailpit）。
>
> **已释放域（不在上面的目录树里）**：`.1.x` pg、`.4.x` mysql、`.5.x` mongo、`.6.x` kafka、`.7.x` rocketmq、
> `.8.x` rabbitmq、`.9.x` etcd、`.10.x` consul、`.11.x` nats，以及 `.0.x` 的 minio。
> 它们按 DEC-26 于 v3.0 移出，**块号与 `[stack.*]` 命名仍保留**；重新纳入的步骤见 §17，
> 归档设计（含身份文件、bootstrap 探测、面板清单）见 `docs/archive/plan-v2.3-13stacks.md`。

---

## 5. 服务花名册（4 域 / 7 目录 / 8 部署单元）

> 内存为"限堆/限缓存后"稳态估算，非默认值（Redis 默认 `maxmemory` 无上限，见 §9.2）。

| 部署单元（profile） | 域 | 容器（solo → ha） | 形态 | 内存 solo / ha |
|---|---|---|---|---|
| nginx | `.0.x` | `nginx-1` → `+nginx-2` | 入口（**唯一**发布宿主端口的栈） | 0.02 / 0.05 GB |
| mailpit | `.0.x` | `mailpit`（两形态相同） | 告警收件箱（SMTP 1025 + Web 8025） | 0.03 / 0.03 GB |
| **redis-sentinel** | `.2.x` | `redis-master` → `+2R + 3 sentinel`；`redis-exporter` | 哨兵自动切换 | 0.10 / 0.34 GB |
| **redis-cluster** | `.3.x` | `rc-1` → `+rc-2/3 + rc-1r/2r/3r`；`redis-exporter` | 分片 + 副本（16384 slots） | 0.10 / 0.48 GB |
| prometheus | `.12.x` | `prometheus-1` → `+prometheus-2` | 冗余采集（非故障转移，§16.3） | 0.30 / 0.85 GB |
| alertmanager | `.12.x` | `alertmanager` | 告警路由 | 0.05 / 0.05 GB |
| grafana | `.12.x` | `grafana` | 面板（provisioning） | 0.25 / 0.25 GB |
| **jaeger** | `.12.x` | `jaeger`（两形态相同） | 链路追踪（OTLP + Badger + UI） | 0.15 / 0.15 GB |
| **合计** | **4 域** | **10 → 22 个容器** | | **1.00 / 2.20 GB** |

> `redis-sentinel` 与 `redis-cluster` **同属 `services/redis/`**（复合栈，§2.1），两个 profile 互斥；
> 其余每行 = 一个目录。表里的"域"仍分属 `.2.x` / `.3.x` 两块（IP 规划独立于目录结构）。

### 5.1 `stock/network.ini`（唯一权威）

行格式：`name | ip | ports | role | mode`，竖线分隔便于 `awk -F'|'` 零依赖解析。

**`mode` 列默认值为 `ha`**（省略即 ha），取值：

| mode | 含义 |
|---|---|
| `ha` | 仅属于集群/主从拓扑（默认） |
| `both` | solo 与 ha 共用同一节点身份（solo 时的单实例就是它） |
| `solo` | 仅属于 solo 拓扑（当前无此类行；保留语义） |

**solo 复用该栈 `.11` 节点的 IP**（两形态互斥、不同时运行），但**配置模板与数据目录独立**（`config/solo/`、`data/solo/`），互不污染。

```ini
[global]
subnet  | 172.28.0.0/16 | |
gateway | 172.28.0.1    | |

[stack.nginx]
nginx-1          | 172.28.0.11 | 80,443   | entry | both
nginx-2          | 172.28.0.12 | 80,443   | entry

[stack.mailpit]
mailpit          | 172.28.0.32 | 1025,8025| tool  | both

# 下面两个 [stack.*] 同属 services/redis/（复合栈，§2.1）：profile 互斥，不同时运行
[stack.redis-sentinel]
redis-master     | 172.28.2.11 | 6379  | master   | both
redis-replica-1  | 172.28.2.12 | 6379  | replica
redis-replica-2  | 172.28.2.13 | 6379  | replica
sentinel-1       | 172.28.2.21 | 26379 | sentinel
sentinel-2       | 172.28.2.22 | 26379 | sentinel
sentinel-3       | 172.28.2.23 | 26379 | sentinel
redis-exporter   | 172.28.2.41 | 9121  | exporter | both

[stack.redis-cluster]
rc-1             | 172.28.3.11 | 6379,16379 | master  | both
rc-2             | 172.28.3.12 | 6379,16379 | master
rc-3             | 172.28.3.13 | 6379,16379 | master
rc-1r            | 172.28.3.21 | 6379,16379 | replica
rc-2r            | 172.28.3.22 | 6379,16379 | replica
rc-3r            | 172.28.3.23 | 6379,16379 | replica
redis-exporter   | 172.28.3.41 | 9121       | exporter | both

# observability 域（§16）：四栈共享 172.28.12.0/24，各自有目录/profile/data
[stack.prometheus]
prometheus-1     | 172.28.12.11 | 9090 | both
prometheus-2     | 172.28.12.12 | 9090 | ha

[stack.alertmanager]
alertmanager     | 172.28.12.21 | 9093 | both

[stack.grafana]
grafana          | 172.28.12.31 | 3000 | both

[stack.jaeger]
jaeger           | 172.28.12.32 | 16686,4317,4318,8888,13133 | both

# 宿主访问入口（§15）：host | upstream_ip | port | base-path 能力
[routes]
grafana.localhost      | 172.28.12.31 | 3000 | subdomain-only
prometheus.localhost   | 172.28.12.11 | 9090 | path-ok
alertmanager.localhost | 172.28.12.21 | 9093 | path-ok
jaeger.localhost       | 172.28.12.32 | 16686 | subdomain-only
mailpit.localhost      | 172.28.0.32  | 8025 | path-ok
```

### 5.2 集群形态选型表（需求⑤）

| 组件 | 最小 HA 拓扑 | 选型理由 | 关键机制 / 身份文件 |
|---|---|---|---|
| **redis-sentinel** | 1M + 2R + **3 哨兵**（奇数法定人数） | 哨兵要过半数投票才能切主，3 个是最小可用；1M+2R 保证切换后有可提升副本 | `sentinel monitor` 固定 master IP、`requirepass` = `masterauth`、哨兵配置运行时重写（落 `data/`） |
| **redis-cluster** | **3M + 3R**（16384 slots 均分） | 每主至少 1 从才叫"有冗余"；3 主才能在一主宕机时仍满足 quorum | `cluster-enabled yes`、总线端口 = 端口 +10000、`nodes.conf` 持久化 |
| **nginx** | ×2（`.11/.12`），各自独立 IP | 单机无共享存储，VIP 只是伪需求；客户端用双地址 + 健康探测即可 | `server_name` 按 `[routes]` 生成；`keepalived` 仅作可选 profile（默认关） |
| **prometheus** | 单实例（solo）/ ×2 冗余采集（ha） | 拉模式无共识，HA 语义 = 冗余采集；独立成栈因 TSDB 生命周期最长 | `data/prometheus-N/`（TSDB）、`config/prometheus.yml`（由 ini 生成） |
| **alertmanager** | 单实例 | 告警路由无状态（silence 落盘）；真 HA（gossip ×3）列入 N 级 | `config/alertmanager.yml`、`data/alertmanager/` |
| **grafana** | 单实例 | 无状态，dashboard/数据源全部 provisioning（入库） | `config/provisioning/**`、`data/grafana/` |
| **jaeger** | 单实例（solo / ha 相同，**豁免**，见 §5.3） | 本地 Badger 是**单写者**存储，两实例无法共享同一目录；真 HA 需分布式存储（ES/Cassandra）→ 列入 N09 | `config/config.yaml`（OTel Collector 格式）、`data/jaeger/badger/` |

### 5.3 豁免清单（不为 HA 而 HA）

| 组件 | 豁免理由 |
|---|---|
| mailpit | 单次会话工具，状态无价值，重启即重置 |
| redis_exporter | 无状态只读，重启无影响 |
| nginx VIP（keepalived） | **默认不启用**：单机故障域相同，VRRP 无法验证真实切换，只增加调试噪音 |
| prometheus / alertmanager / grafana | **部分豁免**：Prom 双实例是冗余采集（无状态同步），Grafana 无状态（provisioning 即恢复），AM 单实例；真 HA（Thanos/VictoriaMetrics、AM gossip ×3）列入 N 级（§16.3） |
| **jaeger** | **存储侧豁免**：Badger 为本地单写者，双实例写同一目录会锁冲突；采集侧无状态可多实例，但**存储不共享的双实例只会得到两份互不可见的 trace**。真 HA（ES/Cassandra 后端 + collector×2）列入 N09 |

### 5.4 单机"集群"的诚实边界

21 个容器共享**同一内核、同一磁盘、同一时钟**，因此本环境可验证：

- ✅ 拓扑配置是否正确（哨兵监听对象、sentinel 法定人数、slot 分布与副本对应）
- ✅ 协议行为是否正确（`REPLICAOF` 复制、`FAILOVER`/哨兵切主、`MOVED`/`ASK` 重定向、迁移 slot）
- ✅ 故障转移**脚本与流程**是否可执行（`make failover-drill`）

不可验证：

- ❌ 网络分区（脑裂）、跨机时钟漂移、真实磁盘/主机故障
- ❌ 跨机网络延迟对哨兵判定（`down-after-milliseconds`）的影响

→ 本环境定位是"配置与流程的正确性台架"，生产前仍需多机验证。

> 缩容后的**新边界**（重要）：只剩 Redis，**无法验证跨组件交互**（如"缓存与 DB 的一致性/失效策略"）。
> 需要此类验证时按 §17 追加一个域，而不是在本环境里模拟。

### 5.5 双形态：solo 与 ha

同一栈用 profile 切换，**IP 身份不变、数据目录隔离**：

| 部署单元（profile） | solo 拓扑 | solo 内存 | ha 内存 | 适用场景 |
|---|---|---|---|---|
| nginx | nginx 1 | 0.02 GB | 0.05 GB | solo：本地面板入口；ha：验证双入口 |
| mailpit | 1 实例 | 0.03 GB | 0.03 GB | 两形态相同；收件箱 UI |
| redis-sentinel | redis 1（无哨兵） | 0.10 GB | 0.34 GB | solo：写业务代码；ha：验证哨兵切主 |
| redis-cluster | redis 1（`cluster-enabled no`） | 0.10 GB | 0.48 GB | solo：验证 key 设计；ha：验证 slot 与重定向 |
| prometheus | 1 实例 | 0.30 GB | 0.85 GB | solo：单机看指标；ha：双实例冗余采集 |
| alertmanager | 1 实例 | 0.05 GB | 0.05 GB | 两形态相同 |
| grafana | 1 实例 | 0.25 GB | 0.25 GB | 两形态相同 |
| jaeger | 1 实例（Badger） | 0.15 GB | 0.15 GB | 两形态相同；trace 接收端 + 查询 UI |

#### 5.5.1 命令

```bash
make stack-up S=redis-sentinel MODE=solo   # 起单实例（v1 形态）
make stack-up S=redis-sentinel MODE=ha     # 起 1M+2R+3S + exporter
make stack-switch S=redis-cluster MODE=ha  # 先停当前形态再起目标形态（数据目录不互通，会提示）
```

> `S` 取的是**部署单元名（= profile 名）**，不是目录名：`services/redis/` 下有两个部署单元
> `redis-sentinel` / `redis-cluster`；`S=redis` 会报错并列出合法值。

#### 5.5.2 纪律

1. `MODE=solo` 只启动 `mode IN (solo,both)` 的节点；`MODE=ha` 只启动 `mode IN (ha,both)`。
2. 两形态**数据目录物理隔离**（`data/<group>/solo/` vs `data/<group>/<node>/`；普通栈为 `data/solo/` vs `data/<node>/`），禁止直接互相搬运（集群元数据不兼容）。
3. `render.sh` 同时生成两套配置，`doctor.sh` 第 13 项校验 profile 与 ini `mode` 一致。
4. solo 是**取巧的简化**（停掉 `cluster-enabled`、不起哨兵），**solo 的结论不是集群的结论**——`docs/stacks.md` 每栈标注语义差异。

---

## 6. 三大铁律与校验

### 6.1 铁律一：不变量不下沉

`subnet` / `gateway` / `logging` / `restart` / `TZ` 只允许出现在 `base/`。组件内出现即 review 打回。

### 6.2 铁律二：端口按"同一 IP 内不重复"校验

单网络 + 静态 IP 下，各栈同端口（6379）**不冲突**——不同 IP。真正的冲突对象是"一个容器 IP 的端口集"。
宿主端口冲突在"仅 `[stack.nginx]` 发布"策略下自然消失。

多端口栈需特别标注：

| 栈 | 除主端口外的隐式端口 |
|---|---|
| redis-cluster | `16379`（总线 = 端口 + 10000） |
| redis-sentinel | `26379`（哨兵自身） |
| observability | `9090` / `9093` / `3000` / `9121` |
| jaeger | `4317`（OTLP gRPC）/ `4318`（OTLP HTTP）/ `8888`（自身指标）/ `13133`（health）/ `16686`（UI+query） |

### 6.3 铁律三：`doctor.sh` 十四项体检

| # | 检查 | 失败处理 |
|---|---|---|
| 1 | ini 内 IP 均在 `/16` 内，非 `.0`/`.1`/`.255` | 报错并列出 |
| 2 | ini 内 IP 无重复 | 报错并给出重复项 |
| 3 | 同一 IP 的端口集无重复 | 报错 |
| 4 | 各组件 `compose.yml` 的 `ipv4_address` ⊆ ini 且一致（防手写漂移） | 报错并提示重跑 `render-all` |
| 5 | 每个 service 均声明 `profiles`（无可 profiling 的服务 → 任何 `up` 都会起它，破坏复合栈互斥） | 失败（R24） |
| 6 | 宿主端口仅出现在 `[stack.nginx]` | 失败 |
| 7 | `docker context` 必须是 `orbstack`（方案前提） | 失败并解释原因 |
| 8 | `172.28.0.0/16` 与宿主路由无重叠 | 失败 |
| 9 | `env/.env` 存在且权限 `600` | 提示 |
| 10 | 各栈 `data/<node>` 存在且属主正确（redis = 999） | 提示修复命令 |
| 11 | **HA 拓扑完整性**：哨兵 3 且在监；cluster 3M3R 覆盖 16384 slots；豁免栈（grafana/jaeger/alertmanager）不得声明多余副本 | 失败 |
| 12 | **演练保护**：`restart: unless-stopped` 存在时，演练必须走 `stop` 而非 `kill` | 提示 |
| 13 | **双形态一致性**：`compose.yml` 的 profile 与 ini `mode` 一致；`data/solo` 与 `data/<node>` 不混用 | 失败 |
| 14 | **路由与引用校验**：`[routes]` host 唯一、upstream IP 属于已启用块；观测四栈的跨栈引用（Grafana→Prometheus、Grafana→Jaeger、Prom→AM）指向的 IP 必须存在且 mode 已启用 | 失败 |

---

## 7. 身份固化清单（真实痛点）

| 栈 | 必须写死 | 必须持久化的状态文件 | 搞错的症状 |
|---|---|---|---|
| nginx | 两实例 `server_name` / 监听端口错开；`[routes]` 生成的 upstream | 无状态 | 后端全挂时无法判断入口是否存活 |
| mailpit | 无持久身份（纯工具）；`MP_MAX_MESSAGES` 控制保留条数 | 无（重启即清空） | 误当"已归档邮件"——它只是告警调试收件箱 |
| **redis-sentinel** | `sentinel monitor <name> 172.28.2.11 6379 2`；`requirepass` 与 `masterauth` **必须一致**；`sentinel down-after-milliseconds` | `data/sentinel/sentinel-N/sentinel.conf`（**运行时重写**）、`data/sentinel/redis-master/appendonlydir` | 切主后新主拒绝写入；哨兵重启忘记监听对象 |
| **redis-cluster** | `cluster-enabled yes`；总线端口 = 端口 +10000；`cluster-announce-ip` = 容器 IP | `data/cluster/<node>/nodes.conf`、AOF/RDB | 重启后忘记集群身份，需整栈重建 |
| prometheus | `--web.external-url=http://prometheus.localhost`、`--storage.tsdb.retention.time`、`scrape_configs` 由 ini 生成 | `data/prometheus-N/`（TSDB chunk/WAL） | 手改 `prometheus.yml` 导致目标漂移；换保留期却不重建 TSDB |
| alertmanager | `--web.external-url`、`route`/`receivers`（`render.sh` 注入 IP） | `data/alertmanager/`（`silences`、`notify`） | 静默丢失；告警重复或静默失效 |
| grafana | `root_url=http://grafana.localhost/`、`GF_PATHS_PROVISIONING`、数据源指向 `172.28.12.11:9090`（Prom）与 `172.28.12.32:16686`（Jaeger） | `data/grafana/`（SQLite） | 面板丢配置（未走 provisioning）；数据源指向旧 Prom / 旧 Jaeger |
| **jaeger** | `config.yaml` 的 `jaeger_storage.badger.directory`（= `data/jaeger/badger`）、OTLP receiver 监听 `0.0.0.0:4317/4318`、`jaeger_query.base_path`、采样策略文件 | `data/jaeger/badger/`（trace 存储）、`config/sampling.json` | 改了 `data/` 路径→历史 trace "消失"；采样策略写错→全部丢弃（UI 有服务无链路） |

**这些文件全部落在 `services/<stack>/data/` 下（复合栈再加一层 profile：`services/redis/data/<group>/<node>/`）→ `backup-all.sh` 一并归档 → 恢复即恢复身份。**

---

## 8. 组件契约（7 目录 / 8 部署单元）

### 8.0 普通目录（6 个：nginx / mailpit / prometheus / alertmanager / grafana / jaeger）

> 逐目录的实际文件清单见 §4；本节只约定"契约形状"。`scripts/` 按需裁剪（无 `bootstrap` 或整组省略），
> 目录里出现什么由职责决定，不是套模板。

```text
services/<stack>/
├── compose.yml        # 每个 service 都带 profiles: ["<profile>"]
├── config/            # 模板（入库），以 :ro 挂载
├── scripts/
│   ├── render.sh      # stock/network.ini → data/ 下真实配置
│   ├── bootstrap.sh   # 幂等：先探测状态，已完成则 exit 0
│   ├── status.sh      # 成员/quorum/复制状态
│   └── reset.sh       # 停容器 → 删本 profile 的 data/ 子树 → 重新 bootstrap
└── data/<node>/       # 运行时（忽略入库）
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
└── data/
    ├── sentinel/<node>/           # solo：data/sentinel/solo/
    └── cluster/<node>/            # solo：data/cluster/solo/
```

四条硬约束（不满足就不该继续用复合形式，应拆回两个目录）：

1. `compose.yml` 里**每个 service 必须同时带两个标签**：`profiles: ["redis-sentinel"]` 或 `["redis-cluster"]`，禁止无 profile 的服务（否则 `down` 会误删另一组）。
2. `reset.sh` **只能删本组子树**（`data/sentinel/` 或 `data/cluster/`）。
3. `render.sh` 两组各自独立，但共用 `config/base/redis-base.conf` 的 include（单一事实源）。
4. `doctor.sh` 按 ini 的 `[stack.*]` 段（而不是目录）校验 profile 与 `mode`，因此第 4/5/13 项不需特殊处理。

### 8.1 统一命令

```bash
make stack-up S=redis-cluster      # render → compose --profile redis-cluster up -d → 等 healthy → bootstrap
make stack-status S=redis-cluster
make stack-reset S=redis-cluster   # 只清 services/redis/data/cluster/

# 观测域是 4 个部署单元（§16.1），因此多一层"组"语法：组 = 多个部署单元的有序集合（定义在 Makefile，不入 ini）
make group-up     G=observability MODE=solo   # 依次 stack-up prometheus → alertmanager → jaeger → grafana
make group-status G=observability
make obs / make obs-ha                        # = group-up G=observability MODE=solo|ha 的简写
```

> 组只用于**日常一键起齐**；永久态仍以"部署单元（profile）"为单位 —— 单栈单独起停/重置/切形态始终合法。
> `S` 一律填 profile 名：`nginx` / `mailpit` / `redis-sentinel` / `redis-cluster` / `prometheus` / `alertmanager` / `grafana` / `jaeger`（没有 `S=core`、没有 `S=redis`）。

### 8.2 幂等探测（bootstrap 的判定条件）

| 栈 | 探测命令 | 通过条件 |
|---|---|---|
| redis-sentinel | `redis-cli -p 26379 sentinel get-master-addr-by-name devmaster` | 返回 `172.28.2.11 6379` |
| redis-cluster | `redis-cli -c cluster info` / `cluster nodes` | `cluster_state:ok`，3M3R，16384 slots 全覆盖 |
| prometheus | `curl -sf localhost:9090/-/ready` | `Prometheus Server is Ready.` |
| alertmanager | `curl -sf localhost:9093/-/ready` | 200 |
| grafana | `curl -sf localhost:3000/api/health` | `{"database":"ok"}` |
| jaeger | `curl -sf localhost:8888/metrics` / `curl -sf localhost:16686/api/services` | 200，且 `/api/services` 返回数组（空也可） |
| nginx | `curl -sf -H 'Host: grafana.localhost' 127.0.0.1/` | 200（路由打通） |
| mailpit | `curl -sf localhost:8025/livez` | 200 |

### 8.3 演练保护（重要）

`restart: unless-stopped` 会让"被杀"的容器自动复活，**直接破坏故障转移演练的观察窗口**。约定：

```bash
# 演练：用 stop（不触发 restart 策略）
docker compose stop sentinel-1        # 停 1 哨兵 → 剩余 2 个仍可投票
docker compose stop redis-master      # 观察哨兵提升新主
docker compose start redis-master     # 观察旧主以 replica 身份回归

# 禁止在演练中用：docker kill / docker rm
make failover-drill S=redis-sentinel  # Makefile 内部已强制走 stop
make failover-drill S=redis-cluster   # 停 1 主，观察其副本提升 + slot 归属变化
```

---

## 9. 资源纪律

### 9.1 档位（缩容后只剩两档，且都可常驻）

| 档 | 组合 | 估算 |
|---|---|---|
| **S 日常 solo** | 8 个部署单元全部 solo（nginx 1 + mailpit 1 + redis 单实例 ×2 + obs 四栈） | ≈ 1.00 GB |
| **HA 全量** | 8 个部署单元全部 ha（22 容器） | ≈ 2.20 GB |
| 单栈 | `make stack-up S=<stack> MODE=solo\|ha` | 见 §5 表 |

> 可见内存 15.7 GB，ha 全量占比 ≈ 13% → **不再需要"五档纪律"**。
> 保留的纪律只有一条：**排障时不要顺手起旧方案**（v2.3 全量 14.35 GB），归档文档只做参考。

### 9.2 硬性限流（不做就会炸）

| 组件 | 必设 |
|---|---|
| redis（所有实例） | `maxmemory 256mb` + `maxmemory-policy noeviction`；`appendonly yes` + `appendfsync everysec`；`slowlog-log-slower-than 10000` |
| prometheus | `--storage.tsdb.retention.time=15d --storage.tsdb.retention.size=2GB`（否则 TSDB 无限长，`data/` 先炸盘） |
| grafana | `GF_ANALYTICS_CHECK_FOR_UPDATES=false`、`GF_USERS_ALLOW_SIGN_UP=false` |
| jaeger | `jaeger_storage.backends.badger.ttl: 72h`（trace 默认保留 3 天）；`memory.max_traces` 不启用（走磁盘）；`badger.ephemeral: false` |
| 全栈 | `logging: json-file max-size=10m max-file=3` |

---

## 10. 聚合与入口

```yaml
# compose.yml（生成物）—— 显式列举，因 include 不支持 glob
include:
  - base/network.yml
  - services/nginx/compose.yml
  - services/mailpit/compose.yml
  - services/redis/compose.yml          # 一个文件装两个 profile（复合栈）
  - services/prometheus/compose.yml
  - services/alertmanager/compose.yml
  - services/grafana/compose.yml
  - services/jaeger/compose.yml
```

- `render-all.sh` 扫描 `services/*/compose.yml` 生成该文件（**缩容新增栈自动纳入**；复合栈只产生 1 行 include）。
- **唯一入口**：`make` 或 `docker compose -f compose.yml`。组件文件脱离入口会报 `undefined network devnet`（已实测），属预期行为。
- 组件目录内禁止 `../` 跨栈引用；共享片段放 `base/`，仅同一目录内的复用放该目录 `config/base/`（如 `services/redis/config/base/redis-base.conf`）。

---

## 11. 决策记录（ADR 摘要）

### 11.1 沿用（v2.3 及以前）

| # | 决策 | 理由 |
|---|---|---|
| DEC-1 | 单网络 `172.28.0.0/16`，不拆多网络 | 同端口不同 IP 天然隔离；/24 容量不足 |
| DEC-2 | 按组件分目录（非技术分层）；**同一产品的互斥拓扑可合为复合栈**（目前仅 `services/redis/`，见 DEC-31） | 改一个栈只动一个目录；删栈无孤儿数据；而哨兵/集群共享 80% 配置与同一镜像，拆两目录会重复一半文件 |
| DEC-3 | 除 nginx 外不发布宿主端口（v3.2 起 core 已拆） | 宿主可直连容器 IP（实测），消除 NAT 破坏地址公告的风险 |
| DEC-4 | `stock/network.ini` 单一事实源 + 生成 compose | IP 手写必漂移；doctor 可双向校验 |
| DEC-5 | ini 用竖线分隔 | `awk -F'\|'` 零依赖解析 |
| DEC-6 | profiles 强隔离 | 单栈可独立起停（v3.0 下内存已不是主因，隔离便于演练） |
| DEC-10 | 数据放组件内 `data/`，不集中根目录 | 生命周期与组件一致；`**/data/` 一条 gitignore 覆盖 |
| DEC-11 | Sentinel conf 与 cluster `nodes.conf` 放 `data/`（复合栈内再分 `data/sentinel/` / `data/cluster/`），config 只存模板 | 两者运行时会重写，只读挂载必然启动失败 |
| DEC-12 | **不默认使用 keepalived/VIP**，nginx 双实例 + 客户端双地址 | 单机 VRRP 无法验证真实切换，只增加调试噪音 |
| DEC-17 | 演练一律用 `docker compose stop` | `restart: unless-stopped` 会复活被杀容器，破坏演练观察 |
| DEC-18 | 每栈双形态（solo / ha），profile 切换 | solo 日常快迭代；ha 仅作验证台架 |
| DEC-19 | solo 复用 `.11` IP，但配置与数据目录物理隔离 | 身份一致便于客户端不变；`data/solo/` 防止集群元数据被污染 |
| DEC-20 | 新增 observability 域（`172.28.12.0/24`，域内按组件拆栈；v3.1 起为 4 个） | 每栈都有 exporter 却无归集后端 = 指标白采 |
| DEC-21 | UI 统一经 `<svc>.localhost` 子域，不做子路径 | MinIO/Consul 时代已证子路径失效；子域零配置、macOS 原生解析 |
| DEC-22 | 路由表进 ini 的 `[routes]` 段，nginx 配置由此生成 | 与 IP 同源，避免"IP 改了忘改 nginx" |
| DEC-23 | Prometheus 抓取目标由 ini 的 `exporter` 角色自动生成 | 新增栈自动纳入监控，无需手改 `prometheus.yml` |
| DEC-24 | **可观测性按组件拆栈**（prometheus / alertmanager / grafana） | 配置格式、状态生命周期、重置影响面不同；重置面板不该丢 TSDB（§2.1） |
| DEC-25 | 观测四栈的跨栈引用全部由 `render.sh` 从 ini 注入 | 拆栈后主要新风险是"引用漂移"；`doctor.sh` 第 14 项兜底 |

### 11.2 v3.x 新增

| # | 决策 | 理由 |
|---|---|---|
| DEC-26 | **只保留 Redis**：移除 PG/MySQL/Mongo/Kafka/RocketMQ/RabbitMQ/etcd/Consul/NATS/MinIO 共 10 域 | 维护 13 域 × 双形态的实际使用率极低；每域的 bootstrap/身份文件/体检项都是长期负债。保留"两套 Redis 语义（哨兵 vs 集群）"已覆盖缓存侧的拓扑验证需求 |
| DEC-27 | 保留**最小入口**（nginx×2 + mailpit，v3.2 起各一目录）与**观测栈** | 没有 nginx 则 `<svc>.localhost` 与 F06（不发布宿主端口）冲突；没有观测则 `redis_exporter` 白采（与 DEC-20 同一理由） |
| DEC-28 | 缩容**不移除块号**，保留 `[stack.*]` 命名与尾号约定 | §17 追加域时按原块号回填，避免全表重编号与历史文档错位 |
| **DEC-29** | **新增 `services/jaeger/`**（观测域第 4 栈，`.12.32`，单实例，Badger 存储） | 三支柱只缺 traces：指标能告警但给不出"哪一次调用慢"。选 Badger 而非 ES/Cassandra 是为**不再追加存储域**（v3.0 刚缩容完） |
| **DEC-30** | Jaeger **不伪装成双实例 HA**（solo/ha 同形） | Badger 单写者，双实例共享目录会锁冲突；两份独立存储的双实例只会得到互不可见的 trace（假 HA，比明确单实例更危险）→ 列入 §5.3 豁免 + N09 |
| **DEC-31** | **`redis-sentinel` 与 `redis-cluster` 合并到 `services/redis/`（复合栈）** | 同一产品 + 同一镜像 + 两个 profile 互斥 + 共享 `redis-base.conf`/exporter/脚本骨架 → 拆两目录是重复；数据仍按 `data/sentinel/` 与 `data/cluster/` 物理隔离，`stack-reset S=<profile>` 作用域不交叉（§2.1 / §8.0.1） |
| **DEC-32** | `redis-base.conf` 从 `base/redis/` **下沉到 `services/redis/config/base/`** | 它只被一个目录使用，不再属于"跨栈共享"；`base/` 只留真正的全局不变量（DEC-1/4） |
| **DEC-33** | **拆掉 `services/core/`**：nginx → `services/nginx/`，mailpit → `services/mailpit/`；域 `.0.x` 更名 `edge` | nginx（入口，要渲染 conf.d）与 mailpit（工具，纯 env）是不同产品、可同时运行、重置影响面不同 —— 按 §2.1 判据本该拆。合并时"入口"与"告警收件箱"被绑在同一个 `stack-reset` 作用域里，是最后一个反例 |

### 11.3 已撤销（域移出，设计归档）

| # | 原决策 | 现状 |
|---|---|---|
| DEC-8 | MySQL 基线用 MGR + Router | 域移出（`docs/archive/plan-v2.3-13stacks.md` §5） |
| DEC-9 | RabbitMQ quorum / 3 节点 | 域移出 |
| DEC-13 | core 不再放单机数据库 | 已无意义（无数据库域） |
| DEC-14 | RocketMQ 用 DLedger | 域移出 |
| DEC-15 | MinIO 4 节点 EC:2 | 域移出（core 不再含对象存储） |
| DEC-16 | 各栈自带 DCS | 域移出（Redis 两栈不需要 DCS） |

---

## 12. 风险登记册

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | "宿主免端口映射"依赖 OrbStack | 换 Colima/Docker Desktop → Sentinel 公告 IP、Cluster `nodes.conf` 地址失效 | `doctor.sh` 第 7 项卡死 context；README 顶部写前提 |
| R3 | 身份状态文件丢失（`nodes.conf` / `sentinel.conf`） | Redis 集群不可恢复（需重建 + 数据丢失） | 状态文件全在 `data/` → `backup-all.sh`；`stack-reset` 前强制备份 |
| R4 | macOS bind mount 权限 | Redis 启动失败（`Can't open the append-only file`） | `bootstrap.sh` 对齐 uid（redis = 999）；`appendonlydir` 用子目录 |
| R5 | 单机模拟 ≠ 真分布式 | 无法复现脑裂 / 跨机延迟 | §5.4 明确边界；多机验证另立方案（N02） |
| R7 | 重启顺序依赖 | cluster `meet` 顺序错 → 成员无法加入 | `render.sh` 固定顺序；`stack-up` 内置等待 healthy |
| R8 | `include` 无 glob | 新增栈漏登记 | `render-all.sh` 生成，不手写 |
| R11 | 容器命名/日志量 | 日志炸盘 | 统一命名 `<stack>-<node>`；日志限 10m×3 |
| R12 | `restart` 策略干扰演练 | 误判"切换成功" | `doctor.sh` 第 12 项 + §8.3 |
| R13 | 双形态配置漂移 | solo 行为被误当集群结论 | 两形态共用同一份模板渲染；`docs/stacks.md` 标注语义差异 |
| R14 | 两形态数据目录误用（含复合栈两组间误用） | 用 solo 数据启动 ha 节点 → `nodes.conf` 损坏 | `render.sh` 生成不同 `dir`/`cluster-config-file`；`stack-switch` 强制提示；路径固定为 `data/<group>/<node>/` |
| **R24** | **复合栈的作用域误伤**：`stack-reset`/`down` 没带 profile，可能连带清掉另一组的 `data/` | 误删哨兵栈数据 / 误停集群栈 | §8.0.1 四条硬约束：每个 service 必须带 profile；`reset.sh` 只能删本组子树；`doctor.sh` 第 5 项把"无 profile 的服务"直接告警 |
| R15 | `*.localhost` 只在宿主生效 | 容器内访问 `grafana.localhost` 失败 | 容器间一律用 IP/服务名；`.localhost` 仅用于宿主浏览器 |
| R17 | Grafana 单点 | 面板不可用（指标仍在） | 接受：无状态 + provisioning；`stack-reset S=grafana` 级恢复 |
| R18 | 拆栈后的跨栈引用漂移 | 面板无数据 / 告警不发 | DEC-25：引用由 `render.sh` 注入；`doctor.sh` 第 14 项校验 |
| R19 | 四栈 `render.sh` 执行顺序 | Grafana 先起时短暂 `No data` | 组内固定顺序 prometheus → alertmanager → jaeger → grafana |
| **R20** | **缩容导致覆盖不足**：只剩 Redis，无法验证跨组件交互（缓存↔DB 一致性、消息堆积等） | 结论外推有风险 | §5.4 明示；需要时按 §17 追加域，而不是在现有栈上"假装验证" |
| **R21** | Redis 单机内存上限（`maxmemory 256mb`）与集群 slot 数据倾斜 | 测试大数据量时 `OOM command not allowed` | `maxmemory-policy noeviction` 是刻意选择（暴露问题而非静默淘汰）；压测前按需调高并在 `docs/stacks.md` 记录 |
| **R22** | Jaeger 存储为单实例本地 Badger | 无法验证 collector 多副本/存储高可用；磁盘增长无上限 | TTL 强制 72h（§9.2）；`data/jaeger` 计入 `make size` 与备份；真 HA 列入 N09 |
| **R23** | trace 与指标的**关联依赖数据源配置**（Grafana → Jaeger） | 面板上看不到 trace 跳转，或 trace 里看不到 Pod/实例 | 数据源与 `traceToMetrics` 全部走 provisioning，由 `render.sh` 注入 IP（DEC-25）；`doctor.sh` 第 14 项校验 |

---

## 13. 实施路线

| 期 | 内容 | 验收 |
|---|---|---|
| **P0 地基** | `base/`、`stock/network.ini`、`services/nginx` + `services/mailpit`（solo + ha）、`doctor.sh`、`render-all.sh`、`Makefile`、`.gitignore`、`env/` | `make doctor` 14 项全绿；`MODE=solo` 起 2 容器（nginx-1 + mailpit）、`MODE=ha` 起 3 容器；`mailpit.localhost` 可达；`git status` 不含 `data/`、`.env` |
| **P1 redis-sentinel** | `services/redis/` 下第一组 profile（1M + 2R + 3S + exporter），把 bootstrap 契约打磨成型 | `sentinel get-master-addr-by-name` 正确；`make failover-drill S=redis-sentinel` → 10s 内切主，旧主回归为 replica |
| **P2 redis-cluster** | 同目录第二组 profile（3M + 3R + exporter），`cluster create` + 副本分配 | `cluster_state:ok`、3M3R、16384 slots；`make failover-drill S=redis-cluster` → 副本提升且 slot 归属更新；`MOVED` 重定向可用；`stack-reset S=redis-sentinel` **不影响** `data/cluster/` |
| **P3 观测 + 入口** | 观测四栈（prometheus / alertmanager / grafana / **jaeger**）+ nginx `[routes]` 生成 + 面板（清单 §16.4） | 四栈可独立起停（`stack-reset S=grafana` 后面板恢复且 TSDB 不丢）；两组 Redis profile 的 `/metrics` 全部 `up=1`；`grafana.localhost` 面板有数；`jaeger.localhost` 能搜到一条手工推送的 trace |

每期结束更新 `docs/stacks.md`（起停、验证命令、演练脚本、重置步骤、solo↔ha 语义差异、坑）。

---

## 14. 命令速查（目标契约）

```bash
make doctor                    # 14 项体检
make render                    # ini → compose.generated.yml + 各栈配置
make up                        # 起当前档位（默认 S 档 solo）
make up-ha                     # 起 ha 全量（22 容器）
make down                      # 停全部
make ps / make size            # 状态 / 磁盘占用（含各栈 data/）
make stack-up     S=redis-sentinel MODE=solo|ha   # S = 部署单元（profile）；redis 目录下有 sentinel/cluster 两个
make stack-switch S=redis-cluster MODE=ha
make stack-status S=redis-cluster
make stack-reset  S=redis-cluster     # 整栈重建，强制备份
make stack-shell  S=redis-cluster N=rc-1
make stack-host   S=redis-cluster N=rc-1   # 宿主侧用固定 IP 直连
make stack-up     S=grafana MODE=solo      # 观测四栈可分起（prometheus / alertmanager / jaeger / grafana）
make group-up     G=observability MODE=solo   # 一次起齐（= make obs）
make trace-demo                # 向 jaeger 推一条 OTLP trace（无业务应用也能验收）
make backup                    # 归档所有栈 data/ + 状态文件
make failover-drill S=redis-sentinel|redis-cluster
make ui-open S=grafana|jaeger|mailpit   # 打开 http://<svc>.localhost（按 [routes] 解析）
make routes                    # 打印全部 <svc>.localhost 入口
make obs / make obs-ha         # = group-up G=observability MODE=solo|ha
```

---

## 15. 统一入口与路由（需求⑥ / DEC-21 + DEC-22）

### 15.1 问题背景

铁律 F06 是"除 nginx 外不发布宿主端口"，而面板（Grafana / Prometheus / Alertmanager / Jaeger）都在 `.12.x` 域里。
不管的话这些 UI 从宿主一律打不开。缩容后仍保留该机制：**入口是唯一有宿主端口的栈**。

### 15.2 为什么用子域而不是子路径

| 组件 | 子路径（`/svc/`） | 子域（`svc.localhost`） | 说明 |
|---|---|---|---|
| Prometheus | ✅ `--web.external-url` | ✅ | |
| Alertmanager | ✅ `--web.external-url` | ✅ | |
| Grafana | ✅ `root_url` 含子路径 | ✅ | 子路径需同步 `serve_from_sub_path`，易错 |
| Jaeger | ⚠️ 支持 `--query.base-path` | ✅ | 子路径可用但需同步 `JAEGER_UI_BASE_PATH` |
| Mailpit | ✅ | ✅ | 收件箱在 `/`，子域最直接 |
| 未来的 Redis UI（N06） | ⚠️ 各产品不一 | ✅ | 子域一劳永逸 |

→ **统一走子域**：路由表在 `stock/network.ini` 的 `[routes]`（DEC-22），nginx 配置由此生成。

### 15.3 路由表

```ini
[routes]
grafana.localhost      | 172.28.12.31 | 3000 | subdomain-only
prometheus.localhost   | 172.28.12.11 | 9090 | path-ok
alertmanager.localhost | 172.28.12.21 | 9093 | path-ok
jaeger.localhost       | 172.28.12.32 | 16686 | subdomain-only
mailpit.localhost      | 172.28.0.32  | 8025 | path-ok
```

> 只有 `nginx-1` 把 `80` 发布到宿主（`ENTRY_HTTP_PORT` 可覆盖）；`nginx-2` 不发布，供"双地址"验证。
> 其余 UI 一律经 nginx，不直接发布端口（F06）。

### 15.4 nginx 生成规则

`render.sh` 为每个 `[routes]` 行生成一个 `server` 块（`services/nginx/data/conf.d/<host>.conf`，`config/` 只放模板），固定包含：

```nginx
server {
    listen 80;
    server_name <host>;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;      # 面板长连接必需
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
| 端口 | 仅 `80`（nginx）；`443` 保留给后续自签 TLS |

---

## 16. 可观测性域（需求⑥⑦⑧ / DEC-20 + DEC-24 + DEC-29）

> 本域**不是一个大杂烩目录**，而是 4 个组件栈共享一个 `/24`：每个观测组件在 `services/` 下拥有自己的
> `compose.yml` / `config/` / `scripts/` / `data/`，独立 profile、独立起停、独立重置、独立切 solo/ha（§2.1）。

### 16.1 四个组件栈

| 组件栈 | 目录 | 容器（solo → ha） | IP | 作用 | profile | 内存 solo / ha |
|---|---|---|---|---|---|---|
| **prometheus** | `services/prometheus/` | `prometheus-1` → `+prometheus-2` | `.12.11` / `.12.12` | 指标采集与 TSDB | `prometheus` | 0.30 / 0.85 GB |
| **alertmanager** | `services/alertmanager/` | `alertmanager`（两形态相同） | `.12.21` | 告警路由 | `alertmanager` | 0.05 / 0.05 GB |
| **grafana** | `services/grafana/` | `grafana`（两形态相同） | `.12.31` | 面板 + 数据源（provisioning 入库） | `grafana` | 0.25 / 0.25 GB |
| **jaeger** | `services/jaeger/` | `jaeger`（两形态相同） | `.12.32` | 链路追踪：OTLP 接收 + Badger 存储 + 查询 UI | `jaeger` | 0.15 / 0.15 GB |
| | | | | | **合计** | **0.75 / 1.30 GB** |

四目录结构相同（§8 契约），内容各异：

```text
services/prometheus/    compose.yml  config/prometheus.yml                            scripts/  data/prometheus-1|2/
services/alertmanager/  compose.yml  config/alertmanager.yml                           scripts/  data/alertmanager/
services/grafana/       compose.yml  config/provisioning/{datasources,dashboards}/*.y*ml  scripts/  data/grafana/
services/jaeger/        compose.yml  config/config.yaml  config/sampling.json         scripts/  data/jaeger/badger/
```

> 为什么不合成一个 `services/observability/`：四者配置格式、状态生命周期、重置影响面完全不同。
> 合并后 `stack-reset S=observability` 会同时删掉面板配置、TSDB 与 trace，且无法单独升起某一组件（§2.1）。

### 16.1.1 启动顺序与跨栈引用（DEC-25）

四栈之间**无启动依赖**（被采对象不在线也能起，只是 `up=0`），但**引用必须由 `render.sh` 从 ini 注入**，禁止手写 IP：

| 顺序 | 组件栈 | 引用点 | 取值来源 |
|---|---|---|---|
| 1 | prometheus | `alertmanager` 静态目标、`scrape_configs` | ini `[stack.alertmanager]` 的 IP + 全部 `role=exporter` 行 |
| 2 | alertmanager | `receivers`（默认收件人 mailpit） | ini `[stack.mailpit]` = `172.28.0.32:1025` |
| 3 | jaeger | 无外部引用（只监听 OTLP；采样策略读本地文件） | ini `[stack.jaeger]` 仅用于生成 `--query.base-path` 与路由 |
| 4 | grafana | 数据源 URL：`http://172.28.12.11:9090`（Prom）、`http://172.28.12.32:16686`（Jaeger） | ini `[stack.prometheus] prometheus-1` / `[stack.jaeger] jaeger` |

> 顺序只影响"组起"时的短暂 `No data`；单栈重启不牽连他栈。Grafana 是唯一"依赖两边"的栈，但它只靠配置，不靠时序。

### 16.1.2 拆栈后的可操作边界（P3 验收项）

| 场景 | 命令 | 影响面 |
|---|---|---|
| 只要指标，不要告警 | `make stack-up S=prometheus`（+ `S=grafana`） | 不起 alertmanager，省 0.05 GB |
| 升 Grafana / 换面板 | `make stack-reset S=grafana` | TSDB 与告警静默**不受影响** |
| 改采集目标 / 保留期 | `make render && make stack-up S=prometheus` | Grafana 无需重启 |
| 改告警 receiver | `make stack-up S=alertmanager` | 采集与面板零中断 |
| 全量重建指标 | `make stack-reset S=prometheus` | 面板配置仍在（provisioning），只是历史数据清空 |
| 清空 trace / 改采样 | `make stack-reset S=jaeger` | 指标、面板、告警**均不受影响** |
| 只想检索 trace | `make stack-up S=jaeger`（不起 grafana） | 直接用 `jaeger.localhost` 的 UI |

### 16.2 抓取目标自动生成（DEC-23）

`render.sh` 扫 `stock/network.ini` 中 `role = exporter` 的行，生成 `prometheus.yml`：

```yaml
scrape_configs:
  - job_name: redis-sentinel
    static_configs:
      - targets: ['172.28.2.41:9121']
  - job_name: redis-cluster
    static_configs:
      - targets: ['172.28.3.41:9121']
  - job_name: prometheus
    static_configs:
      - targets: ['172.28.12.11:9090']
  - job_name: jaeger
    static_configs:
      - targets: ['172.28.12.32:8888']
  # ……新增栈自动出现，无需手改
```

**效果**：加一个栈 → `make render` → 监控自动纳入，不会出现"新栈没人监控"。

> **自监控端点例外**：观测栈自身（prometheus `:9090`、alertmanager `:9093`、grafana `:3000/metrics`、jaeger `:8888`）
> 不是 `role=exporter` 行，`render.sh` 用一张 4 行的固定映射表 + ini 里的 IP 生成它们（避免给同一 IP 写重复行而破坏 `doctor.sh` 第 2 项）。
>
> `redis_exporter` 采用**多目标模式**（单实例 + Prometheus 侧 `/scrape?target=<ip:port>` relabel），
> 因此每栈只占 1 个容器、1 个 `.41` 尾号，却能覆盖该栈全部节点（哨兵栈 6 节点、集群栈 6 节点）。

### 16.3 为什么这里是"冗余采集"而不是"故障转移"

Prometheus 是**拉模式、无共识、本地 TSDB**，不存在"主"的概念，因此：

| 做法 | 效果 | 本方案 |
|---|---|---|
| Prometheus×2 同 targets | 两份独立数据，任一存活即可查 | ✅ ha 形态（`services/prometheus/` 内两个 service） |
| Thanos / VictoriaMetrics 集群 | 真正的多副本 + 长期存储（需对象存储） | ❌ 列为 N 级扩展（MinIO 已移出，需先追加对象存储域） |
| Grafana 多副本 | 无状态，重建即恢复（provisioning） | 单实例足够（R17，`services/grafana/` 独立栈） |

> 诚实标注：本环境能验证"采集与面板正确"，**不能**验证"监控系统自身高可用"。

### 16.4 预置面板（P3 交付物）

| 面板 | 数据源 |
|---|---|
| Redis 全实例 up/down（两组共 12 个目标） | `redis_exporter`（multi-target） |
| 哨兵主节点与切换次数 / 各哨兵 `last-ping` | `redis_exporter` sentinel 指标 |
| 集群 slot 覆盖、节点状态、主从对应关系 | `redis_exporter` cluster 指标 |
| 内存使用与 `maxmemory` 逼近度、key 数量 | `redis_exporter` |
| 命中率 / ops / 慢日志条数 | `redis_exporter` |
| 复制延迟（master → replica） | `redis_exporter` |
| 全栈 up/down 总览 | Prometheus `up` |
| 容器资源总览（若 D30=A，另起 `services/cadvisor/`） | cadvisor |
| trace 检索 / 慢调用排序 / 服务依赖图 | **Jaeger UI**（`jaeger.localhost`），不在 Grafana 里重建 |

### 16.5 追踪：jaeger 组件栈（需求⑧ / DEC-29）

| 项 | 设计 |
|---|---|
| 镜像 | `jaegertracing/jaeger:2.x`（v2 = OTel Collector 发行版；v1 已进 EOL）——见 D33 |
| 存储 | **Badger**（本地磁盘，`data/jaeger/badger`），TTL 72h；不引入 ES/Cassandra（N09） |
| 接入点 | OTLP gRPC `172.28.12.32:4317`、OTLP HTTP `172.28.12.32:4318`（应用侧只需配 `OTEL_EXPORTER_OTLP_ENDPOINT`） |
| UI | `http://jaeger.localhost`（nginx 子域转发 `:16686`） |
| 采样 | `config/sampling.json`，默认 `parentbased_ratelimited`（1 trace/s/服务）；验收时改为 `always_on` 推一条 |
| 与 Grafana 关联 | Grafana 增加 Jaeger 数据源；dashboard 面板位增加 `trace_id` → Jaeger 跳转（provisioning 里的 `links`） |
| 与指标关联 | Jaeger 自身指标 `:8888` 入 Prometheus；**业务 trace 不写指标**（不引入 exemplar 复杂度，列入 N10） |
| 谁产生 trace | 本环境无业务应用：用 `make trace-demo`（curl 推 OTLP）验收链路；真实 trace 由你的应用推送 |
| 保留与体积 | 72h TTL，估算 < 200 MB（演示量级）；`make size` 纳入统计 |
| 不可验证 | collector 多副本、存储高可用、跨服务 trace 关联的延迟分析（需真实分布式负载） |

**验收口径（P3）**：

```bash
make trace-demo                     # 推一条 OTLP span（含 2 层子 span）
curl -s http://172.28.12.32:16686/api/services   # 包含 trace-demo
open http://jaeger.localhost                     # 按 service=trace-demo 能搜到
```

---

## 17. 如何把域加回来（缩容可逆）

缩容是**有意的范围裁剪**，但机制必须保留"追加一个域 = 加一个目录 + 几行 ini"。步骤固定：

1. `services/<name>/`：照 §8 契约建 `compose.yml` + `config/` + `scripts/`（`render/bootstrap/status/reset`）+ `data/`。
   仅当新域满足 §2.1 的四条"复合栈"条件时，才允许与已有栈同目录；否则新建目录。
2. `stock/network.ini`：加 `[stack.<name>]`，**用 §3.2 表里为该域保留的原块号**（DEC-28），每行写 `role` 与 `mode`。
3. `bash scripts/render-all.sh`：`compose.generated.yml` 自动 include（扫描 `services/*/compose.yml`），`prometheus.yml` 自动纳入 `role=exporter` 的新目标。
4. `Makefile`：仅当需要"组"（一键起齐多个栈）时才加；单栈 `make stack-up S=<name>` 无需改。
5. `doctor.sh`：无需改 —— 第 1–4/11/13 项按 ini 通用校验（法定人数、IP 一致性、双形态）会自动覆盖新栈。

推荐追加顺序（覆盖收益 / 成本比最高 → 最低）：

| 顺序 | 域 | 块 | 追加后能验证什么 | 成本（ha） |
|---|---|---|---|---|
| 1 | pg（Patroni + 自带 DCS） | `.1.x` | **Redis ↔ DB 的缓存一致性/失效策略**（§5.4 的最大缺口） | 1.25 GB / 8 容器 |
| 2 | kafka | `.6.x` | 缓存穿透/热点 key 下的异步回填与消费幂等 | 3.30 GB / 6 容器 |
| 3 | mysql（MGR）/ mongo（RS） | `.4.x` / `.5.x` | 另一套主从语义对照 | 1.47 / 1.05 GB |

> 追加哪一个，就同时补 `docs/stacks.md` 的对应章节；不要"只起容器不写验证口径"。
