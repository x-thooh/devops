# 栈操作手册

> 每落地一个部署单元就补一章：起停、验证命令、演练、重置、solo ↔ ha 语义差异、坑。
> 设计细节见 [`plan.md`](plan.md)，未定事项见 [`pending-decisions.md`](pending-decisions.md)。

## nginx（P0）

### 形态

| mode | 容器 | 宿主端口 | 说明 |
|---|---|---|---|
| `solo` | `nginx-1`（`172.28.0.11`） | `ENTRY_HTTP_PORT`（默认 80） | 唯一入口 |
| `ha` | `nginx-1` + `nginx-2`（`172.28.0.12`） | 仅 `nginx-1` 发布 | 双入口，无 VIP；`nginx-2` 只供直连验证 |

两实例共用 `services/nginx/config/nginx.conf` 与 `services/nginx/data/conf.d/`；
`[routes]` 的每个 host 生成一个 server 块，upstream 指向 ini 中的固定 IP。

### 输入

| 文件 | 作用 |
|---|---|
| `stock/network.ini` 的 `[stack.nginx]` | 两个节点的 IP / 端口 / mode |
| `stock/network.ini` 的 `[routes]` | `host \| upstream_ip \| port \| capability` |
| `services/nginx/compose.yml` | 手写骨架（`x-image: nginx` + profile + 挂载 + 健康检查） |
| `services/nginx/config/nginx.conf` | 默认站点 `/healthz`、WebSocket map、`include conf.d/*.conf` |
| `services/nginx/scripts/render.sh` | 生成 `data/conf.d/<host>.conf` |

### 起停

```bash
make stack-up   S=nginx MODE=solo
make stack-up   S=nginx MODE=ha
make stack-status S=nginx              # 省略 MODE = 沿用当前部署形态（DEC-50）
make stack-down S=nginx MODE=ha     # 只删本 profile 的容器，不影响其它栈
```

`stack.sh up` 会先 `make render`，再按 ini 过滤出当前 mode 的 service，
最后 `stop` 掉不属于该 mode 的节点（`solo` 时 `nginx-2` 变 `Exited`，数据不删）。

### 验证

```bash
# solo / ha 都应有
curl -s http://127.0.0.1/healthz                  # ok
docker exec nginx-1 date                          # CST +0800
docker exec nginx-1 nginx -t

# 路由已通（观测栈未起时 502 是预期，不是 404/000）
curl -s -o /dev/null -w '%{http_code}\n' \
     -H 'Host: grafana.localhost' http://127.0.0.1/

# 仅 ha
curl -s http://172.28.0.12/healthz                # ok
```

`make doctor` 的 15 项应全绿；第 4/6/13 项会校验 nginx 的渲染 IP、profile 与宿主端口，
第 15 项校验容器真的在跑且健康。

### solo ↔ ha 语义差异

- `solo` 只复用 `nginx-1`（`.11`）；`nginx-2` 不启动，`172.28.0.12` 不可达。
- `ha` 才启动 `nginx-2`；两者无 VIP，宿主入口只指向 `nginx-1`，`nginx-2` 用直连 IP 验证。
- 两者共用同一份 `data/conf.d/`（无状态，不存在数据隔离问题）。

### 重置

```bash
make stack-reset S=nginx MODE=solo
```

顺序：删容器 → 清 `services/nginx/data/conf.d/*.conf` → `render.sh` 重建路由 →
重新 `up`。`config/nginx.conf` 是入库模板，不会被删。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| `port is already allocated` | 宿主 80 被占；`lsof -nP -iTCP:80 -sTCP:LISTEN`，或改 `env/.env` 的 `ENTRY_HTTP_PORT` |
| 改 `nginx.conf` 不生效 | `stack-up` 不会重建未变化的容器；用 `make stack-reset` 或 `docker compose restart nginx-1` |
| 浏览器打不开 `grafana.localhost` | 只有宿主能解析 `*.localhost`；容器之间必须用 IP / 服务名（R15） |
| `grafana.localhost` 返回 502 | 正常：路由已通，grafana 未起；等观测栈起来后再验 200 |
| `nginx-2` 直连 000 | `MODE=solo` 或容器未起；切 `MODE=ha` 后再试 |
| `make doctor` 第 8 项失败 | VPN / 其它网桥占用了 `172.28.0.0/16`；`netstat -rn -f inet \| grep 172.28` |
| `[routes]` 改了但配置没变 | 只改 ini 不够，必须 `make render`（或 `make stack-up`，它内部会 render） |
| 新增路由后 `*.localhost` 返回默认站点文本（如 `devops edge (nginx) is up`） | render 只生成 `data/conf.d/<host>.conf`，**nginx 不会自动重读**：`docker exec nginx-1 nginx -t && docker exec nginx-1 nginx -s reload`，或 `make stack-reset S=nginx MODE=solo` |
| curl 返回 200 但浏览器打不开 | 服务端没问题，查宿主侧：地址栏被补成 `https://`（443 未启用，见 DEC-42）、Chrome "安全 DNS（DoH）"把 `*.localhost` 丢给远端解析、代理类插件劫持（系统代理的 bypass 列有 `localhost` 但**不含 `*.localhost`**）；零配置退路：直接开容器 IP `http://172.28.20.11:3000` |
| 想看 nginx 收到过哪些请求 | `docker logs nginx-1`。**不要** `docker exec nginx-1 tail /var/log/nginx/access.log` —— 该文件是指向 `/dev/stdout` 的软链，`tail` 会永久阻塞 |

---

## 形态 marker 与 `make render` 的渲染形态（全局约定）

