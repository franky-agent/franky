#!/usr/bin/env bash
# Builds the franky CLI via `zig build` and prints the install path.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=scripts/env.sh
source scripts/env.sh
franky_setup_cache

zig build "$@"
echo "Built: $(pwd)/zig-out/bin/franky"
