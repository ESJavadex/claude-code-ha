#!/usr/bin/env bash
set -euo pipefail

tests_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$tests_dir/test-production-run.sh"
"$tests_dir/test-persistent-packages.sh"
"$tests_dir/test-login-url-watcher.sh"
node "$tests_dir/test-terminal-clipboard.js"
node "$tests_dir/test-sidebar-api.mjs"

echo "All regression suites passed"
