# franky self-improvement

How to use franky's cross-session analyzer to surface patterns —
failing tools, model quirks, doc gaps — as a backlog of feature
requests and bug reports you (or franky-as-agent) can act on.

## TL;DR

After you've run a few sessions and triggered `/diagnostics` in some of
them, run either:

```sh
zig build doctor                           # all-models, cross-model report
zig build doctor -- --model gemini-2.5-pro # filter to one model
```

Or, from inside a live session:

```
/improve   # interactive mode — defaults to current session's model
/improve   # proxy mode (web UI) — same
```

You get back a markdown report with one section per detected pattern,
each shaped like a draft feature request: title, type, severity,
evidence, hypothesis, suggested action, references. Reports persist to
`~/.franky/improvements/<model>/<unix_ms>.md` (or `_global/` when no
`--model` filter is applied).

## Why this exists

`/diagnostics` (see [`diagnostics.md`](diagnostics.md)) flags anomalies
*per session*. That works for "what went wrong in the conversation I
just had?" but doesn't help with "what's the recurring failure mode
across 30 sessions on this model?"

`franky doctor` mines all per-session summaries, runs detectors, and
produces a report meant to feed straight into spec/roadmap authoring.
Each finding is structured so a human can read it AND an agent can
extract a single section as a one-shot prompt to implement the
suggested action.

## Data flow

```
session run
  ↓
/diagnostics invoked
  ↓
~/.franky/diagnostics/<sid>/12345.txt    ← human-readable report
~/.franky/diagnostics/<sid>/summary.json ← machine-readable summary
  ↓
franky doctor / /improve
  ↓
load all summary.json files
  ↓
aggregate + run 4 detectors
  ↓
~/.franky/improvements/<model>/<unix_ms>.md   ← feature-request-shaped report
```

The pipeline is **opt-in per session** — only sessions where you
invoke `/diagnostics` produce a `summary.json`. Sessions that finish
without it are invisible to the analyzer. (Auto-emitting summaries at
session-end is a v3 follow-up.)

## The detectors (v2.0)

Four heuristics ship today. Each fires when its threshold is crossed
(simple count: low ≥2, medium ≥5, high ≥10).

| Detector | Type | Trigger |
|---|---|---|
| `edit_no_match retry loops` | improvement | global `edit_no_match` count ≥ 2 |
| `unbounded reads — pagination not used` | improvement | global `read_too_large` + `read_line_too_large` count ≥ 2 |
| `degenerate (zero-content) turns on <model>` | bug | per-model `degenerate` anomaly count ≥ 2 |
| `prose tool calls — enable --text-tool-call-fallback on <model>` | improvement | per-model `prose_tool_call` anomaly count ≥ 2 |

Adding new detectors is mechanical: add a `fn detectX(allocator, *Aggregate) anyerror!?Finding`
to `src/coding/improvement.zig` and register it in the `detectors` array
inside `findings()`.

## The finding schema

Every finding in the rendered report has six sections plus a
machine-readable JSON tail:

```markdown
## Finding N: <Type> — <title>

**Type:** improvement | bug | investigation
**Severity:** low | medium | high
**Occurrences:** N across M sessions

### Evidence
- short bullet describing the count + scope

### Hypothesis
multi-paragraph explanation of WHY this pattern likely exists

### Suggested action
concrete change description — file paths, rough LOC estimate,
canonical-fix template references

### References
- /Users/.../diagnostics/<sid>/<ts>.txt   ← drill-back to per-session detail
- ... (max 5 sample references)

### Evidence (machine-readable)
```json
{"occurrences":N,"sessions_affected":M,"sample_session_ids":[...]}
```
```

The machine-readable JSON block is stable across releases — agents
parsing the file by section can rely on it.

## Triage workflow

1. **Run the report**: `zig build doctor` (or `/improve` mid-session).
2. **Skim the header**: total sessions, failure %, anomaly count. If
   percentages look outlier-y, the report's worth reading carefully.
3. **For each finding**:
   - Read **Evidence** + **Hypothesis** to decide if the pattern is
     real or noise.
   - If real: copy the **Suggested action** into a v2.md / v3.md row,
     CHANGELOG candidate, or directly hand it to franky as a one-shot
     prompt ("implement the suggested action from the finding below").
   - For deeper context, follow a path in **References** to the
     per-session TXT report — that has turn-by-turn detail.
