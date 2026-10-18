# devops 本地多栈测试环境 · 总体方案 v2.3

> 单机（macOS + OrbStack）承载 **13 个 IP 域 / 15 个组件栈**：
> **solo 形态**（单节点，日常调试）与 **ha 形态**（集群/主从，验证台架，≈ 65 容器）双轨并存，
> 全部同一网络且各带固定 IP，配置与运行时数据全部位于本仓库，
> **每个组件（除明确豁免的工具类）的 ha 形态都具备集群或主从**，
> 并统一经 `<服务>.localhost` 子域从宿主访问（§15）；
> **可观测性同样按组件拆分**（`prometheus` / `alertmanager` / `grafana` 三个独立组件栈，§16）。

---

## 0. 需求追溯

| 需求 | 设计落点 | 章节 |
|---|---|---|
| ① 所有容器同一网络，各自分配 IP | 单一 `devnet` = `172.28.0.0/16`，每服务显式 `ipv4_address`，IP 唯一权威登记在 `stock/network.ini`，`doctor.sh` 双向校验 | §3 §6 |
| ② 配置、运行时数据放 devops | `services/<组件>/config`（入库）+ `services/<组件>/data`（gitignore，`**/data/` 一条规则） | §4 |
| ③ Redis 集群 + 哨兵 | 独立两块 IP 段（`.2.x` 哨兵、`.3.x` 集群），配置互斥、profiles 隔离，状态文件持久化 | §5 §7 |
| ④ PG 主从，以及 Kafka / MySQL / MongoDB / RocketMQ / RabbitMQ / etcd / Consul / NATS | 12 栈块号表 + 身份固化清单 + 统一 bootstrap 契约 + 内存分档 | §5 §7 §8 §9 |
| **⑤ 每个组件都要有集群/主从形态** | **§5.2 集群形态选型表**：每栈给出最小可用 HA 拓扑与选型理由；§5.3 明确"工具豁免清单"（不为 HA 而 HA） | **§5.2 §5.3** |
| **⑥ 各栈 UI/控制台要从宿主访问，且指标要有统一归集** | **§15 统一入口与路由**（`<svc>.localhost` 子域，nginx 按路由表生成）+ **§16 可观测性域**（采集目标由 ini 的 exporter 角色生成） | **§15 §16** |
| **⑦ 可观测性也要按组件来** | **每个观测组件一个目录**：`services/prometheus/`、`services/alertmanager/`、`services/grafana/`，各带 compose/config/scripts/data、独立 profile、独立起停与重置；三者共享 `.12.x` 域 | **§2.1 §5 §16** |

### 0.1 版本沿革（避免混淆）

| 版本 | 形态 | 容器 | 内存 | 定位 |
|---|---|---|---|---|
| **v1** | **全单节点**（nginx 1、pg 1、redis 1、minio 1、工具若干） | 5–6 | ≈ 0.6 GB | 最小可用基线 |
| **v2** | 全 HA（12 栈集群/主从） | ≈ 61 | ≈ 13.2 GB | 集群验证台架，**日常偏重** |
| **v2.1** | **双形态**：solo = v1 形态；ha = v2 形态，同栈切换 | 6 / 61 | 0.6 / 13.2 GB | 日常用 solo 快迭代，验证用 ha |
| **v2.2** | v2.1 + **observability 栈**（第 13 域，当时为单目录）+ **统一入口路由**（`<svc>.localhost`）+ 指标归集 | 3 / 65 | 0.6 / 14.35 GB | 补上 v2.1 的三个缺口：监控后端、UI 无法访问、入口域名 |
| **v2.3（本版）** | v2.2 + **observability 按组件拆栈**（prometheus / alertmanager / grafana 三个目录）+ 三层模型（域 / 组件栈 / 容器） | 3 / 65 | 0.6 / 14.35 GB | 拆分不改容器数与内存，只改**部署单元边界**：重置面板不再丢 TSDB |

> v1 的每个组件都是单节点，**没有任何集群/主从**；集群形态全部由 v2 引入。§5.5 说明双形态如何共存。

---

## 1. 已实测确认的环境事实

| 探测项 | 结果 | 对方案的影响 |
|---|---|---|
| Docker context | `orbstack`（Docker 29.8.2 / Compose v5.5.0） | 入口统一，换运行时需重做方案 |
| **宿主直连容器 IP**（`172.28.0.10:8080`） | ✅ **可达** | 哨兵/集群/PG 返回的 `IP:port` 宿主可直接用，**无需端口重映射**，避免 NAT 破坏地址公告 |
| 同网络容器按静态 IP 互访 | ✅ 可达 | 静态 IP 方案成立 |
| `172.28.0.0/16` 与宿主路由 | ✅ 无冲突（宿主已用 `192.168.1.0/24`、`192.168.138.0/23`） | 可直接采用 /16 |
| `include: services/*/compose.yml`（glob） | ❌ 不支持 | 聚合文件用**生成**而非手写清单 |
| `include` + `profiles` 透传 | ✅ 无 profile 时服务为空 | 组件文件必须自带 `profiles` |
| 组件内 `./data`、`./config` 相对路径基准 | ✅ 以**组件文件所在目录**为基准 | 组件可整体搬迁，高内聚成立 |
| 物理内存 / CPU | 48 GB / 14 core | — |
| Docker VM 可见内存 | **15.7 GB** | 决定必须分档，禁止全量 |

> ⚠️ 前提声明：本方案"宿主免端口映射"依赖 OrbStack 的容器 IP 路由（`docker.expose_ports_to_lan: true`）。
> 切换到 Colima / Docker Desktop 默认配置时，Sentinel、Cluster、Patroni、Kafka 的地址公告会失效（见 §12 R1）。

---

## 2. 分层原则

**组件内聚（垂直切片）+ 全局不变量集中（水平薄层）。**

| 一起变的东西 | 位置 |
|---|---|
| 某栈的服务定义、配置模板、bootstrap 脚本、运行数据 | `services/<stack>/` 内（删栈 = `rm -rf` 一个目录） |
| 子网、网关、IP 花名册、日志/重启/TZ/健康检查锚点 | `base/` + `stock/`，组件内出现 `subnet:`、`logging:` 一律打回 |
| 跨栈胶水（体检、全量备份、聚合生成） | 顶层 `scripts/` |

### 2.1 三层模型（v2.3 新增，回答"什么该拆成独立栈"）

| 层 | 单位 | 数量 | 决定什么 |
|---|---|---|---|
| 域（domain） | `/24` IP 块 | 13 | IP 段分配；域内组件共享网关与尾号约定 |
| **组件栈（stack）** | `services/<name>/` 目录 | **15** | **部署 / 起停 / 重置 / 形态切换的最小单位**：一目录 = 一 profile = 一套 config+data |
| 容器（container） | `compose.yml` 里的 service | 65 | 进程与资源占用 |

**拆分判据**：一个目录 = **一个可独立起停、独立重置、独立切 solo/ha 的部署单元**，且配置格式与状态生命周期不与他者耦合 → 拆。

- ✅ 独立成栈：`prometheus`（TSDB 生命周期最长）、`grafana`（无状态，随时可重置）、`alertmanager`（重启不打断采集）。
- ❌ 留在宿主栈目录内：`pg-dcs`（DEC-16：必须与 PG 生命周期绑定）、`pg-haproxy` / `mysql-router`（宿主栈的访问层）、`*-exporter`（随被采对象）、`bootstrap` 一次性容器（幂等子步骤）。

> 判据可直接验收：`make stack-reset S=grafana` 不该丢 TSDB；`make stack-reset S=prometheus` 不该影响面板；改告警路由不该中断采集。

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

### 3.2 块号 = 栈号

