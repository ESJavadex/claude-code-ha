#!/usr/bin/env bash
set -euo pipefail

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

"$tests_dir/test-production-run.sh"
"$tests_dir/test-persistent-packages.sh"

echo "All regression suites passed"
