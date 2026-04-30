# Diagnosing franky

A field guide for figuring out *why* a turn went sideways. Written
after the v1.29.0 diagnostics-everywhere bundle landed; assumes a
binary at v1.29.0 or newer.

## TL;DR — `/diagnostics` (interactive *and* proxy mode)

If you're in `franky --mode interactive`, type:

```
/diagnostics
```

If you're in `franky --mode proxy` (web UI), the same command
works — type it in the composer or send `POST /command` with
body `/diagnostics`. The report renders as a system message in
the conversation pane *outside the LLM context* (slash output
never appends to the transcript that gets sent to the model).

Either mode runs the entire process documented below in one shot —
walks the live transcript, flags anomalies, prints expected paths
to matching HTTP trace files / reducer-state dumps, emits one
recovery hint per flagged anomaly, **and persists the rendered
report to disk** at:

```
~/.franky/diagnostics/<session_id>/<unix_ms>.txt
```

(Interactive mode synthesizes `interactive-<startup_ms>` as the
session id since it has no on-disk session per v1 spec §J. Proxy
uses its real ULID. Persistence is best-effort — a disk-write
failure shows up at the bottom of the report but doesn't fail
the command.) Source: `src/coding/diagnostics.zig`. Outside
those two modes (or when analyzing an *old* session by hand) the
rest of this doc covers the underlying jq / file recipes.

## Quick map: where do I look first?

| Symptom | Open this first |
|---|---|
| "Assistant message has weird content / fake tool calls" | `~/.franky/sessions/<id>/transcript.json` — `messages[N].diagnostics` |
| "Web UI says disconnected" | `franky --log-level warn` stderr; look for `proxy subscriber.*` lines |
| "Turn ended with no output but no error" | `~/.franky/sessions/<id>/events/turn-<N>.reducer-dump.json` |
| "Provider rejected my request" | `--http-trace-dir /tmp/trace`, then read the matching `.txt` file |
| "Tool call args came through corrupted" | HTTP trace `--- response body ---`, grep for `functionCall` or `tool_calls` |
| "Bash output was truncated" | `<session>/bash/<call_id>.log` |
| "Sub-agent's full conversation" | `<session>/subagents/<call_id>/transcript.json` |

### Anomaly classes flagged

The analyzer flags five classes of trouble per assistant turn,
listed by the worked-example order in this doc:

| Anomaly | Trigger |
|---|---|
| `DEGENERATE` | `Message.diagnostics.was_degenerate=true` (clean stop, zero content) |
| `PROSE_TOOL_CALL` | First text content matches `^call:NAME{...}` (Gemini) or `{"name":"X","parameters":{...}}` (JSON shape) |
| `THINKING_BUDGET_EXHAUSTION` | `parts_seen=0 AND candidates_tokens=0 AND thoughts_tokens>0` |
| `SAVED_ERROR` | Pre-v1.29.0 `Message.error_message` field non-null |
| `TOOL_ERROR` | One or more `tool_result` messages on this turn have `is_error=true` (v1.29.3) |

For `TOOL_ERROR` the report renders one bullet per failed tool
call with the tool name, call id, code, message, the
provider-supplied `hint` (if any), and a targeted recovery
suggestion. Recognized codes include `timeout`, `auth`,
`rate_limited`, `transport`, `role_denied`, `tool_blocked`,
`path_escape_workspace`, `edit_no_match`, `bash_timeout`,
`read_too_large`, plus the sub-agent `agent_error` envelope —
keyword-matching also catches deeper error_messages so
generic-envelope failures still get a targeted hint.

## The four diagnostic layers

Franky surfaces information at four nested layers. Each one builds
on the previous, and each one is independently optional — you can
turn on as much as you need.

```
┌───────────────────────────────────────────────┐
│ Layer 4: HTTP traces (--http-trace-dir)       │  raw request/response bytes
├───────────────────────────────────────────────┤
│ Layer 3: Reducer-state dumps (auto)           │  reducer buffers on degenerate turns
├───────────────────────────────────────────────┤
│ Layer 2: Empty-response error_ev (auto)       │  loud failure on silent-stop turns
├───────────────────────────────────────────────┤
│ Layer 1: Message.diagnostics (always on)      │  per-turn metrics on every saved message
└───────────────────────────────────────────────┘
```

