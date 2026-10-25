#!/usr/bin/env python3
"""15 项体检（plan §6.3）。

范围约定：第 4/5/10/11/13/14/15 项按“已启用的栈”取集合——只检查
`services/<dir>/compose.yml` 已存在的目录；未开工的栈不参与判定。
第 15 项额外按“已部署的 profile”取集合（读 `.data/.mode-*` marker）。
"""
from __future__ import annotations

import ipaddress
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ini import (  # noqa: E402
    IniError,
    Row,
    expand_ports,
    parse_ini,
    rows_by_name,
    services_for,
    stack_dir,
    stack_sections,
)

NETWORK = ipaddress.ip_network("172.28.0.0/16")
ENV_FILE = ROOT / "env" / ".env"
ANCHORS_FILE = ROOT / "base" / "anchors.yml"
IMAGES_FILE = ROOT / "base" / "images.yml"
GENERATED = ROOT / ".generated"

# 每个 profile 的 HA 角色数量（ini 结构，不是运行时状态）
EXPECTED_HA_ROLES: dict[str, dict[str, int]] = {
    "nginx": {"entry": 2},
    "pg": {"leader": 1, "replica": 2, "dcs": 3, "proxy": 2},
    "redis-sentinel": {"master": 1, "replica": 2, "sentinel": 3},
    "redis-cluster": {"master": 3, "replica": 3},
    "mysql": {"mgr-member": 3, "proxy": 2},
    "mongo": {"primary": 1, "secondary": 2},
    "kafka": {"broker": 3, "controller": 3},
    "rocketmq": {"namesrv": 2, "dledger": 3},
    "rabbitmq": {"seed": 1, "member": 2},
    "etcd": {"member": 3},
    "consul": {"bootstrap": 1, "server": 2},
    "nats": {"member": 3},
    "prometheus": {"metrics": 2},
    "alertmanager": {"alerts": 1},
    "grafana": {"ui": 1},
    "jaeger": {"trace": 1},
    "nacos": {"server": 3, "console": 1},
    "docsify": {"docs": 1},
}

QUORUM_ROLES: dict[str, tuple[str, ...]] = {
    "etcd": ("member",),
    "consul": ("bootstrap", "server"),
    "mongo": ("primary", "secondary"),
    "rabbitmq": ("seed", "member"),
}

FORBIDDEN_AUTHORED = {"image", "restart", "logging", "networks", "network_mode", "subnet"}


def load_yaml(path: Path) -> Any:
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    if ENV_FILE.exists():
        for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    for key, value in os.environ.items():
        if key.startswith("IMG_") or key == "IMAGE_PREFIX":
            env[key] = value
    return env


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=False)


def enabled_dirs() -> list[Path]:
    return sorted(p.parent for p in (ROOT / "services").glob("*/compose.yml"))


def enabled_profiles(stacks: dict[str, list[Row]]) -> list[str]:
    dirs = {p.name for p in enabled_dirs()}
    return [s.removeprefix("stack.") for s in stacks if stack_dir(s.removeprefix("stack.")) in dirs]


def generated_doc(directory: str) -> dict[str, Any] | None:
    path = GENERATED / f"{directory}.yml"
    if not path.exists():
        return None
    doc = load_yaml(path)
    services = doc.get("services")
    return services if isinstance(services, dict) else None


def authored_doc(directory: str) -> dict[str, Any]:
    doc = load_yaml(ROOT / "services" / directory / "compose.yml")
    services = doc.get("services")
    if not isinstance(services, dict):
        raise ValueError(f"services/{directory}/compose.yml: missing services map")
    return services


# ---------------------------------------------------------------- checks


