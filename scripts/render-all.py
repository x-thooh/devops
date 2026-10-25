#!/usr/bin/env python3
"""Render authored service skeletons + ini + base inputs into compose outputs.

Contract (P0):
  services/<stack>/compose.yml   authored skeleton: no image/logging/restart/TZ/networks
  base/images.yml                only image source (x-image key -> image ref)
  base/anchors.yml               logging/restart/TZ/healthcheck defaults
  stock/network.ini              only IP/profile/mode source
  .generated/<stack>.yml         rendered per-stack compose (gitignored)
  compose.generated.yml          aggregate entry (gitignored)
  compose.yml                    identical copy of the aggregate (gitignored)
"""
from __future__ import annotations

import copy
import os
import shutil
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ini import IniError, Row, parse_ini  # noqa: E402

GENERATED_DIR = ROOT / ".generated"
COMPOSE_GENERATED = ROOT / "compose.generated.yml"
COMPOSE_ENTRY = ROOT / "compose.yml"

FORBIDDEN_SERVICE_KEYS = {
    "image",
    "logging",
    "restart",
    "networks",
    "network_mode",
    "subnet",
}


class RenderError(RuntimeError):
    pass


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if path.exists():
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    # shell env wins over env/.env (Compose precedence)
    for key, value in os.environ.items():
        if key.startswith("IMG_") or key in {"IMAGE_PREFIX"}:
            env[key] = value
    return env