每个部署单元在 `services/<dir>/data/.mode-<profile>` 存一行 `solo` / `ha`，由 `stack.sh` 在
`up` / `reset` 时先写 marker 再渲染。`make render` 会按 marker 逐目录调用 `render.sh`，
**不再一律按 solo 重渲染**——否则一次全量 render 会把 ha 的 `entry.sh` / `my.cnf`
悄悄打回 solo 形态（踩过：pg 演练后用 `make render`，patroni-1 被换成了 solo 的 postgres）。

- 没 marker 的目录按 `solo` 渲染；同一目录多 profile（`redis`）取最近修改的 marker。
- marker 在 `data/` 下，不入库；换机器后先 `make stack-up` 一次，形态即重新固化。
- marker 还被三处消费：`prometheus` 的 render 据此**只列真会起的抓取目标**（DEC-47）、
  `doctor` 第 15 项据此算出「该在跑的容器」（DEC-48）、`stack.sh` 据此定 MODE 缺省（DEC-50）。

### `make stack-*` 的 MODE 缺省（DEC-50）

`MODE` 不写时**不假定 solo**：`stack.sh` 读本 profile 的 `.mode-<profile>` marker 沿用当前
部署形态（从没部署过才回退 solo），并打印 `# MODE 未指定 -> <mode>`。

原因：拿 solo 视图去查一个 ha 部署，会得到"看着输出了东西、验的却是另一个形态"的结果。
实测：`make stack-status S=mysql`（旧默认 `MODE=solo`）在 ha 部署上打的是
`@@server_id / @@gtid_mode / @@version`，而不是 MGR 成员表 —— 看着绿、其实没验集群。

要显式换形态仍然必须写 `MODE=solo|ha`；DEC-48 的恢复口径（重跑 `make stack-up`）
不带 MODE 时不再会把 ha 静默改成 solo。

### 工具链：`mise.toml` + 仓库内 `.venv`（DEC-51）

所有 `python3` 调用（render-all.py / doctor.py / ini.py）都固定命中 `.venv/bin/python3`：
Makefile 前置 `.venv/bin` 到 PATH，`scripts/lib.sh` 同效（覆盖不走 make 的直接调用）。
解释器版本由 `mise.toml` 钉（`python = "3.12"`），依赖只由 `make setup` 装进 `.venv`。

为何不是"升级系统 Python"：`/usr/bin/python3` 是 Apple 随 Command Line Tools 发的（SIP 保护，
升不动也不该动）；真因是宿主同时存在多个 `python3` 且 PATH 顺序随 shell 类型而变——实测
`zsh -ic` 得 3.12、`zsh -lc` / `bash -lc` / `env -i` 得 3.9.6，于是出现过一次
`make render` 报 `ModuleNotFoundError: yaml`。坑在于**两个解释器都能单独跑通**，
症状只在换 shell 时出现，靠"我本地能跑"排查不出来。

- 换机器 / 新开仓库：`make setup`（pypi 直连不通时 `make setup PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple`）。
- `.venv/` 是生成物（已 gitignore）；**不要**把依赖装回宿主解释器（包括 `--break-system-packages`）。
- 没装 mise 时 `make setup` 会提示后退出；其余目标仍会回退宿主 `python3`，不会硬坏。

### Docker daemon 重启后的恢复（重要）

`restart: unless-stopped` 只会**复活容器**，不会恢复**集群不变量**——`mysql` 的
`loose_group_replication_start_on_boot=OFF`（防自动裂脑，设计如此）会让 MGR 停在
`OFFLINE`，进而把下游（`nacos`）打成 crash loop。**容器都 Up ≠ 服务可用**。

恢复口径见 plan §8.4 / DEC-48，一句话：按依赖顺序重跑 `make stack-up`（幂等），
先 `mysql` 再 `nacos`。`make doctor` 第 15 项会把这种情况报出来：容器在跑但不健康
（crash loop）= **FAIL**；marker 说该在跑而容器没在跑 = **WARN**（所以一次干净的全量
`down` 后是 14 PASS / 1 WARN，不是 FAIL——语义是对的）。

> 这句话在 DEC-52 之前对 mysql 是假的（下面两个坑只有在全量 `down` 后才会同时出现，
> 逐栈 `stop/start` 演练探不到）。

### `stack-up` 的两段式启动（DEC-52）

`up` / `reset` 的实际顺序是：**起容器（不等健康）→ `bootstrap` → 再等健康**。

旧写法 `up -d --wait` 后接 `bootstrap` 对**任何需要 bootstrap 才转健康的栈**都是死循环：
mysql 实测 `down` 后三节点 MGR 全 `OFFLINE`，Router 只在 metadata cache 里看到 ONLINE
primary 后才监听 6446 → `--wait` 超时失败 → bootstrap 永远轮不到 → Router 永远 `unhealthy`，
还连累下游 nacos（11 次重启）。现在第一段能跑过去是因为 bootstrap 自带就绪轮询
（各栈 20–60 次），第二段才把"真的健康"当终态。验证：`stack.sh rm mysql ha` 后重建
11.7 s 回到 MGR 3 `ONLINE` + 两台 Router `6446/6447 ok`。

配套修复：mysql 首次成组前先逐节点 `SET GLOBAL super_read_only=OFF`——单主 MGR 重启后节点
带 `super_read_only=ON` 回来（运行时值，不落 `mysqld-auto.cnf`），而成组前必须建 `repl` 用户，
不解就撞 `ERROR 1290`。**只在首次成组分支解**："已成组"分支里 SECONDARY 的只读就是单主语义本身。

---

## etcd（数据库域 / DCS）