| 块 | 栈 | 块 | 栈 |
|---|---|---|---|
| `172.28.0.0/24` | core（入口/对象存储/工具） | `172.28.6.0/24` | kafka |
| `172.28.1.0/24` | pg | `172.28.7.0/24` | rocketmq |
| `172.28.2.0/24` | redis-sentinel | `172.28.8.0/24` | rabbitmq |
| `172.28.3.0/24` | redis-cluster | `172.28.9.0/24` | etcd |
| `172.28.4.0/24` | mysql | `172.28.10.0/24` | consul |
| `172.28.5.0/24` | mongo | `172.28.11.0/24` | nats |
| `172.28.12.0/24` | **observability 域**（prometheus / alertmanager / grafana 三栈共享，§16.1） | `172.28.20–29.0/24` | 预留 |
| `172.28.99.0/24` | 一次性/工具容器 | | |

### 3.3 块内尾号约定（13 域统一）

| 尾号 | 角色 |
|---|---|
| `.1` / `.2` | 网关（Docker 自占）/ 仅备用 VIP（可选组件） |
| **`.11–.19`** | 核心成员：primary / leader / broker-0..2 / controller / seed |
| **`.21–.29`** | 副本或次要成员：replica / secondary / sentinel / DLedger broker |
| `.31–.39` | 栈内代理与 DCS：haproxy / mysql-router / pg-dcs(etcd) / adminer |
| `.41–.49` | exporter / 观测 |
| `.51–.59` | 临时客户端（redis-cli、kafka CLI、benchmark） |

> 唯一「多组件共享一个域」的例外：`172.28.12.0/24`（observability）。域内按组件再切一段，
> 语义仍与上表一致：`prometheus` 占 `.11–.12`（核心，ha 才有 `.12`）、`alertmanager` 占 `.21`（副本位）、
> `grafana` 占 `.31`（前端/代理位）。IP 依旧全 ini 唯一，`doctor.sh` 第 1/2 项照常校验。

---

## 4. 目录结构

```text
devops/
├── compose.yml                     # 唯一入口（生成物，见 §10）
├── compose.generated.yml
├── stock/
│   └── network.ini                 # ★ IP/端口/路由唯一权威（15 组件栈花名册）
├── base/
│   ├── network.yml                 # devnet ipam
│   ├── anchors.yml                 # x-common：logging/restart/TZ/healthcheck 默认
│   ├── redis/redis-base.conf       # 跨栈共享的 redis 公共段
│   └── jvm/heap.env                # 统一 JVM 限堆变量
├── services/
│   ├── core/            compose.yml  config/  data/     # nginx×2 + minio×4 + 工具
│   ├── pg/              compose.yml  config/  scripts/  data/   # Patroni + DCS + HAProxy
│   ├── redis-sentinel/  compose.yml  config/  scripts/  data/
│   ├── redis-cluster/   compose.yml  config/  scripts/  data/
│   ├── mysql/           compose.yml  config/  scripts/  data/   # MGR + Router
│   ├── mongo/           compose.yml  config/  scripts/  data/   # Replica Set
│   ├── kafka/           compose.yml  config/  scripts/  data/   # KRaft 3+3
│   ├── rocketmq/        compose.yml  config/  scripts/  data/   # DLedger 3
│   ├── rabbitmq/        compose.yml  config/  scripts/  data/   # 3 节点
│   ├── etcd/            compose.yml  config/  scripts/  data/
│   ├── consul/          compose.yml  config/  scripts/  data/
│   ├── nats/            compose.yml  config/  scripts/  data/
│   ├── prometheus/      compose.yml  config/  scripts/  data/   # 指标采集与 TSDB（1 / 2 实例）
│   ├── alertmanager/    compose.yml  config/  scripts/  data/   # 告警路由
│   └── grafana/         compose.yml  config/  scripts/  data/   # 面板（provisioning 入库）
├── scripts/
│   ├── doctor.sh                   # 12 项体检（§6.3）
│   ├── render-all.sh               # ini → compose.generated.yml + 各栈配置渲染
│   └── backup-all.sh               # find services -name data → 归档
├── env/{.env.example, .env}
├── docs/{plan.md, stacks.md, adr.md}
├── Makefile
├── .gitignore
└── README.md
```

```gitignore
**/data/
!**/data/.gitkeep
env/.env
```

---

## 5. 服务花名册（13 域 / 15 组件栈，ha 形态）

> 内存为"限堆/限缓存后"稳态估算，非默认值（默认值会 OOM，见 §9.2）。

| 组件栈 | 域（块） | 容器 | 形态 | 内存 |
|---|---|---|---|---|
| core | `.0.x` | nginx×2, minio×4, adminer, mailpit | 双入口 + 分布式对象存储（EC:2） | 1.35 GB |
| pg | `.1.x` | patroni×3, pg-dcs(etcd)×3, haproxy×2 | Patroni 自动故障转移 | 1.25 GB |
| redis-sentinel | `.2.x` | 1M + 2R + 3S = 6 | 哨兵自动切换 | 0.33 GB |
| redis-cluster | `.3.x` | 3M + 3R = 6 | 分片 + 副本 | 0.48 GB |
| mysql | `.4.x` | mgr×3, router×2 | MGR 单主自动选主 | 1.47 GB |
| mongo | `.5.x` | 3 节点 RS | Replica Set 自动选主 | 1.05 GB |
| kafka | `.6.x` | broker×3 + controller×3 | KRaft，RF=3 | 3.30 GB |
| rocketmq | `.7.x` | namesrv×2 + broker×3 | **DLedger（Raft）** 自动切换 | 2.60 GB |
| rabbitmq | `.8.x` | 3 节点 | quorum queue | 0.75 GB |
| etcd | `.9.x` | 3 节点 | Raft quorum | 0.24 GB |
| consul | `.10.x` | 3 节点 | Raft + gossip | 0.18 GB |
| nats | `.11.x` | 3 节点 | cluster routes + JetStream R3 | 0.12 GB |
| **prometheus** | `.12.x` | prometheus-1，prometheus-2（仅 ha） | 冗余采集（非故障转移，见 §16.3） | 0.85 GB |
| **alertmanager** | `.12.x` | alertmanager | 告警路由 | 0.05 GB |
| **grafana** | `.12.x` | grafana | 面板（provisioning） | 0.25 GB |
| **合计** | **13 域** | **≈ 65 个容器**（15 组件栈） | | **≈ 14.35 GB**（+VM 开销 ≈ 15.6 GB，**已贴上限**） |

> 后三行同属 `observability` 域，但**各自是独立组件栈**（独立目录 / profile / data / 起停重置），详见 §16.1。

### 5.1 `stock/network.ini`（唯一权威）

行格式：`name | ip | ports | role | mode`，竖线分隔便于 `awk -F'|'` 零依赖解析。

**`mode` 列默认值为 `ha`**（省略即 ha），取值：

| mode | 含义 |
|---|---|
| `ha` | 仅属于集群/主从拓扑（默认，全部未标注的行） |
| `both` | solo 与 ha 共用同一节点身份（如 `patroni-1`：solo 时它就是单实例） |
| `solo` | 仅属于 solo 拓扑 |

**solo 复用该栈 `.11` 节点的 IP**（两形态互斥、不同时运行），但**配置模板与数据目录独立**（`config/solo/`、`data/solo/`），互不污染。

