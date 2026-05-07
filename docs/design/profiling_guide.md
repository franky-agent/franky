# 🔬 Profiling and Memory Analysis Guide (franky / Zig 0.17-dev)

**Document Status:** Practical workflow + technical reference
**Target Version:** 0.17-dev
**Purpose:** Reproducible workflow for capturing CPU hotspots and
memory allocation profiles from franky's existing test binaries,
producing SVG flamegraphs via [`inferno`](https://github.com/jonhoo/inferno)
without touching the code under test.

---

## TL;DR — one command

Once prerequisites are installed (§2):

```bash
# Build FP-preserved test binaries + capture CPU and all 4 memory
# flamegraphs against the unit-test binary. Output goes to
# zig-out/profile/<binary>/<unix_ms>/.
zig build profile -- --binary franky-test
```

`zig build profile` rebuilds the FP-preserved binaries (transitively
runs `test-profile`), then drives `perf` / `heaptrack` / `inferno` for
you. See §3.5 for the full CLI.

If you want to drive the pipeline by hand — to learn what the driver
does, or to plug in a different acquisition tool — the canonical
manual workflow is:

```bash
# Build a release-safe, frame-pointer-preserved test binary.
zig build test-profile -Doptimize=ReleaseSafe

# CPU flamegraph: frame-pointer unwinding keeps perf.data ~10× smaller
# than DWARF. See §4.1 for the trade-offs and DWARF fallback.
perf record -F 997 --call-graph fp -o perf.data -- ./zig-out/bin/franky-test
perf script --input perf.data | inferno-collapse-perf | inferno-flamegraph > cpu.svg

# Memory: heaptrack captures, heaptrack_print extracts a folded stack
# per cost dimension, inferno-flamegraph renders the SVG. See §5 for
# the full four-flamegraph workflow.
heaptrack ./zig-out/bin/franky-test
heaptrack_print -p 0 -a 0 -T 0 --flamegraph-cost-type peak \
  -F mem-peak.folded -f heaptrack.franky-test.*.zst
inferno-flamegraph --countname=bytes --colors=mem mem-peak.folded > mem-peak.svg
```

Below is the full picture.

---

## 1. Why profile the test suite?

The previous draft of this guide proposed writing a dedicated
`test_high_intensity_pipeline` function. **franky's existing test
suite is already that function.** 1041+ tests across the unit-test
binary plus six integration binaries exercise:

- All seven LLM-provider stream parsers (faux + Anthropic + 5 others).
- All seven coding tools (`read`/`write`/`edit`/`bash`/`ls`/`find`/`grep`).
- Full agent-loop flows (parallel tool execution, subagents, compaction).
- Session round-trip + branching + object-store.
- The web UI's transcript renderer and JSON helpers.

Profiling this gives you a representative dataset on day one. You can
narrow scope via `--test-filter <pattern>` once a hotspot is known.

The integration test binaries (`franky-agent_loop_test`,
`franky-kitchen_sink_test`, etc.) tend to be the most allocation-heavy
because they drive end-to-end flows. Profile `franky-test` first for
breadth; switch to a specific integration binary once the bottleneck
is known to be in agent or coding logic.

---

## 2. Prerequisites

| Tool | Linux | macOS | Notes |
|---|---|---|---|
| **Zig 0.17-dev** | required | required | Same version as `build.zig.zon`. |
| **`perf`** | `apt install linux-tools-$(uname -r)` / `apt install linux-perf` | n/a — use `Instruments` or `dtrace` | CPU sampling profiler. Needs `kernel.perf_event_paranoid` lowered to 1 or root. |
| **`heaptrack`** | `apt install heaptrack` / `brew install heaptrack` | yes (CLI tools work without a display) | Allocation tracker. We use `heaptrack` (capture) + `heaptrack_print -F <cost>` (extract folded stacks) — no display required. |
| **`inferno`** | `cargo install inferno` | `cargo install inferno` | Rust port of FlameGraph; we use `inferno-collapse-perf` + `inferno-flamegraph` for CPU only. Already available in the environment. |
| **`addr2line`** | bundled with binutils | bundled with `llvm` | Resolves stack addresses to symbols when DWARF is present. |

Verify in one go:

```bash
command -v zig perf heaptrack inferno-flamegraph addr2line || echo "missing tools above"
sysctl kernel.perf_event_paranoid    # should be ≤ 1 for unprivileged perf
```

If `kernel.perf_event_paranoid` is 2+ and you can't change it
system-wide, run perf with `sudo`. CI runners almost always need
the relaxed value or a privileged container.

---

## 3. Build setup — installing a profilable test binary

`zig build test` builds the test executables under `.zig-cache/o/<hash>/`
and runs them in one step. For profiling we need (a) a stable path,
(b) **build without running**, and (c) **frame pointers preserved**
so `perf record --call-graph fp` works (§4.1).

The `test-profile` build step in `build.zig` does this. It uses a
separate module from the regular `test` step so default-optimisation
behaviour for `zig build test` is unchanged; the profile variant
overrides only `omit_frame_pointer = false` (and applies the same
override to each integration test module so every binary is FP-
preserved). The `profile` step depends on `test-profile`'s install
step, so `zig build profile -- ...` always runs against fresh
artifacts.

`zig build test-profile -Doptimize=ReleaseSafe` produces:

```
zig-out/bin/
  franky-test
  franky-agent_loop_test
  franky-agent_class_test
  franky-gitignore_test
  franky-parallel_tools_test
  franky-kitchen_sink_test
  franky-replay_test
```

Each is directly invokable: `./zig-out/bin/franky-test`. Same flags as
`zig build test` would have applied (`--test-filter <pattern>`,
`--seed <hex>`), passed through to the test runner.

### Optimization mode for profiling

| Mode | Use when |
|---|---|
| `Debug` | Hunting wrong-answer regressions. Stacks are most precise but allocation pattern is unrealistic (extra checks, no inlining). |
| **`ReleaseSafe`** *(recommended)* | First-pass profiling. Production-like inlining + DWARF still emitted for accurate stacks. |
| `ReleaseFast` | Validating that a specific hotspot still shows up after maximum inlining. Stacks degrade noticeably. |
| `ReleaseSmall` | Rarely useful for profiling — skip. |

The `--call-graph dwarf` form of perf works in all four; `--call-graph
fp` (frame-pointer unwinding, faster) needs the build to keep frame
pointers, which `ReleaseFast` typically strips.

### 3.5 The `franky-profile` driver

`zig build profile -- ...` runs `src/bin/franky_profile.zig`, a thin
CLI wrapper around the manual perf / heaptrack / inferno pipelines
described in §§4–5. It exists so the canonical workflow is one
command and produces a self-describing output directory.

```
zig build profile -- [options]

  --binary NAME        franky-test (default), or one of:
                       franky-agent_loop_test
                       franky-agent_class_test
                       franky-gitignore_test
                       franky-parallel_tools_test
                       franky-kitchen_sink_test
                       franky-replay_test
  --mode MODE          cpu | mem | both (default: both)
  --out-dir PATH       default: zig-out/profile/<binary>/<unix_ms>
  --freq HZ            perf sampling frequency (default: 997)
  --call-graph MODE    fp (default) | dwarf,16384
  --no-keep-trace      delete perf.data and heaptrack.*.zst after rendering
                       (default: keep, so SVGs can be re-rendered)
  --check              verify prerequisites and exit
  --list               list installed franky-* test binaries and exit
  -h, --help
```

**Filtering tests:** Zig 0.17's standalone test binary does *not*
accept `--test-filter` at runtime — that flag is consumed by `zig
test` at compile time and bakes the filtered test list into the
binary. The driver therefore exposes filtering as a build-time
option:

```bash
zig build profile -Dprofile-filter=parallel                  # one filter
zig build profile -Dprofile-filter=edit -Dprofile-filter=grep  # multiple
```

`-Dprofile-filter` accumulates and is forwarded to every
FP-preserved test binary's `addTest({ .filters = ... })`. The
`profile` step depends on `test-profile`, so a fresh filtered
build runs automatically before the capture.

What the driver does, in order:

1. **Preflight** — verifies the tools needed for the chosen `--mode`
   are on `$PATH`. CPU mode needs `perf`, `inferno-collapse-perf`,
   `inferno-flamegraph`. Memory mode adds `heaptrack` and
   `heaptrack_print`. Missing tools produce a single error block
   with install hints.
2. **OS / kernel checks** — refuses to run on non-Linux (§2 says
   macOS uses Instruments / dtrace). On Linux, reads
   `/proc/sys/kernel/perf_event_paranoid`; if > 1, prints the
   `sysctl -w kernel.perf_event_paranoid=1` hint before invoking
   perf.
3. **CPU pipeline** (if requested) — produces `perf.data`,
   `cpu.folded`, and `cpu.svg` in the output directory using the
   commands from §4.
4. **Memory pipeline** (if requested) — produces
   `heaptrack.*.{zst,gz}`, four `mem-<cost>.folded` files, and four
   `mem-<cost>.svg` files using the loop from §5.2.3.
5. **Summary** — prints every artefact written, with sizes.

Output layout (default `zig-out/profile/franky-test/1714992000000/`):

```
perf.data
cpu.folded
cpu.svg
heaptrack.franky-test.<pid>.zst   # or .gz on systems without zstd
mem-peak.folded            mem-peak.svg
mem-leaked.folded          mem-leaked.svg
mem-allocations.folded     mem-allocations.svg
mem-temporary.folded       mem-temporary.svg
```

Differential analysis (§4.4) is not built in. To compare two commits,
run with two different `--out-dir`s, then by hand:

```bash
inferno-diff-folded before/cpu.folded after/cpu.folded \
  | inferno-flamegraph --colors red > cpu-diff.svg
```

The driver is intentionally a thin wrapper. Everything below in
§§4–5 still applies — it is the underlying mechanism the driver
invokes, and the right level of detail when something doesn't look
right.

---

## 4. CPU flamegraph

### 4.1 Capture

Three call-graph modes are available; pick by the trade-off you want.
All three require the build step from §3 (in particular,
`--call-graph fp` is the recommended default but only works because
`omit_frame_pointer = false` keeps `%rbp` in the prologue/epilogue).

```bash
zig build test-profile -Doptimize=ReleaseSafe

# Default: frame-pointer unwinding. ~10× smaller perf.data than dwarf,
# full stack depth, low capture overhead. Requires the build to keep
# frame pointers (§3).
perf record -F 997 --call-graph fp -o perf.data -- ./zig-out/bin/franky-test
```

| Mode | perf.data size (60s @ 997 Hz, single thread) | Stack depth | Overhead | When to use |
|---|---|---|---|---|
| **`fp`** *(default)* | ~50–100 MB | full | low | first choice; works once §3 is in place |
| **`lbr`** | ~30–60 MB | 16–32 entries | very low | hardware-accelerated; Intel Haswell+ / AMD Zen+. Limited depth means deeply-nested calls truncate. |
| `dwarf` (or `dwarf,N`) | **~1 GB+** | full | high | last resort when the optimiser inlined past where fp can recover. Increase `N` (default 8 KB → 16 384 / 32 768) to capture deeper Zig stacks. |

```bash
# Hardware-accelerated alternative (Intel Haswell+ / AMD Zen 3+):
perf record -F 997 --call-graph lbr -o perf.data -- ./zig-out/bin/franky-test

# Fallback when `fp` produces "[unknown]" frames in the flamegraph
# (typically inside ReleaseFast inlined hot loops):
perf record -F 997 --call-graph dwarf,16384 -o perf.data -- ./zig-out/bin/franky-test
```

Notes that apply to all three:

- `997 Hz` is prime to avoid aliasing with timer interrupts.
- For long-running profiles (e.g. integration tests), add
  `--mmap-pages 2048` to avoid losing samples under memory pressure.
- If you see `[unknown]` boxes in the flamegraph after using `fp`,
  the optimiser elided some frames. Either rebuild with
  `-Doptimize=Debug` (most precise) or fall back to `dwarf`.

### 4.2 Convert to flamegraph (inferno)

```bash
perf script --input perf.data | inferno-collapse-perf > cpu.folded
inferno-flamegraph cpu.folded > cpu.svg
```

Or as a one-liner:

```bash
perf script --input perf.data \
  | inferno-collapse-perf \
  | inferno-flamegraph --title "franky-test CPU" --colors aqua \
  > cpu.svg
```

### 4.3 Narrowing scope (compile-time filter)

In Zig 0.17 the standalone test binary doesn't accept
`--test-filter` at runtime — `zig test --test-filter PATTERN` is a
compile-time flag that filters which tests get linked into the
binary. To profile a subset, rebuild the FP-preserved binary with
the filter, then run the resulting binary normally:

```bash
# All tests whose name matches the substring "edit"
zig build test-profile -Doptimize=ReleaseSafe -Dprofile-filter=edit
perf record -F 997 --call-graph fp -o perf.data -- ./zig-out/bin/franky-test

# A single named test (Zig matches by substring, so be specific)
zig build test-profile -Doptimize=ReleaseSafe \
  -Dprofile-filter="computeUnifiedDiff: golden snapshot"
perf record -F 997 --call-graph fp -o perf.data -- ./zig-out/bin/franky-test
```

The same `cpu.folded` → `cpu.svg` step applies. Filtered binaries
are much smaller and easier to read when chasing a specific
hotspot. With the `franky-profile` driver, equivalent invocations
collapse to one command — see §3.5.

### 4.4 Differential ("which change made this slower?")

Capture twice — before and after — then compare:

```bash
git checkout HEAD~1 && zig build test-profile -Doptimize=ReleaseSafe
perf record -F 997 --call-graph fp -o before.data -- ./zig-out/bin/franky-test
perf script --input before.data | inferno-collapse-perf > before.folded

git checkout - && zig build test-profile -Doptimize=ReleaseSafe
perf record -F 997 --call-graph fp -o after.data -- ./zig-out/bin/franky-test
perf script --input after.data | inferno-collapse-perf > after.folded

# `inferno-diff-folded` highlights paths that grew (red) or shrank (blue).
inferno-diff-folded before.folded after.folded > diff.folded
inferno-flamegraph --colors red diff.folded > cpu-diff.svg
```

This is the most useful CPU-perf workflow for "did my change regress
something?" questions.

---

## 5. Memory profile (heaptrack + inferno)

heaptrack is the canonical capture tool. It hooks `malloc`/`free` via
`LD_PRELOAD` and writes a compact `.zst`-compressed trace. From that
single trace, `heaptrack_print -F <cost>` extracts collapsed-format
stacks per cost dimension, which `inferno-flamegraph` renders into
SVG — same pipeline shape as the CPU flow (§4), and the same
artefact format that drops cleanly into CI / PR comments / static
sites.

This stays purely CLI: no display, no Qt dependency, reproducible in
any environment that runs the rest of the test suite.

### 5.1 Capture

```bash
zig build test-profile -Doptimize=ReleaseSafe

heaptrack ./zig-out/bin/franky-test
# Writes: heaptrack.franky-test.<pid>.zst (compressed; ~5–50 MB
# for a full test run depending on allocation churn)
```

heaptrack's overhead is moderate (~2–5× slowdown). For long
integration runs, narrow scope by rebuilding with
`-Dprofile-filter` first (§4.3 explains why filtering is
compile-time in Zig 0.17):

```bash
zig build test-profile -Doptimize=ReleaseSafe -Dprofile-filter="edit tool"
heaptrack ./zig-out/bin/franky-test
```

### 5.2 SVG flamegraphs via `heaptrack_print` + inferno

`heaptrack_print --flamegraph-cost-type <cost> -F <out.folded> -f <trace>`
writes collapsed-format stacks per cost dimension to a file, ready
to feed into `inferno-flamegraph`. **Watch the flags:** `-F` is the
*output path* (`--print-flamegraph`), and the cost is selected by
`--flamegraph-cost-type`. Pass `-p 0 -a 0 -T 0` to suppress the
default text reports on stdout. One trace produces **four distinct
flamegraphs**, each answering a different question.

#### 5.2.1 Cost dimensions

| Cost | What you read off it | When to use |
|---|---|---|
| **`peak`** | "What was holding memory at the high-water mark?" — the worst-case resident-set composition | Hunting OOMs / large RSS |
| **`leaked`** | "Which call paths allocated bytes never freed by program exit?" | Pinpointing memory leaks |
| **`allocations`** | "Which call paths make the most malloc calls?" — count, not bytes | Finding malloc churn (allocator pressure, fragmentation risk) |
| **`temporary`** | "Which call paths allocate then free shortly after?" | Identifying arena candidates — short-lived allocations are wasted work |

heaptrack 1.5 only supports these four cost types (`heaptrack_print
--help` is authoritative). Earlier drafts of this guide listed an
`allocated` dimension; that was a typo, not a real cost.

#### 5.2.2 Single-cost example

```bash
heaptrack_print -p 0 -a 0 -T 0 \
  --flamegraph-cost-type peak \
  -F mem-peak.folded \
  -f heaptrack.franky-test.*.zst
inferno-flamegraph \
  --title "franky-test — peak heap by call site" \
  --countname=bytes \
  --colors=mem \
  mem-peak.folded > mem-peak.svg
```

#### 5.2.3 All four flamegraphs in one shell loop

```bash
TRACE=heaptrack.franky-test.*.zst
OUT=./flamegraphs
mkdir -p "$OUT"

for entry in \
    "peak:Peak heap by call site" \
    "leaked:Leaked allocations" \
    "allocations:Allocation count by call site" \
    "temporary:Short-lived allocations"
do
    cost="${entry%%:*}"
    title="${entry#*:}"
    heaptrack_print -p 0 -a 0 -T 0 \
        --flamegraph-cost-type "$cost" \
        -F "$OUT/mem-$cost.folded" \
        -f $TRACE
    inferno-flamegraph \
        --title "$title" \
        --countname=bytes \
        --colors=mem \
        "$OUT/mem-$cost.folded" > "$OUT/mem-$cost.svg"
    echo "→ $OUT/mem-$cost.svg"
done
```

Output: four SVGs in `./flamegraphs/`, browsable side-by-side. The
`--colors=mem` palette greens-on-greys distinguishes memory
flamegraphs from CPU at a glance.

#### 5.2.4 What to expect for franky specifically

- **`peak`** — provider-side response buffers (`sse.zig`,
  `partial_json.zig`) plus transcript `ArrayList` storage.
- **`leaked`** — should be empty or near-empty; the test runner's GPA
  already fails on leaks. Non-empty means a real bug surfaced by an
  external tracer the GPA missed (e.g. C-malloc allocations from
  vendored deps).
- **`temporary`** — likely shows `std.fmt.allocPrint` callers, JSON
  parse paths, short-lived dupe()s. Candidates for migration to
  `ArenaAllocator` if the surrounding scope permits.

#### 5.2.5 Heaptrack version note

`heaptrack_print --print-flamegraph` ships in heaptrack 1.4+. Older
versions (≤ 1.3) exposed only the text `--print-*` reports. Verify
with `heaptrack_print --help | grep -i flamegraph`. If the flag is
missing, upgrade heaptrack — the text-only reports in §5.3 cover the
worst case but lose the call-graph view.

Note also that the `.zst` suffix needs `zstd` on `$PATH` at the time
heaptrack was invoked; otherwise heaptrack 1.5 falls back to `.gz`.
Both work as inputs to `heaptrack_print -f`. The `franky-profile`
driver accepts either suffix when locating the trace.

### 5.3 Headless text reports (no inferno)

When inferno isn't available — minimal CI runners, log-only
debugging — `heaptrack_print` produces text reports directly:

```bash
heaptrack_print heaptrack.franky-test.*.zst         # full report
heaptrack_print --print-leaks heaptrack.*.zst       # leaks only
heaptrack_print --print-peaks heaptrack.*.zst       # peak heap allocators
heaptrack_print --print-temporary heaptrack.*.zst   # short-lived allocs
```

Pipe through `awk` / `grep` / `sort -k <bytes-column>` for terminal
analysis.

### 5.4 Built-in Zig allocator trace (no external tool)

`std.heap.GeneralPurposeAllocator(.{ .verbose_log = true })` logs
every allocation/free with a stack trace. The franky test runner
already uses GPA with `.safety = true`, so **leak reports already
print at the end of every test run**. To enable verbose allocation
tracing for a session:

```zig
// In test_helpers.zig — temporary, for one profiling session
var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
    .verbose_log = true,
}).init;
```

The output is a textual stream of `alloc N bytes at <stack>` lines —
not a flamegraph, but searchable, diff-able, and immune to symbol-
resolution problems. Useful when heaptrack's `LD_PRELOAD` hook can't
attach (containers without `LD_PRELOAD` permission, debuggers
already attached, etc.).

---

## 6. Profiling specific scenarios

### 6.1 A single agent-loop turn under perf

The `franky-agent_loop_test` integration binary runs end-to-end
faux-provider turns. Profile that binary instead of `franky-test` to
get a tighter call graph focused on the runtime loop:

```bash
zig build profile -Dprofile-filter=parallel -- --binary franky-agent_loop_test --mode cpu
```

Or by hand:

```bash
zig build test-profile -Doptimize=ReleaseSafe -Dprofile-filter=parallel
perf record -F 997 --call-graph fp -o perf.data -- \
  ./zig-out/bin/franky-agent_loop_test
perf script --input perf.data | inferno-collapse-perf | inferno-flamegraph > loop.svg
```

### 6.2 Tool-call hot paths (`coding/tools/*`)

The unit-test binary contains every tool's tests. Filter at build time:

```bash
zig build profile -Dprofile-filter="edit tool"     # ~20 tests
zig build profile -Dprofile-filter="grep tool"     # ~15 tests
zig build profile -Dprofile-filter="find tool"     # ~10 tests
```

Run each separately to isolate per-tool hotspots.

### 6.3 SSE parse / partial-JSON parse

Two of the highest-traffic code paths during a real session live in
`src/ai/sse.zig` and `src/ai/partial_json.zig`. Both have dedicated
tests:

```bash
zig build profile -Dprofile-filter="sse:"
zig build profile -Dprofile-filter="partial_json:"
```

Profile these in `ReleaseFast` (`-Doptimize=ReleaseFast`) to catch
what the optimised build keeps in the hot loop.

---

## 7. Zig-specific gotchas

These are why the previous draft of this guide existed; the practical
sections above lean on them implicitly.

### 7.1 Allocator visibility

External tools like `heaptrack` hook the C `malloc`/`free`
ABI. franky's test allocator is `std.heap.GeneralPurposeAllocator`,
which calls `mmap`/`munmap` for large allocations and a free list for
small ones. **`heaptrack` may under-count small Zig allocations**
because GPA serves them from its own pages without per-call `malloc`
hits.

For an apples-to-apples view, switch the test allocator to
`std.heap.c_allocator` (which goes straight to libc malloc) for the
profiling run only. Editing `test_helpers.zig` to use `c_allocator`
gives external tools full visibility at the cost of slightly different
allocation patterns. Don't ship that change.

### 7.2 ArenaAllocator + heaptrack

`ArenaAllocator` allocates a few large pages and serves many small
allocations from them. Heaptrack sees the few large allocs; it does
**not** see the per-object slicing inside the arena. This is by
design — arenas are intentionally allocation-cheap — but means
"missing per-call entries" in heaptrack output is expected, not a
bug.

If you need per-object visibility through an arena, wrap it in a
custom debug allocator that records every `alloc()` call to a side
log. Drop-in replacement during the profiling session only.

### 7.3 Frame-pointer preservation

`--call-graph fp` (recommended in §4.1) only works because the
`test-profile` build sets `omit_frame_pointer = false` on its module
(§3). Without that, `ReleaseSafe` and `ReleaseFast` strip
`%rbp`-as-FP and perf falls back to single-leaf samples — the
flamegraph collapses to a single tower with no caller context.

If your flamegraph looks suspiciously flat (one or two tall stacks
that don't branch), check that the binary actually has frame
pointers:

```bash
# Frame pointers preserved → "push %rbp" + "mov %rsp,%rbp" in prologues
objdump -d ./zig-out/bin/franky-test | head -50 | grep -E "push.*rbp|mov.*rsp.*rbp"
```

If you see neither, the `omit_frame_pointer = false` didn't take
effect — re-check that `test-profile` is using the FP-preserved
module from §3, not the regular `test_module`.

For deeply-inlined hot loops (typical in `ReleaseFast`) where even
with frame pointers some intermediate frames are gone, fall back to
`--call-graph dwarf,16384` — it pays the larger perf.data size in
exchange for full DWARF stack walking. Don't make `dwarf` the default;
the file size explosion makes long captures unmanageable (§4.1 table).

### 7.4 errdefer + signals

If a test panics or aborts, perf still records what it captured — but
the data may end mid-stack. Heaptrack handles abort gracefully via its
shutdown hook. `errdefer` chains run normally either way; they don't
affect the profiler.

---

Every artefact is directly viewable on the PR (CPU SVG + four memory
SVGs). The `peak.svg` is usually the first to look at; `leaked.svg`
should be empty (otherwise a real bug). The raw `.zst` is bundled
too so a different cost dimension can be re-rendered locally without
re-running the test suite.

Even if no comparison is automated, the artefacts are eyeballable on
every PR — the diff between yesterday's and today's CPU tower
silhouette plus changes in peak heap catches regressions humans
would never spot in the test count.

---

## 9. Reference

| Step | Linux command |
|---|---|
| **One-shot** (CPU + 4-cost memory) | `zig build profile -- --binary franky-test` |
| One-shot, narrowed | `zig build profile -Dprofile-filter=parallel -- --binary franky-agent_loop_test` |
| Verify tools / list binaries | `zig build profile -- --check` / `zig build profile -- --list` |
| Build profilable tests | `zig build test-profile -Doptimize=ReleaseSafe` |
| Build profilable tests, filtered | `zig build test-profile -Dprofile-filter=PATTERN` |
| Capture CPU (recommended) | `perf record -F 997 --call-graph fp -o perf.data -- <binary>` |
| Capture CPU (LBR alt.) | `perf record -F 997 --call-graph lbr -o perf.data -- <binary>` |
| Capture CPU (DWARF fallback) | `perf record -F 997 --call-graph dwarf,16384 -o perf.data -- <binary>` |
| CPU → folded | `perf script --input perf.data \| inferno-collapse-perf > cpu.folded` |
| CPU → SVG | `inferno-flamegraph cpu.folded > cpu.svg` |
| Capture memory | `heaptrack <binary>` → `heaptrack.*.zst` (or `.gz` if zstd not installed) |
| Memory → folded (one cost) | `heaptrack_print -p 0 -a 0 -T 0 --flamegraph-cost-type <peak\|leaked\|allocations\|temporary> -F mem.folded -f <trace>` |
| Memory → SVG | `inferno-flamegraph --countname=bytes --colors=mem mem.folded > mem.svg` |
| Memory → all 4 SVGs | shell loop in §5.2.3 |
| Memory → text reports | `heaptrack_print --print-peaks \| --print-leaks \| --print-temporary <trace.zst>` |
| Differential CPU | `inferno-diff-folded before.folded after.folded \| inferno-flamegraph > diff.svg` |
| Filter tests | `<binary> --test-filter "<substring>"` |

The `inferno-*` family also includes `inferno-collapse-vtune`,
`inferno-collapse-dtrace`, `inferno-collapse-sample` (macOS Sample),
and others — useful when you've recorded with a different acquisition
tool and still want the same SVG renderer.
