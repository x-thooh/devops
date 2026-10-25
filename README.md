# devops

单机 macOS + OrbStack 承载的本地基础设施栈。设计源是 [`docs/plan.md`](docs/plan.md)，
操作契约是 [`AGENTS.md`](AGENTS.md)，每期沉淀在 [`docs/stacks.md`](docs/stacks.md)。

## 当前状态

| 已实现 | 说明 |
|---|---|
| `stock/network.ini` | 15 域 / 17 目录 / 18 部署单元 / 71 行花名册；IP、端口、mode、路由唯一权威 |
| `base/` | `network.yml`（唯一 subnet）、`anchors.yml`、`images.yml`、`jvm/heap.env` |
| 生成器 | `scripts/ini.py` + `scripts/render-all.py` → `.generated/*.yml` + 聚合 compose |
| `services/*`（17 个） | nginx / pg / redis（复合栈：sentinel + cluster）/ mysql / mongo / kafka / rocketmq / rabbitmq / etcd / consul / nats / nacos / prometheus / alertmanager / grafana / jaeger / docsify |
| `services/nginx/` | solo（nginx-1）与 ha（nginx-1 + nginx-2），路由由 `[routes]` 生成 |
| `make doctor` | 15 项体检，按"已启用的栈"取集合（第 15 项按部署形态校运行态） |
| `Makefile` | render / doctor / up / tier / stack-* / prepull / backup-all / ui-open / failover-drill / trace-demo |

各栈的起停 / 验证 / 演练 / 重置口径见 [`docs/stacks.md`](docs/stacks.md)（每栈一章）。

## 前提

- macOS + OrbStack，`docker context` 必须是 `orbstack`。
- Docker Compose v2.20+（实测 v5.5.0）。
- Python 3.9+ 与 PyYAML（`python3 -c 'import yaml'`）。
- 宿主 80 端口空闲；`172.28.0.0/16` 未被 VPN / 其它网桥占用。

## 快速开始

```bash
make secrets                  # 生成 env/.env（chmod 600，已存在则不覆盖）
make render                   # ini + base + 骨架 → compose.generated.yml
make doctor                   # 15 项体检

make stack-up S=nginx MODE=solo
curl -s http://127.0.0.1/healthz                  # ok
curl -s -o /dev/null -w '%{http_code}\n' \
     -H 'Host: grafana.localhost' http://127.0.0.1/  # 502（grafana 未起，说明路由已通）
docker exec nginx-1 date                          # CST +0800

make stack-up S=nginx MODE=ha
curl -s http://172.28.0.12/healthz                # nginx-2 直连 200
make stack-status S=nginx MODE=ha

make down
```

`make up` 默认起 A 档，未实现的栈会打印 `skip` 而不会失败：

```bash
make up            # = make tier-a
make tier-s        # solo 全栈（未实现的栈自动 skip）
```

## 输入 / 输出契约

| 路径 | 角色 | 提交 |
|---|---|---|
| `stock/network.ini` | IP / 端口 / role / mode / 路由的唯一权威 | 是 |
| `base/network.yml` | 唯一 `subnet` / `gateway` | 是 |
| `base/anchors.yml` | `restart` / `logging` / `TZ` / 健康检查默认 | 是 |
| `base/images.yml` | 镜像唯一清单 | 是 |
| `services/<stack>/compose.yml` | **手写骨架**：`services` / `container_name` / `profiles` / `volumes` / `healthcheck` / `x-image` | 是 |
| `services/<stack>/config/` | 配置模板 | 是 |
| `.generated/<stack>.yml` | 渲染后的单栈 compose | 否 |
| `compose.generated.yml`、根 `compose.yml` | 聚合入口（同一内容） | 否 |
| `services/<stack>/data/` | 运行时状态与渲染产物 | 否 |
| `env/.env` | 本地密钥与覆盖 | 否 |

硬约束：

- `services/<stack>/compose.yml` 里禁止出现 `image` / `restart` / `logging` / `networks` /
  `network_mode` / `TZ` / `subnet`；镜像写 `x-image: <base/images.yml 的键>`。