```ini
[global]
subnet  | 172.28.0.0/16 | |
gateway | 172.28.0.1    | |

[stack.core]
nginx-1          | 172.28.0.11 | 80,443            | entry
nginx-2          | 172.28.0.12 | 8080,8443         | entry
nginx-vip        | 172.28.0.2  | 80,443            | vip-optional
minio-1          | 172.28.0.21 | 9000,9001         | storage
minio-2          | 172.28.0.22 | 9000,9001         | storage
minio-3          | 172.28.0.23 | 9000,9001         | storage
minio-4          | 172.28.0.24 | 9000,9001         | storage
adminer          | 172.28.0.31 | 8080              | tool
mailpit          | 172.28.0.32 | 1025,8025         | tool

[stack.pg]
patroni-1        | 172.28.1.11 | 5432              | leader
patroni-2        | 172.28.1.12 | 5432              | replica
patroni-3        | 172.28.1.13 | 5432              | replica
pg-dcs-1         | 172.28.1.31 | 2379,2380         | dcs
pg-dcs-2         | 172.28.1.32 | 2379,2380         | dcs
pg-dcs-3         | 172.28.1.33 | 2379,2380         | dcs
pg-haproxy-1     | 172.28.1.41 | 5000,5001,7000    | proxy
pg-haproxy-2     | 172.28.1.42 | 5000,5001,7000    | proxy
pg-exporter      | 172.28.1.41 | 9187              | exporter

[stack.redis-sentinel]
redis-master     | 172.28.2.11 | 6379  | master
redis-replica-1  | 172.28.2.12 | 6379  | replica
redis-replica-2  | 172.28.2.13 | 6379  | replica
sentinel-1       | 172.28.2.21 | 26379 | sentinel
sentinel-2       | 172.28.2.22 | 26379 | sentinel
sentinel-3       | 172.28.2.23 | 26379 | sentinel

[stack.redis-cluster]
rc-1             | 172.28.3.11 | 6379,16379 | master
rc-2             | 172.28.3.12 | 6379,16379 | master
rc-3             | 172.28.3.13 | 6379,16379 | master
rc-1r            | 172.28.3.21 | 6379,16379 | replica
rc-2r            | 172.28.3.22 | 6379,16379 | replica
rc-3r            | 172.28.3.23 | 6379,16379 | replica

[stack.mysql]
mysql-1          | 172.28.4.11 | 3306,33061 | mgr-member
mysql-2          | 172.28.4.12 | 3306,33061 | mgr-member
mysql-3          | 172.28.4.13 | 3306,33061 | mgr-member
mysql-router-1   | 172.28.4.31 | 6446,6447  | proxy
mysql-router-2   | 172.28.4.32 | 6446,6447  | proxy

[stack.mongo]
mongo-1          | 172.28.5.11 | 27017 | primary
mongo-2          | 172.28.5.12 | 27017 | secondary
mongo-3          | 172.28.5.13 | 27017 | secondary

[stack.kafka]
kafka-1          | 172.28.6.11 | 9092 | broker
kafka-2          | 172.28.6.12 | 9092 | broker
kafka-3          | 172.28.6.13 | 9092 | broker
kafka-ctrl-1     | 172.28.6.21 | 9093 | controller
kafka-ctrl-2     | 172.28.6.22 | 9093 | controller
kafka-ctrl-3     | 172.28.6.23 | 9093 | controller
kafka-exporter   | 172.28.6.41 | 9308 | exporter

[stack.rocketmq]
rmq-namesrv-1    | 172.28.7.11 | 9876        | namesrv
rmq-namesrv-2    | 172.28.7.12 | 9876        | namesrv
rmq-broker-1     | 172.28.7.21 | 10911,10909 | dledger
rmq-broker-2     | 172.28.7.22 | 10911,10909 | dledger
rmq-broker-3     | 172.28.7.23 | 10911,10909 | dledger

[stack.rabbitmq]
rabbit-1         | 172.28.8.11 | 5672,15672,4369,25672,35672-35682 | seed
rabbit-2         | 172.28.8.12 | 5672,15672,4369,25672,35672-35682 | member
rabbit-3         | 172.28.8.13 | 5672,15672,4369,25672,35672-35682 | member

[stack.etcd]
etcd-1           | 172.28.9.11 | 2379,2380 | member
etcd-2           | 172.28.9.12 | 2379,2380 | member
etcd-3           | 172.28.9.13 | 2379,2380 | member

[stack.consul]
consul-1         | 172.28.10.11 | 8500,8300,8301,8302,8600 | bootstrap
consul-2         | 172.28.10.12 | 8500,8300,8301,8302,8600 | server
consul-3         | 172.28.10.13 | 8500,8300,8301,8302,8600 | server

[stack.nats]
nats-1           | 172.28.11.11 | 4222,6222,8222 | member
nats-2           | 172.28.11.12 | 4222,6222,8222 | member
nats-3           | 172.28.11.13 | 4222,6222,8222 | member

[stack.prometheus]
; observability 域（§16）：三栈共享 172.28.12.0/24，各自有目录/profile/data
prometheus-1     | 172.28.12.11 | 9090 | both
prometheus-2     | 172.28.12.12 | 9090 | ha

[stack.alertmanager]
alertmanager     | 172.28.12.21 | 9093 | both

[stack.grafana]
grafana          | 172.28.12.31 | 3000 | both

# 宿主访问入口（§15）：host | upstream_ip | port | base-path 能力
[routes]
adminer.localhost      | 172.28.0.31  | 8080  | path-ok
minio.localhost        | 172.28.0.21  | 9001  | subdomain-only
rabbitmq.localhost     | 172.28.8.11  | 15672 | path-ok
consul.localhost       | 172.28.10.11 | 8500  | subdomain-only
grafana.localhost      | 172.28.12.31 | 3000  | subdomain-only
prometheus.localhost   | 172.28.12.11 | 9090  | path-ok
alertmanager.localhost | 172.28.12.21 | 9093  | path-ok
```

### 5.2 集群形态选型表（需求⑤的核心）

| 组件 | 最小 HA 拓扑 | 选型理由 | 关键机制 / 身份文件 |
|---|---|---|---|
| **nginx** | ×2（`.11/.12`），各自独立 IP | 单机无共享存储，做 VIP 只是伪需求；**客户端用双地址 + 健康探测**即可 | `upstream` 后端健康检查；`keepalived` 仅作可选 profile |
| **minio** | ×4 + 各 1 盘（EC:2） | MinIO 分布式**最低 4 盘**，否则退化为单机无冗余 | 4 节点 server pool 配置必须完全一致；`data/minio-N` |
| **postgres** | Patroni ×3 + **自带 etcd DCS ×3** + HAProxy ×2 | 只有流复制是"主从"，没有故障转移；Patroni 是流复制的事实标准 | `patroni.yml`（`bootstrap.dcs`、`pg_hba`）；DCS 内 `/service/pg/leader` |
| **redis** | 哨兵 1M+2R+3S / 集群 3M+3R | 两种语义不同，都要有 | `sentinel.conf`（运行时重写）、`nodes.conf` |
| **mysql** | MGR ×3 + Router ×2 | 异步主从切换要人工；MGR 单主自动选主 + Router 自动感知 | `server_id` 唯一、GTID、`group_replication_group_seeds` |
| **mongo** | RS ×3（1P+2S） | 副本集奇数人数才能形成多数派 | `--replSet` + `rs.initiate` 固定 IP、keyfile |
| **kafka** | broker ×3 + controller ×3（KRaft） | RF=3 + `min.insync.replicas=2`，controller 仲裁与数据面分离 | `advertised.listeners`、`meta.properties` |
| **rocketmq** | namesrv ×2 + broker ×3 **DLedger** | 原生主从是异步复制且**切换需人工**；DLedger(Raft) 才具备自动切换 | `enableDLegerCommitLog`、`dLegerPeers`、`dLegerSelfId` |
| **rabbitmq** | ×3 | quorum queue 需要 3 副本；2 节点无法形成多数派 | `hostname` 固定、erlang cookie、`cluster_formation.peer_discovery_backend` |
| **etcd** | ×3 | Raft 奇数成员 | `--initial-cluster`、`--initial-cluster-token` |
| **consul** | ×3 | `bootstrap_expect 3` | `retry_join`、gossip key |
| **nats** | ×3 | 路由全互联 + JetStream R3 | `server_name`、`--routes` |
| **prometheus** | 单实例（solo）/ ×2 冗余采集（ha） | Prometheus 是**拉模式无共识**，不存在"主"；HA 语义 = 冗余采集而非故障转移。独立成栈是因为 TSDB 生命周期最长，换保留期/重建 TSDB 不应连带面板 | `data/prometheus-N/`（TSDB）、`config/prometheus.yml`（由 ini 的 exporter 角色生成） |
| **alertmanager** | 单实例（solo / ha 相同） | 告警路由无状态（silence 落盘）；独立成栈可"只重启告警不打断采集"。真 HA（gossip 集群 ×3）列入 N 级 | `config/alertmanager.yml`、`data/alertmanager/`（silences / notify 日志） |
| **grafana** | 单实例 | 无状态，dashboard 与数据源全部走 provisioning（入库）；独立成栈才能 `stack-reset` 而不碰 TSDB | `config/provisioning/**`（datasources + dashboards）、`data/grafana/`（SQLite） |

