#!/usr/bin/env bash
set -euo pipefail

FRANKY_SRC="${1:-/installed-agent/franky}"
FRANKY_BIN="/usr/local/bin/franky"

if [[ ! -d "$FRANKY_SRC" ]]; then
  echo "franky source directory not found: $FRANKY_SRC" >&2
  exit 1
fi

cd "$FRANKY_SRC"

if [[ -x zig-out/bin/franky ]]; then
  echo "Installing prebuilt franky from $FRANKY_SRC/zig-out/bin/franky"
  install -m 0755 zig-out/bin/franky "$FRANKY_BIN"
elif command -v zig >/dev/null 2>&1; then
  echo "No prebuilt franky binary found; building from local checkout"
  zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe -Dtls-insecure=true
  install -m 0755 zig-out/bin/franky "$FRANKY_BIN"
else
  cat >&2 <<'EOF'
No franky binary found and Zig is not installed in the task container.

Build franky on the host before running Harbor, for example:

  zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe

Then rerun Harbor so bench/harbor/franky_agent.py can upload the checkout with
zig-out/bin/franky included. Alternatively use a task/container image that has
Zig available.
EOF
  exit 1
fi

"$FRANKY_BIN" --version
