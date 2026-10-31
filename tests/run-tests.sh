#!/usr/bin/env bash
set -euo pipefail

tests_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$tests_dir/test-production-run.sh"
"$tests_dir/test-persistent-packages.sh"
"$tests_dir/test-login-url-watcher.sh"
node "$tests_dir/test-terminal-clipboard.js"
node "$tests_dir/test-sidebar-api.mjs"
node "$tests_dir/test-uploads.mjs"
node "$tests_dir/test-voice-audio.mjs"
# Runs the real image service, so it needs its npm dependencies. CI runs it
# inside the built image (docker-build job).
if [ -d "$tests_dir/../claude-terminal/image-service/node_modules" ]; then
    node "$tests_dir/test-upload-concurrency.mjs"
    node "$tests_dir/test-voice-api.mjs"
else
    echo "skip test-upload-concurrency.mjs (run npm install in claude-terminal/image-service)"
fi

echo "All regression suites passed"