### 5.3 豁免清单（不为 HA 而 HA）

| 组件 | 豁免理由 |
|---|---|
| adminer、mailpit | 单次会话工具，状态无价值，重启即重置 |
| exporter（pg/kafka 等） | 无状态只读，重启无影响 |
| bootstrap 一次性容器 | 天然幂等，不参与拓扑 |
| nginx VIP（keepalived） | **默认不启用**：单机故障域相同，VRRP 无法验证真实切换，只增加调试噪音 |
| prometheus / alertmanager / grafana | **部分豁免**：Prom 双实例是冗余采集（无状态同步），Grafana 无状态（provisioning 即恢复），Alertmanager 单实例；真 HA（Thanos/VictoriaMetrics、AM gossip ×3）列入 N 级（见 §16.3） |

### 5.4 单机"集群"的诚实边界

61 个容器共享**同一内核、同一磁盘、同一时钟**，因此本环境可验证：

- ✅ 拓扑配置是否正确（成员身份、quorum、seeds、公告地址）
- ✅ 协议行为是否正确（复制、选主、slot 分布、消费位点）
- ✅ 故障转移**脚本与流程**是否可执行

不可验证：

- ❌ 网络分区（脑裂）、跨机时钟漂移、真实磁盘/主机故障
- ❌ 跨机网络延迟对 quorum 的影响

→ 生产前仍需多机验证，本环境定位是"配置与流程的正确性台架"。

### 5.5 双形态：solo（= v1 形态）与 ha（= v2 形态）

同一栈用 profile 切换，**IP 身份不变、数据目录隔离**：

| 栈 | solo 拓扑 | solo 内存 | ha 内存 | 适用场景 |
|---|---|---|---|---|
| core | nginx 1 + minio 1 + 工具 | 0.45 GB | 1.35 GB | solo：单机开发；ha：验证 EC 与双入口 |
| pg | postgres 1 | 0.30 GB | 1.25 GB | solo：写 SQL/迁移；ha：验证 Patroni 切换 |
| redis-sentinel | redis 1 | 0.08 GB | 0.33 GB | solo：缓存调试；ha：验证哨兵 |
| redis-cluster | redis 1（cluster 关闭） | 0.08 GB | 0.48 GB | solo：分片逻辑调试；ha：验证 slot |
| mysql | mysql 1 | 0.45 GB | 1.47 GB | solo：建表/导入；ha：验证 MGR |
| mongo | mongo 1 | 0.35 GB | 1.05 GB | solo：文档模型调试；ha：验证 RS |
| kafka | broker 1 + controller 1 | 1.10 GB | 3.30 GB | solo：生产/消费；ha：验证 RF=3 |
| rocketmq | namesrv 1 + broker 1 | 0.95 GB | 2.60 GB | solo：消息语义；ha：验证 DLedger |
| rabbitmq | 1 节点 | 0.25 GB | 0.75 GB | solo：队列语义；ha：验证 quorum |
| etcd / consul / nats | 1 节点 | 0.08 / 0.06 / 0.04 GB | 0.24 / 0.18 / 0.12 GB | 单节点足够验证 API，不单独做 solo 档（ha 本身很轻） |
| prometheus | 1 实例 | 0.30 GB | 0.85 GB | solo：单机看指标；ha：双实例冗余采集（双份 TSDB） |
| alertmanager | 1 实例 | 0.05 GB | 0.05 GB | 两形态相同；告警路由不随采集冗余 |
| grafana | 1 实例 | 0.25 GB | 0.25 GB | 两形态相同；dashboard 走 provisioning |

#### 5.5.1 命令

```bash
make stack-up S=pg MODE=solo   # 起单节点（v1 形态）
make stack-up S=pg MODE=ha     # 起 Patroni 三节点（v2 形态）
make stack-switch S=pg MODE=ha # 先停当前形态再起目标形态（数据目录不互通，会提示）
```

#### 5.5.2 纪律

1. `MODE=solo` 只启动 `mode IN (solo,both)` 的节点；`MODE=ha` 只启动 `mode IN (ha,both)`。
2. 两形态**数据目录物理隔离**（`data/solo/` vs `data/<node>/`），禁止直接互相搬运（副本集/集群元数据不兼容）。
3. `render.sh` 同时生成两套配置，`doctor.sh` 第 13 项校验 profile 与 ini `mode` 一致。
4. solo 是**取巧的简化**（如停掉 `cluster-enabled`），文档每栈标注"solo 与 ha 的语义差异"，避免把 solo 结论当成集群结论。

---

## 6. 三大铁律与校验

### 6.1 铁律一：不变量不下沉

`subnet` / `gateway` / `logging` / `restart` / `TZ` 只允许出现在 `base/`。组件内出现即 review 打回。

### 6.2 铁律二：端口按"同一 IP 内不重复"校验

单网络 + 静态 IP 下，`5432`（PG）、`3306`（MySQL）、`6379`（Redis）各栈同时存在**不冲突**——不同 IP。
真正的冲突对象是"一个容器 IP 的端口集"。宿主端口冲突在"仅 core 发布"策略下自然消失。

多端口栈需特别标注：

| 栈 | 除主端口外的隐式端口 |
|---|---|
| redis-cluster | `16379`（总线 = 端口 +10000） |
| kafka | `9093`（KRaft controller） |
| rocketmq | `10909`（VIP 通道）+ `10911` |
| rabbitmq | `4369` epmd、`25672`、`35672-35682` |
| mysql | `33061`（MGR）、router `6446/6447` |
| pg | haproxy `5000/5001/7000`、DCS `2379/2380` |
| etcd | `2380`（peer） |
| consul | `8300/8301/8302` + `8600`（TCP 与 UDP 各一） |
| nats | `6222`（cluster routes） |

### 6.3 铁律三：`doctor.sh` 十四项体检

| # | 检查 | 失败处理 |
|---|---|---|
| 1 | ini 内 IP 均在 `/16` 内，非 `.0`/`.1`/`.255` | 报错并列出 |
| 2 | ini 内 IP 无重复 | 报错并给出重复项 |
| 3 | 同一 IP 的端口集无重复 | 报错 |
| 4 | 各组件 `compose.yml` 的 `ipv4_address` ⊆ ini 且一致（防手写漂移） | 报错并提示重跑 `render-all` |
| 5 | 每个组件服务均声明 `profiles` | 告警 |
| 6 | 宿主端口仅出现在 `[stack.core]` | 失败 |
| 7 | `docker context` 必须是 `orbstack`（方案前提） | 失败并解释原因 |
| 8 | `172.28.0.0/16` 与宿主路由无重叠 | 失败 |
| 9 | `env/.env` 存在且权限 `600` | 提示 |
| 10 | 各栈 `data/<node>` 存在且属主正确（pg/redis=999 等） | 提示修复命令 |
| 11 | **HA 拓扑完整性**：每栈声明的成员数与 ini 一致，且为奇数法定人数（etcd/consul/mongo/rabbit） | 失败 |
| 12 | **演练保护**：`restart: unless-stopped` 存在时，演练必须走 `stop` 而非 `kill` | 提示 |
| 13 | **双形态一致性**：`compose.yml` 的 profile 与 ini `mode` 一致；`data/solo` 与 `data/<node>` 不混用 | 失败 |
| 14 | **路由表校验**：`[routes]` 的 host 唯一、upstream IP 必须存在于本 ini 且属于运行中的栈、端口与节点声明不矛盾 | 失败 |