## Layer 1: `Message.diagnostics`

Every saved assistant message carries an optional `diagnostics`
struct populated by the agent loop. The field appears in
`transcript.json` only when at least one sub-field is non-default,
so old transcripts round-trip unchanged.

### Schema

```jsonc
{
  "role": "assistant",
  "content": [...],
  "stopReason": "stop",
  "diagnostics": {
    "traceId": "1777498943846-0001",     // matches --http-trace-dir filename stem
    "finishReasonRaw": "STOP",            // raw provider string ("STOP", "tool_calls", "end_turn", …)
    "partsSeen": 4,                       // SSE events that carried content
    "candidatesTokens": 12,               // provider's output token count
    "thoughtsTokens": 561,                // Gemini-only: reasoning tokens
    "textEvents": 3,                      // text_delta events the Reducer absorbed
    "thinkingEvents": 0,
    "toolCallEvents": 0,
    "wasDegenerate": false                // true → finalize emitted zero content blocks
  }
}
```

### jq recipes

```sh
SID=$(ls -t ~/.franky/sessions/ | head -1)
SDIR=~/.franky/sessions/$SID

# Every degenerate turn in this session
jq '.messages[] | select(.role=="assistant" and .diagnostics.wasDegenerate)' \
   "$SDIR/transcript.json"

# Per-turn snapshot — type breakdown, token counts, trace_id
jq -r '.messages[] | select(.role=="assistant") |
       [.timestamp, .stopReason,
        .diagnostics.traceId // "-",
        .diagnostics.partsSeen // 0,
        .diagnostics.candidatesTokens // 0,
        .diagnostics.thoughtsTokens // 0] | @tsv' \
   "$SDIR/transcript.json"

# Find the trace file for a specific turn
jq -r '.messages[5].diagnostics.traceId' "$SDIR/transcript.json"
# → 1777498943846-0001
ls /path/to/trace-dir/1777498943846-0001-*.txt
```

### What the counts mean

- **`partsSeen == 0` AND `wasDegenerate == true`** → provider sent
  the terminal SSE event with no content events preceding it.
  This is the classic Gemini "thought then stopped" failure.
- **`thoughtsTokens > 0` AND `candidatesTokens == 0`** → model
  burned reasoning budget without producing output. Try lowering
  `--thinking` or raising the model's effective output budget.
- **`textEvents > 0` AND `wasDegenerate == false`** but the saved
  text "looks like" a fake tool call — the model emitted prose-shaped
  tool-call syntax instead of a structured `functionCall`. The
  text content is real; this is a model regression, not a parser
  bug.

### Code references

- `src/ai/types.zig` — `pub const Diagnostics`
- `src/ai/stream.zig` — `Reducer.finalize` attaches diagnostics
- `src/coding/session.zig` — JSON serializer/deserializer

## Layer 2: empty-response detection

When a provider sends a clean `stop_reason: stop` terminal but
emits zero text, zero thinking, and zero tool calls, the
provider's stream driver promotes the close from
`StreamEvent.done` to
`StreamEvent.error_ev{ code = .empty_response }`. The agent loop
maps that to `AgentError.EmptyResponse` and surfaces it through
the standard `agent_error` event channel.

### What you'll see

**Print mode** — stderr:
```
agent error code=empty_response message=google-gemini returned stop_reason=stop but emitted no content (parts_seen=0, candidates_tokens=0, thoughts_tokens=561). Likely model regression — re-run with adjusted thinking budget or a format-reminder nudge.
```

**Web UI / proxy mode** — same message via the SSE `agent_error`
event; renders as a red toast.

**RPC mode** — `agent_error` JSON-RPC notification.

**Saved transcript** — the empty-response turn does **not** save an
empty assistant message; it ends the run cleanly with the error
visible in stderr / the UI. The turn that triggered the failure
is still preserved in the transcript up to the user message.