def load_yaml(path: Path) -> Any:
    if not path.exists():
        raise RenderError(f"missing input: {path.relative_to(ROOT)}")
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def find_forbidden(value: Any, path: str = "") -> list[str]:
    """Find forbidden keys recursively (subnet/TZ are checked separately)."""
    hits: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}" if path else str(key)
            if key in FORBIDDEN_SERVICE_KEYS:
                hits.append(child_path)
            hits.extend(find_forbidden(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            hits.extend(find_forbidden(child, f"{path}[{index}]"))
    return hits


def normalize_environment(value: Any, service: str) -> dict[str, str]:
    if value is None:
        return {}
    if isinstance(value, dict):
        return {str(k): "" if v is None else str(v) for k, v in value.items()}
    if isinstance(value, list):
        out: dict[str, str] = {}
        for item in value:
            text = str(item)
            if "=" not in text:
                raise RenderError(f"{service}: environment item {text!r} must be KEY=VALUE")
            key, val = text.split("=", 1)
            out[key] = val
        return out
    raise RenderError(f"{service}: unsupported environment type {type(value).__name__}")


def resolve_image(key: str, images: dict[str, str], env: dict[str, str]) -> str:
    if not key:
        raise RenderError("service is missing x-image")
    image = env.get(f"IMG_{key}") or env.get(f"IMG_{key.upper()}") or images.get(key)
    if not image:
        raise RenderError(f"image key {key!r} not found in base/images.yml")
    prefix = env.get("IMAGE_PREFIX", "").strip()
    if prefix:
        image = prefix.rstrip("/") + "/" + image.lstrip("/")
    return str(image)


def rewrite_build(build: Any, stack_dir: Path) -> Any:
    """Resolve build context/dockerfile against the authored file."""
    if isinstance(build, str):
        return str((stack_dir / build).resolve()) if build.startswith(".") else build
    if not isinstance(build, dict):
        return build
    entry = copy.deepcopy(build)
    context = str(entry.get("context", ""))
    if context.startswith("."):
        entry["context"] = str((stack_dir / context).resolve())
    dockerfile = str(entry.get("dockerfile", ""))
    if dockerfile.startswith("."):
        entry["dockerfile"] = str((stack_dir / dockerfile).resolve())
    return entry


def rewrite_env_file(env_file: Any, stack_dir: Path, service: str) -> list[str]:
    """Resolve env_file entries against the authored file, not .generated/."""
    if env_file is None:
        return []
    items = [env_file] if isinstance(env_file, str) else env_file
    if not isinstance(items, list):
        raise RenderError(f"{service}: env_file must be a string or a list")
    out: list[str] = []
    for item in items:
        if not isinstance(item, str):
            raise RenderError(f"{service}: unsupported env_file entry {item!r}")
        if item.startswith("./") or item.startswith("../"):
            item = str((stack_dir / item).resolve())
        out.append(item)
    return out


def rewrite_volumes(volumes: Any, stack_dir: Path, service: str) -> list[Any]:
    if volumes is None:
        return []
    if not isinstance(volumes, list):
        raise RenderError(f"{service}: volumes must be a list")
    out: list[Any] = []
    for item in volumes:
        if isinstance(item, str):
            parts = item.split(":")
            source = parts[0]
            if source.startswith("./") or source.startswith("../"):
                source = str((stack_dir / source).resolve())
                parts[0] = source
                item = ":".join(parts)
            out.append(item)
        elif isinstance(item, dict):
            entry = copy.deepcopy(item)
            source = str(entry.get("source", ""))
            if source.startswith("./") or source.startswith("../"):
                entry["source"] = str((stack_dir / source).resolve())
            out.append(entry)
        else:
            raise RenderError(f"{service}: unsupported volume entry {item!r}")
    return out


def render_stack(
    stack: str,
    compose_path: Path,
    sections: dict[str, list[Row]],
    images: dict[str, str],
    anchors: dict[str, Any],
    env: dict[str, str],
    seen_services: set[str],
    seen_containers: set[str],
) -> tuple[dict[str, Any], set[str]]:
    doc = load_yaml(compose_path)
    services = doc.get("services")
    if not isinstance(services, dict) or not services:
        raise RenderError(f"{compose_path.relative_to(ROOT)}: missing services map")

    rendered: dict[str, Any] = {}
    profiles_in_file: set[str] = set()
    expected_rows: set[str] = set()

    for name, original in services.items():
        if name in seen_services:
            raise RenderError(f"duplicate service name {name!r}")
        seen_services.add(name)
        if not isinstance(original, dict):
            raise RenderError(f"{name}: service definition must be a mapping")

        hits = find_forbidden(original)
        if hits:
            raise RenderError(
                f"{name}: forbidden keys in authored compose: {', '.join(hits)} "
                "(image/logging/restart/networks belong in base/)"
            )

        service = copy.deepcopy(original)
        image_key = service.pop("x-image", None)
        if not image_key:
            raise RenderError(f"{name}: x-image is required")

        profiles = service.get("profiles")
        if not isinstance(profiles, list) or not profiles:
            raise RenderError(f"{name}: profiles must be a non-empty list")
        if len(profiles) != 1:
            raise RenderError(f"{name}: exactly one profile per service is required")
        profile = str(profiles[0])
        profiles_in_file.add(profile)

        rows = sections.get(f"stack.{profile}")
        if not rows:
            raise RenderError(f"{name}: profile {profile!r} has no [stack.{profile}] in ini")
        row = next((r for r in rows if r.name == name), None)
        if row is None:
            raise RenderError(f"{name}: no matching row in [stack.{profile}]")
        if row.section != f"stack.{profile}":
            raise RenderError(f"{name}: row section {row.section} != stack.{profile}")

        expected_rows.add(name)
        environment = normalize_environment(service.get("environment"), name)
        if "TZ" in environment:
            raise RenderError(f"{name}: TZ belongs in base/anchors.yml, not the service")
        environment["TZ"] = str(anchors.get("environment", {}).get("TZ", "Asia/Shanghai"))

        service["image"] = resolve_image(str(image_key), images, env)
        service.setdefault("container_name", name)
        container_name = str(service["container_name"])
        if container_name in seen_containers:
            raise RenderError(f"duplicate container_name {container_name!r}")
        seen_containers.add(container_name)

        service["restart"] = anchors.get("restart", "unless-stopped")
        service["logging"] = copy.deepcopy(anchors.get("logging", {}))
        service["environment"] = environment
        if "healthcheck" in service and anchors.get("healthcheck"):
            for key, value in anchors["healthcheck"].items():
                service["healthcheck"].setdefault(key, value)
        if "volumes" in service:
            service["volumes"] = rewrite_volumes(service["volumes"], compose_path.parent, name)
        if "env_file" in service:
            service["env_file"] = rewrite_env_file(service["env_file"], compose_path.parent, name)
        if "build" in service:
            service["build"] = rewrite_build(service["build"], compose_path.parent)

        if name == "nginx-1" and "ports" not in service:
            raise RenderError("nginx-1 must publish the host port")
        if name != "nginx-1" and "ports" in service:
            raise RenderError(f"{name}: only nginx-1 may declare host ports")

        service["networks"] = {"devnet": {"ipv4_address": row.ip}}
        rendered[name] = service

    # Every ini row for the profiles used by this file must be represented.
    for profile in profiles_in_file:
        for row in sections.get(f"stack.{profile}", []):
            if row.name not in expected_rows:
                raise RenderError(
                    f"{stack}: ini row {row.name!r} in [stack.{profile}] "
                    "has no service in compose.yml"
                )
    return rendered, profiles_in_file


def main() -> int:
    try:
        sections = parse_ini()
        images = load_yaml(ROOT / "base" / "images.yml")
        anchors_doc = load_yaml(ROOT / "base" / "anchors.yml")
        anchors = anchors_doc.get("x-common", {})
        if not isinstance(anchors, dict):
            raise RenderError("base/anchors.yml: x-common must be a mapping")
        env = load_env(ROOT / "env" / ".env")

        if not isinstance(images, dict) or not images:
            raise RenderError("base/images.yml must be a non-empty mapping")

        GENERATED_DIR.mkdir(exist_ok=True)
        for old in GENERATED_DIR.glob("*.yml"):
            old.unlink()

        includes: list[str] = ["base/network.yml"]
        seen_services: set[str] = set()
        seen_containers: set[str] = set()
        summary: list[tuple[str, int]] = []

        for compose_path in sorted((ROOT / "services").glob("*/compose.yml")):
            stack = compose_path.parent.name
            rendered, profiles = render_stack(
                stack,
                compose_path,
                sections,
                images,
                anchors,
                env,
                seen_services,
                seen_containers,
            )
            out = GENERATED_DIR / f"{stack}.yml"
            out.write_text(
                "# 生成物：由 scripts/render-all.py 生成，禁止手改\n"
                + yaml.safe_dump({"services": rendered}, sort_keys=False, allow_unicode=True),
                encoding="utf-8",
            )
            includes.append(f".generated/{stack}.yml")
            summary.append((stack, len(rendered)))

        header = (
            "# 生成物：由 scripts/render-all.py 生成，禁止手改\n"
            "# 输入：stock/network.ini + base/{network,anchors,images}.yml + services/*/compose.yml\n"
        )
        aggregate = header + yaml.safe_dump(
            {"include": includes}, sort_keys=False, allow_unicode=True
        )
        COMPOSE_GENERATED.write_text(aggregate, encoding="utf-8")
        shutil.copyfile(COMPOSE_GENERATED, COMPOSE_ENTRY)

        for stack, count in summary:
            print(f"rendered {stack}: {count} service(s)")
        print(f"wrote {COMPOSE_GENERATED.relative_to(ROOT)}")
        print(f"wrote {COMPOSE_ENTRY.relative_to(ROOT)}")
        return 0
    except (OSError, IniError, RenderError, yaml.YAMLError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