---

## 7. 身份固化清单（真实痛点）

| 栈 | 必须写死 | 必须持久化的状态文件 | 搞错的症状 |
|---|---|---|---|
| nginx | 两个实例的 `server_name`/监听端口错开 | 无状态 | 后端全挂时无法判断入口是否存活 |
| minio | 4 节点 server pool 列表**完全一致**；`MINIO_ROOT_USER` | `data/minio-N/` | 节点配置不一致 → 启动即报错或降级为单机 |
| pg (Patroni) | `scope`、`name`、`restapi`、`dcs.etcd3.hosts`、`bootstrap.dcs` | `data/patroni-N/`（含 `postgresql0/`）、DCS 数据 | 重启后 leader 丢失 / split-brain |
| redis-sentinel | `sentinel monitor` IP；`requirepass` 与 `masterauth` **必须一致** | `data/sentinel-N/sentinel.conf`（运行时重写）、AOF | 切换后新主拒绝写入 |
| redis-cluster | `cluster-enabled yes`；总线端口 = 端口 +10000 | `data/cN/nodes.conf` | 重启后忘记集群身份，需重建 |
| mysql | `server_id` 唯一、`gtid_mode=ON`、`group_replication_group_seeds` | `data/mysql-N/`、router 的 `mysqlrouter` 元数据缓存 | MGR 加入失败 / Router 指向旧主 |
| mongo | `--replSet`、`rs.initiate` 成员地址、keyfile | `data/mongo-N/db` | rs 地址与实际不符，选主失败 |
| kafka | `advertised.listeners`=容器 IP；`controller.quorum.voters`=3 固定 IP；`clusterId` | `data/kafka-N/meta.properties` | 客户端拿到不可达地址；clusterId 漂移需重新 format |
| rocketmq | **`brokerIP1`**、`namesrvAddr`、`dLegerPeers`/`dLegerSelfId` | `data/broker-N/store`（DLedger 含 `dledgerconfig`） | 消费者连不上；DLedger 成员 ID 重复导致选主失败 |
| rabbitmq | `hostname:` 固定且唯一、erlang cookie 一致 | `data/rabbit-N/mnesia` | 节点名变化 → 集群分裂、数据看似丢失 |
| etcd | `--initial-cluster` peer URL、`--initial-cluster-token` | `data/etcd-N/` | 重启后无法重组 |
| consul | `-node` 名、`retry_join` 静态 IP、gossip key | `data/consul-N/` | 节点重名 / gossip 失败 |
| nats | `server_name`、`--routes` 静态 IP | `data/nats-N/jetstream` | 路由不通、JetStream 副本不达 quorum |
| prometheus | `--web.external-url=http://prometheus.localhost`、`--storage.tsdb.retention.time`、`scrape_configs` 由 ini 生成 | `data/prometheus-N/`（TSDB chunk/WAL） | 手改 `prometheus.yml` 导致目标漂移；换保留期却不重建 TSDB |
| alertmanager | `--web.external-url`、`route`/`receivers` 模板（`render.sh` 注入 IP） | `data/alertmanager/`（`silences`、`notify`） | 静默丢失；告警重复或静默失效 |
| grafana | `root_url=http://grafana.localhost/`、`GF_PATHS_PROVISIONING`、数据源指向 `172.28.12.11:9090` | `data/grafana/`（SQLite） | 面板丢配置（未走 provisioning）；数据源指向旧 Prom |

**这些文件全部落在 `services/<stack>/data/` → `backup-all.sh` 一并归档 → 恢复即恢复身份。**

---

## 8. 组件契约（15 栈结构完全一致）

```text
services/<stack>/
├── compose.yml        # 每个 service 都带 profiles: ["<stack>"]
├── config/            # 模板（入库），以 :ro 挂载
├── scripts/
│   ├── render.sh      # stock/network.ini → data/ 下真实配置
│   ├── bootstrap.sh   # 幂等：先探测状态，已完成则 exit 0
│   ├── status.sh      # 成员/quorum/复制状态
│   └── reset.sh       # 停容器 → 删该栈 data/ 子树 → 重新 bootstrap
└── data/<node>/       # 运行时（忽略入库）
```

### 8.1 统一命令（15 栈只记这一条）

```bash
make stack-up S=kafka      # render → compose --profile kafka up -d → 等 healthy → bootstrap
make stack-status S=kafka
make stack-reset S=kafka

# 观测域是 3 个栈（§16.1），因此多一层"组"语法：组 = 多个组件栈的有序集合（定义在 Makefile，不入 ini）
make group-up    G=observability MODE=solo   # 依次 stack-up prometheus → alertmanager → grafana
make group-status G=observability
make obs / make obs-ha                       # = group-up G=observability MODE=solo|ha 的简写
```

> 组只用于**日常一键起齐**；永久态仍以"组件栈"为单位 —— 单栈单独起停/重置/切形态始终合法。

### 8.2 幂等探测（bootstrap 的判定条件）

| 栈 | 探测命令 | 通过条件 |
|---|---|---|
| etcd | `etcdctl endpoint health` | 3 个 endpoint 全 healthy |
| pg | `patronictl list` | 1 Leader + 2 Replica，`Lag` ≈ 0 |
| redis-sentinel | `sentinel get-master-addr-by-name` | 返回 `172.28.2.11` |
| redis-cluster | `cluster info` / `cluster nodes` | `cluster_state:ok`，3M3R，16384 slots |
| mysql | `SELECT * FROM performance_schema.replication_group_members` | 3 成员 `ONLINE` |
| mongo | `rs.status().ok` | `1`，1P+2S |
| kafka | `kafka-metadata-quorum describe --status` | leader + 3 voters |
| rocketmq | `mqadmin clusterList` | 3 broker 均为 `SYNC_MASTER`（DLedger） |
| rabbitmq | `rabbitmqctl cluster_status` | 3 节点 running |
| consul | `consul members` | 3 alive |
| nats | `nats server report jetstream` | 3 节点，stream R3 |
| minio | `mc admin info local` | 4 节点 online，EC:2 |

### 8.3 演练保护（重要）

`restart: unless-stopped` 会让"被杀"的容器自动复活，**直接破坏故障转移演练的观察窗口**。约定：

```bash
# 演练：用 stop（不触发 restart 策略）
docker compose stop patroni-1        # 观察 DCS 选出新 leader
docker compose start patroni-1       # 观察旧主以 replica 身份回归

# 禁止在演练中用：docker kill / docker rm
make failover-drill S=pg             # Makefile 内部已强制走 stop
```

---

## 9. 资源纪律

### 9.1 档位（`make` 目标，禁止手起全量）

| 档 | 组合 | 估算 |
|---|---|---|
| **A 日常**（含数据库与 HA 验证） | core + pg + redis-sentinel + obs(solo) | ≈ 3.5 GB |
| **B 消息** | core + kafka + rabbitmq + obs(solo) | ≈ 6.0 GB |
| **C 重栈** | core + rocketmq + mysql + obs(solo) | ≈ 6.0 GB |
| **D 组合** | core + redis-cluster + kafka + obs(solo) | ≈ 5.7 GB |
| **E 共识** | core + etcd + consul + nats + obs(solo) | ≈ 2.5 GB |
| **S 单人日常（= v1 形态）** | core(solo) + pg(solo) + redis(solo) + obs(solo) | ≈ 1.45 GB |
| **S+ 日常全栈 solo** | 全部 13 域 / 15 组件栈以 solo 形态同时在线 | ≈ 5.0 GB |
| ❌ 全量 | 15 组件栈 ha（≈ 14.35 GB / 可见 15.7 GB） | 余量 < 1.5 GB，**严格禁止常驻** |

