# nginx（入口栈）

> 组件级说明：只回答"这个目录里有什么、怎么用、踩过什么坑"。
> 设计源见 [`docs/plan.md`](../../docs/plan.md) §15，逐栈操作口径见 [`docs/stacks.md`](../../docs/stacks.md) 的「nginx」章。

## 定位

- 17 个组件目录中唯一的 **edge 域**（`172.28.0.0/24`），也是**唯一发布宿主端口的栈**。
- 只做两件事：入口（`/healthz` + 未匹配域名兜底）、按 `Host` 把 `*.localhost` 反代到固定容器 IP。
- 无状态：不建集群、没有持久数据；入口**只有单实例**，没有 ha 形态（DEC-53），故 HA 豁免。

## 形态

单实例（`mode=both`：solo / ha 共用同一个节点身份，两形态起的容器完全相同）：

| mode | 容器 | 宿主端口 | 说明 |
|---|---|---|---|
| `solo` / `ha` | `nginx` | `HTTP_PORT`（默认 80） | 唯一入口；`MODE` 不改变规模 |

双实例既无 VIP、又同宿主同 daemon，切不过去，重复的只是同一份配置 —— 属假 HA，v4.6 已删除（DEC-53）。

节点 IP / 端口 / mode 一律以 `stock/network.ini` 的 `[stack.nginx]` 为准（本文不复制这些值，避免双份事实源）：

```bash
python3 scripts/ini.py rows | awk -F'|' '$1 == "nginx"'
python3 scripts/ini.py routes            # host|upstream_ip|port|capability
```

## 数据流

```text
stock/network.ini [stack.nginx] --render-all.py--> .generated/nginx.yml --compose--> 容器
stock/network.ini [routes]      --render.sh-----> .data/conf.d/<host>.conf --reload--> 运行中的 nginx
```

- 路由只有 ini 一个事实源（DEC-22）；`.data/conf.d/` 是渲染产物，手改会被下一次 render 冲掉（DEC-11）。

## 文件职责

| 路径 | 角色 | 入库 |
|---|---|---|
| `compose.yml` | 手写骨架：`x-image` / `profiles` / 挂载 / 健康检查 | 是 |
| `config/nginx.conf` | 模板：默认站点 `/healthz`、gzip、WebSocket map、`include conf.d/*.conf` | 是 |
| `scripts/render.sh` | `[routes]` → `.data/conf.d/<host>.conf`（host / IP / 端口白名单校验） | 是 |
| `scripts/bootstrap.sh` | `up` 后对运行节点 `nginx -t` → `nginx -s reload`，让新路由生效 | 是 |
| `scripts/status.sh` | 只读探测：入口健康 / 第一条路由 / `nginx -t` | 是 |
| `scripts/reset.sh` | 清 `.data/conf.d/*.conf` 后重渲染（无状态，不删数据） | 是 |
| `.data/conf.d/` | 渲染产物 | 否 |
| `.data/.mode-nginx` | 当前部署形态 marker（`solo` / `ha`，DEC-50） | 否 |

## 命令

```bash
make stack-up   S=nginx MODE=solo      # 起（MODE=ha 规模相同，无 ha）
make stack-status S=nginx              # 省略 MODE = 沿用 marker（DEC-50）
make stack-reset  S=nginx              # 清路由配置 → 重渲染 → 重启
```

## 改路由 / 改配置

1. 改 `stock/network.ini` 的 `[routes]`（或 `config/nginx.conf`）。
2. `make stack-up S=nginx` —— 内部依次 render → `bootstrap.sh` reload → 等健康。

> 只跑 `make render` 不行：它只写宿主上的 `.data/conf.d/`，而 `up` 也不会重建未变化的容器，
> nginx 更不会自己去读新目录。`bootstrap.sh` 就是补这一段；`nginx -t` 不通过时 `stack-up` 直接失败，
> 不会静默沿用旧配置（旧 worker 继续服务是最难发现的一种"改了没生效"）。

## 验证

```bash
curl -s http://127.0.0.1/healthz                 # ok（HTTP_PORT≠80 时换成实际端口）
docker exec nginx nginx -t                     # syntax is ok
docker exec nginx date                         # CST +0800

# 路由已通：观测栈未起时是 502，不是 404 / 000
curl -s -o /dev/null -w '%{http_code}\n' \
     -H 'Host: grafana.localhost' http://127.0.0.1/
```

- `502` = nginx 已收到请求但上游未起（路由是通的）；`000` = 入口本身不可达（容器未起 / 端口不对）。
- 未知 `Host` 会命中默认站点，返回 `devops edge (nginx) is up` —— 看到这句通常说明**路由没载入**。

## 坑

只列最常撞的；完整表见 [`docs/stacks.md`](../../docs/stacks.md) 的「nginx → 坑」。

| 现象 | 原因 / 处理 |
|---|---|
| 改完 `[routes]` 仍返回默认站点文案 | 没 reload；用 `make stack-up S=nginx`，别只 `make render` |
| `port is already allocated` | 宿主 80 被占；`lsof -nP -iTCP:80 -sTCP:LISTEN`，或改 `env/.env` 的 `HTTP_PORT` |
| 浏览器打不开 `*.localhost` | 只有宿主能解析；容器之间必须用 IP / 服务名（R15） |
| curl 200 但浏览器打不开 | 多半是服务端之外的原因：地址栏被补成 `https://`（443 未启用，DEC-42）、DoH、代理插件 |
| 想要入口冗余 / 双活 | 本环境做不到：单机 + 单 daemon，双实例同故障域（DEC-53）；真冗余需多机 + VIP |
