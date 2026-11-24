#!/usr/bin/env python3
"""Blocking npm audit gate for claude-terminal/image-service.

Run locally with:  python3 scripts/npm-audit-gate.py

Fails if the production dependency audit reports a vulnerability or cannot
complete.
"""

import json
import subprocess
import sys
from pathlib import Path

SERVICE_DIR = Path(__file__).resolve().parent.parent / "claude-terminal" / "image-service"

subprocess.run(
    ["npm", "install", "--package-lock-only", "--ignore-scripts"],
    cwd=SERVICE_DIR, check=True, capture_output=True,
)
# npm audit can exit 1 for findings or for registry errors. Only a complete
# audit report can pass the gate, even if npm returned JSON for the error.
result = subprocess.run(
    ["npm", "audit", "--omit=dev", "--json"],
    cwd=SERVICE_DIR, capture_output=True, text=True,
)
try:
    audit = json.loads(result.stdout)
except ValueError:
    sys.exit("FAIL: npm audit did not return a JSON report")

if (
    result.returncode not in (0, 1)
    or not isinstance(audit, dict)
    or "error" in audit
    or not isinstance(audit.get("vulnerabilities"), dict)
):
    sys.exit("FAIL: npm audit did not return a complete vulnerability report")

vulnerabilities = audit["vulnerabilities"]
if vulnerabilities:
    print("FAIL: npm audit found vulnerabilities in production dependencies:")
    for name, finding in sorted(vulnerabilities.items()):
        print(f"  {name}: {finding['severity']}")
        for via in finding["via"]:
            if isinstance(via, dict) and via.get("url"):
                print(f"    {via['url']}")
    sys.exit(1)

if result.returncode != 0:
    sys.exit("FAIL: npm audit exited unsuccessfully without reporting vulnerabilities")

print("npm audit: no known vulnerabilities in production dependencies")