> `obs(solo)` = 观测域三个组件栈的 solo 形态（prometheus + alertmanager + grafana，合计 0.60 GB）。
> 拆分后可只起需要的：只要指标 → `S=prometheus`；要面板 → 再加 `S=grafana`；不要告警就不起 `S=alertmanager`（0.05 GB）。

### 9.2 硬性限流（不做就会炸）

| 组件 | 必设 |
|---|---|
| rocketmq broker | `-Xms512m -Xmx512m`（默认 `-Xms8g`，直接拖垮 VM） |
| kafka | `KAFKA_HEAP_OPTS=-Xmx512m` |
| mongo | `--wiredTigerCacheSizeGB 0.25` |
| mysql | `innodb_buffer_pool_size=128M` |
| redis | `maxmemory 256mb` + `maxmemory-policy noeviction` |
| minio | `MINIO_CI_CD=1` 或显式限制并发；单节点 ≤ 300 MB |
| prometheus | `--storage.tsdb.retention.time=15d --storage.tsdb.retention.size=2GB`（否则 TSDB 无限长，`data/` 先炸盘） |
| grafana | `GF_ANALYTICS_CHECK_FOR_UPDATES=false`、`GF_USERS_ALLOW_SIGN_UP=false`（不跑更新检查、不建多余用户库） |
| 全栈 | `logging: json-file max-size=10m max-file=3` |

可选：`orb config set memory_mib 24576`（物理 48 GB，安全），但**不改档位纪律**。

---

## 10. 聚合与入口

```yaml
# compose.yml（生成物）—— 显式列举，因 include 不支持 glob
include:
  - base/network.yml
  - services/core/compose.yml
  - services/pg/compose.yml
  - services/redis-sentinel/compose.yml
  ...
```

- `render-all.sh` 扫描 `services/*/compose.yml` 生成该文件，避免"加了组件忘记登记"。
- **唯一入口**：`make` 或 `docker compose -f compose.yml`。组件文件脱离入口会报 `undefined network devnet`（已实测），属预期行为。
- 组件目录内禁止 `../` 跨栈引用；共享片段提到 `base/`（如 `base/redis/redis-base.conf`）。

---

## 11. 决策记录（ADR 摘要）

| # | 决策 | 理由 |
|---|---|---|
| DEC-1 | 单网络 `172.28.0.0/16`，不拆多网络 | 需求①；同端口不同 IP 天然隔离；/24 容量不足 |
| DEC-2 | 按组件分目录（非技术分层） | 改一个栈的拓扑只动一个目录；删栈无孤儿数据 |
| DEC-3 | 除 core 外不发布宿主端口 | 宿主可直连容器 IP（实测），消除 NAT 破坏地址公告的风险 |
| DEC-4 | `stock/network.ini` 单一事实源 + 生成 compose | 61 个 IP 手写必漂移；doctor 可双向校验 |
| DEC-5 | ini 用竖线分隔 | `awk -F'\|'` 零依赖解析 |
| DEC-6 | profiles 强隔离 + 内存档位 | 15.7 GB 装不下全量 |
| DEC-7 | Kafka 用 KRaft（无 ZK） | 少 3 个容器，官方方向 |
| DEC-8 | **MySQL 基线用 MGR（单主自动选主）+ Router** | 需求⑤：异步主从切换需人工，不构成"集群" |
| DEC-9 | RabbitMQ 由队列声明决定 classic/quorum，集群基线 3 节点 | 测试灵活性 + 满足 quorum 多数派 |
| DEC-10 | 数据放组件内 `data/`，不集中根目录 | 生命周期与组件一致；`**/data/` 一条 gitignore 覆盖 |
| DEC-11 | Sentinel conf 与 cluster `nodes.conf` 放 `data/`，config 只存模板 | 两者运行时会重写，只读挂载必然启动失败 |
| DEC-12 | **不默认使用 keepalived/VIP**，nginx 双实例 + 客户端双地址 | 单机 VRRP 无法验证真实切换，只增加调试噪音 |
| DEC-13 | **core 不再放单机数据库**，DB 全部由各自 HA 栈提供 | 避免"core 单机 pg"与"pg HA 栈"双份配置漂移 |
| DEC-14 | **RocketMQ 用 DLedger（Raft）3 broker**，不用原生主从 | 原生主从切换需人工，不满足"自动切换" |
| DEC-15 | **MinIO 4 节点分布式（EC:2）** | 分布式模式最低 4 盘，否则无冗余 |
| DEC-16 | **各栈自带 DCS/元数据**（pg 自带 etcd ×3），不复用 etcd 栈 | 生命周期解耦：关掉 etcd 档位不能拖垮 PG 的 leader 选举 |
| DEC-17 | 演练一律用 `docker compose stop` | `restart: unless-stopped` 会复活被杀容器，破坏演练观察 |
| DEC-18 | **每栈双形态（solo / ha）**，profile 切换 | v1 单节点形态仍有日常价值（1/10 资源）；ha 仅作验证台架 |
| DEC-19 | solo 复用 `.11` IP，但**配置与数据目录物理隔离** | 身份一致便于客户端不变；`data/solo/` 防止集群元数据被 solo 污染 |
| DEC-20 | **新增 observability 域**（`172.28.12.0/24`，域内拆 3 个组件栈） | 每栈都规划了 exporter 却无归集后端 = 指标白采；这是 v2.1 的最大缺口 |
| DEC-21 | **UI 统一经 `<svc>.localhost` 子域**，不做子路径优先 | MinIO console、Consul UI 强制根路径，子路径方案会在两处直接失效；子域零配置且 macOS 原生解析 |
| DEC-22 | 路由表进 `stock/network.ini` 的 `[routes]` 段，nginx 配置由此生成 | 与 IP 同源，避免"IP 改了忘改 nginx" |
| DEC-23 | Prometheus 的抓取目标由 ini 的 `exporter` 角色自动生成 | 新增栈自动纳入监控，无需手改 `prometheus.yml` |
| DEC-24 | **可观测性按组件拆栈**：`services/prometheus/`、`services/alertmanager/`、`services/grafana/` 各自拥有 compose/config/scripts/data 与独立 profile | 三个产品的配置格式、状态生命周期、重置影响面完全不同（重置 Grafana 不该丢 TSDB）；大杂烩目录会让"删栈无孤儿数据"失效；将来加 Loki/cadvisor 只需再开一栈，不扰现有栈（§2.1 拆分判据） |
| DEC-25 | 观测三栈的**跨栈引用全部由 `render.sh` 从 ini 注入**（Grafana 数据源、Prom→AM 地址、AM receiver），禁止手写 IP | 拆栈后的主要新风险是"引用漂移"；与 DEC-4 同一条纪律，`doctor.sh` 第 14 项延伸校验 |

---

