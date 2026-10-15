#!/usr/bin/env python3
"""Consistency checks for the Home Assistant add-on metadata.

Run locally with:  python3 scripts/check-addon-metadata.py

Validates, without building anything:
  - claude-terminal/config.yaml parses and has the required add-on fields,
    with a semver version and at least one supported architecture.
  - claude-terminal/build.yaml parses, covers the same architectures and its
    org.opencontainers.image.version label matches config.yaml's version
    (the label drifts easily because it sits far from config.yaml).
  - repository.yaml parses and points at this repository.
  - image-service/package.json is valid JSON with a start script.
"""

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")

failures = []


def check(condition, message):
    if condition:
        print(f"ok   {message}")
    else:
        failures.append(message)
        print(f"FAIL {message}")


# --- config.yaml: the add-on manifest the Supervisor reads -----------------
config_path = ROOT / "claude-terminal" / "config.yaml"
config = yaml.safe_load(config_path.read_text())

for field in ("name", "description", "version", "slug", "arch", "map"):
    check(field in config, f"config.yaml has '{field}'")

version = config.get("version", "")
check(bool(SEMVER.match(str(version))), f"config.yaml version '{version}' is semver (x.y.z)")

arch = config.get("arch") or []
check(bool(arch), "config.yaml lists at least one architecture")

# --- build.yaml: per-arch base images and OCI labels ------------------------
build_path = ROOT / "claude-terminal" / "build.yaml"
build = yaml.safe_load(build_path.read_text())

build_from = build.get("build_from") or {}
check(bool(build_from), "build.yaml defines build_from")
check(
    set(build_from) == set(arch),
    f"build.yaml archs {sorted(build_from)} match config.yaml archs {sorted(arch)}",
)

labels = build.get("labels") or {}
label_version = labels.get("org.opencontainers.image.version", "")
check(
    label_version == str(version),
    f"build.yaml image version label ({label_version}) matches config.yaml ({version})",
)

# --- repository.yaml: the add-on repository manifest ------------------------
repo = yaml.safe_load((ROOT / "repository.yaml").read_text())
check(bool(repo.get("name")), "repository.yaml has a name")
check(str(repo.get("url", "")).startswith("https://"), "repository.yaml url is https")

# --- image-service package.json ---------------------------------------------
pkg_path = ROOT / "claude-terminal" / "image-service" / "package.json"
try:
    pkg = json.loads(pkg_path.read_text())
    check("start" in pkg.get("scripts", {}), "image-service/package.json has a start script")
except (json.JSONDecodeError, OSError) as exc:
    check(False, f"image-service/package.json is valid JSON ({exc})")

if failures:
    print(f"\n{len(failures)} metadata check(s) failed")
    sys.exit(1)
print("\nAll add-on metadata checks passed")
