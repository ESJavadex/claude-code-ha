#!/usr/bin/env python3
"""Blocking npm audit gate for claude-terminal/image-service.

Run locally with:  python3 scripts/npm-audit-gate.py

Fails if the production dependency tree has any vulnerability, except the
explicitly waived advisories below. A waiver must always come with a reason
and a review date, otherwise delete it and fix the dependency instead.

Waived advisories:
  - GHSA-vfj7-8cjw-p6xm (CVE-2026-93687): braces <= 3.0.3 stack-exhaustion
    DoS while compiling a deeply nested glob pattern. There is no fixed
    release and upstream has stated none is planned; every maintained
    version of http-proxy-middleware (2.x, 3.x, 4.x) pulls braces via
    micromatch, so this cannot be resolved by upgrading either.
    Not exploitable here: the add-on never passes attacker-controlled glob
    patterns to braces — it is only reachable through proxy path matching
    with the fixed literal '/terminal'.
    Reviewed: 2026-10-15.
"""

import json
import subprocess
import sys
from pathlib import Path

SERVICE_DIR = Path(__file__).resolve().parent.parent / "claude-terminal" / "image-service"
WAIVED = {"GHSA-vfj7-8cjw-p6xm"}

subprocess.run(
    ["npm", "install", "--package-lock-only", "--ignore-scripts"],
    cwd=SERVICE_DIR, check=True, capture_output=True,
)
# npm audit exits non-zero when it finds vulnerabilities, which is expected
# here: the gate itself decides whether they are waived or blocking
audit = json.loads(
    subprocess.run(
        ["npm", "audit", "--omit=dev", "--json"],
        cwd=SERVICE_DIR, capture_output=True, text=True,
    ).stdout
)

advisories = set()
for vuln in audit.get("vulnerabilities", {}).values():
    for via in vuln.get("via", []):
        if isinstance(via, dict) and via.get("url"):
            advisories.add(via["url"].rsplit("/", 1)[-1])

if not advisories:
    print("npm audit: no known vulnerabilities in production dependencies")
    sys.exit(0)

unwaived = sorted(advisories - WAIVED)
for adv in sorted(advisories & WAIVED):
    print(f"waived {adv} (documented in this script's header)")

if unwaived:
    print("\nFAIL: unwaived vulnerabilities in production dependencies:")
    for adv in unwaived:
        print(f"  {adv} - https://github.com/advisories/{adv}")
    print("\nFix them, or extend the waiver with a reason and review date.")
    sys.exit(1)

print("\nnpm audit gate passed (only waived advisories present)")