def check_1_ip_range(stacks: dict[str, list[Row]]) -> tuple[str, str]:
    problems: list[str] = []
    count = 0
    global_rows = {row.name: row.ip for row in stacks.get("global", [])}
    if global_rows.get("subnet") != "172.28.0.0/16":
        problems.append(f"[global] subnet={global_rows.get('subnet')!r}，应为 172.28.0.0/16")
    if global_rows.get("gateway") != "172.28.0.1":
        problems.append(f"[global] gateway={global_rows.get('gateway')!r}，应为 172.28.0.1")
    for rows in stack_sections(stacks).values():
        for row in rows:
            count += 1
            try:
                addr = ipaddress.ip_address(row.ip)
            except ValueError:
                problems.append(f"L{row.lineno} {row.name}: bad IP {row.ip!r}")
                continue
            if addr not in NETWORK:
                problems.append(f"L{row.lineno} {row.name}: {row.ip} outside /16")
            if addr.packed[-1] in (0, 1, 255):
                problems.append(f"L{row.lineno} {row.name}: {row.ip} reserved octet")
    if problems:
        return "FAIL", "; ".join(problems)
    return "PASS", f"{count} 行均在 172.28.0.0/16 且未占用 .0/.1/.255"


def check_2_ip_unique(stacks: dict[str, list[Row]]) -> tuple[str, str]:
    seen: dict[str, Row] = {}
    problems: list[str] = []
    for rows in stack_sections(stacks).values():
        for row in rows:
            if row.ip in seen:
                problems.append(f"{row.ip}: {row.name}(L{row.lineno}) 与 {seen[row.ip].name}(L{seen[row.ip].lineno})")
            else:
                seen[row.ip] = row
    if problems:
        return "FAIL", "; ".join(problems)
    return "PASS", f"{len(seen)} 个 IP 无重复"


def check_3_ports(stacks: dict[str, list[Row]]) -> tuple[str, str]:
    seen: dict[tuple[str, int], Row] = {}
    problems: list[str] = []
    for rows in stack_sections(stacks).values():
        for row in rows:
            try:
                ports = list(expand_ports(row.ports))
            except ValueError:
                problems.append(f"L{row.lineno} {row.name}: bad port spec {row.ports!r}")
                continue
            for port in ports:
                key = (row.ip, port)
                if key in seen:
                    problems.append(f"{row.ip}:{port} {row.name} 与 {seen[key].name} 冲突")
                else:
                    seen[key] = row
    if problems:
        return "FAIL", "; ".join(problems)
    return "PASS", "同一 IP 内端口无重复（含 a-b 展开）"


def check_4_compose(stacks: dict[str, list[Row]]) -> tuple[str, str]:
    problems: list[str] = []
    by_name = rows_by_name(stacks)
    images = load_yaml(IMAGES_FILE)
    env = load_env()
    checked = 0

    for directory in enabled_dirs():
        author = authored_doc(directory.name)
        rendered = generated_doc(directory.name)
        if rendered is None:
            problems.append(f"services/{directory.name}: 缺少 .generated/{directory.name}.yml，请 make render")
            continue
        for name, service in author.items():
            if not isinstance(service, dict):
                continue
            for key in sorted(FORBIDDEN_AUTHORED & service.keys()):
                problems.append(f"{name}: 骨架出现 {key}（应只在 base/）")
        for name, service in rendered.items():
            checked += 1
            row = by_name.get(name)
            if row is None:
                problems.append(f"{name}: 渲染结果不在 ini")
                continue
            ip = ((service.get("networks") or {}).get("devnet") or {}).get("ipv4_address")
            if ip != row.ip:
                problems.append(f"{name}: rendered {ip} != ini {row.ip}")
            key = (author.get(name) or {}).get("x-image")
            expected = env.get(f"IMG_{key}") or env.get(f"IMG_{str(key).upper()}") or images.get(key)
            prefix = env.get("IMAGE_PREFIX", "").strip()
            if expected and prefix:
                expected = prefix.rstrip("/") + "/" + expected.lstrip("/")
            if not expected:
                problems.append(f"{name}: x-image={key!r} 不在 base/images.yml")
            elif service.get("image") != expected:
                problems.append(f"{name}: image {service.get('image')!r} != {expected!r}")

    if problems:
        return "FAIL", "; ".join(problems)
    return "PASS", f"{len(enabled_dirs())} 个目录 / {checked} 个 service 的 IP 与镜像均来自唯一源"