### Recovery suggestions

```sh
# Lower thinking budget
franky --thinking low ...
# or unset for Gemini Pro (it requires thinking but its default budget is fine)
franky --thinking off ...

# Inject a format nudge into the system prompt
franky --append-system-prompt "When calling a tool, emit a structured \`functionCall\` part. Do not describe the call in prose." ...

# Switch to a different provider for the retry
franky --provider anthropic --model sonnet ...
```

### Code references

- `src/ai/errors.zig` — `Code.empty_response`, `AgentError.EmptyResponse`
- `src/ai/stream.zig` — `closeWithDiagnostics` helper (provider-side close path)
- `src/ai/providers/google_gemini.zig` — Driver state + close call
- `src/agent/loop.zig` — `agentErrorCode` mapping

## Layer 3: reducer-state dumps

When the Reducer is about to emit a `was_degenerate=true` message
AND the agent loop has a `reducer_dump_dir` configured, it
snapshots the Reducer's full internal state to disk *before*
finalize transfers ownership to the Message. This captures every
text/thinking/tool buffer that didn't make it into a content
block — useful when you suspect the parser dropped events that
should have produced content.

### Where dumps land

- **Print mode**: `<session>/events/turn-<N>.reducer-dump.json` (auto-wired)
- **Proxy / RPC / Interactive**: deferred to v1.30.0 — see
  `docs/spec/v2.md` §4.14 for the wiring plan.

`turn-<N>` is 0-based and resets per agent-loop run.

### Format

```jsonc
{
  "version": 1,
  "stopReason": "stop",
  "diagnostics": {
    "traceId": "1777498943846-0001",
    "finishReasonRaw": "STOP",
    "partsSeen": 0,
    "thoughtsTokens": 561,
    "textEvents": 0,
    "thinkingEvents": 0,
    "toolCallEvents": 0
  },
  "blockOrder": [
    {"kind": "text", "index": 0}
  ],
  "textBlocks": [
    {"len": 0, "text": ""}
  ],
  "thinkingBlocks": [],
  "toolCalls": []
}
```

`blockOrder` is the order in which content blocks would be
emitted. `textBlocks[i].len == 0` with no `thinkingBlocks` and no
`toolCalls` is the textbook degenerate signature.

### When to read a dump

- **Empty `textBlocks` and empty `thinkingBlocks`** → confirms
  the provider sent zero deltas. This is the empty-response case
  that Layer 2 already caught — the dump just gives you the proof.
- **Non-empty `textBlocks` but `was_degenerate=true`** → contradiction.
  Means a buffer was populated but then somehow not emitted. File
  a bug.
- **Non-zero `thinkingEvents` but empty `thinkingBlocks`** →
  Reducer counter and storage diverged. Bug.

### Code references

- `src/ai/stream.zig` — `Reducer.snapshotJson`, `Reducer.isLikelyDegenerate`
- `src/agent/loop.zig` — `dumpReducerSnapshot`

## Layer 4: HTTP traces (`--http-trace-dir`)

The deepest layer: the raw HTTP request and response, written
verbatim to disk before any parsing. Pair this with Layer 1's
`traceId` and you have a bidirectional link from any saved
message to the bytes that produced it.

### Enabling

```sh
# Per-run flag
franky --http-trace-dir /tmp/franky-trace ...

# Per-profile (settings.json or profile JSON)
{
  "http_trace_dir": "/tmp/franky-trace"
}

# Or env var via the CLI flag
FRANKY_HTTP_TRACE_DIR=/tmp/franky-trace franky ...   # not yet wired; use the flag
```

The directory is created with `mkdir -p` semantics. No rotation
in the current revision — clean it up yourself.

### File format

```
=== franky http trace ===
ts_ms: 1777498943846
seq: 1
provider: google-gemini
url: https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse&key=...
method: POST
status: 200
request_body_bytes: 12277
response_body_bytes: 324

--- request body ---
{"systemInstruction":{...},"tools":[{"functionDeclarations":[...]}],"contents":[...]}

--- response body ---
data: {"candidates":[{"content":{"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{...}}
```

