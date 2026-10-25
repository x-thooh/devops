# devops 本地栈：输入只有 stock/network.ini + base/ + services/*/compose.yml
SHELL := /bin/bash

# 解释器与依赖一律来自仓库内 .venv（`make setup` 建，版本由 mise.toml 定，DEC-51）：
# 把它的 bin 前置到 PATH，所有目标里的 `python3` 就固定命中它，不再依赖宿主 PATH 顺序。
# 目录不存在时这一行无害（PATH 会跳过不存在项），仍退回宿主 python3。
export PATH := $(CURDIR)/.venv/bin:$(PATH)

# 依赖镜像：pypi 直连不通的机器改成 https://pypi.tuna.tsinghua.edu.cn/simple
PIP_INDEX_URL ?= https://pypi.org/simple

S ?=
# MODE 留空 = 不写死 solo：由 scripts/stack.sh 读 .mode-<profile> marker 沿用当前部署形态，
# 从没部署过的栈才回退 solo（DEC-50）
MODE ?=
TIER ?= a
N ?=

.PHONY: help setup render doctor up down ps tier-s tier-a tier-b tier-c tier-d tier-e tier-f \
	stack-up stack-down stack-status stack-reset stack-shell stack-logs \
	ui-open failover-drill trace-demo secrets secrets-show prepull backup-all

help:
	@echo "make setup                       建 .venv（mise 定 python 3.12）并装 PyYAML"
	@echo "make render                      ini + base + 骨架 -> compose.generated.yml"
	@echo "make doctor                      15 项体检（按已启用栈；第 15 项看运行态）"
	@echo "make up [TIER=a]                 起档位（默认 A；未实现栈自动跳过）"
	@echo "make down                        停整个 project"
	@echo "make tier-s|tier-a..tier-f       档位简写"
	@echo "make stack-up S=nginx [MODE=]   单栈（先 render，再按 mode 起 service；省略 MODE 则沿用当前形态）"
	@echo "make stack-status S=nginx       省略 MODE 则按 marker 查当前部署形态（ha 部署不会再看成 solo）"
	@echo "make stack-reset S=nginx"
	@echo "make stack-shell S=nginx N=nginx-1"
	@echo "make failover-drill S=pg [N=controller|broker（kafka）]"
	@echo "make trace-demo                 推一条 OTLP trace 给 jaeger"
	@echo "make ui-open S=grafana"
	@echo "make secrets / secrets-show"
	@echo "make prepull / backup-all"

render:
	@scripts/render-all.sh

# 工具链固定：mise.toml 定解释器版本，依赖只进仓库内 .venv（不污染宿主解释器）。
setup:
	@command -v mise >/dev/null 2>&1 || { echo "ERROR: 需要 mise（brew install mise），或手动建 .venv 后装 pyyaml" >&2; exit 2; }
	@mise trust >/dev/null 2>&1 || true
	@mise install
	@test -x .venv/bin/python3 || mise exec -- python -m venv .venv
	@.venv/bin/python -m pip install --index-url "$(PIP_INDEX_URL)" pyyaml
	@.venv/bin/python -c 'import sys, yaml; print("setup ok:", sys.version.split()[0], "| pyyaml", yaml.__version__)'

env/.env:
	@bash scripts/gen-secrets.sh

doctor:
	@scripts/doctor.sh

up: env/.env
	@scripts/tier-up.sh $(TIER)

down: env/.env
	@docker compose --env-file env/.env -f compose.generated.yml --profile '*' down --remove-orphans

ps: env/.env
	@docker compose --env-file env/.env -f compose.generated.yml --profile '*' ps

tier-s:
	@scripts/tier-up.sh s

tier-a:
	@scripts/tier-up.sh a

tier-b:
	@scripts/tier-up.sh b

tier-c:
	@scripts/tier-up.sh c

tier-d:
	@scripts/tier-up.sh d

tier-e:
	@scripts/tier-up.sh e

tier-f:
	@scripts/tier-up.sh f

stack-up: env/.env
	@test -n "$(S)" || { echo "ERROR: S=<profile> required（如 S=nginx）" >&2; exit 2; }
	@scripts/stack.sh up "$(S)" "$(MODE)"

stack-down: env/.env
	@test -n "$(S)" || { echo "ERROR: S=<profile> required" >&2; exit 2; }
	@scripts/stack.sh rm "$(S)" "$(MODE)"

stack-status: env/.env
	@test -n "$(S)" || { echo "ERROR: S=<profile> required" >&2; exit 2; }
	@scripts/stack.sh status "$(S)" "$(MODE)"

stack-reset: env/.env
	@test -n "$(S)" || { echo "ERROR: S=<profile> required" >&2; exit 2; }
	@scripts/stack.sh reset "$(S)" "$(MODE)"

stack-shell: env/.env
	@test -n "$(S)" || { echo "ERROR: S=<profile> required" >&2; exit 2; }
	@scripts/stack.sh shell "$(S)" "$(MODE)" "$(N)"

stack-logs: env/.env
	@test -n "$(S)" || { echo "ERROR: S=<profile> required" >&2; exit 2; }
	@scripts/stack.sh logs "$(S)" "$(MODE)"

ui-open:
	@test -n "$(S)" || { echo "ERROR: S=<service> required（如 S=grafana）" >&2; exit 2; }
	@python3 scripts/ini.py routes | grep -q "^$(S).localhost|" || { echo "ERROR: no route for $(S).localhost" >&2; exit 2; }
	@open "http://$(S).localhost"

failover-drill:
	@test -n "$(S)" || { echo "ERROR: S=<profile> required（如 S=pg）" >&2; exit 2; }
	@scripts/failover.sh "$(S)" "$(N)"

trace-demo:
	@scripts/trace-demo.sh

secrets:
	@bash scripts/gen-secrets.sh

secrets-show:
	@cat env/.env

prepull: env/.env
	@scripts/prepull.sh

backup-all:
	@scripts/backup-all.sh