def check_5_profiles(stacks: dict[str, list[Row]]) -> tuple[str, str]:
    problems: list[str] = []
    by_name = rows_by_name(stacks)
    checked = 0
    for directory in enabled_dirs():
        for name, service in authored_doc(directory.name).items():
            checked += 1
            profiles = service.get("profiles") if isinstance(service, dict) else None
            if not isinstance(profiles, list) or len(profiles) != 1:
                problems.append(f"{name}: profiles 必须且只能有 1 个")
                continue
            profile = str(profiles[0])
            row = by_name.get(name)
            if row is None:
                problems.append(f"{name}: 不在 ini")
            elif row.profile != profile:
                problems.append(f"{name}: profile {profile!r} != ini {row.profile!r}")
    if problems:
        return "FAIL", "; ".join(problems)
    return "PASS", f"{checked} 个 service 均恰好带 1 个 profile"


def check_6_ports_publish() -> tuple[str, str]:
    problems: list[str] = []
    for directory in enabled_dirs():
        for label, services in (
            ("authored", authored_doc(directory.name)),
            ("generated", generated_doc(directory.name) or {}),
        ):
            for name, service in services.items():
                if not isinstance(service, dict):
                    continue
                if "ports" in service and name != "nginx-1":
                    problems.append(f"{directory.name}/{label}: {name} 声明了宿主 ports")
                if service.get("network_mode") == "host":
                    problems.append(f"{directory.name}/{label}: {name} 使用 host 网络")
    if problems:
        return "FAIL", "; ".join(problems)
    return "PASS", "只有 nginx-1 发布宿主端口"


def check_7_context() -> tuple[str, str]:
    result = run(["docker", "context", "show"])
    context = result.stdout.strip()
    if result.returncode != 0:
        return "FAIL", f"docker context show 失败：{result.stderr.strip()}"
    if context != "orbstack":
        return "FAIL", f"当前 context={context!r}，方案前提是 orbstack"
    return "PASS", "docker context = orbstack"


def _parse_route_dest(dest: str) -> ipaddress.IPv4Network | None:
    if dest in ("default", ""):
        return None
    if "/" in dest:
        addr, prefix = dest.split("/", 1)
    else:
        addr = dest
        octets = addr.split(".")
        # macOS netstat 会缩写目的地址：172.28 -> /16、172.28.0 -> /24
        prefix = str(len(octets) * 8) if 1 <= len(octets) <= 4 else "32"
    parts = addr.split(".")
    if len(parts) == 4:
        pass
    elif len(parts) < 4 and addr:
        parts = parts + ["0"] * (4 - len(parts))
    else:
        return None
    try:
        net = ipaddress.ip_network(".".join(parts) + "/" + prefix, strict=False)
    except ValueError:
        return None
    return net if isinstance(net, ipaddress.IPv4Network) else None


def check_8_route_overlap() -> tuple[str, str]:
    """宿主 172.28.0.0/16 路由只允许来自 devnet 自身（OrbStack 管路），第三方一律算冲突。

    devnet 建好之后，OrbStack 会在宿主留下两条 172.28.* 路由：
      - `172.28 -> UC -> bridgeXXX`：devnet 的网段路由（宿主的落点就是这条 bridge）
      - `172.28.0.0 -> UHLWbI -> lo0`：该 bridge 本机地址的 ifscope 主机路由
    两者都是本方案自己造出来的，先按“哪条 bridge 持有 /16 网段路由”认出 devnet，
    再只豁免这条 bridge 及其 lo0 镜像路由；VPN（utun*）、en0 或**别的** docker 网桥
    上的 172.28.* 仍判 FAIL——那才是真正要先解的冲突。
    """
    result = run(["netstat", "-rn", "-f", "inet"])
    if result.returncode != 0:
        return "WARN", f"netstat 失败，跳过：{result.stderr.strip()}"

    rows: list[tuple[str, ipaddress.IPv4Network, str, str]] = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if not fields:
            continue
        route = _parse_route_dest(fields[0])
        if route is None or route.prefixlen < 16 or not route.overlaps(NETWORK):
            continue
        flags = fields[2] if len(fields) > 2 else ""
        iface = fields[3] if len(fields) > 3 else ""
        rows.append((line.strip(), route, flags, iface))

    devnet_bridges = {iface for _, route, _, iface in rows if route == NETWORK and iface.startswith("bridge")}

    hits: list[str] = []
    expected = 0
    for line, route, flags, iface in rows:
        if iface in devnet_bridges and route.subnet_of(NETWORK):
            expected += 1
            continue
        # 本机地址被导到 lo0 的 ifscope 主机路由（UHLWbI），属于同一套 devnet 管路
        if devnet_bridges and iface == "lo0" and "H" in flags and route.subnet_of(NETWORK):
            expected += 1
            continue
        hits.append(line)
    if hits:
        return "FAIL", "宿主已有非 devnet 的 172.28.0.0/16 路由（先解 VPN/其它网桥冲突）：" + " | ".join(hits[:5])
    if expected:
        bridges = "/".join(sorted(devnet_bridges)) or "bridge"
        return "PASS", f"{expected} 条 172.28.* 路由均来自 devnet 自身（{bridges}），无第三方重叠"
    return "PASS", "宿主路由与 172.28.0.0/16 无重叠"