`172.28.9.x`（数据库域）。solo 只有 `etcd-1`；ha 三节点 `etcd-1..3`、
peer 走 `2380`、client 走 `2379`，`initial-cluster-state` 首次为 `new`，
数据目录 `data/<node>`（solo 为 `data/solo`）。

```bash
make stack-up S=etcd MODE=ha
make stack-status S=etcd MODE=ha     # etcdctl endpoint health（只探在跑的成员）
docker exec etcd-1 etcdctl member list
docker exec etcd-1 etcdctl endpoint status --cluster -w table
make failover-drill S=etcd           # stop 一个成员，写读照常
```

坑：

| 现象 | 原因 / 处理 |
|---|---|
| ha 起不来、日志报 `cluster ID mismatch` | 换形态没清数据；`make stack-reset S=etcd MODE=ha` |
| `etcdctl` 报 `context deadline exceeded` | 只探 `127.0.0.1` 不行，必须带 `--endpoints=http://<ip>:2379` |
| 想扩到 4/5 节点 | 必须同时改 ini 的 `initial-cluster` 生成源与 quorum；不是加一行的事 |

---

## consul（注册域 / 与 etcd 分域）

`172.28.10.x`（注册域，与 etcd 分域）。solo=1 台，ha=3 台 server，
ha 的 `bootstrap_expect=3`；单机时是 `bootstrap_expect=1`。

```bash
make stack-up S=consul MODE=ha
make stack-status S=consul MODE=ha    # consul members + raft list-peers
curl -s http://172.28.10.11:8500/v1/status/leader
curl -s http://172.28.10.11:8500/v1/agent/metrics?format=prometheus | head
```

坑：

| 现象 | 原因 / 处理 |
|---|---|
| UI 打不开 | consul 未发布宿主端口；走 `consul.localhost` 或容器 IP `:8500` |
| ha 只有一台 leader、其余 `left` | 检查 ini 里三台的 IP 与 `retry_join` 生成结果；重起前先 `stack-reset` |
| 想加密 gossip | 未启用（Lab 范围），启用需分发 `encrypt` key，见 pending-decisions |

---

## nats（消息域 / JetStream）

solo=`nats-1`，ha=`nats-1..3`；client `4222`、cluster `6222`、HTTP 监控 `8222`。
Exporter（`nats-exporter`，`7777`）以 `-jsz all` 拉 JetStream 指标。

```bash
make stack-up S=nats MODE=solo
make stack-status S=nats MODE=solo     # /varz 概览
curl -s http://172.28.11.11:8222/jsz?streams=1 | head -c 200
curl -s http://172.28.11.41:7777/metrics | grep -c '^nats'
```

坑：

| 现象 | 原因 / 处理 |
|---|---|
| exporter 报 `Unable to parse URL "-varz"` | 老版本 exporter 参数写法不同；本次已改为 `-jsz all`，改完要 `--force-recreate` 才会生效 |
| ha 三节点不组成集群 | 检查每台的 `cluster.routes` 是否指向另两台的 `6222` |

---

## redis（唯一复合栈：两组互斥 profile）

| profile | 拓扑 | IP |
|---|---|---|
| `redis-sentinel` | `redis-master` + 2 replica + 3 sentinel（`devmaster`） | `172.28.2.11-13` / `.21-23` |
| `redis-cluster` | 3 master + 3 replica（`cluster-announce-ip` 写死） | `172.28.3.11-13` / `.21-23` |

两组 profile 各自有 exporter（`9121`）；数据按形态隔离：`data/sentinel/<node>`、
`data/cluster/<node>`（solo 落在各自 `data/active` 下的 `solo` 子树）。
密码取 `env/.env` 的 `REDIS_PASSWORD`，所有节点一致。

```bash
make stack-up S=redis-sentinel MODE=ha
make stack-up S=redis-cluster  MODE=ha
make stack-status S=redis-sentinel MODE=ha   # sentinel get-master-addr-by-name devmaster
make stack-status S=redis-cluster  MODE=ha   # cluster nodes / cluster info
make failover-drill S=redis-sentinel         # stop master → sentinel 升主
make failover-drill S=redis-cluster          # stop 一个 master → 其 replica 顶上
```

实测（sentinel ha + 切主演练）：`redis-master` 1M2R `state=online`；三台 sentinel
`get-master-addr-by-name devmaster` 一致；`stop redis-master` 后 sentinel 把 `redis-replica-1`
（`.12`）升主且新主可写，旧主回来自动降为 replica（`master_host=172.28.2.12`）。
切主后 `sentinel.conf` 里的 `sentinel monitor devmaster` 已被 CONFIG REWRITE 改成 `.12`——
这是运行态事实，不是模板漂移（DEC-11）。

### 监控口径（sentinel 口不抓，DEC-49）

prometheus 的 `redis-sentinel` job 只列 3 个 6379 节点：`/scrape` 中继只能带一份共享
`REDIS_PASSWORD`，而 sentinel 自身不设密码，带密码去连会 AUTH 失败（已用不带密码的临时
exporter 对照证实：同一目标 `redis_up` 从 1 变 0）。sentinel 健康看
`make stack-status S=redis-sentinel`；主从切换在指标上体现为 `redis_role` 在两个 instance 间互换。

坑：

