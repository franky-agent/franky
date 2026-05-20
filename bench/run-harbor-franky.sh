#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Run Terminal-Bench through Harbor with the local Franky checkout.

USAGE:
  bench/run-harbor-franky.sh PROFILE [OPTIONS] [-- HARBOR_ARGS...]

PROFILES:
  openai                 Uses settings.json profile "openai"; requires OPENAI_API_KEY.
  ollama-deepseek-flash  Uses settings.json profile "ollama-deepseek-flash"; requires OLLAMA_API_KEY.
  mistral-labs-leanstral Uses settings.json profile "mistral-labs-leanstral"; requires MISTRAL_API_KEY.

OPTIONS:
  --task-id ID           Run one Terminal-Bench task.
  --dataset DATASET      Harbor dataset value. Default: terminal-bench/terminal-bench-2
  -n, --n N              Harbor concurrency. Default: 1
  --max-turns N          Franky max turns. Default: 100
  --build                Rebuild zig-out/bin/franky for x86_64-linux-gnu before running.
  -h, --help             Show this help.

Any args after -- are passed through to `harbor run`.

EXAMPLES:
  OPENAI_API_KEY=... bench/run-harbor-franky.sh openai --task-id <task-id>

  OLLAMA_API_KEY=... bench/run-harbor-franky.sh ollama-deepseek-flash --task-id <task-id>

  MISTRAL_API_KEY=... bench/run-harbor-franky.sh mistral-labs-leanstral --task-id <task-id>
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

PROFILE="$1"
shift

DATASET="${HARBOR_DATASET:-terminal-bench/terminal-bench-2}"
N_CONCURRENT="${HARBOR_N_CONCURRENT:-1}"
TASK_ID=""
MAX_TURNS="${FRANKY_BENCH_MAX_TURNS:-200}"
BUILD=0
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)
      [[ $# -ge 2 ]] || { echo "missing value for --task-id" >&2; exit 2; }
      TASK_ID="$2"
      shift 2
      ;;
    --dataset|-d)
      [[ $# -ge 2 ]] || { echo "missing value for --dataset" >&2; exit 2; }
      DATASET="$2"
      shift 2
      ;;
    -n|--n|--n-concurrent)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
      N_CONCURRENT="$2"
      shift 2
      ;;
    --max-turns)
      [[ $# -ge 2 ]] || { echo "missing value for --max-turns" >&2; exit 2; }
      MAX_TURNS="$2"
      shift 2
      ;;
    --build)
      BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      PASSTHROUGH+=("$@")
      break
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "required environment variable is not set: $name" >&2
    exit 2
  fi
}

append_forward_env() {
  local name="$1"
  if [[ -z "${FRANKY_BENCH_FORWARD_ENV:-}" ]]; then
    export FRANKY_BENCH_FORWARD_ENV="$name"
    return
  fi
  case ",${FRANKY_BENCH_FORWARD_ENV}," in
    *",${name},"*) ;;
    *) export FRANKY_BENCH_FORWARD_ENV="${FRANKY_BENCH_FORWARD_ENV},${name}" ;;
  esac
}

case "$PROFILE" in
  openai)
    require_env OPENAI_API_KEY
    export FRANKY_BENCH_ARGS="--profile openai"
    ;;
  ollama-deepseek-flash)
    require_env OLLAMA_API_KEY
    append_forward_env OLLAMA_API_KEY
    export FRANKY_BENCH_ARGS="--profile ollama-deepseek-flash --thinking high"
    ;;
  mistral-labs-leanstral)
    require_env MISTRAL_API_KEY
    append_forward_env MISTRAL_API_KEY
    export FRANKY_BENCH_ARGS="--profile mistral-labs-leanstral"
    ;;
  *)
    echo "unknown profile: $PROFILE" >&2
    usage >&2
    exit 2
    ;;
esac

export FRANKY_CHECKOUT="$REPO_ROOT"
export FRANKY_BENCH_MAX_TURNS="$MAX_TURNS"

cd "$REPO_ROOT"

if [[ "$BUILD" -eq 1 || ! -x zig-out/bin/franky ]]; then
  echo "Building Franky Linux binary for Harbor task containers..." >&2
  zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
fi

cmd=(
  harbor run
  -d "$DATASET"
  --timeout-multiplier 4
  --agent-import-path bench.harbor.franky_agent:FrankyAgent
  -n "$N_CONCURRENT"
)

if [[ -n "$TASK_ID" ]]; then
  cmd+=(--task-id "$TASK_ID")
fi

if [[ ${#PASSTHROUGH[@]} -gt 0 ]]; then
  cmd+=("${PASSTHROUGH[@]}")
fi

cat >&2 <<EOF
Running Harbor with Franky:
  profile:      $PROFILE
  dataset:      $DATASET
  task_id:      ${TASK_ID:-<all/harbor default>}
  concurrency:  $N_CONCURRENT
  max_turns:    $MAX_TURNS
  checkout:     $FRANKY_CHECKOUT
  bench_args:   $FRANKY_BENCH_ARGS
EOF

exec "${cmd[@]}"
