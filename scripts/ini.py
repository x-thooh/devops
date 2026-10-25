#!/usr/bin/env python3
"""Parse stock/network.ini and expose small query commands.

This module is shared by render-all.py and doctor.py.  It is intentionally
dependency-free (stdlib only) so the repository remains portable.
"""
from __future__ import annotations

import argparse
import ipaddress
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
INI_PATH = ROOT / "stock" / "network.ini"

VALID_MODES = {"ha", "both", "solo"}


@dataclass(frozen=True)
class Row:
    lineno: int
    section: str
    name: str
    ip: str
    ports: str
    role: str
    mode: str

    @property
    def profile(self) -> str:
        return self.section.removeprefix("stack.")


class IniError(RuntimeError):
    pass


def parse_ini(path: Path = INI_PATH) -> dict[str, list[Row]]:
    """Return {section: [Row, ...]} preserving file order."""
    sections: dict[str, list[Row]] = {}
    current: str | None = None
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip()
            sections.setdefault(current, [])
            continue
        if current is None:
            raise IniError(f"{path}:{lineno}: row outside section")
        cells = [c.strip() for c in line.split("|")]
        if current == "global":
            if len(cells) < 2:
                raise IniError(f"{path}:{lineno}: global row needs name|value")
            sections[current].append(
                Row(lineno, current, cells[0], cells[1], "", "", "")
            )
        elif current == "routes":
            if len(cells) < 3:
                raise IniError(f"{path}:{lineno}: route needs host|ip|port")
            sections[current].append(
                Row(lineno, current, cells[0], cells[1], cells[2], cells[3] if len(cells) > 3 else "", "")
            )
        elif current.startswith("stack."):
            if len(cells) < 4:
                raise IniError(f"{path}:{lineno}: stack row needs name|ip|ports|role[|mode]")
            mode = cells[4] if len(cells) > 4 and cells[4] else "ha"
            if mode not in VALID_MODES:
                raise IniError(f"{path}:{lineno}: invalid mode {mode!r}")
            sections[current].append(
                Row(lineno, current, cells[0], cells[1], cells[2], cells[3], mode)
            )
        else:
            raise IniError(f"{path}:{lineno}: unknown section [{current}]")
    return sections


def stack_sections(sections: dict[str, list[Row]]) -> dict[str, list[Row]]:
    return {k: v for k, v in sections.items() if k.startswith("stack.")}


def rows_by_name(sections: dict[str, list[Row]]) -> dict[str, Row]:
    out: dict[str, Row] = {}
    for rows in stack_sections(sections).values():
        for row in rows:
            if row.name in out:
                raise IniError(
                    f"duplicate name {row.name!r} at line {row.lineno} "
                    f"(already at line {out[row.name].lineno})"
                )
            out[row.name] = row
    return out


def stack_dir(profile: str) -> str:
    """Composite stack: two profiles share services/redis/."""
    if profile.startswith("redis-"):
        return "redis"
    return profile


def expand_ports(spec: str) -> Iterable[int]:
    for item in filter(None, (p.strip() for p in spec.split(","))):
        if "-" in item:
            start, end = item.split("-", 1)
            yield from range(int(start), int(end) + 1)
        elif item.isdigit():
            yield int(item)


def services_for(sections: dict[str, list[Row]], profile: str, mode: str) -> list[str]:
    if mode not in ("solo", "ha"):
        raise IniError(f"invalid mode {mode!r} (use solo|ha)")
    rows = sections.get(f"stack.{profile}", [])
    if not rows:
        raise IniError(f"unknown profile {profile!r}")
    allowed = {"solo": {"both", "solo"}, "ha": {"both", "ha"}}[mode]
    return [r.name for r in rows if r.mode in allowed]


def find_row(sections: dict[str, list[Row]], name: str) -> Row:
    return rows_by_name(sections)[name]