| 现象 | 原因 / 处理 |
|---|---|
| `S=redis` 报 profile 不存在 | redis 是目录不是部署单元；用 `redis-sentinel` / `redis-cluster` |
| cluster 一直 `cluster_state:fail` | 槽位没分完；`stack-reset S=redis-cluster MODE=ha` 重走 `cluster create` |
| 两组同时起，内存吃紧 | 两组共 14 个 service；按档位（`make tier-*`）分别起 |
| sentinel 报 `master down` 但 redis 正常 | sentinel 用 IP 探测，检查 ini 的 master IP 与 `sentinel.conf` 渲染结果 |
| sentinel 目标 `redis_up=0` 但三台明明活着 | 预期（DEC-49）：中继带了 redis 密码而 sentinel 不设密码；已从 job 剔除，改看 `make stack-status` |
| 用 `(exec 3<>/dev/tcp/IP/PORT)` 探 redis/sentinel 端口，结果总是 `refused` | `/dev/tcp` 是 **bash 特有**，busybox ash（redis 镜像）与 zsh 都不支持，失败与连通性无关。跨容器探端口用 `redis-cli -h <ip> -p <port> ping` 或 `nc -zv`；`status.sh` 里的 `/dev/tcp` 只在 bash 下才成立 |

---

## mongo（`172.28.5.x`）

solo=`mongo-1` 单实例；ha=`mongo-1..3` 副本集（`rs.initiate` 在 `bootstrap.sh` 里，`mongo-1`
固定为 priority 高的主）。**未启用认证**（Lab 范围，见 pending-decisions）：
容器内 `mongosh` 直接连，`MONGO_INITDB_ROOT_*` 只用于初始化。

```bash
make stack-up S=mongo MODE=ha
make stack-status S=mongo MODE=ha     # rs.status() 成员与角色
make failover-drill S=mongo           # stop primary → 剩余节点选主
docker exec mongo-1 mongosh --quiet --eval 'rs.status().members.map(m=>m.name+" "+m.stateStr)'
```

坑：

| 现象 | 原因 / 处理 |
|---|---|
| ha 起完 `rs.status()` 只有一台 | `bootstrap.sh` 幂等判断失败；先 `stack-reset` 再 `stack-up` |
| exporter 抓不到指标 | exporter 连的是 `mongo-1`；主切走后指标会断，属预期（未做多目标） |
| 想开认证 | 需同时改 `bootstrap.sh` 建用户与 exporter 凭据，别只改 env |

---

## mysql（`172.28.4.x`，MGR）

| mode | 容器 | 说明 |
|---|---|---|
| `solo` | `mysql-1` + `mysql-exporter` | 单实例，`data/solo/data` |
| `ha` | `mysql-1..3` + `mysql-router-1..2` + exporter | 三节点 MGR（单主），Router 读写分离 |

实例 `3306`（组复制内部 `33061`）；Router `6446` 走 `first-available`（默认主）、
`6447` 走 `round-robin`（只读）。数据目录按形态隔离：`data/<node>/data`。

```bash
make stack-up S=mysql MODE=ha
make stack-status S=mysql MODE=ha    # MGR 成员表 + Router 端口探活
docker exec mysql-1 mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
  'SELECT MEMBER_HOST,MEMBER_ROLE,MEMBER_STATE FROM performance_schema.replication_group_members'

# Router 写入口 / 只读口（在任意 mysql 客户端容器里测）
docker exec mysql-1 mysql -h172.28.4.31 -P6446 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e 'SELECT @@read_only'
docker exec mysql-1 mysql -h172.28.4.31 -P6447 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e 'SELECT @@read_only'
```

实测：`6446` 返回 `read_only=0`（mysql-1），`6447` 返回 `read_only=1`（mysql-2/3 轮询）。

### solo ↔ ha 语义差异

- `ha` 的库表不能靠 `MYSQL_DATABASE`：各节点本地建库会让 GTID 分叉；改由 `bootstrap.sh`
  在成组**之后**建 `nacos_config`。`solo` 仍走 env。
- `mysql-router-*` 只在 `ha` 启动；`solo` 的 nacos 直连 `mysql-1:3306`，`ha` 走 `router:6446`。
- 成组失败重来前必须 `RESET MASTER` 清各节点本地 GTID，否则 join 报
  `member has more executed transactions`。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| `mysqld` 起不来，日志 `unknown variable 'group_replication_group_name'` | `--initialize` 阶段 GR 插件还没加载；所有 GR 变量加 `loose_` 前缀 |
| 日志 `Unable to lock ./ibdata1` | 上一次初始化中断留下的半成品；`stack-reset` 后重来 |
| `mysqladmin ping` 失败但进程在 | 镜像默认走 socket；健康检查与脚本都加 `-h127.0.0.1`（`status.sh` 曾漏掉，自己报 ERROR 2002） |
| Docker daemon 重启 / 全量 `down` 后三台都 `Up` 但 MGR 全 `OFFLINE` | 预期：`group_replication_start_on_boot=OFF` 是防裂脑的设计，不会自动成组。`make stack-up S=mysql`（省略 MODE 即沿用 ha）重跑 `bootstrap.sh`：因为**没有任何节点是 ONLINE**，走的是"首次成组"分支（清 GTID → 重建组 → join → adoptFromGR/rescan），不是"只补离队节点"；数据保留。两段式启动（DEC-52）保证这一步真能跑到。下游 nacos 会因此 crash loop，先修 mysql 再修 nacos（plan §8.4） |
| `bootstrap.sh` 在 `configuring recovery channel` 就退出（输出里没有错误行） | `sql()` 里 `2>/dev/null` 吞掉了 stderr，实际是 `ERROR 1290 ... --super-read-only`：重启后节点带只读回来而成组前必须建 `repl` 用户。已由首次成组分支前的 `SET GLOBAL super_read_only=OFF` 修掉（DEC-52） |
| `mysql-router-*` 一直 `unhealthy` | 健康检查是 `exec 3<>/dev/tcp/127.0.0.1/6446`（只有 bash 支持），而 Router 只在 MGR 有 ONLINE primary 时才监听 6446 —— 先查成员表而不是 Router 本身 |
| Router 报 `One can only use the -u/--user switch if running as root` | 镜像以 uid 999 运行；去掉 `--user=root`，把 `data/mysql-router-*` chmod 0777 |
| Router 起不来，缺 `mysql_innodb_cluster_metadata` | 静态路由不依赖 AdminAPI 元数据；本仓库不用 `mysqlrouter --bootstrap`（偏差见 pending-decisions） |
| 组复制成员 `ERROR` 后反复重试 | 先 `stack-reset S=mysql MODE=ha`，不要在半死集群上手工 `START GROUP_REPLICATION` |