def check_9_env() -> tuple[str, str]:
    if not ENV_FILE.exists():
        return "WARN", "env/.env 不存在，运行 bash scripts/gen-secrets.sh"
    mode = ENV_FILE.stat().st_mode & 0o777
    if mode != 0o600:
        return "WARN", f"env/.env 权限为 {mode:o}，应为 600：chmod 600 env/.env"
    return "PASS", "env/.env 存在且权限 600"


def check_10_data() -> tuple[str, str]:
    notes: list[str] = []
    for directory in enabled_dirs():
        data = directory / ".data"
        if not data.exists():
            notes.append(f"services/{directory.name}/.data 不存在（make render 会创建）")
        elif not os.access(data, os.W_OK):
            notes.append(f"services/{directory.name}/.data 不可写")
    if notes:
        return "WARN", "; ".join(notes)
    return "PASS", f"{len(enabled_dirs())} 个已启用目录的 .data/ 可写"


def check_11_topology(stacks: dict[str, list[Row]], profiles: list[str]) -> tuple[str, str]:
    problems: list[str] = []
    notes: list[str] = []
    for profile in profiles:
        rows = stacks.get(f"stack.{profile}", [])
        roles: dict[str, int] = {}
        for row in rows:
            roles[row.role] = roles.get(row.role, 0) + 1
        for role, expected in EXPECTED_HA_ROLES.get(profile, {}).items():
            if roles.get(role, 0) != expected:
                problems.append(f"{profile}: role {role} 期望 {expected}，实际 {roles.get(role, 0)}")
        quorum_roles = QUORUM_ROLES.get(profile)
        if quorum_roles:
            quorum_total = sum(roles.get(role, 0) for role in quorum_roles)
            if quorum_total % 2 == 0:
                problems.append(f"{profile}: quorum 成员总数为偶数（{quorum_total}）")
        solo = services_for(stacks, profile, "solo")
        ha = services_for(stacks, profile, "ha")
        if not solo:
            problems.append(f"{profile}: solo 形态无 service")
        if not ha:
            problems.append(f"{profile}: ha 形态无 service")
        notes.append(f"{profile} solo={len(solo)}/ha={len(ha)}")
    if problems:
        return "FAIL", "; ".join(problems)
    return "PASS", "；".join(notes) if notes else "无已启用栈"


def check_12_drill() -> tuple[str, str]:
    anchors = load_yaml(ANCHORS_FILE).get("x-common", {})
    restart = anchors.get("restart") if isinstance(anchors, dict) else None
    if restart != "unless-stopped":
        return "FAIL", f"base/anchors.yml restart={restart!r}，应为 unless-stopped"
    offenders: list[str] = []
    candidates = list((ROOT / "scripts").glob("*.sh")) + list((ROOT / "services").glob("*/scripts/*.sh"))
    candidates.append(ROOT / "Makefile")
    pattern = re.compile(r"\bdocker\s+kill\b|\bdocker\s+rm\b")
    for path in candidates:
        if not path.exists():
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if pattern.search(line) and "failover-drill" not in line:
                offenders.append(f"{path.relative_to(ROOT)}:{lineno}")
    if offenders:
        return "FAIL", "演练禁用 docker kill/rm：" + ", ".join(offenders)
    return "PASS", "restart=unless-stopped；脚本未使用 docker kill/rm"


