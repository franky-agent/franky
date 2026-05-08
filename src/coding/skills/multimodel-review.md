---
name: multimodel-review
description: |
  Runs an identical code-review prompt across N models in parallel and
  aggregates findings by cross-model confidence. TRIGGER when: user
  invokes /review --multimodel.
auto_apply: []
---

# Multi-Model Code Review

Activate on `/review --multimodel` or `franky --skill multimodel-review` with the
`/review` slash command.

## Process

1. **Collect the diff.**
   Default: `git diff HEAD` (staged + unstaged). Accept an explicit path
   or revision if the user provided one (e.g. `/review src/agent/loop.zig`).

2. **Select profiles.**
   Priority order:
   a. `--profiles A,B,C` in the invocation argument — split on comma, use as-is.
   b. The `## Review configuration` block in this system prompt (populated from
      `settings.json → review.profiles` at session start).
   c. Auto-discovery fallback: call `list_subagent_presets` and select up to
      `max_models` profiles (default 4) whose names suggest code capability.

3. **Fan out in parallel — single tool-call batch.**
   Spawn one `code-audit` subagent per selected profile. All subagents receive
   the identical prompt:

   > "Review the following diff for correctness, security, and performance
   > issues. Report each finding on its own line as:
   > `file:line — description`
   > Include only real issues; omit style nits and formatting comments."
   > [paste full diff]

   Use `timeout_ms` from the Review configuration (default 180000).
   Use `preset: "code-audit"` and `profile: "<profile-name>"` for each call.

4. **Check quorum.**
   Count how many subagents returned output. If fewer than `min_models`
   (default 2), abort: "Multi-model review aborted: only N/M models
   responded (minimum: min_models required)."

5. **Aggregate.**
   Group findings semantically — same file, same concern, possibly different
   line numbers. Label each group:
   - `[all N]`  — every model flagged it → high confidence
   - `[N-1 of N]` — all but one → medium confidence
   - `[1 of N]`  — one model only → low confidence / disputed

6. **Render the unified report** (see Output format below).

## Output format

```
## Multi-Model Review  (N models · M findings)

### High confidence  [found by N/N]
- file:line — description

### Medium confidence  [found by N-1/N]
- file:line — description

### Low confidence  [found by 1/N]
- file:line — description  (model-name only)

### Profiles that timed out or errored
- profile-name: reason
```

Sort sections high → low confidence. Within each section, sort by file path.