---

## pg（`172.28.1.x`，Patroni）

| mode | 容器 | 说明 |
|---|---|---|
| `solo` | `patroni-1` + `pg-exporter` | `patroni-1` 内直接跑 postgres，无 DCS / HAProxy |
| `ha` | `patroni-1..3` + `pg-dcs-1..3` + `pg-haproxy-1..2` + exporter | Patroni + etcd DCS + 双 HAProxy |

`5432` 数据库、`8008` Patroni REST；HAProxy `5000` 主写、`5001` 只读、`7000` stats。

```bash
make stack-up S=pg MODE=ha
make stack-status S=pg MODE=ha       # patronictl list + haproxy stats
make failover-drill S=pg             # stop leader → 观察新主 + 旧主回归

docker exec patroni-1 patronictl -c /data/active/patroni-1/patroni.yml list
docker exec patroni-1 psql "postgresql://postgres:$PG_SUPERUSER_PASSWORD@172.28.1.34:5000/postgres" -Atc \
  'select inet_server_addr(), pg_is_in_recovery()'   # 主：f
docker exec patroni-1 psql "postgresql://postgres:$PG_SUPERUSER_PASSWORD@172.28.1.34:5001/postgres" -Atc \
  'select inet_server_addr(), pg_is_in_recovery()'   # 只读：t
```

实测：`1 Leader + 2 Replica(streaming, lag 0)`；`5000` 指向 `.11`，`5001` 指向 `.12`；
停掉 leader 后 HAProxy 自动跟随新主。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| `Patroni requires psycopg2/psycopg` | 镜像不自带；`Dockerfile` 加 `psycopg[binary]==3.2.3` 并重新 `docker compose build` |
| `data directory has invalid permissions` | OrbStack 的 virtiofs 上 **chown 是空操作**（永远显示 root:root）；entry.sh 改 chmod：父目录 0777、pgdata 0700 |
| `pg-haproxy` 永远 unhealthy | 原探针里的 `apk info -e haproxy` 返回 1；只保留 `wget -qO- http://127.0.0.1:7000/` |
| 演练后旧主起成了 solo postgres | `make render` 曾一律按 solo 渲染；现由 `.mode-pg` marker 决定形态（见文首约定） |
| `5000` 连上却写不进去 | 连到了旧主或只读节点；`patronictl list` 看 Leader，再 `curl http://<haproxy>:7000/` 看后端健康 |

---

## kafka（`172.28.6.x`，KRaft）

| mode | 容器 | 说明 |
|---|---|---|
| `solo` | `kafka-1` + `kafka-exporter` | 单节点兼任 broker + controller（node.id=1，voters=`1@ip:9093`） |
| `ha` | `kafka-1..3` + `kafka-ctrl-1..3` + exporter | broker×3（id 1–3）+ controller×3（id 101–103，独立 quorum） |

配置**不走镜像的 `KAFKA_*` 环境变量包装器**（KRaft 校验会把 `0.0.0.0` 误判）：
`render.sh` 直接写 `server.properties`，`entry.sh` 首次启动时用固定 `clusterId`
（`data/active/kafka-cluster-id`）执行 `kafka-storage.sh format`。

```bash
make stack-up S=kafka MODE=ha
make stack-status S=kafka MODE=ha    # metadata quorum + topics
# controller 只能在 controller 节点上查（broker 不监听 9093）
docker exec kafka-ctrl-1 /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-controller 127.0.0.1:9093 describe --status
docker exec kafka-1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server 127.0.0.1:9092 --describe --topic devops-demo
```

实测 ha：`LeaderId=102`，voters 101/102/103，observers 是三个 broker；`devops-demo` 3 分区、
副本因子 3；`kafka-broker-api-versions` 能列出 3 个 broker。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| 启动报 `advertised.listeners` 校验失败 | 合体节点必须同时公告 `CONTROLLER://<ip>:9093`；不能留给 `0.0.0.0` |
| 从 broker 查 quorum 超时 | ha 下 broker 不监听 9093；改在 `kafka-ctrl-*` 容器里查 |
| 重新 `format` 报目录已有 clusterId | `entry.sh` 只在缺 `meta.properties` 时 format；换形态先 `stack-reset` |
| 三副本 topic 写不进去 | `default.replication.factor` / `min.insync.replicas` 随形态变；solo 下 rf=1 才能写 |
| exporter 无数据 | `kafka-exporter` 只配了 `kafka-1`；broker 切换后会断，属预期 |

---

## rocketmq（`172.28.7.x`）

| mode | 容器 | 说明 |
|---|---|---|
| `solo` | `rmq-namesrv-1` + `rmq-broker-1` + exporter | `broker-solo`，DLedger 关闭，`ASYNC_MASTER` |
| `ha` | `rmq-namesrv-1..2` + `rmq-broker-1..3` + exporter | 三 broker 同属 `broker-dledger`，Raft 自动选主 |