4. **For agent-driven implementation**:
   - The machine-readable JSON block lets you programmatically pull
     the sample session IDs.
   - From a session ID, the per-session `transcript.json` is at
     `~/.franky/sessions/<sid>/transcript.json` (when persisted).
   - Sample prompt: *"Read finding section N from
     `~/.franky/improvements/<model>/<ts>.md` and implement the
     'Suggested action'. Verify by re-reading the existing edit tool
     description in `src/coding/tools/edit.zig`."*

## File layout

```
~/.franky/
├── diagnostics/
│   └── <session_id>/
│       ├── <unix_ms>.txt    ← per-/diagnostics-invocation human report
│       └── summary.json     ← deterministic; latest invocation wins
└── improvements/
    ├── <model_id_safe>/     ← per-model reports (slashes/colons → dashes)
    │   ├── <unix_ms>.md
    │   └── <unix_ms>.md
    └── _global/             ← cross-model reports (no --model filter)
        └── <unix_ms>.md
```

Model id sanitization: `models/gemini-2.5-pro:v1 beta` →
`models-gemini-2.5-pro-v1-beta`. Idempotent; safe to re-run.

## CLI surface

```
franky doctor [options]
  --model NAME              Filter to summaries from this model.
                            Default: all models (writes to _global/).
  --days N                  No-op today (deferred — see v3 follow-up).
  --out PATH                Write report to PATH instead of the
                            default ~/.franky/improvements/...
  --no-persist              Print to stdout only.
  --diagnostics-dir PATH    Override the diagnostics root.
  -h, --help                Show help.
```

Slash command (interactive + proxy):
```
/improve
```

No arguments — defaults to filtering by the active session's model,
which is the most useful default ("what's wrong with what I'm using
right now?"). Reports persist to disk identically to the `franky
doctor` path.

## Schema versioning

`summary.json` carries a `schema_version` integer. The current writer
emits `1`. The aggregator refuses to parse unknown versions
(`UnsupportedSchemaVersion`). When the schema changes incompatibly:

1. Bump the writer (`coding/diagnostics.zig::toJson`) to `schema_version: 2`.
2. Update the parser (`coding/improvement.zig::parseSummary`) to accept
   both versions, or reject `1` with a migration hint.
3. Add a CHANGELOG entry.

Forward-compatible additions (new fields) don't need a version bump —
the parser is missing-field tolerant.

## Code references

| What | Where |
|---|---|
| `Report` (per-session struct) | `src/coding/diagnostics.zig` |
| `Report.toJson` (writes summary.json) | `src/coding/diagnostics.zig` |
| `Summary` (per-session, parsed back) | `src/coding/improvement.zig` |
| `Aggregate` (cross-session) | `src/coding/improvement.zig` |
| `Finding` (one detected pattern) | `src/coding/improvement.zig` |
| `parseSummary`, `loadAggregate` | `src/coding/improvement.zig` |
| `findings()` + 4 detectors | `src/coding/improvement.zig` |
| `render()` (markdown emitter) | `src/coding/improvement.zig` |
| `runAndPersist()` (orchestration) | `src/coding/improvement.zig` |
| `franky doctor` CLI binary | `src/bin/franky_doctor.zig` |
| `/improve` slash (interactive) | `src/coding/modes/interactive.zig::interactiveImproveHandler` |
| `/improve` slash (proxy) | `src/coding/modes/proxy.zig::improveHandler` |

## Limits and what's deferred

The current implementation deliberately stops short of:

- **Auto-injection of suggestions back into the system prompt.** Out
  of scope by design — humans review before any change reaches a live
  session. Tracked as a v3 follow-up.
- **Auto-codebase patching.** Same reason — agent-driven implementation
  of findings is supported via human-in-the-loop prompting, not via
  silent self-modification. Tracked as a v3 follow-up.
- **`--days N` time-window filtering.** Accepted as a CLI flag for
  forward compatibility; currently a no-op (uses all summaries).
  Implementing this requires reading the file mtime or adding a
  session-started timestamp to summary.json. Tracked as a v3 follow-up.
- **Per-session-end auto-emit of `summary.json`.** Today summaries
  only get written when `/diagnostics` is invoked; sessions where the
  user doesn't run it are invisible to the analyzer.
- **More detectors.** The current four cover the highest-signal
  patterns observed in v1.x development. New detectors are mechanical
  to add (one function in `improvement.zig`).
