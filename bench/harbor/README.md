# Franky on Terminal-Bench via Harbor

This directory contains a Harbor installed-agent wrapper for running Franky from
this local checkout inside Terminal-Bench task containers.

## Prerequisites

- Harbor installed on the host.
- Docker installed and running on the host.
- This Franky checkout available locally.
- Provider/model flags supplied through `FRANKY_BENCH_ARGS`.

Sanity-check Harbor first:

```sh
harbor run -d terminal-bench/terminal-bench-2 -a oracle
```

If your Harbor version uses the newer dataset spelling, use:

```sh
harbor run --dataset terminal-bench@2.0 --agent oracle
```

## Build/install strategy

The wrapper uploads this local checkout into each task container. The install
script then:

1. Uses `zig-out/bin/franky` if it exists in the uploaded checkout.
2. Otherwise runs `zig build -Doptimize=ReleaseSafe` inside the task container
   if `zig` is installed there.
3. Fails with a clear error if neither a prebuilt binary nor Zig is available.

For the most reliable first run, prebuild a Linux binary before invoking Harbor:

```sh
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
```

If your task containers are not compatible with that artifact, try a container
with Zig installed or adjust the target to match the task image.

## Required environment

`FRANKY_BENCH_ARGS` is required and must contain provider/model configuration.
The wrapper intentionally does not choose a provider or model.

Examples:

```sh
export FRANKY_BENCH_ARGS='--provider gateway --base-url http://host.docker.internal:11434/v1 --model qwen3-coder'
```

```sh
export FRANKY_BENCH_ARGS='--profile openrouter --model anthropic/claude-sonnet-4.5'
```

For local providers running on the host from Docker task containers, use
`host.docker.internal` rather than `localhost` on Docker Desktop.

## Optional environment

```sh
export FRANKY_CHECKOUT=/absolute/path/to/franky     # defaults to repo root
export FRANKY_BENCH_MAX_TURNS=100                  # default: 100
export FRANKY_BENCH_RUN_TIMEOUT_SEC=7200           # default: 2 hours
export FRANKY_BENCH_INSTALL_TIMEOUT_SEC=600        # default: 10 minutes
export FRANKY_BENCH_FORWARD_ENV=NAME1,NAME2        # extra env vars to pass
```

The wrapper forwards common provider credentials automatically, including:

- `ANTHROPIC_API_KEY`
- `ANTHROPIC_AUTH_TOKEN`
- `CLAUDE_CODE_OAUTH_TOKEN`
- `OPENAI_API_KEY`
- `OPENROUTER_API_KEY`
- `GOOGLE_API_KEY`
- `GEMINI_API_KEY`
- `MISTRAL_API_KEY`
- `CEREBRAS_API_KEY`
- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

## Smoke run

From the Franky repository root:

```sh
export FRANKY_CHECKOUT="$PWD"
export FRANKY_BENCH_ARGS='--provider gateway --base-url http://host.docker.internal:11434/v1 --model qwen3-coder'

harbor run \
  -d terminal-bench/terminal-bench-2 \
  --agent-import-path bench.harbor.franky_agent:FrankyAgent \
  --task-id <small-task-id> \
  -n 1
```

Replace `FRANKY_BENCH_ARGS` with your actual provider-neutral configuration.

## Runtime command

Inside the task container the wrapper runs roughly:

```sh
FRANKY_HOME=/tmp/franky \
franky \
  --mode print \
  --role full \
  --tools read,write,edit,bash,ls,find,grep \
  --session-dir /tmp/franky/sessions \
  --log-file /tmp/franky/franky.log \
  --max-turns "${FRANKY_BENCH_MAX_TURNS:-100}" \
  ${FRANKY_BENCH_ARGS} \
  -- "$TASK_INSTRUCTION"
```

Franky artifacts are written under `/tmp/franky` inside the task container.
After each run, the wrapper best-effort downloads that directory to the Harbor
trial logs directory under a `franky/` subdirectory. Look there for:

```text
franky/
  franky.log
  sessions/
  diagnostics/
```
