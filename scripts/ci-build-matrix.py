#!/usr/bin/env python3
"""Generate GitHub's build matrix from the add-on's supported architectures."""

import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
config = yaml.safe_load((ROOT / "claude-terminal/config.yaml").read_text())
build = yaml.safe_load((ROOT / "claude-terminal/build.yaml").read_text())
targets = {
    "amd64": ("linux/amd64", "ubuntu-latest"),
    "aarch64": ("linux/arm64", "ubuntu-24.04-arm"),
}

matrix = []
for arch in config["arch"]:
    if arch not in targets:
        raise SystemExit(f"No CI platform/runner defined for supported architecture: {arch}")
    platform, runner = targets[arch]
    matrix.append({
        "arch": arch,
        "platform": platform,
        "runner": runner,
        "base": build["build_from"][arch],
    })

print("matrix=" + json.dumps({"include": matrix}, separators=(",", ":")))