## 12. 风险登记册

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | "宿主免端口映射"依赖 OrbStack | 换 Colima/Docker Desktop → Sentinel/Cluster/Patroni/Kafka 地址公告失效 | `doctor.sh` 第 7 项卡死 context；README 顶部写前提；换运行时按 §1 重新评估 |
| R2 | 61 容器 / 13.2 GB 内存 | OOM / 宿主卡顿 | 五档纪律 + §9.2 限流；`make size` 监控 |
| R3 | 身份状态文件丢失 | 集群不可恢复（需重建 + 数据丢失） | 状态文件全在 `data/` → `backup-all.sh`；`stack-reset` 前强制备份 |
| R4 | macOS bind mount 权限 | PG/Redis 启动失败 | `bootstrap.sh` 对齐 uid（pg/redis=999）；`PGDATA` 用子目录避开 lost+found |
| R5 | 单机模拟集群 ≠ 真分布式 | 无法复现脑裂/时钟/跨机延迟 | §5.4 明确边界；多机验证留待后续 compose-over-SSH 或多 VM 方案 |
| R6 | JVM 默认堆 | RocketMQ/Kafka 吃满 VM | `base/jvm/heap.env` 统一注入 |
| R7 | 重启顺序依赖 | bootstrap 逆序导致成员无法加入 | `render.sh` 固定依赖顺序；`stack-up` 内置等待 healthy |
| R8 | `include` 无 glob | 新增组件漏登记 | `render-all.sh` 生成，不手写 |
| R9 | MinIO 4 节点配置必须完全一致 | 一个节点参数不同即整集群拒绝启动 | server pool 与 `MINIO_ROOT_USER` 由 `render.sh` 统一生成 |
| R10 | MGR/DLedger/Patroni 均依赖"初始种子 + 整栈重建" | 单节点 reset 会导致集群无法恢复 | `reset.sh` 强制整栈；`doctor.sh` 第 11 项校验法定人数 |
| R11 | 容器命名/日志量 | 61 个容器日志炸盘 | 统一命名 `<stack>-<node>`；日志限 10m×3 |
| R12 | `restart` 策略干扰演练 | 误判"切换成功" | `doctor.sh` 第 12 项 + §8.3 演练保护 |
| R13 | 双形态配置漂移 | solo 与 ha 行为不一致，solo 结论被误当集群结论 | 两形态共用同一份模板渲染；`docs/stacks.md` 每栈标注语义差异 |
| R14 | 两形态数据目录误用 | 用 solo 数据启动 ha 节点 → 集群元数据损坏 | `render.sh` 生成不同 `PGDATA`/`storePath`；`stack-switch` 强制提示 |
| R15 | `*.localhost` 只在宿主生效 | 容器内访问 `grafana.localhost` 失败 | 容器间一律用 IP/服务名；`.localhost` 仅用于宿主浏览器（§15.5） |
| R16 | 观测三栈挤占内存预算 | 全量余量从 2.5 GB 降到 < 1.5 GB | 三栈可分起：`obs(solo)` 归入所有档位为常驻层，ha 形态仅在排障时临时起；告警栈可不起（省 0.05 GB） |
| R17 | Grafana 单点 | 面板不可用（指标仍在） | 接受：无状态 + provisioning；`services/grafana/` 独立栈，`stack-reset S=grafana` 级重建即恢复，不影响 TSDB |
| R18 | **拆栈后的跨栈引用漂移**：Grafana 数据源指向 `prometheus-1`、Prom 指向 `alertmanager`，任一侧 IP 变更 | 面板无数据 / 告警不发 | DEC-25：引用由 `render.sh` 从 ini 注入；`doctor.sh` 第 14 项额外校验"引用 IP 属于对应组件栈且 mode 已启用"（如 ha 引用 `prometheus-2` 而当前为 solo 形态 → 失败） |
| R19 | 三栈各自 `render.sh` 的**执行顺序** | Grafana 先起时数据源暂时不可用（面板显示 No data） | 组内固定顺序 prometheus → alertmanager → grafana；Grafana 侧仅需数据源 URL，无启动时序硬依赖（§16.1.1） |

---

## 13. 实施路线

| 期 | 内容 | 验收 |
|---|---|---|
| **P0 地基** | `base/`、`stock/network.ini`（含 mode 列）、`services/core`（solo + ha 双形态）、`doctor.sh`、`render-all.sh`、`Makefile`、`.gitignore`、`env/` | `make doctor` 14 项全绿；`MODE=solo` 起 4 容器、`MODE=ha` 起 8 容器且 `mc admin info` 显示 4 节点 EC:2；`git status` 不含 `data/`、`.env` |
| **P1 etcd** | 最轻的共识栈，把 bootstrap 契约打磨成型 | 3 节点 `endpoint health` 全 ok；停 1 节点仍可写；恢复后成员自动回归 |
| **P2 pg（Patroni）** | patroni×3 + DCS×3 + haproxy×2 | `patronictl list` 1L2R；`make failover-drill S=pg` → leader 在 30s 内转移，旧主回归为 replica |
| **P3 redis-sentinel / redis-cluster** | 需求③ | 哨兵：`get-master-addr-by-name` 正确、演练 10s 内切换；集群：`cluster_state:ok`、3M3R、16384 slots |
| **P4 consul / nats** | 与 etcd 同构，复制改参 | 3 成员 alive；nats JetStream 副本 R3 |
| **P5 mysql MGR / mongo RS** | 3 节点 + Router×2 | MGR 3 成员 `ONLINE`，杀 primary 后自动选出新主且 Router 跟随；`rs.status()` 1P2S 并完成一次自动选主 |
| **P6 kafka / rabbitmq / rocketmq** | 最重，最后 | offset 三副本、`min.insync.replicas=2`；quorum queue 3 副本；DLedger 3 broker 自动切换 |
| **P7 observability + 入口** | 三个观测组件栈（`prometheus` / `alertmanager` / `grafana`，各自 compose+config+scripts+data）+ nginx `[routes]` 生成 + 预置面板（清单见 §16.4） | 三栈可独立起停：`stack-reset S=grafana` 后面板恢复且 TSDB 不丢；各栈 `/metrics` 全部 up；`grafana.localhost` 可开且 7 个 dashboard 有数；`minio.localhost`/`consul.localhost` 能通（子域方案验证） |

**每期统一节奏**：先 `MODE=solo` 打通（快速验证镜像/配置/连通），再 `MODE=ha` 上集群并做故障演练。solo 只证明"能跑"，ha 才证明"集群成立"。

每期结束更新 `docs/stacks.md`（起停、验证命令、演练脚本、重置步骤、solo↔ha 语义差异、坑）。

---

## 14. 命令速查（目标契约）

```bash
make doctor                    # 14 项体检
make render                    # ini → compose.generated.yml + 各栈配置
make up                        # 起当前档位（默认 A）
make down                      # 停全部
make ps / make size            # 状态 / 磁盘占用（含各栈 data/）
make tier-s                    # 单人日常（= v1 形态，≈ 0.85 GB）
make tier-a|tier-b|tier-c|tier-d|tier-e
make stack-up     S=pg MODE=solo|ha
make stack-switch S=pg MODE=ha
make stack-status S=pg
make stack-reset  S=pg          # 整栈重建，强制备份
make stack-shell  S=pg N=patroni-1
make stack-host   S=pg N=patroni-1   # 宿主侧用固定 IP 直连
make stack-up     S=grafana MODE=solo   # 观测域三栈可分起（prometheus / alertmanager / grafana）
make group-up     G=observability MODE=solo  # 一次起齐观测三栈（= make obs）
make backup                    # 归档所有栈 data/ + 状态文件
make failover-drill S=pg       # 内部强制走 docker compose stop
make ui-open S=grafana         # 打开 http://grafana.localhost（按 [routes] 解析）
make routes                    # 打印全部 <svc>.localhost 入口
make obs / make obs-ha         # = group-up G=observability MODE=solo|ha
```

---

## 15. 统一入口与路由（需求⑥ / 决策 D18 + D23）

### 15.1 问题背景

plan 铁律 F06 是"除 core 外不发布宿主端口"，而各栈的控制台（Adminer / MinIO Console / RabbitMQ Mgmt / Consul UI / Grafana / Prometheus）**都在非 core 的栈里**。
如果不管，这些 UI 从宿主一律打不开 —— 这是 v2.1 的逻辑漏洞。