def check_13_dual_form(stacks: dict[str, list[Row]], profiles: list[str]) -> tuple[str, str]:
    problems: list[str] = []
    checked = 0
    for directory in enabled_dirs():
        rows_present = {row.name for row in rows_by_name(stacks).values() if stack_dir(row.profile) == directory.name}
        rendered = generated_doc(directory.name)
        if rendered is None:
            problems.append(f"{directory.name}: 缺少渲染结果")
            continue
        generated = set(rendered)
        checked += len(generated)
        missing = rows_present - generated
        extra = generated - rows_present
        if missing:
            problems.append(f"{directory.name}: ini 有但 compose 无 {sorted(missing)}")
        if extra:
            problems.append(f"{directory.name}: compose 有但 ini 无 {sorted(extra)}")
    for profile in profiles:
        try:
            solo = set(services_for(stacks, profile, "solo"))
            ha = set(services_for(stacks, profile, "ha"))
        except IniError as exc:
            problems.append(str(exc))
            continue
        if not solo <= ha:
            problems.append(f"{profile}: solo 服务不是 ha 的子集：{sorted(solo - ha)}")
    if problems:
        return "FAIL", "; ".join(problems)
    return "PASS", f"{checked} 个 service 与 ini 双形态一致"


def check_14_routes(stacks: dict[str, list[Row]], profiles: list[str]) -> tuple[str, str]:
    problems: list[str] = []
    notes: list[str] = []
    routes = stacks.get("routes", [])
    if not routes:
        return "FAIL", "ini 没有 [routes]"
    seen_hosts: set[str] = set()
    by_ip = {row.ip: row for rows in stack_sections(stacks).values() for row in rows}
    active_ips: set[str] = set()
    for profile in profiles:
        rendered = generated_doc(stack_dir(profile)) or {}
        for service in rendered.values():
            ip = ((service.get("networks") or {}).get("devnet") or {}).get("ipv4_address")
            if ip:
                active_ips.add(str(ip))

    for row in routes:
        if row.name in seen_hosts:
            problems.append(f"{row.name}: 路由 host 重复")
        seen_hosts.add(row.name)
        if not row.name.endswith(".localhost"):
            problems.append(f"{row.name}: 不是 *.localhost")
        target = by_ip.get(row.ip)
        if target is None:
            problems.append(f"{row.name}: upstream {row.ip} 不在 ini")
            continue
        if row.ip in active_ips:
            rendered = generated_doc(stack_dir(target.profile)) or {}
            service = rendered.get(target.name)
            if service is None:
                problems.append(f"{row.name}: upstream {target.name} 已启用但未渲染")
            notes.append(f"{row.name}->{target.name}")
        else:
            notes.append(f"{row.name} pending({target.profile})")

    aggregate = ROOT / "compose.generated.yml"
    if not aggregate.exists():
        problems.append("compose.generated.yml 不存在，请 make render")
    else:
        includes = set(load_yaml(aggregate).get("include") or [])
        for directory in enabled_dirs():
            want = f".generated/{directory.name}.yml"
            if want not in includes:
                problems.append(f"聚合 compose 缺少 {want}")
    if problems:
        return "FAIL", "; ".join(problems)
    active = sum(1 for n in notes if "pending" not in n)
    return "PASS", f"{len(routes)} 条路由合法；已打通 {active}，待观测栈 {len(routes) - active}"


def deployed_mode(profile: str) -> str:
    """该 profile 当前部署形态（读 stack.sh 写的 .data/.mode-<profile>）；没 marker = 从未部署。"""
    for marker in sorted((ROOT / "services").glob(f"*/.data/.mode-{profile}")):
        return marker.read_text(encoding="utf-8").strip()
    return ""