DLedger 副本间走 `40911`（ini 里有写，渲染时生成 `dLegerPeers`）；业务口 `10911`、
HA 口 `10909`。`bootstrap.sh` 等 clusterList 出现 3 行 `DefaultCluster` 后建 `devops-demo`。

```bash
make stack-up S=rocketmq MODE=ha
make stack-status S=rocketmq MODE=ha   # mqadmin clusterList + topicRoute（慢，约 15s/次）
docker exec rmq-broker-1 sh mqadmin clusterList -n 172.28.7.11:9876
```

实测 ha：三行 `DefaultCluster broker-dledger`（BID 0/1/2，leader 的 `#ACTIVATED=true`），
`devops-demo` 读写队列各 3。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| 启动后没选主 | 三台 `dLegerGroup` / `dLegerPeers` / `dLegerSelfId` 必须完全一致；BID 由 DLedger 自分配，不要手写 |
| 把 `mqadmin` 当探针 | 每次调用启 JVM，十几秒；只能做手动检查，`bootstrap.sh` 也只用它轮询一次 |
| solo 日志刷 namesrv 注册失败 | `namesrvAddr` 里留了未启动的 namesrv-2；render 已按形态过滤 |
| `SYNC_MASTER` 一直等不到 | DLedger 模式 clusterList 不显示该字样；改用 `^DefaultCluster` 行数判断 |
| exporter 指标为空 | exporter 只认 `namesrvAddr`；namesrv 未就绪时它不会自行重连，重起 exporter |

---

## rabbitmq（`172.28.8.x`）

solo=`rabbit-1`；ha=`rabbit-1..3`，`classic_config` 静态节点发现，默认队列类型 `quorum`。
`5672` AMQP、`15672` 管理 UI、`15692` Prometheus；Erlang 分布 `25672`、EPMD `4369`、
`35672-35682`（`inet_dist_listen_min/max`）。

```bash
make stack-up S=rabbitmq MODE=ha
make stack-status S=rabbitmq MODE=ha   # cluster_status + 队列类型
docker exec rabbit-1 rabbitmqctl cluster_status
docker exec rabbit-1 rabbitmqctl list_queues name type messages
```

实测 ha：三个 `rabbit@rabbit-*` 均为 running；管理 UI 走 `rabbitmq.localhost`。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| 4.0 起不来用户 / 登录 401 | 4.0 不再从 `RABBITMQ_DEFAULT_USER` 建用户；由 `bootstrap.sh` 用 `rabbitmqctl add_user` 建 `devops` |
| 三节点各自为政 | `RABBITMQ_ERLANG_COOKIE` 必须一致；`RABBITMQ_NODENAME` 用固定 `rabbit@<node>` |
| 节点名变成随机容器名 | 没设 `RABBITMQ_NODENAME`；容器重启会丢集群身份 |
| `15692` 无指标 | `enabled_plugins` 里 `rabbitmq_prometheus` 是否生效；改完需重建容器 |
| 队列不是 quorum | `default_queue_type` 只对新队列生效；老队列需删后重建 |

---

## prometheus（`172.28.12.11-12`）

| mode | 容器 | 说明 |
|---|---|---|
| `solo` | `prometheus-1` | 单节点采集 |
| `ha` | `prometheus-1` + `prometheus-2` | 两套独立采集，各写自己的 TSDB（拉模式无共识） |

`scrape_configs` 全部由 ini 生成：exporter 行一个 job、redis 走 `/scrape` 中继、
etcd/consul/rabbitmq/nacos 按角色生成多 target。`entry.sh` 带
`--web.external-url=http://prometheus.localhost/`、`--web.enable-lifecycle`、
保留 15d / 2GB。TSDB：solo `data/solo/tsdb`、ha `data/<node>/tsdb`。

```bash
make stack-up S=prometheus MODE=ha
make stack-status S=prometheus MODE=ha    # ready + up/down 计数
curl -s http://172.28.12.11:9090/api/v1/targets?state=active | head -c 200
curl -s http://172.28.12.11:9090/-/ready
```

全栈实测（18 个 profile 全起）：**30 targets / 30 up / 0 down**。目标数随形态变
（consul solo=1 / ha=3），所以**不要把绝对数字当断言**，只断言 `down=0`。

目标按**各栈当前部署形态**过滤（读 `.mode-<profile>` marker，DEC-47）：consul 跑 solo 时
只出 `.11`，不会把 `consul-2/3` 长期报成 down。改了某栈形态后要 `make render` +
`curl -X POST http://<ip>:9090/-/reload` 才同步。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| 改完配置不生效 | 先 `make render`，再 `curl -X POST http://<ip>:9090/-/reload`（或重建容器） |
| 容器内 `curl /targets` 被重定向到 `prometheus.localhost` | 带了 `--web.external-url`；容器内用 `-L` 或直接查 API |
| 两个副本数据不一致 | 设计如此：无集群/远程存储，各自 TSDB；查询只指 `prometheus-1` |
| 部分 target `down` | 对应栈未启动；目标已按部署形态过滤（DEC-47），因此真 `down` = **该起而没起来**，不是「未部署」，要当故障查 |
| 某栈从 solo 换 ha 后 prometheus 没跟着变 | 目标在 render 时算：`make render` 后 `POST /-/reload` |
| 磁盘爆 | retention 已限 15d/2GB，改大前先看 plan §9 预算 |

---

## alertmanager（`172.28.12.21`）

单节点，`9093`；`receiver: nul`（只收不发，不外发邮件/webhook）。存储 `data/alertmanager`，
Prometheus 的 `alerting` 段固定指向它。

```bash
make stack-up S=alertmanager MODE=solo
make stack-status S=alertmanager MODE=solo   # ready + 当前告警
curl -s http://172.28.12.21:9093/-/ready
curl -s http://172.28.12.21:9093/api/v2/alerts
```