Filename: `<ts_ms>-<seq:0>4>-<provider>.txt`. The `<ts_ms>-<seq>`
prefix matches `Message.diagnostics.traceId`.

**Important:** the request body for some providers includes
auth-bearing query parameters in the URL (Google AI Studio's
`?key=...`). Do not paste traces into public bug reports without
redacting them first.

### Useful greps

```sh
TRACE=/tmp/franky-trace

# Did the request actually include a tools array?
grep -c '"tools"\|"functionDeclarations"' $TRACE/*.txt

# Did the response contain a structured tool call?
grep -E 'functionCall|tool_calls|content_block_start.*tool_use' $TRACE/*.txt | head

# Per-trace size summary
for f in $TRACE/*.txt; do
  bytes=$(grep -m1 response_body_bytes "$f" | awk '{print $2}')
  status=$(grep -m1 '^status:' "$f" | awk '{print $2}')
  echo "$(basename $f) status=$status response=${bytes}B"
done | sort

# Pull just the response body of the most recent trace
LAST=$(ls -t $TRACE/*.txt | head -1)
awk '/^--- response body ---$/ { in_body=1; next } in_body' "$LAST"
```

### Linking trace ↔ transcript

```sh
SDIR=~/.franky/sessions/$(ls -t ~/.franky/sessions/ | head -1)

# Every (turn timestamp, trace_id) pair
jq -r '.messages[] | select(.role=="assistant" and .diagnostics.traceId) |
       [.timestamp, .diagnostics.traceId] | @tsv' "$SDIR/transcript.json"

# Pull the trace file for a specific turn
TID=$(jq -r '.messages[5].diagnostics.traceId' "$SDIR/transcript.json")
ls /tmp/franky-trace/${TID}-*.txt
```

### Code references

- `src/ai/http.zig` — `writeTraceFile` (returns the trace_id stem)
- `src/ai/providers/*.zig` — each provider captures `trace_id_owned` from `writeTraceFile` and forwards via `runFromSseWithTrace`

## Worked example A: "Gemini emitted prose-shaped tool calls"

**The symptom.** Saved transcript ends with:
```jsonc
{"role":"assistant","content":[{"type":"text","text":"call:read{path:src/coding/tools/grep.zig}"}],"stopReason":"stop"}
```

The text `"call:read{path:...}"` looks like a tool call but isn't —
it's prose. The model wrote it as text instead of emitting a
structured `functionCall` part.

**Diagnosis path.**

```sh
SID=$(ls -t ~/.franky/sessions/ | head -1)
SDIR=~/.franky/sessions/$SID

# 1. Confirm there's no structured tool_use block on that turn —
#    franky stores tool calls under content[].type == "toolCall".
jq '.messages[5].content | map(.type) | unique' "$SDIR/transcript.json"
# → ["text"]

# 2. Pull the diagnostics block for the suspect turn.
jq '.messages[5].diagnostics' "$SDIR/transcript.json"

# 3. Pull the matching trace file.
TID=$(jq -r '.messages[5].diagnostics.traceId' "$SDIR/transcript.json")
LAST=$(ls /tmp/franky-trace/${TID}-*.txt | head -1)

# 4. Did Gemini actually send a functionCall part?
grep -c '"functionCall"' "$LAST"
# 0 → no, model emitted prose

# 5. Did it send only text parts?
awk '/^--- response body ---$/ { in_body=1; next } in_body' "$LAST" \
  | jq -r '.candidates[0].content.parts[] | keys[]' 2>/dev/null | sort -u
# → ["text"]
```

**Conclusion.** Model regression. Provider parser is correct;
nothing to fix in franky. The model wrote a text approximation of
tool-call syntax. Mitigations:

- Inject a system-prompt nudge: `--append-system-prompt "Emit tool calls as structured functionCall parts, not as text descriptions."`
- Lower `--thinking`; this failure is correlated with thinking-budget exhaustion.
- Try a different model.