def check_15_runtime(stacks: dict[str, list[Row]], profiles: list[str]) -> tuple[str, str]:
    """运行态健康：Docker daemon 重启只会按 restart=unless-stopped 复活容器，
    不会恢复集群不变量（如 mysql 的 group_replication_start_on_boot=OFF），
    于是依赖它的栈（nacos）会 crash loop。前 14 项全是静态校验，看不到这一层
    （实测事故当时 `make doctor` 14/14 PASS，而三个 nacos 容器正在重启）。
    """
    expect: dict[str, str] = {}
    for profile in profiles:
        mode = deployed_mode(profile)
        if not mode:
            continue
        for name in services_for(stacks, profile, mode):
            expect[name] = profile
    if not expect:
        return "WARN", "没有已部署的 profile（先 make stack-up S=<profile>）"

    probe = run(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}\t{{.Status}}"])
    if probe.returncode != 0:
        return "WARN", f"docker 不可达：{probe.stderr.strip()[:70]}"
    actual = {c[0]: c[1:] for c in (line.split("\t") for line in probe.stdout.splitlines() if line)}

    crashes: set[str] = set()
    broken_profiles: set[str] = set()
    stopped: set[str] = set()
    for name, profile in sorted(expect.items()):
        cols = actual.get(name)
        if cols is None:
            stopped.add(f"{name}({profile}:未创建)")
            continue
        state, status = cols[0], (cols[1] if len(cols) > 1 else "")
        if state == "restarting" or "unhealthy" in status:
            crashes.add(name)
            broken_profiles.add(profile)
        elif state != "running":
            stopped.add(f"{name}({profile}:{state})")

    if crashes:
        return "FAIL", (f"容器在 crash loop / 不健康：{', '.join(sorted(crashes))}；"
                        f"重跑幂等引导：make stack-up S={' or S='.join(sorted(broken_profiles))} MODE=<形态>")
    if stopped:
        return "WARN", "已部署但没在跑：" + ", ".join(sorted(stopped)) + "（daemon 重启后需重跑 make stack-up）"

    # RestartCount 不会自动清零（要 docker compose up --force-recreate 才重计），
    # 所以只当线索报出来，不作为 WARN：否则会永久卡住“0 WARN”口径。
    restarted: list[str] = []
    names = [n for n in expect if n in actual]
    if names:
        insp = run(["docker", "inspect", "-f", "{{.Name}}\t{{.RestartCount}}", *names])
        if insp.returncode == 0:
            for line in insp.stdout.splitlines():
                cols = line.split("\t")
                if len(cols) == 2 and cols[1].isdigit() and int(cols[1]) > 0:
                    restarted.append(f"{cols[0].lstrip('/')}={cols[1]}")
    detail = f"{len(expect)} 个已部署容器均在跑且健康"
    if restarted:
        detail += f"（累计重启：{', '.join(sorted(restarted))}；已修复则 --force-recreate 可清零）"
    return "PASS", detail


CHECKS = [
    ("ini IP 范围", check_1_ip_range, True),
    ("ini IP 唯一", check_2_ip_unique, True),
    ("同 IP 端口唯一", check_3_ports, True),
    ("compose IP/镜像一致性", check_4_compose, True),
    ("service profile", check_5_profiles, True),
    ("宿主端口发布", check_6_ports_publish, True),
    ("docker context", check_7_context, True),
    ("宿主路由重叠", check_8_route_overlap, True),
    ("env/.env", check_9_env, True),
    ("data 目录", check_10_data, True),
    ("HA 拓扑完整性", check_11_topology, True),
    ("演练保护", check_12_drill, True),
    ("双形态一致性", check_13_dual_form, True),
    ("路由与引用", check_14_routes, True),
    ("运行态健康", check_15_runtime, True),
]


def main() -> int:
    try:
        stacks = parse_ini()
    except (OSError, IniError) as exc:
        print(f"FAIL  ini 解析失败：{exc}", file=sys.stderr)
        return 2

    profiles = enabled_profiles(stacks)
    total = len(CHECKS)
    failures = 0
    warnings = 0
    print(f"devops doctor · 已启用 {len(enabled_dirs())} 个目录 / {len(profiles)} 个 profile")
    for index, (title, func, _needs_stacks) in enumerate(CHECKS, 1):
        try:
            if func in (check_1_ip_range, check_2_ip_unique, check_3_ports, check_4_compose, check_5_profiles):
                status, detail = func(stacks)
            elif func is check_11_topology or func is check_13_dual_form or func is check_14_routes or func is check_15_runtime:
                status, detail = func(stacks, profiles)
            else:
                status, detail = func()
        except Exception as exc:  # 单项异常不应掩盖其余结果
            status, detail = "FAIL", f"{type(exc).__name__}: {exc}"
        if status == "FAIL":
            failures += 1
        elif status == "WARN":
            warnings += 1
        print(f"[{index:2d}/{total}] {status:4s} {title:<20s} {detail}")

    print(f"\nSummary: {total - failures - warnings} PASS, {warnings} WARN, {failures} FAIL")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