- 每个 service 必须恰好带一个 `profiles`，且与 ini 的 `[stack.*]` 段一致。
- 只有 `nginx-1` 可以声明宿主 `ports`；其它 UI 一律走 `<svc>.localhost`。
- 改 IP / 端口 / 路由只改 `stock/network.ini`，然后 `make render`；不要手改生成物。
- `solo ↔ ha` 互斥：`stack.sh up` 会自动 `stop` 不属于当前 mode 的节点（不删数据）。

## 常用命令

| 命令 | 作用 |
|---|---|
| `make render` | ini + base + 各栈模板 → 聚合 compose + `data/` 下的真实配置 |
| `make doctor` | 15 项体检；失败项按提示修，不要手工绕过 |
| `make up` / `make down` | 起 / 停当前档位（默认 A） |
| `make tier-s` … `tier-f` | 档位启动；未实现栈自动跳过 |
| `make stack-up S=<profile> MODE=solo\|ha` | 单栈起停；`S` 是 profile，不是目录 |
| `make stack-status S=<profile>` | 容器状态 + 栈自带探测；省略 `MODE` 则按当前部署形态（DEC-50） |
| `make stack-reset S=<profile>` | 停容器 → 删本 profile 的 `data/` 子树 → 重渲染 → 重启 |
| `make stack-shell S=<profile> N=<node>` | 进容器 |
| `make ui-open S=grafana` | 打开 `http://grafana.localhost`（需对应栈已起）；docsify 站点同理 |
| `make prepull` / `make backup-all` | 预拉镜像 / 归档 `services/*/data` |

> `S` 填部署单元名：`redis` 目录下是 `redis-sentinel` / `redis-cluster`，**没有 `S=redis`**。

## 验证口径（P0）

- `make doctor`：15 PASS / 0 WARN / 0 FAIL。
- `MODE=solo`：只有 `nginx-1` 一个容器；`nginx-2` 为 `Exited`。
- `MODE=ha`：`nginx-1` + `nginx-2` 均 healthy；`172.28.0.12/healthz` 返回 200。
- 容器内 `date` 显示 `CST +0800`。
- `grafana.localhost` 在观测栈未起时返回 502（不是 404 / 000）。
- `git status` 不出现 `data/`、`env/.env`、`.generated/`、根 `compose*.yml`。

## 故障排查

| 症状 | 处理 |
|---|---|
| `port is already allocated` | `lsof -nP -iTCP:80 -sTCP:LISTEN`；或改 `env/.env` 的 `ENTRY_HTTP_PORT` |
| doctor 第 7 项失败 | `docker context use orbstack` |
| doctor 第 8 项失败 | `netstat -rn -f inet \| grep 172.28`；停掉占用该网段的 VPN / 网桥 |
| `ModuleNotFoundError: yaml` | `python3 -m pip install pyyaml` |
| 改了 nginx 配置不生效 | `make stack-reset S=nginx MODE=solo`（`stack-up` 不会重建未变化的容器） |
| 502 / 000 分不清 | 502 = nginx 已收到请求但 upstream 未起；000 = 入口本身不可达 |
| Docker 重启后容器都 `Up`、但 nacos 一直 `Restarting` | `restart` 只复活容器，MGR 不会自动成组（`start_on_boot=OFF` 是设计）；按依赖重跑 `make stack-up S=mysql MODE=ha` → `S=nacos MODE=ha`（plan §8.4） |
| grafana 面板列表为空 | `dashboards.yml` 的 `path` 必须是容器视角 `/data/…`；`make render` 后 `docker compose restart grafana` |

## 目录

```text
base/          共享不变量（network / anchors / images / jvm）
stock/         network.ini（唯一权威）
services/      各栈骨架、模板、脚本；data/ 为运行时产物
scripts/       ini 解析、渲染、doctor、stack/tier 操作
.env（本地）   入口端口、镜像覆盖、凭据；由 scripts/gen-secrets.sh 生成
docs/          plan.md（设计源）、stacks.md（每期沉淀）、pending-decisions.md
```