## Worked example B: "Gemini turn produced no output"

**The symptom.** Stderr shows:
```
agent error code=empty_response message=google-gemini returned stop_reason=stop but emitted no content (parts_seen=0, candidates_tokens=0, thoughts_tokens=561). …
```

**Diagnosis path.**

```sh
SID=$(ls -t ~/.franky/sessions/ | head -1)
SDIR=~/.franky/sessions/$SID

# 1. The reducer-dump file proves nothing came in.
ls "$SDIR/events/"
cat "$SDIR/events/turn-1.reducer-dump.json" | jq '.diagnostics, .blockOrder, .textBlocks | length'
# → diagnostics: {partsSeen: 0, candidatesTokens: 0, thoughtsTokens: 561}
#   blockOrder: 0
#   textBlocks: 0

# 2. The trace file shows the raw response.
TRACE=/tmp/franky-trace
LAST=$(ls -t $TRACE/*google-gemini*.txt | head -1)
awk '/^--- response body ---$/ { in_body=1; next } in_body' "$LAST"
# data: {"candidates":[{"content":{"role":"model"},"finishReason":"STOP",…}],
#       "usageMetadata":{"promptTokenCount":3619,"thoughtsTokenCount":561,…}}

# 3. Math check: candidates_token_count is absent (or 0). Model
#    truly produced 0 output tokens.
```

**Conclusion.** Real Gemini-2.5-pro failure mode: thought for N
tokens, then stopped without emitting any candidate. Pre-v1.29.0
this would have saved an empty assistant message and silently
wedged the next turn. Now it surfaces as a loud error_ev so you
can decide: retry with different settings, switch providers, or
reword the prompt.

## What's NOT in v1.29.0 (yet)

The following tier-2 items are catalogued in `docs/spec/v2.md`
§4.14 for a future v1.x release:

- **Per-turn event JSONL spill** (`<session>/events/<turn-N>.jsonl`).
  Every StreamEvent on its own line. Toggle with `--record-events`.
- **`franky replay <trace_file>`** — feeds a captured response
  body through the SSE parser deterministically. Lets you turn any
  failed trace into a regression-test fixture.
- **Provider fixture suite** — curated pathological traces under
  `test/fixtures/<provider>/<scenario>.txt` that CI walks on every
  build.
- **`franky doctor <session_id>`** — operator subcommand that
  walks transcript + traces + dumps and reports per-turn anomalies
  with suggested fixes.
- **Typed `error_ev` recovery taxonomy** — promote the freeform
  code string into a tag union with default recovery actions
  (retry with reduced thinking, retry with format nudge, surface
  to user). Closes the loop on auto-retry for the empty-response
  case.
- **Reducer-dump wiring for proxy / rpc / interactive** — print
  is auto-wired in v1.29.0; the other modes follow the same
  pattern but need their own session-dir-derivation plumbing.

## Quick reference card

```sh
# Enable HTTP traces (Layer 4)
franky --http-trace-dir /tmp/franky-trace ...

# Find the most recent session
SID=$(ls -t ~/.franky/sessions/ | head -1) ; SDIR=~/.franky/sessions/$SID

# Per-turn diagnostics summary
jq -r '.messages[] | select(.role=="assistant") |
       [.timestamp, .stopReason, .diagnostics.traceId,
        .diagnostics.partsSeen, .diagnostics.candidatesTokens,
        .diagnostics.thoughtsTokens, .diagnostics.wasDegenerate] | @tsv' \
   "$SDIR/transcript.json"

# Reducer dumps for degenerate turns
ls "$SDIR/events/" 2>/dev/null

# Trace file for a specific turn
TID=$(jq -r '.messages[N].diagnostics.traceId' "$SDIR/transcript.json")
ls /tmp/franky-trace/${TID}-*.txt

# Bash spill files
find "$SDIR/bash/" -ls 2>/dev/null

# Sub-agent transcripts
find "$SDIR/subagents/" -name transcript.json -ls 2>/dev/null
```