### 15.2 为什么用子域而不是子路径

| 组件 | 子路径（`/svc/`） | 子域（`svc.localhost`） | 说明 |
|---|---|---|---|
| Adminer | ✅ | ✅ | 两种都可用 |
| RabbitMQ Mgmt | ✅ `management.path_prefix` | ✅ | 需 WebSocket 升级头 |
| Prometheus | ✅ `--web.external-url` | ✅ | |
| Alertmanager | ✅ `--web.external-url` | ✅ | |
| Grafana | ✅ `root_url` 含子路径 | ✅ | 子路径需同步 `serve_from_sub_path` |
| Kafka UI（可选） | ✅ `SERVER_SERVLET_CONTEXT_PATH` | ✅ | |
| **MinIO Console** | ❌ **强制根路径** | ✅ | 子路径直接白屏/重定向丢前缀 |
| **Consul UI** | ⚠️ 固定 `/ui`，不支持自定义前缀 | ✅ | |

→ **结论（DEC-21）：统一走子域**。子域方案让"后端是否支持 base-path"这个问题根本不存在，且 macOS 对 `*.localhost` 原生解析（RFC 6761），零配置。

### 15.3 路由表

路由是**配置**，所以进 `stock/network.ini` 的 `[routes]` 段（DEC-22），与 IP 同源：

```ini
[routes]
adminer.localhost      | 172.28.0.31  | 8080  | path-ok
minio.localhost        | 172.28.0.21  | 9001  | subdomain-only
rabbitmq.localhost     | 172.28.8.11  | 15672 | path-ok
consul.localhost       | 172.28.10.11 | 8500  | subdomain-only
grafana.localhost      | 172.28.12.31 | 3000  | subdomain-only
prometheus.localhost   | 172.28.12.11 | 9090  | path-ok
alertmanager.localhost | 172.28.12.21 | 9093  | path-ok
```

### 15.4 nginx 生成规则

`render.sh` 为每个 `[routes]` 行生成一个 `server` 块（`core/config/conf.d/` 下），固定包含：

```nginx
server {
    listen 80;
    server_name <host>;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;      # RabbitMQ/Kafka UI 必需
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

## 16. 可观测性域（需求⑥⑦ / 决策 D20 + DEC-24）

> 本域**不是一个大杂烩目录**，而是 3 个组件栈共享一个 `/24`：每个观测组件在 `services/` 下拥有自己的
> `compose.yml` / `config/` / `scripts/` / `data/`，独立 profile、独立起停、独立重置、独立切 solo/ha（§2.1 拆分判据）。

### 16.1 三个组件栈

| 组件栈 | 目录 | 容器（solo → ha） | IP | 作用 | profile | 内存 solo / ha |
|---|---|---|---|---|---|---|
| **prometheus** | `services/prometheus/` | `prometheus-1` → `+prometheus-2` | `.12.11` / `.12.12` | 指标采集与 TSDB | `prometheus` | 0.30 / 0.85 GB |
| **alertmanager** | `services/alertmanager/` | `alertmanager`（两形态相同） | `.12.21` | 告警路由 | `alertmanager` | 0.05 / 0.05 GB |
| **grafana** | `services/grafana/` | `grafana`（两形态相同） | `.12.31` | 面板 + 数据源（provisioning 入库） | `grafana` | 0.25 / 0.25 GB |
| | | | | | **合计** | **0.60 / 1.15 GB** |

三目录结构相同（§8 契约），内容各异：

```text
services/prometheus/    compose.yml  config/prometheus.yml                            scripts/  data/prometheus-1|2/
services/alertmanager/  compose.yml  config/alertmanager.yml                           scripts/  data/alertmanager/
services/grafana/       compose.yml  config/provisioning/{datasources,dashboards}/*.y*ml  scripts/  data/grafana/
```

> 为什么不合成一个 `services/observability/`：三者的配置格式、状态生命周期、重置影响面完全不同。
> 合并后 `stack-reset S=observability` 会同时删掉面板配置与 TSDB，且无法单独升起某一组件（§2.1）。

### 16.1.1 启动顺序与跨栈引用（DEC-25）

三栈之间**无启动依赖**（被采对象不在线也能起，只是 `up=0`），但**引用必须由 `render.sh` 从 ini 注入**，禁止手写 IP：

| 顺序 | 组件栈 | 引用点 | 取值来源 |
|---|---|---|---|
| 1 | prometheus | `alertmanager` 静态目标、`scrape_configs` | ini `[stack.alertmanager]` 的 IP + 全部 `role=exporter` 行 |
| 2 | alertmanager | `receivers`（默认收件人 mailpit） | ini `[stack.core] mailpit` = `172.28.0.32:1025` |
| 3 | grafana | 数据源 URL `http://172.28.12.11:9090` | ini `[stack.prometheus] prometheus-1`（solo/ha 均指 `-1`） |

> 顺序只影响"组起"时的短暂 `No data`；单栈重启不牽连他栈 —— 这正是拆栈的收益。

### 16.1.2 拆栈后的可操作边界（P7 验收项）

| 场景 | 命令 | 影响面 |
|---|---|---|
| 只要指标，不要告警 | `make stack-up S=prometheus`（+ `S=grafana`） | 不起 alertmanager，省 0.05 GB |
| 升 Grafana / 换面板 | `make stack-reset S=grafana` | TSDB 与告警静默**不受影响** |
| 改采集目标 / 保留期 | `make render && make stack-up S=prometheus` | Grafana 无需重启 |
| 改告警 receiver | `make stack-up S=alertmanager` | 采集与面板零中断 |
| 全量重建指标 | `make stack-reset S=prometheus` | 面板配置仍在（provisioning），只是历史数据清空 |

### 16.2 抓取目标自动生成（DEC-23）

`render.sh` 扫 `stock/network.ini` 中 `role = exporter` 的行，生成 `prometheus.yml`：

```yaml
scrape_configs:
  - job_name: pg
    static_configs:
      - targets: ['172.28.1.41:9187']
  - job_name: kafka
    static_configs:
      - targets: ['172.28.6.41:9308']
  # ……新增栈自动出现，无需手改
```

**效果**：加一个栈 → `make render` → 监控自动纳入，不会出现"新栈没人监控"。

### 16.3 为什么这里是"冗余采集"而不是"故障转移"

Prometheus 是**拉模式、无共识、本地 TSDB**，不存在"主"的概念，因此：

| 做法 | 效果 | 本方案 |
|---|---|---|
| Prometheus×2 同 targets | 两份独立数据，任一存活即可查 | ✅ ha 形态（`services/prometheus/` 内两个 service） |
| Thanos / VictoriaMetrics 集群 | 真正的多副本 + 长期存储（需对象存储，可用现有 MinIO） | ❌ 列为 N 级扩展 |
| Grafana 多副本 | 无状态，重建即恢复（dashboard 走 provisioning） | 单实例足够（R17，`services/grafana/` 独立栈） |

> 诚实标注：本环境能验证"采集与面板正确"，**不能**验证"监控系统自身高可用"。需要时再上 Thanos + MinIO（已在 §5.3 豁免清单登记）。

### 16.4 预置面板（P7 交付物）

| 面板 | 数据源 |
|---|---|
| 容器资源总览 | cadvisor（若启用，同样按组件独立成栈 `services/cadvisor/`，`.12.41`，`role=exporter`，见 D30） |
| PG 复制延迟 / leader 变更 | `pg-exporter` + Patroni |
| Redis 哨兵切换 / 集群 slot | `redis_exporter` |
| MySQL MGR 成员状态 | `mysqld_exporter` |
| Kafka lag / 副本同步 | `kafka-exporter` |
| etcd / Consul Raft 健康 | `etcd` `/metrics`、`consul` `/v1/agent/metrics` |
| 全栈 up/down 总览 | Prometheus `up` |