def validate(sections: dict[str, list[Row]]) -> list[str]:
    """Return a list of human-readable problems (empty means valid)."""
    problems: list[str] = []
    network = ipaddress.ip_network("172.28.0.0/16")
    names: dict[str, Row] = {}
    ips: dict[str, Row] = {}
    per_ip: dict[tuple[str, int], Row] = {}

    for profile, rows in stack_sections(sections).items():
        for row in rows:
            if row.name in names:
                problems.append(
                    f"line {row.lineno}: duplicate name {row.name!r} "
                    f"(also line {names[row.name].lineno})"
                )
            else:
                names[row.name] = row

            try:
                addr = ipaddress.ip_address(row.ip)
            except ValueError:
                problems.append(f"line {row.lineno}: invalid IP {row.ip!r}")
                continue
            if addr not in network:
                problems.append(f"line {row.lineno}: {row.ip} outside 172.28.0.0/16")
            if addr.packed[-1] in (0, 1, 255):
                problems.append(f"line {row.lineno}: {row.ip} uses reserved host octet")
            if row.ip in ips:
                problems.append(
                    f"line {row.lineno}: duplicate IP {row.ip} "
                    f"(also line {ips[row.ip].lineno})"
                )
            else:
                ips[row.ip] = row

            try:
                ports = list(expand_ports(row.ports))
            except ValueError:
                problems.append(f"line {row.lineno}: invalid port spec {row.ports!r}")
                continue
            for port in ports:
                key = (row.ip, port)
                if key in per_ip:
                    problems.append(
                        f"line {row.lineno}: {row.ip}:{port} duplicates line "
                        f"{per_ip[key].lineno} ({per_ip[key].name})"
                    )
                else:
                    per_ip[key] = row

    for row in sections.get("routes", []):
        if not row.name.endswith(".localhost"):
            problems.append(f"line {row.lineno}: route host {row.name!r} is not *.localhost")
        if row.ip not in ips:
            problems.append(f"line {row.lineno}: route upstream {row.ip} not in any [stack.*]")
    return problems


def _print_rows(rows: Iterable[Row]) -> None:
    for row in rows:
        print(f"{row.profile}|{row.name}|{row.ip}|{row.ports}|{row.role}|{row.mode}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_services = sub.add_parser("services", help="print service names for profile/mode")
    p_services.add_argument("profile")
    p_services.add_argument("mode", choices=("solo", "ha"))

    p_ip = sub.add_parser("ip", help="print IP for a node")
    p_ip.add_argument("name")

    p_ports = sub.add_parser("ports", help="print ports for a node")
    p_ports.add_argument("name")

    p_dir = sub.add_parser("dir", help="print services/<dir> for a profile")
    p_dir.add_argument("profile")

    sub.add_parser("routes", help="print host|ip|port|capability")
    sub.add_parser("profiles", help="print profile names")
    sub.add_parser("rows", help="print profile|name|ip|ports|role|mode")
    sub.add_parser("validate", help="validate ini and exit non-zero on problems")

    args = parser.parse_args(argv)
    try:
        sections = parse_ini()
    except (OSError, IniError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if args.cmd == "services":
        try:
            print("\n".join(services_for(sections, args.profile, args.mode)))
        except IniError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2
        return 0
    if args.cmd == "ip":
        try:
            print(find_row(sections, args.name).ip)
        except IniError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2
        return 0
    if args.cmd == "ports":
        try:
            print(find_row(sections, args.name).ports)
        except IniError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2
        return 0
    if args.cmd == "dir":
        print(stack_dir(args.profile))
        return 0
    if args.cmd == "routes":
        for row in sections.get("routes", []):
            print(f"{row.name}|{row.ip}|{row.ports}|{row.role}")
        return 0
    if args.cmd == "profiles":
        for section in stack_sections(sections):
            print(section.removeprefix("stack."))
        return 0
    if args.cmd == "rows":
        for rows in stack_sections(sections).values():
            _print_rows(rows)
        return 0
    if args.cmd == "validate":
        problems = validate(sections)
        for problem in problems:
            print(f"FAIL: {problem}")
        if problems:
            return 1
        print("OK: stock/network.ini is valid")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
