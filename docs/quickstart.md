# Quickstart：逐栈起停（solo / ha）

> 一页速查：18 个部署单元（profile）各自的 solo 与集群（ha）启动命令。
> 设计源见 [`plan.md`](plan.md)（§5 花名册 / §8 组件契约），每栈验证与演练口径见 [`stacks.md`](stacks.md)，
> 执行层约束见 [`../AGENTS.md`](../AGENTS.md)。本页只回答「用什么命令起、起哪几个容器、切形态要注意什么」。

## 前提

命令模板：`make stack-up S=<profile> MODE=solo|ha`。首次或换机器先跑：

```bash
make setup      # mise 定 python 3.12 + 建仓库内 .venv + 装 PyYAML（DEC-51）
make secrets    # 生成 env/.env（已存在则不覆盖，chmod 600）
make render     # ini + base + 骨架 → 聚合 compose + 各栈 .data/ 配置
make doctor     # 15 项体检
```

## 一键起全栈

```bash
make tier-s                       # 全部 solo（每栈单实例，28 容器基线）
make up TIER=a                    # A 档默认形态（档位定义见 Makefile）
```

## 逐栈命令：solo 与 ha 对照

下表 `S` 一律填 **profile 名**（不是目录名）。容器构成取自 `stock/network.ini` 的真实 service。

### 接入层

| profile | solo 起 | ha 起 |
|---|---|---|
| `nginx` | nginx-1 | nginx-1 nginx-2 |

```bash
make stack-up S=nginx MODE=solo
make stack-up S=nginx MODE=ha
```

### 数据库

| profile | solo 起 | ha 起 |
|---|---|---|
| `pg` | patroni-1 pg-exporter | patroni×3 + pg-dcs(etcd)×3 + pg-haproxy×2 + exporter |
| `mysql` | mysql-1 + exporter | MGR mysql×3 + router×2 + exporter |
| `mongo` | mongo-1 + exporter | 副本集 mongo×3 + exporter |

```bash
make stack-up S=pg     MODE=solo
make stack-up S=pg     MODE=ha
make stack-up S=mysql  MODE=solo
make stack-up S=mysql  MODE=ha
make stack-up S=mongo  MODE=solo
make stack-up S=mongo  MODE=ha
```

### 消息

| profile | solo 起 | ha 起 |
|---|---|---|
| `kafka` | kafka-1 + exporter | broker×3 + controller×3 + exporter |
| `rocketmq` | namesrv-1 + broker-1 + exporter | namesrv×2 + DLedger broker×3 + exporter |
| `rabbitmq` | rabbit-1 | rabbit×3 |
| `redis-sentinel` | redis-master + exporter | 1M+2R+3S + exporter |
| `redis-cluster` | rc-1 + exporter | 3M+3R + exporter |

```bash
make stack-up S=kafka          MODE=solo
make stack-up S=kafka          MODE=ha
make stack-up S=rocketmq       MODE=solo
make stack-up S=rocketmq       MODE=ha
make stack-up S=rabbitmq       MODE=solo
make stack-up S=rabbitmq       MODE=ha
make stack-up S=redis-sentinel MODE=solo
make stack-up S=redis-sentinel MODE=ha
make stack-up S=redis-cluster  MODE=solo
make stack-up S=redis-cluster  MODE=ha
```

### 共识 / 注册配置

| profile | solo 起 | ha 起 |
|---|---|---|
| `etcd` | etcd-1 | etcd×3 |
| `consul` | consul-1 | consul×3 |
| `nats` | nats-1 + exporter | nats×3 + exporter |
| `nacos` | nacos-server-1 + console | server×3 + console |

```bash
make stack-up S=etcd    MODE=solo
make stack-up S=etcd    MODE=ha
make stack-up S=consul  MODE=solo
make stack-up S=consul  MODE=ha
make stack-up S=nats    MODE=solo
make stack-up S=nats    MODE=ha
make stack-up S=nacos   MODE=solo
make stack-up S=nacos   MODE=ha
```

### 观测四栈（单实例栈）

`prometheus` ha 语义是冗余采集而非故障转移；`alertmanager` / `grafana` / `jaeger` / `docsify` 为 HA 全量豁免，`ha` 与 `solo` 同规模。

| profile | solo 起 | ha 起 |
|---|---|---|
| `prometheus` | prometheus-1 | prometheus×2 |
| `alertmanager` | alertmanager | alertmanager（同规模） |
| `grafana` | grafana | grafana（同规模） |
| `jaeger` | jaeger | jaeger（同规模） |
| `docsify` | docsify-1 | docsify-1（同规模） |

```bash
make stack-up S=prometheus   MODE=solo
make stack-up S=prometheus   MODE=ha
make stack-up S=alertmanager MODE=solo
make stack-up S=grafana      MODE=solo
make stack-up S=jaeger       MODE=solo
make stack-up S=docsify      MODE=solo
```

## 注意事项

1. **`S` 是 profile 名不是目录名**：`redis/` 目录下是 `redis-sentinel` / `redis-cluster` 两组互斥 profile，没有 `S=redis`。
2. **省略 `MODE` 不写死 solo**：`stack.sh` 读 `.data/.mode-<profile>` marker 沿用当前部署形态，从没部署过才回退 solo（DEC-50）。要指定形态必须显式写 `MODE=solo|ha`。
3. **两段式启动**：`stack-up` = 起容器 → bootstrap → 等健康（DEC-52），需先引导才转健康的栈（mysql Router、nacos schema）不会死锁。
4. **共识 / 有状态栈 solo↔ha 切换先 reset**：consul / etcd / mysql / mongo / kafka / redis-cluster 等 Raft/MGR 成员关系不兼容，残留数据会造成「假集群」或身份冲突。

   ```bash
   make stack-reset S=<profile> MODE=ha    # 停容器 → 删本 profile 的 .data 子树 → 重渲染 → 起
   ```

   无状态栈（nginx / grafana / jaeger / docsify / prometheus / alertmanager）可直接就地 `stack-up ... MODE=ha`。
5. **依赖顺序**：`nacos` 需 `mysql` 先起（ha 经 Router `172.28.4.31:6446`，solo 直连 `mysql-1:3306`）；`pg` 的 ha 自带 pg-dcs(etcd)，无需外部 etcd。

## 验证与状态

```bash
make stack-status S=<profile>          # 容器状态 + 栈自带探测（省略 MODE 按当前形态）
make doctor                            # 15 项体检（第 15 项按 marker 校验运行态）
make stack-shell  S=<profile> N=<node> # 进容器，如 make stack-shell S=kafka N=kafka-1
make ui-open      S=grafana            # 宿主浏览器打开 <svc>.localhost（需对应栈已起）
```

全栈 solo 的成功基线：`make doctor` 15 PASS / 0 WARN / 0 FAIL，28 容器全部 healthy，18 个 marker 均为 `solo`。