坑：

| 现象 | 原因 / 处理 |
|---|---|
| 收不到告警通知 | 设计如此：`nul` receiver；要外发得加 receiver（超出 Lab 范围） |
| 改了路由没生效 | `alertmanager.yml` 是渲染产物；改 `render.sh` 后重建容器 |
| silence 重启后消失 | 存储路径应在 `data/alertmanager`；`stack-reset` 会清掉 |

---

## grafana（`172.28.12.31`）

单节点，`3000`；数据源与面板全部 provisioning（`data/active/grafana/provisioning/`）：
Prometheus（默认） + Jaeger，面板在 `DevOps` 目录（`overview.json`）。
账号取 `env/.env` 的 `GRAFANA_ADMIN_PASSWORD`。

```bash
make stack-up S=grafana MODE=solo
make stack-status S=grafana MODE=solo   # health + datasources + dashboards
make ui-open S=grafana                  # http://grafana.localhost
curl -s -u admin:"$GRAFANA_ADMIN_PASSWORD" http://172.28.12.31:3000/api/datasources
```

实测：`/api/datasources` 返回 `[Jaeger, Prometheus]`，`/api/search?type=dash-db` 返回
`DevOps 总览`（folder `DevOps`，uid `devops-overview`）。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| 数据源红叉 | URL 必须写容器 IP（`172.28.12.11:9090`），写 `localhost` 会指向 grafana 自己 |
| 改了 provisioning 不生效 | provisioning 只在启动时读；`docker compose restart grafana` |
| 面板不出现 | `dashboards.yml` 的 `path` 必须是**容器视角** `/data/active/grafana/dashboards`；compose 只挂 `./data:/data`，写宿主绝对路径时容器里不存在，provisioning 静默空列表（render.sh 已固定用 `CTR_DASHBOARDS`）|
| 登录失败 | 密码在 `env/.env`；改后需重建容器（env_file 在启动时注入） |

---

## jaeger（`172.28.12.32`，v2）

单节点，jaeger v2（OTel Collector 发行版）：`16686` UI/查询、`4317` OTLP gRPC、`4318` OTLP HTTP、
`8888` 自身指标、`13133` 健康（healthcheckv2）。存储用 Badger：
`data/jaeger/badger/{keys,values}`，`ttl.spans: 72h`。

```bash
make stack-up S=jaeger MODE=solo
make stack-status S=jaeger MODE=solo   # /status + /api/services
make trace-demo                      # 推一条 OTLP trace
curl -s http://172.28.12.32:16686/api/services
```

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| 启动报 `'badger' has invalid keys: directory` | v2 字段是 `directories.keys` / `directories.values`，不是单数 `directory` |
| 启动报 `'badger.ttl' has invalid keys: time` | TTL 字段是 `ttl.spans`（不是 `ttl.time`） |
| 重启后 trace 丢失 | Badger 目录在 `data/jaeger/`，但 `stack-reset` 会清；不要拿它当持久存储 |
| 健康检查 404 | v2 用 `healthcheckv2`（`/status`），不是 v1 的 `/` |

---

## nacos（`172.28.13.x`，3.x）

| mode | 容器 | 说明 |
|---|---|---|
| `solo` | `nacos-server-1` + `nacos-console` | 单 server，库在 `mysql-1:3306` |
| `ha` | `nacos-server-1..3` + `nacos-console` | 三 server（raft），库走 `mysql-router-1:6446` |

3.x 把控制台拆成独立进程：`server` 只管 API（`8848/9848/9849/7848`），`console`（`8080`）
是无状态前端，两者同镜像、用 `NACOS_DEPLOYMENT_TYPE` 区分。成员发现用
`NACOS_CORE_MEMBER_LOOKUP_TYPE=file` + `CLUSTER_CONF`（不依赖 address server）；
console 额外需要 `MEMBER_LIST`。表结构由 `pre.sh` 从 `config/mysql-schema.sql` 导入。

```bash
make stack-up S=nacos MODE=ha      # 前置：mysql 必须已起（solo 单机 / ha 成组）
make stack-status S=nacos MODE=ha  # actuator 200 + 关键指标 + console 200
make ui-open S=nacos               # http://nacos.localhost
curl -s http://172.28.13.11:8848/nacos/actuator/prometheus | head -3
```

实测 ha：三台 actuator `200`、console `200`；`nacos_config` 各节点 10 张表，
走 Router `6446` 可查。

### 前置依赖（跟 mysql 绑定，DEC-36 / R25）

nacos 的库表在 mysql，**没有 `nacos_config` 它就起不来**：`solo` 直连 `mysql-1:3306`，
`ha` 走 `mysql-router-1:6446`（`172.28.4.31`）。库只能在 MGR **成组之后**建（各节点本地
建库会让 GTID 分叉），由 `bootstrap.sh`（mysql 侧）与 `pre.sh`（nacos 侧）幂等保证。

