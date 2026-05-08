# Stream channel capacity limit

## Summary

The per-turn stream channel (`streamChannel` in `src/agent/loop.zig`) has a
fixed-capacity ring buffer. If a single model response generates more events
than the capacity allows, the worker thread **deadlocks** and the response never
appears in the web UI.

Current capacity: **65 536 events** (set in `src/agent/loop.zig`
`streamChannel`).

---

## Root cause

`registry.stream` fills the channel synchronously — the HTTP response is fully
buffered in memory first, then `runFromSse` pushes every event to the channel in
a tight loop. The drain loop (the `while (stream_ch.next(io))` block) runs on
the **same thread**, so it cannot run until `registry.stream` returns.

`channel.push` blocks when the ring is full, waiting for space that the consumer
never creates. One thread, two roles, one mutex → deadlock.

```
worker thread
│
├─ registry.stream(... .out = &stream_ch)   ← pushes N events synchronously
│    ├─ event 1 … 65 536  → push succeeds
│    └─ event 65 537      → push BLOCKS waiting on not_full
│                              ↑ consumer never runs → deadlock
│
└─ while (stream_ch.next(io)) |ev| { ... }  ← never reached
```

---

## How it was discovered

A session using **deepseek-v4-flash:cloud** via `openai-gateway` produced no
response in the web UI. The HTTP trace (`transcript2.txt`) showed a successful
200 response with ~1 MB of SSE data, ruling out network or model errors.

The trace contained two phases:

| Phase | Count | Event type |
|---|---|---|
| Reasoning (`delta.reasoning`) | ~1 003 | `thinking_delta` |
| Content (`delta.content`) | ~3 195 | `text_delta` |
| Overhead (start, done, diagnostic) | ~10 | various |
| **Total** | **~4 208** | |

The previous channel capacity was **4 096**. After commit `8fb9913`
(`fix(deepseek): reasoning handling`) added `thinking_delta` events for the
reasoning phase, the total crossed 4 096 and deadlocked. Before that fix, only
the ~3 195 content events were generated, staying under the cap — the deadlock
was latent.

---

## Current mitigation

Capacity raised to **65 536** (commit after this doc). This gives a ~12× safety
margin over the observed peak and covers models producing up to ~60 K output
tokens before the limit is hit again.

A high-watermark log warning fires at ≥ 75 % (≥ 49 152 events):

```
WARN loop stream_channel_high_watermark events=51000/65536 (77%) — ...
```

A debug-level usage log fires on every turn to make trends visible in traces.

---

## Affected scenarios

| Scenario | Event count | Safe with 65 536? |
|---|---|---|
| Short chat response (~500 tokens) | ~500 | Yes |
| Long code generation (~4 K tokens) | ~4 000 | Yes |
| DeepSeek reasoning + content (~5 K events) | ~5 300 | Yes |
| Very long response (~60 K tokens) | ~60 000 | Yes (marginal) |
| 60 K tokens + heavy reasoning | > 65 536 | **No — deadlock** |

---

## Permanent fix options

### Option A — Unbounded per-turn buffer (recommended)

Replace `stream_ch` with an `ArrayList(StreamEvent)` that appends during the
provider phase and iterates during drain. No ring, no capacity, no blocking.
Requires changing the `out: *Channel` parameter in all provider `streamFn`
implementations to accept a more general interface or a concrete `ArrayList`.

### Option B — Drop-on-full push

Change `channel.push` to drop the oldest item (calling `drop_fn`) instead of
blocking when the ring is full and a drop function is set. This prevents the
deadlock at the cost of losing the earliest events (typically early
`thinking_delta` chunks, which are less critical than the final answer).

Concrete change in `src/ai/channel.zig`:
```zig
// In push(), replace the blocking wait with a drop when drop_fn is set:
if (self.len == self.capacity) {
    if (self.drop_fn) |drop| {
        const oldest = self.ring[self.head];
        drop(oldest, self.drop_allocator.?);
        self.head = (self.head + 1) % self.capacity;
        self.len -= 1;
    } else {
        self.not_full.waitUncancelable(io, &self.mutex);
        continue;
    }
}
```

### Option C — Concurrent provider thread

Spawn a dedicated thread for `registry.stream` so provider and consumer run
concurrently. Backpressure then works as intended and any capacity is safe.
Higher implementation complexity; the existing `AgentChannel` in `proxy.zig`
already uses this pattern successfully.

---

## Monitoring

Watch for `stream_channel_high_watermark` in logs. If it appears consistently,
increase the capacity constant in `streamChannel` or implement Option A/B above.

The debug log `stream_channel_usage` emits on every turn and is useful for
tracking event-count growth over time as new models are added.