因此启动顺序固定：`mysql` 成组 → `nacos`。`pre.sh` 在 `mysql-1` 未运行时只警告不报错
退出，nacos 会"看起来在启动、实际在 crash loop"。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| solo 启动报 `ServerMemberManager ... SocketTimeoutException` | `NACOS_SERVERS` 含未启动的 ha 节点；solo 只写自己 |
| 日志 `AddressServerMemberLookup ... Read timed out` | 3.x 默认走 address server；设 `NACOS_CORE_MEMBER_LOOKUP_TYPE=file` |
| console 报 `No server list provider found` | console 必须带 `MEMBER_LIST`（镜像转成 `-Dnacos.member.list`） |
| 容器一直 unhealthy | 3.x 禁用了 v1 console health API（404/503）；用 `/nacos/actuator/prometheus`，并留 `start_period: 120s`（启动 60–90s） |
| 启动前 mysql 没起 | `pre.sh` 只警告并退出，nacos 会因建表失败起不来；先起 mysql |
| 库表导入失败 | 导入命令要带 `-h127.0.0.1`（镜像默认 socket 路径不对），并先 `CREATE DATABASE nacos_config` |
| 三台 `Restarting (1)`，日志 `Unknown database 'nacos_config'` | 不是 nacos 的锅：MGR 未成组（daemon 重启后 `start_on_boot=OFF`），Router 后面没主。先 `make stack-up S=mysql MODE=ha` 再 `make stack-up S=nacos MODE=ha`（plan §8.4） |
| crash loop 后 `stack-up` 报 `container nacos-server-3 is unhealthy`，但库里已有表 | 前50 次重启留下的旧状态与 backoff；DB 已就绪时 `docker restart nacos-server-{1,2,3}` 即可转 healthy，不要急得 `stack-reset` |
| 查日志时看到 `Unknown database` 但现在已经好了 | crash loop 的旧日志还在；先确认可查（`select count(*) from nacos_config.config_info`），再看当前一轮启动 |

---

## docsify（`172.28.20.11`，文档浏览）

把仓库 `docs/` 变成一个可浏览的静态站点（docsify，无需构建）。**第 15 域，由 §17 预留块 `.20–.29` 启用**（后续新域从 `.21` 取）。

| mode | 容器 | 说明 |
|---|---|---|
| `solo` / `ha` | `docsify-1`（`172.28.20.11:3000`） | `mode=both`：两形态完全相同（无状态纯浏览，HA 全量豁免，DEC-46） |

挂载形状（嵌套）：

| 容器路径 | 宿主来源 | 读写 |
|---|---|---|
| `/docs` | `services/docsify/data/site/`（render 产物：`index.html` / `assets/` / `_sidebar.md`） | rw，但 `DOCSIFY_AUTO_INIT=false` 下容器不写任何文件 |
| `/docs/content` | 仓库 `docs/` | `:ro` |

内容不复制、不改写：站点只把 `docs/` 的 markdown 直读。镜像自带 `HEALTHCHECK`，骨架另声明 `wget --spider :3000/`（`bootstrap.sh` 探 `root / content / assets` 三个 200）。

```bash
make stack-up S=docsify MODE=solo
make stack-status S=docsify MODE=solo   # root 200 sidebar 200 content 200
make ui-open S=docsify                 # http://docsify.localhost（首页 = docs/plan.md）
curl -s http://172.28.20.11:3000/_sidebar.md
```

### 改内容 / 改样式

| 要改的东西 | 改哪里 | 生效方式 |
|---|---|---|
| 文档正文 | `docs/*.md` | 刷新浏览器（内容直读，无需重启） |
| 侧栏 | `scripts/render.sh` 的生成规则 | `make render`（`_sidebar.md` 只在 render 时重算） |
| 站点样式/标题 | `config/index.html.tpl` 的 `TITLE` / `$docsify` 配置 | `make render` + `make stack-reset S=docsify` |
| 前端资产（docsify.js / 主题） | `config/assets/` | 从镜像重新导出：`C=$(docker create rockben/docsify-server:<ver>) && docker cp "$C:/opt/docsify-template/assets/." services/docsify/config/assets/ && docker rm "$C"`，再 `make render` |

### solo ↔ ha 语义差异

无。`docsify-1` 是 `both` 节点，两形态同一个容器、同一份数据；`make failover-drill` 不适用（没有可切换的副本）。

### 重置

```bash
make stack-reset S=docsify MODE=solo
```

只清 `services/docsify/data/`（= 可重建的站点壳），**不碰仓库 `docs/`**（只读挂载，容器也写不了）。

### 坑

| 现象 | 原因 / 处理 |
|---|---|
| `bootstrap.sh` 报 `content=404` | `docs/` 未挂载或路径不对；先 `make render`，再看 `.generated/docsify.yml` 的第二条 volume 是否指向仓库 `docs/` |
| 容器启动即退出，日志报 `Docsify can't find index.html!` | `DOCSIFY_AUTO_INIT=false`（严格模式）且 `data/site/index.html` 不在；跑一次 `make render` 即补回 |
| 新加的 `docs/x.md` 不在侧栏 | `_sidebar.md` 是 render 时生成的快照；`make render` 后刷新 |
| 删了文档但侧栏还挂着它，点进去"像是有内容" | 同一个快照原因；且 `notFoundPage: "content/plan.md"` 会把 404 **静默回落到首页**，看上去像链接生效。删文档后也要 `make render`；判断真假请直看 `curl -o /dev/null -w '%{http_code}' :3000/content/<file>.md` |
| `docsify.localhost` 返回默认 `devops edge (nginx) is up` | nginx 还没 reload（新 `conf.d/*.conf` 要重读）：`docker exec nginx-1 nginx -s reload` 或 `make stack-reset S=nginx MODE=solo` |
| 页面能开但样式/脚本缺失（白底无侧栏） | `data/site/assets/` 丢了或与镜像版本不同步；`make render` 重拷，必要时按上表从镜像重新导出 |
| 子目录文档（`docs/archive/*`）里的相对链接点不开 | 链接按仓库目录书写（相对于文档自身），子目录内互指正常；跨回顶层请写 `../plan.md` |
| 想直接返宿主端口 8080（原草稿写法） | 违反 F06（只有 `nginx-1` 发布宿主端口）；走 `docsify.localhost` |
