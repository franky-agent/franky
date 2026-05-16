# 🔍 Code Quality Guardrail Report

**Project**: .

**Scanned**: live

**Window**: 6 months ago

### Summary

| Zone | Count |
|---|---|
| 🟢 Green | 73 |
| 🟡 Yellow | 30 |
| 🟠 Orange | 12 |
| 🔴 Red | 7 |

<details>
<summary>📖 Understanding the Report — Zones &amp; Signals</summary>

Each file in the table below is scored on six signals. Every signal is classified into a **zone** (1–4) based on auto-calibrated percentile thresholds from the entire repository.

### Zone Colors

| Zone | Color | Percentile | Meaning |
|------|-------|------------|---------|
| 🟢 **Green** | 1 | ≥ p95 | Low risk — within normal bounds |
| 🟡 **Yellow** | 2 | p85 – p95 | Elevated — worth monitoring |
| 🟠 **Orange** | 3 | p60 – p85 | Warning — above typical range |
| 🔴 **Red** | 4 | < p60 | Critical — top tier of concern |

Percentiles are computed from the current snapshot of all tracked files. A **red** file is in the worst ~40% of the codebase for that signal; a **green** file is in the best ~5%.

### Signal Definitions

| Signal | Formula | What It Detects |
|--------|---------|------------------|
| **Hotspot** | `revisions × indent_mean` | Files that change often and are deeply nested — painful to maintain |
| **Complexity** | `indent_mean` | Average nesting depth; higher values indicate tangled control flow |
| **Revisions** | `revision count` | How many commits touched this file — churn-prone code |
| **Authors** | `distinct author count` | Many authors = diffusion of ownership |
| **Congestion** | `authors / revisions` | High ratio means many people edit a file that changes infrequently — coordination bottleneck |
| **Risk*** | `indent_mean × (1 - main_dev_pct)` | Complex code where no single author dominates — knowledge-loss danger |

### How to Use This

- **Red** files should be reviewed and refactored as soon as feasible.
- **Orange** files are trending toward red — schedule a review in the next iteration.
- **Yellow** files are above average but not urgent — keep an eye on them.
- **Green** files are fine; no action needed.

The **Risk** column combines complexity with knowledge-loss potential. A red risk zone means the file is complex *and* lacks a clear primary owner — if the main developer leaves, that knowledge is gone.

</details>

### Files

| File | Hotspot | Complexity | Revisions | Authors | Congestion | Risk |
|------|---------|------------|-----------|--------|------------|------|
| bench/harbor/franky_agent.py | 🟢 0.0 | 🟠 7.7 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🔴 |
| bench/harbor/__init__.py | 🟢 0.0 | 🟢 0.0 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🟢 |
| bench/__init__.py | 🟢 0.0 | 🟢 0.0 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🟢 |
| .containifyci/containifyci.go | 🟢 6.7 | 🟢 3.4 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| .zig-cache/o/9ea63b5a5d15316ae7ee58a6f5c1d319/dependencies.zig | 🟢 0.0 | 🟢 0.0 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🟢 |
| .zig-cache/o/a9cfc9d8fc3d796eec03d5c3167c0979/dependencies.zig | 🟢 0.0 | 🟢 0.0 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🟢 |
| .zig-cache/o/55769b804f88f674ec77d178ae3ac3eb/dependencies.zig | 🟢 0.0 | 🟢 4.0 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🔴 |
| .zig-cache/c/f26962e1673d34a9ed90ba1fdec1742c/options.zig | 🟢 0.0 | 🟢 0.0 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🟢 |
| .zig-cache/c/e1f66ac6c3dba1b8083d15747f8dd7b6/options.zig | 🟢 0.0 | 🟢 0.0 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🟢 |
| .zig-cache/c/228ba3c0c02a5af63f65e5aa6b2f4369/options.zig | 🟢 0.0 | 🟢 0.0 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🟢 |
| .zig-cache/c/a785c14eb9106dba5b57f3386ae037d5/options.zig | 🟢 0.0 | 🟢 0.0 | 🟢 0 | 🟢 0 | 🟢 0.00 | 🟢 |
| test/gitignore_test.zig | 🟢 10.2 | 🟢 3.4 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟢 |
| test/mode_test.zig | 🟢 6.4 | 🟡 6.4 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| test/agent_loop_test.zig | 🟡 38.3 | 🟡 6.4 | 🟡 6 | 🟢 2 | 🟢 0.33 | 🟢 |
| test/agent_class_test.zig | 🟡 36.8 | 🟢 5.3 | 🟡 7 | 🟢 2 | 🟢 0.29 | 🟢 |
| test/parallel_tools_test.zig | 🟡 19.3 | 🟡 6.4 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟡 |
| test/replay_test.zig | 🟡 18.5 | 🔴 9.2 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🔴 |
| test/kitchen_sink_test.zig | 🟢 13.5 | 🟢 4.5 | 🟢 3 | 🟢 1 | 🟢 0.33 | 🟢 |
| build.zig | 🟠 103.2 | 🟡 6.5 | 🟠 16 | 🟢 2 | 🟢 0.13 | 🟡 |
| src/sdk.zig | 🟢 7.9 | 🟢 2.0 | 🟡 4 | 🟢 2 | 🟢 0.50 | 🟢 |
| src/bin/franky_doctor.zig | 🟢 5.8 | 🟡 5.8 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/bin/gen_models.zig | 🟢 12.3 | 🟡 6.2 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/bin/franky_profile.zig | 🟢 10.6 | 🟢 5.3 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/bin/check_spec_anchors.zig | 🟢 8.8 | 🟢 4.4 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/bin/main.zig | 🟢 11.3 | 🟢 3.8 | 🟢 3 | 🟢 1 | 🟢 0.33 | 🟢 |
| src/bin/check_doc_links.zig | 🟢 4.7 | 🟢 4.7 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/tui/editor.zig | 🟢 13.3 | 🟡 6.7 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/tui/diff_renderer.zig | 🟢 7.0 | 🟡 7.0 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/tui/text_buffer.zig | 🟢 4.9 | 🟢 4.9 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/tui/region.zig | 🟢 5.8 | 🟢 5.8 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/tui/key_decoder.zig | 🟢 6.8 | 🟡 6.8 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/tui/buffer.zig | 🟢 6.1 | 🟡 6.1 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/tui/keybindings.zig | 🟢 4.3 | 🟢 4.3 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/tui/cell.zig | 🟢 9.5 | 🟢 4.8 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/tui/mod.zig | 🟢 1.8 | 🟢 1.8 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/global_allocator.zig | 🟢 0.0 | 🟢 0.0 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/agent/guardrails/guardrails.zig | 🟡 34.0 | 🟡 6.8 | 🟡 5 | 🟢 1 | 🟢 0.20 | 🟢 |
| src/agent/guardrails/compilation_guard.zig | 🟡 29.2 | 🟠 7.3 | 🟡 4 | 🟢 1 | 🟢 0.25 | 🟢 |
| src/agent/guardrails/stuck_detector.zig | 🟡 25.6 | 🟠 8.5 | 🟢 3 | 🟢 1 | 🟢 0.33 | 🟢 |
| src/agent/guardrails/finish_task.zig | 🟡 20.8 | 🟢 5.2 | 🟡 4 | 🟢 1 | 🟢 0.25 | 🟢 |
| src/agent/agent.zig | 🟠 93.9 | 🟠 7.8 | 🟠 12 | 🟢 2 | 🟢 0.17 | 🟡 |
| src/agent/types.zig | 🟡 61.6 | 🟡 6.8 | 🟡 9 | 🟢 2 | 🟢 0.22 | 🟠 |
| src/agent/loop.zig | 🔴 163.3 | 🟡 6.5 | 🔴 25 | 🟢 2 | 🟢 0.08 | 🟠 |
| src/agent/proxy.zig | 🟡 61.4 | 🟠 7.7 | 🟡 8 | 🟢 2 | 🟢 0.25 | 🟠 |
| src/agent/mod.zig | 🟢 6.0 | 🟢 2.0 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟢 |
| src/ai/http.zig | 🟠 96.0 | 🟢 5.3 | 🟠 18 | 🟢 2 | 🟢 0.11 | 🟢 |
| src/ai/stream.zig | 🟡 55.6 | 🟠 7.9 | 🟡 7 | 🟢 2 | 🟢 0.29 | 🟠 |
| src/ai/transform.zig | 🟢 13.3 | 🟡 6.7 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🟠 |
| src/ai/registry.zig | 🟡 41.5 | 🟢 4.1 | 🟡 10 | 🟢 2 | 🟢 0.20 | 🟡 |
| src/ai/sse.zig | 🟡 17.8 | 🟡 5.9 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟡 |
| src/ai/retry.zig | 🟡 20.6 | 🟡 6.9 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟡 |
| src/ai/providers/openai_gateway.zig | 🟢 8.1 | 🟢 4.1 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🟡 |
| src/ai/providers/faux.zig | 🟡 31.2 | 🔴 10.4 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟠 |
| src/ai/providers/openai_chat.zig | 🔴 119.6 | 🟡 7.0 | 🟠 17 | 🟢 2 | 🟢 0.12 | 🟡 |
| src/ai/providers/anthropic.zig | 🟠 110.5 | 🟠 7.9 | 🟠 14 | 🟢 2 | 🟢 0.14 | 🟡 |
| src/ai/providers/google_vertex.zig | 🟠 66.3 | 🟢 5.5 | 🟠 12 | 🟢 2 | 🟢 0.17 | 🟢 |
| src/ai/providers/openai_responses.zig | 🟠 98.6 | 🟠 8.2 | 🟠 12 | 🟢 2 | 🟢 0.17 | 🟡 |
| src/ai/providers/google_gemini.zig | 🟠 113.0 | 🟠 7.5 | 🟠 15 | 🟢 2 | 🟢 0.13 | 🟡 |
| src/ai/errors.zig | 🟡 44.9 | 🟢 5.6 | 🟡 8 | 🟢 2 | 🟢 0.25 | 🟡 |
| src/ai/partial_json.zig | 🟡 29.1 | 🔴 9.7 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟠 |
| src/ai/log.zig | 🟢 12.1 | 🟢 4.0 | 🟢 3 | 🟢 1 | 🟢 0.33 | 🟢 |
| src/ai/utils.zig | 🟢 11.9 | 🟡 6.0 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/ai/types.zig | 🟡 29.1 | 🟡 5.8 | 🟡 5 | 🟢 2 | 🟢 0.40 | 🟡 |
| src/ai/error_map.zig | 🟢 13.4 | 🟢 4.5 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟡 |
| src/ai/vendored/http_client.zig | 🟡 18.9 | 🔴 9.5 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🔴 |
| src/ai/mod.zig | 🟡 19.3 | 🟢 2.4 | 🟡 8 | 🟢 1 | 🟢 0.13 | 🟢 |
| src/ai/channel.zig | 🟡 36.5 | 🔴 9.1 | 🟡 4 | 🟢 2 | 🟢 0.50 | 🟡 |
| src/coding/extensions_builtin/echo.zig | 🟢 3.4 | 🟢 3.4 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/extensions_builtin/catalog.zig | 🟢 7.7 | 🟢 3.9 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🟡 |
| src/coding/restart.zig | 🟢 11.6 | 🟢 3.9 | 🟢 3 | 🟢 1 | 🟢 0.33 | 🟢 |
| src/coding/config.zig | 🟢 10.0 | 🟢 5.0 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/coding/tools/subagent.zig | 🟠 66.7 | 🟡 6.1 | 🟠 11 | 🟢 2 | 🟢 0.18 | 🟡 |
| src/coding/tools/grep.zig | 🟠 65.3 | 🟢 5.4 | 🟠 12 | 🟢 2 | 🟢 0.17 | 🟡 |
| src/coding/tools/web_search.zig | 🟢 12.7 | 🟢 4.2 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟡 |
| src/coding/tools/bash.zig | 🟡 46.2 | 🟢 5.1 | 🟡 9 | 🟢 2 | 🟢 0.22 | 🟢 |
| src/coding/tools/ls.zig | 🟡 45.7 | 🟢 5.1 | 🟡 9 | 🟢 2 | 🟢 0.22 | 🟢 |
| src/coding/tools/web_fetch.zig | 🟢 7.5 | 🟢 3.7 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🟡 |
| src/coding/tools/edit.zig | 🟠 95.1 | 🟡 5.9 | 🟠 16 | 🟢 2 | 🟢 0.13 | 🟡 |
| src/coding/tools/common.zig | 🟢 12.2 | 🟢 3.0 | 🟡 4 | 🟢 2 | 🟢 0.50 | 🟢 |
| src/coding/tools/write.zig | 🟡 30.2 | 🟢 5.0 | 🟡 6 | 🟢 2 | 🟢 0.33 | 🟡 |
| src/coding/tools/truncate.zig | 🟢 12.2 | 🟡 6.1 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🟠 |
| src/coding/tools/workspace.zig | 🟢 10.6 | 🟢 5.3 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🟠 |
| src/coding/tools/find.zig | 🟠 67.1 | 🟠 7.5 | 🟡 9 | 🟢 2 | 🟢 0.22 | 🟡 |
| src/coding/tools/read.zig | 🟡 43.6 | 🟢 4.8 | 🟡 9 | 🟢 2 | 🟢 0.22 | 🟡 |
| src/coding/terminal.zig | 🟢 5.2 | 🟢 5.2 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/modes/interactive.zig | 🔴 280.8 | 🟠 8.5 | 🔴 33 | 🟢 2 | 🟢 0.06 | 🔴 |
| src/coding/modes/web/prism.js | 🟢 11.3 | 🔴 11.3 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/modes/web/app.js | 🔴 116.2 | 🔴 10.6 | 🟠 11 | 🟢 2 | 🟢 0.18 | 🔴 |
| src/coding/modes/rpc.zig | 🔴 137.6 | 🟡 6.9 | 🔴 20 | 🟢 2 | 🟢 0.10 | 🟠 |
| src/coding/modes/proxy.zig | 🔴 219.6 | 🟢 5.8 | 🔴 38 | 🟢 2 | 🟢 0.05 | 🟠 |
| src/coding/modes/print.zig | 🔴 215.0 | 🟡 5.8 | 🔴 37 | 🟢 2 | 🟢 0.05 | 🟡 |
| src/coding/model_catalog/models.zig | 🟢 5.1 | 🟢 5.1 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/model_catalog/render.zig | 🟢 8.9 | 🟢 4.5 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/coding/model_catalog/fetch.zig | 🟢 6.1 | 🟡 6.1 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/config/cli.zig | 🟢 9.9 | 🟢 4.9 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/coding/config/settings.zig | 🟢 10.3 | 🟢 5.2 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/coding/config/profiles.zig | 🟢 9.2 | 🟢 4.6 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/coding/security/role.zig | 🟢 4.1 | 🟢 4.1 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/security/permissions.zig | 🟢 5.3 | 🟢 5.3 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/security/auth.zig | 🟢 4.8 | 🟢 4.8 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/security/path_safety.zig | 🟢 3.3 | 🟢 3.3 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/security/env_denylist.zig | 🟢 3.2 | 🟢 3.2 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/regex.zig | 🟡 31.1 | 🟠 7.8 | 🟡 4 | 🟢 2 | 🟢 0.50 | 🔴 |
| src/coding/templates.zig | 🟢 11.8 | 🟢 3.9 | 🟢 3 | 🟢 1 | 🟢 0.33 | 🟢 |
| src/coding/improvement.zig | 🟡 19.0 | 🟡 6.3 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟡 |
| src/coding/update.zig | 🟢 4.2 | 🟢 4.2 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/slash.zig | 🟢 7.7 | 🟢 3.8 | 🟢 2 | 🟢 1 | 🟢 0.50 | 🟢 |
| src/coding/skills.zig | 🟢 11.4 | 🟢 5.7 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🟠 |
| src/coding/extensions.zig | 🟢 17.5 | 🟡 5.8 | 🟢 3 | 🟢 2 | 🟢 0.67 | 🟡 |
| src/coding/types.zig | 🟢 2.9 | 🟢 2.9 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/rpc.zig | 🟢 5.0 | 🟢 5.0 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/gitignore.zig | 🟡 31.6 | 🟡 6.3 | 🟡 5 | 🟢 2 | 🟢 0.40 | 🟡 |
| src/coding/diagnostics.zig | 🟡 49.1 | 🟡 6.1 | 🟡 8 | 🟢 2 | 🟢 0.25 | 🟡 |
| src/coding/mod.zig | 🟠 65.8 | 🟢 2.7 | 🔴 24 | 🟢 2 | 🟢 0.08 | 🟢 |
| src/coding/session/object_store.zig | 🟢 4.5 | 🟢 4.5 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/session/replay.zig | 🟢 6.2 | 🟡 6.2 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/session/compaction.zig | 🟢 5.7 | 🟢 5.7 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/session/branching.zig | 🟢 4.9 | 🟢 4.9 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/session/persistence.zig | 🟢 5.8 | 🟢 5.8 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/coding/session/mod.zig | 🟢 5.0 | 🟢 5.0 | 🟢 1 | 🟢 1 | 🟡 1.00 | 🟢 |
| src/root.zig | 🟡 43.5 | 🟢 1.5 | 🔴 29 | 🟢 2 | 🟢 0.07 | 🟢 |
| src/test_helpers.zig | 🟢 6.9 | 🟢 3.4 | 🟢 2 | 🟢 2 | 🟡 1.00 | 🟡 |

### 🚫 Critical (Zone 4)

- **src/agent/loop.zig** — #1 complexity hotspot.
- **src/ai/providers/openai_chat.zig** — #1 complexity hotspot.
- **src/coding/modes/interactive.zig** — #1 complexity hotspot.
- **src/coding/modes/web/app.js** — #1 complexity hotspot.
- **src/coding/modes/rpc.zig** — #1 complexity hotspot.
- **src/coding/modes/proxy.zig** — #1 complexity hotspot.
- **src/coding/modes/print.zig** — #1 complexity hotspot.

### ⚠️ Warnings (Zone 3)

- **build.zig** — moderate hotspot. Nesting depth 12.
- **src/agent/agent.zig** — moderate hotspot. Nesting depth 20.
- **src/ai/http.zig** — moderate hotspot. Nesting depth 16.
- **src/ai/providers/anthropic.zig** — moderate hotspot. Nesting depth 20.
- **src/ai/providers/google_vertex.zig** — moderate hotspot. Nesting depth 20.
- **src/ai/providers/openai_responses.zig** — moderate hotspot. Nesting depth 24.
- **src/ai/providers/google_gemini.zig** — moderate hotspot. Nesting depth 36.
- **src/coding/tools/subagent.zig** — moderate hotspot. Nesting depth 24.
- **src/coding/tools/grep.zig** — moderate hotspot. Nesting depth 24.
- **src/coding/tools/edit.zig** — moderate hotspot. Nesting depth 24.
- **src/coding/tools/find.zig** — moderate hotspot. Nesting depth 28.
- **src/coding/mod.zig** — moderate hotspot. Nesting depth 4.

### 🔗 Temporal Coupling

| File | Coupled With | Degree | Trend |
|------|-------------|--------|-------|
| src/agent/loop.zig | src/ai/providers/google_gemini.zig | 60% | 🔺 |
| src/coding/mod.zig | src/ai/errors.zig | 38% | 🔺 |
| src/coding/cli.zig | src/ai/providers/openai_responses.zig | 50% | 🔺 |
| src/coding/branching.zig | src/coding/tools/write.zig | 75% | 🔺 |
| src/coding/mod.zig | src/coding/profiles.zig | 38% | 🔺 |
| src/agent/agent.zig | docs/spec/v1.md | 27% | 🔺 |
| src/coding/tools/grep.zig | src/agent/agent.zig | 25% | 🔺 |
| src/coding/tools/ls.zig | src/ai/providers/openai_responses.zig | 44% | 🔺 |
| src/coding/object_store.zig | src/coding/tools/ls.zig | 75% | 🔺 |
| CHANGELOG.md | franky-spec-v1.md | 75% | 🔺 |
| src/coding/modes/proxy.zig | build.zig.zon | 38% | 🔺 |
| docs/todos/todos.md | src/agent/loop.zig | 32% | 🔽 |
| src/coding/tools/find.zig | src/ai/providers/openai_responses.zig | 44% | 🔺 |
| src/coding/object_store.zig | src/ai/providers/google_gemini.zig | 75% | 🔺 |
| src/root.zig | README.md | 56% | 🔺 |
| src/coding/object_store.zig | src/ai/providers/google_vertex.zig | 75% | 🔺 |
| src/ai/providers/google_gemini.zig | franky-spec-v1.md | 44% | 🔺 |
| src/coding/tools/ls.zig | src/agent/agent.zig | 33% | 🔺 |
| src/coding/tools/grep.zig | src/root.zig | 42% | 🔺 |
| src/coding/mod.zig | src/coding/role.zig | 60% | 🔺 |
| src/agent/loop.zig | docs/spec/v1.md | 36% | 🔺 |
| src/ai/http.zig | src/agent/proxy.zig | 38% | 🔽 |
| src/coding/tools/grep.zig | src/coding/modes/web/style.css | 38% | 🔺 |
| src/coding/cli.zig | src/agent/loop.zig | 60% | 🔺 |
| src/coding/tools/find.zig | src/agent/agent.zig | 33% | 🔺 |
| src/coding/branching.zig | src/coding/tools/ls.zig | 75% | 🔺 |
| src/coding/gitignore.zig | src/coding/tools/find.zig | 80% | 🔽 |
| src/coding/tools/edit.zig | src/coding/modes/web/style.css | 75% | ➡️ |
| src/coding/modes/interactive.zig | src/coding/modes/rpc.zig | 85% | ➡️ |
| src/coding/cli.zig | src/ai/providers/google_vertex.zig | 42% | 🔺 |
| src/coding/tools/read.zig | franky-spec-v1.md | 33% | 🔺 |
| src/ai/stream.zig | src/ai/providers/anthropic.zig | 57% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/tools/write.zig | 67% | ➡️ |
| src/coding/settings.zig | src/coding/modes/proxy.zig | 75% | 🔽 |
| src/coding/tools/ls.zig | src/ai/providers/anthropic.zig | 67% | 🔺 |
| src/coding/tools/bash.zig | README.md | 33% | 🔺 |
| build.zig.zon | src/ai/providers/openai_chat.zig | 76% | 🔺 |
| src/coding/diagnostics.zig | docs/spec/v2.md | 38% | 🔺 |
| src/coding/modes/print.zig | src/coding/branching.zig | 75% | 🔺 |
| src/coding/modes/proxy.zig | src/coding/modes/web/app.js | 91% | ➡️ |
| src/ai/providers/openai_responses.zig | src/coding/tools/common.zig | 75% | 🔺 |
| src/coding/modes/rpc.zig | src/coding/modes/web/index.html | 43% | 🔺 |
| src/coding/modes/print.zig | src/ai/providers/google_vertex.zig | 83% | 🔺 |
| src/coding/tools/read.zig | src/ai/providers/openai_responses.zig | 44% | 🔺 |
| src/ai/stream.zig | src/coding/modes/interactive.zig | 57% | ➡️ |
| CHANGELOG.md | franky-spec-v2.md | 100% | 🔺 |
| src/coding/branching.zig | src/coding/tools/grep.zig | 75% | 🔺 |
| src/coding/auth.zig | src/coding/settings.zig | 75% | 🔺 |
| src/coding/modes/print.zig | src/coding/modes/rpc.zig | 90% | ➡️ |
| src/coding/modes/rpc.zig | src/ai/errors.zig | 38% | 🔺 |
| src/coding/tools/write.zig | src/ai/providers/google_gemini.zig | 50% | 🔺 |
| src/agent/proxy.zig | src/coding/modes/web/index.html | 57% | ➡️ |
| build.zig.zon | src/ai/providers/google_vertex.zig | 67% | 🔺 |
| Dockerfile.sandbox | src/coding/tools/read.zig | 33% | 🔺 |
| src/ai/channel.zig | test/agent_loop_test.zig | 75% | 🔺 |
| src/coding/tools/grep.zig | src/ai/registry.zig | 50% | 🔺 |
| src/coding/tools/read.zig | src/ai/providers/google_gemini.zig | 44% | 🔺 |
| src/coding/compaction.zig | src/coding/tools/subagent.zig | 43% | 🔽 |
| src/coding/mod.zig | src/ai/providers/google_gemini.zig | 60% | 🔺 |
| src/coding/tools/subagent.zig | src/coding/modes/web/index.html | 43% | 🔽 |
| README.md | src/coding/modes/web/style.css | 50% | ➡️ |
| src/coding/tools/bash.zig | src/agent/types.zig | 33% | 🔺 |
| src/ai/http.zig | src/ai/providers/openai_responses.zig | 92% | 🔺 |
| docs/design/decided/v2.17-self-restart.md | src/coding/modes/proxy.zig | 60% | 🔽 |
| src/coding/modes/proxy.zig | build.zig | 50% | 🔽 |
| src/coding/tools/ls.zig | src/coding/tools/read.zig | 78% | 🔺 |
| src/coding/modes/print.zig | src/coding/profiles.zig | 88% | 🔺 |
| build.zig | src/ai/mod.zig | 50% | 🔺 |
| src/coding/settings.zig | src/ai/providers/openai_chat.zig | 33% | 🔺 |
| src/coding/modes/proxy.zig | src/ai/types.zig | 60% | 🔺 |
| src/coding/mod.zig | src/agent/types.zig | 44% | 🔺 |
| docs/todos/todos.md | settings.json | 73% | 🔽 |
| src/coding/tools/ls.zig | src/ai/mod.zig | 38% | 🔺 |
| src/ai/providers/anthropic.zig | src/ai/providers/openai_chat.zig | 93% | 🔺 |
| src/coding/compaction.zig | build.zig.zon | 57% | 🔺 |
| src/coding/tools/subagent.zig | src/coding/modes/web/style.css | 50% | ➡️ |
| src/coding/auth.zig | src/coding/templates.zig | 100% | 🔺 |
| src/agent/loop.zig | src/ai/providers/anthropic.zig | 64% | 🔺 |
| src/coding/tools/ls.zig | src/ai/providers/openai_chat.zig | 56% | 🔺 |
| src/ai/channel.zig | src/ai/mod.zig | 75% | 🔺 |
| src/coding/role.zig | src/coding/modes/web/app.js | 60% | 🔺 |
| src/ai/errors.zig | src/ai/registry.zig | 38% | 🔺 |
| src/coding/modes/print.zig | docs/README.md | 50% | 🔺 |
| src/coding/modes/rpc.zig | src/agent/loop.zig | 55% | ➡️ |
| src/agent/types.zig | src/ai/registry.zig | 44% | ➡️ |
| src/coding/session.zig | src/coding/tools/grep.zig | 56% | 🔺 |
| src/coding/cli.zig | README.md | 44% | 🔺 |
| src/ai/mod.zig | pi-mono-spec.md | 86% | 🔺 |
| src/coding/compaction.zig | src/agent/loop.zig | 43% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/tools/ls.zig | 44% | ➡️ |
| src/coding/modes/proxy.zig | docs/design/decided/v2.16-multimodel-review.md | 100% | 🔽 |
| src/coding/modes/print.zig | src/ai/channel.zig | 75% | 🔺 |
| src/coding/auth.zig | src/coding/object_store.zig | 75% | 🔺 |
| src/ai/stream.zig | src/agent/types.zig | 57% | ➡️ |
| src/ai/registry.zig | src/ai/providers/google_vertex.zig | 50% | 🔺 |
| src/coding/cli.zig | src/coding/env_denylist.zig | 100% | 🔺 |
| src/coding/tools/bash.zig | src/ai/mod.zig | 38% | 🔺 |
| src/agent/loop.zig | pi-mono-spec.md | 43% | 🔺 |
| src/ai/providers/google_vertex.zig | franky-spec-v1.md | 33% | 🔺 |
| src/coding/session.zig | build.zig.zon | 56% | 🔺 |
| franky-spec-v2.md | refactoring.md | 100% | 🔺 |
| src/root.zig | franky-spec-v1.md | 100% | 🔺 |
| src/coding/modes/web/app.js | README.md | 44% | ➡️ |
| src/coding/tools/subagent.zig | src/ai/http.zig | 27% | 🔽 |
| src/coding/tools/bash.zig | src/coding/tools/grep.zig | 56% | 🔺 |
| src/coding/modes/print.zig | src/ai/providers/openai_responses.zig | 83% | 🔺 |
| docs/spec/v2.md | src/coding/tools/ls.zig | 44% | 🔽 |
| src/coding/session.zig | src/coding/settings.zig | 44% | ➡️ |
| src/coding/cli.zig | src/ai/log.zig | 100% | 🔺 |
| src/coding/tools/find.zig | src/ai/http.zig | 67% | 🔺 |
| src/coding/compaction.zig | src/ai/providers/google_gemini.zig | 57% | 🔺 |
| src/coding/modes/rpc.zig | src/coding/modes/web/style.css | 50% | 🔺 |
| src/root.zig | test/agent_loop_test.zig | 67% | 🔺 |
| src/root.zig | src/agent/agent.zig | 58% | 🔺 |
| docs/spec/v2.md | src/coding/cli.zig | 36% | ➡️ |
| src/coding/branching.zig | build.zig.zon | 75% | 🔺 |
| src/coding/object_store.zig | src/root.zig | 75% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/tools/bash.zig | 56% | 🔺 |
| build.zig | pi-mono-spec.md | 57% | 🔺 |
| src/coding/tools/ls.zig | src/coding/tools/write.zig | 100% | ➡️ |
| src/agent/guardrails/guardrails.zig | src/coding/modes/proxy.zig | 80% | 🔽 |
| src/coding/modes/print.zig | src/coding/session.zig | 56% | 🔺 |
| src/coding/cli.zig | franky-spec-v1.md | 56% | 🔺 |
| src/agent/guardrails/guardrails.zig | .frank-workflow.yaml | 100% | 🔽 |
| docs/todos/todos.md | src/coding/settings.zig | 33% | 🔽 |
| src/coding/mod.zig | src/coding/tools/bash.zig | 78% | 🔺 |
| src/ai/registry.zig | src/ai/providers/anthropic.zig | 60% | 🔺 |
| src/coding/mod.zig | src/agent/loop.zig | 38% | 🔺 |
| src/coding/modes/print.zig | CHANGELOG.md | 75% | 🔺 |
| src/coding/tools/bash.zig | src/coding/tools/ls.zig | 56% | 🔺 |
| src/coding/cli.zig | pi-mono-spec.md | 57% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/modes/web/index.html | 43% | 🔺 |
| src/coding/tools/write.zig | src/ai/providers/openai_responses.zig | 50% | 🔺 |
| src/coding/auth.zig | src/coding/session.zig | 75% | 🔺 |
| src/coding/object_store.zig | src/ai/providers/openai_responses.zig | 75% | 🔺 |
| src/coding/role.zig | src/coding/modes/rpc.zig | 80% | ➡️ |
| src/coding/modes/interactive.zig | src/agent/guardrails/compilation_guard.zig | 75% | 🔽 |
| src/coding/modes/interactive.zig | src/coding/modes/web/style.css | 50% | 🔺 |
| src/coding/tools/ls.zig | src/ai/providers/google_gemini.zig | 44% | 🔺 |
| src/ai/types.zig | src/agent/loop.zig | 80% | 🔺 |
| src/coding/modes/proxy.zig | src/ai/providers/openai_chat.zig | 35% | 🔺 |
| docs/todos/todos.md | docs/spec/v2.md | 27% | 🔽 |
| settings.json | src/coding/modes/web/app.js | 36% | 🔽 |
| src/ai/channel.zig | src/ai/registry.zig | 75% | 🔺 |
| src/coding/modes/print.zig | src/agent/guardrails/guardrails.zig | 60% | 🔽 |
| src/coding/permissions.zig | src/root.zig | 75% | 🔺 |
| src/coding/modes/rpc.zig | src/ai/providers/google_vertex.zig | 42% | 🔺 |
| src/coding/branching.zig | src/coding/compaction.zig | 100% | 🔺 |
| src/coding/tools/edit.zig | src/coding/tools/read.zig | 89% | 🔺 |
| src/coding/modes/proxy.zig | src/ai/providers/google_gemini.zig | 47% | 🔺 |
| src/ai/providers/google_vertex.zig | src/coding/tools/common.zig | 75% | 🔺 |
| src/coding/tools/edit.zig | src/coding/modes/web/index.html | 71% | 🔽 |
| src/coding/modes/web/index.html | src/coding/modes/web/style.css | 100% | ➡️ |
| src/coding/mod.zig | src/agent/agent.zig | 50% | 🔺 |
| src/ai/http.zig | src/ai/providers/anthropic.zig | 93% | 🔺 |
| src/coding/modes/print.zig | src/agent/types.zig | 78% | 🔺 |
| docs/design/decided/v2.17-self-restart.md | src/coding/restart.zig | 100% | 🔽 |
| src/coding/tools/find.zig | src/coding/tools/write.zig | 100% | ➡️ |
| src/root.zig | src/ai/providers/openai_chat.zig | 71% | 🔺 |
| src/coding/branching.zig | src/coding/session.zig | 100% | 🔺 |
| settings.json | src/coding/profiles.zig | 38% | 🔽 |
| src/coding/tools/write.zig | src/ai/providers/openai_chat.zig | 50% | 🔺 |
| settings.json | src/coding/cli.zig | 27% | 🔽 |
| src/coding/modes/print.zig | README.md | 67% | 🔺 |
| franky-spec-v1.md | refactoring.md | 100% | 🔺 |
| src/root.zig | franky-spec-v2.md | 100% | 🔺 |
| src/coding/cli.zig | src/coding/tools/ls.zig | 44% | ➡️ |
| src/coding/tools/grep.zig | src/coding/tools/ls.zig | 89% | 🔺 |
| src/coding/modes/proxy.zig | docs/design/decided/v2.13-model-service-unavailabl.md | 100% | 🔽 |
| settings.json | src/coding/modes/interactive.zig | 27% | 🔽 |
| src/coding/tools/read.zig | src/root.zig | 56% | 🔺 |
| src/coding/branching.zig | src/coding/tools/find.zig | 75% | 🔺 |
| src/ai/registry.zig | test/gitignore_test.zig | 100% | 🔺 |
| src/coding/tools/ls.zig | src/ai/registry.zig | 44% | 🔺 |
| src/coding/mod.zig | src/ai/stream.zig | 43% | 🔺 |
| src/ai/stream.zig | src/coding/modes/proxy.zig | 43% | 🔽 |
| src/coding/tools/grep.zig | src/ai/providers/openai_responses.zig | 33% | 🔺 |
| src/coding/cli.zig | src/coding/modes/proxy.zig | 55% | 🔺 |
| docs/spec/v2.md | src/coding/tools/edit.zig | 45% | 🔽 |
| build.zig.zon | src/ai/providers/anthropic.zig | 79% | 🔺 |
| src/coding/settings.zig | src/ai/providers/google_gemini.zig | 33% | 🔺 |
| src/coding/cli.zig | src/coding/session.zig | 44% | 🔺 |
| src/ai/http.zig | build.zig | 31% | 🔺 |
| src/coding/modes/interactive.zig | src/agent/types.zig | 78% | 🔺 |
| src/ai/stream.zig | src/root.zig | 57% | 🔺 |
| src/coding/tools/bash.zig | build.zig | 56% | 🔺 |
| src/coding/modes/proxy.zig | test/agent_class_test.zig | 43% | 🔺 |
| src/coding/modes/print.zig | src/coding/tools/write.zig | 67% | 🔺 |
| docs/spec/v2.md | src/ai/providers/google_vertex.zig | 36% | 🔺 |
| src/agent/loop.zig | src/agent/proxy.zig | 63% | 🔺 |
| docs/spec/v2.md | src/root.zig | 45% | 🔺 |
| Dockerfile.sandbox | build.zig | 36% | 🔽 |
| src/agent/agent.zig | franky-spec-v1.md | 33% | 🔺 |
| src/coding/tools/edit.zig | src/coding/tools/write.zig | 100% | ➡️ |
| Dockerfile.sandbox | src/coding/tools/ls.zig | 33% | 🔺 |
| src/coding/mod.zig | src/coding/modes/rpc.zig | 30% | 🔺 |
| src/coding/modes/print.zig | src/ai/errors.zig | 88% | 🔺 |
| src/coding/tools/subagent.zig | build.zig.zon | 36% | ➡️ |
| src/coding/tools/grep.zig | src/coding/tools/read.zig | 89% | 🔺 |
| src/ai/http.zig | src/ai/providers/google_vertex.zig | 92% | 🔺 |
| src/coding/modes/print.zig | src/agent/mod.zig | 100% | 🔺 |
| src/coding/modes/rpc.zig | src/root.zig | 30% | 🔺 |
| src/coding/mod.zig | src/coding/tools/grep.zig | 50% | 🔺 |
| src/agent/loop.zig | franky-spec-v1.md | 33% | 🔺 |
| src/ai/providers/google_gemini.zig | src/coding/tools/common.zig | 75% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/permissions.zig | 100% | 🔺 |
| src/coding/cli.zig | src/coding/tools/find.zig | 44% | ➡️ |
| src/coding/session.zig | pi-mono-spec.md | 43% | 🔺 |
| src/coding/branching.zig | src/coding/tools/bash.zig | 75% | 🔺 |
| src/coding/branching.zig | src/coding/modes/interactive.zig | 100% | 🔺 |
| src/coding/tools/bash.zig | franky-spec-v1.md | 44% | 🔺 |
| build.zig.zon | src/coding/modes/web/style.css | 38% | 🔺 |
| docs/spec/v2.md | src/coding/tools/subagent.zig | 27% | 🔽 |
| src/coding/modes/print.zig | src/agent/proxy.zig | 75% | 🔺 |
| src/coding/modes/print.zig | src/coding/settings.zig | 75% | ➡️ |
| src/agent/agent.zig | src/agent/loop.zig | 83% | 🔺 |
| src/root.zig | src/ai/providers/openai_responses.zig | 67% | 🔺 |
| src/coding/modes/web/app.js | src/coding/modes/web/style.css | 100% | ➡️ |
| src/coding/tools/find.zig | src/ai/registry.zig | 44% | 🔺 |
| docs/todos/todos.md | src/ai/providers/openai_chat.zig | 18% | 🔺 |
| src/ai/stream.zig | src/coding/modes/rpc.zig | 43% | 🔽 |
| build.zig.zon | build.zig | 44% | 🔺 |
| src/coding/session.zig | src/ai/providers/google_vertex.zig | 44% | 🔺 |
| src/coding/modes/interactive.zig | src/ai/types.zig | 60% | 🔺 |
| src/coding/settings.zig | build.zig.zon | 33% | 🔺 |
| src/coding/tools/find.zig | src/agent/types.zig | 33% | 🔺 |
| src/agent/guardrails/guardrails.zig | src/coding/tools/edit.zig | 60% | 🔽 |
| src/coding/tools/edit.zig | build.zig.zon | 31% | 🔺 |
| src/coding/object_store.zig | src/coding/tools/write.zig | 75% | 🔺 |
| src/coding/modes/print.zig | src/coding/templates.zig | 100% | 🔺 |
| src/ai/providers/anthropic.zig | src/ai/mod.zig | 50% | 🔺 |
| src/coding/tools/ls.zig | build.zig.zon | 67% | 🔺 |
| src/coding/tools/grep.zig | src/ai/providers/google_gemini.zig | 33% | 🔺 |
| src/coding/tools/edit.zig | src/coding/tools/subagent.zig | 45% | 🔽 |
| src/coding/branching.zig | src/coding/cli.zig | 75% | 🔺 |
| test/agent_loop_test.zig | src/agent/agent.zig | 50% | 🔺 |
| src/coding/gitignore.zig | src/coding/tools/grep.zig | 80% | 🔽 |
| src/coding/mod.zig | test/agent_class_test.zig | 57% | 🔺 |
| src/coding/tools/edit.zig | src/agent/agent.zig | 33% | 🔺 |
| docs/design/v2.10-harness-enforced-guardrails.md | docs/design/v2.13-model-service-unavailabl.md | 75% | 🔽 |
| src/coding/modes/print.zig | src/agent/agent.zig | 83% | 🔺 |
| src/coding/modes/print.zig | src/coding/tools/find.zig | 56% | 🔺 |
| docs/todos/todos.md | src/coding/tools/grep.zig | 33% | 🔽 |
| src/agent/agent.zig | src/agent/proxy.zig | 50% | 🔺 |
| src/coding/mod.zig | franky-spec-v0.md | 100% | 🔺 |
| src/coding/modes/web/app.js | src/coding/modes/web/index.html | 100% | ➡️ |
| build.zig.zon | CHANGELOG.md | 100% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/oauth/listener.zig | 100% | 🔺 |
| src/coding/mod.zig | src/coding/settings.zig | 33% | 🔺 |
| src/ai/registry.zig | src/root.zig | 50% | 🔺 |
| src/ai/http.zig | src/ai/mod.zig | 38% | 🔺 |
| src/coding/tools/edit.zig | src/ai/registry.zig | 40% | 🔺 |
| src/coding/role.zig | src/coding/modes/proxy.zig | 80% | ➡️ |
| src/coding/tools/read.zig | src/coding/modes/rpc.zig | 56% | 🔺 |
| src/coding/tools/edit.zig | docs/spec/v1.md | 36% | 🔺 |
| src/coding/compaction.zig | src/coding/tools/grep.zig | 57% | ➡️ |
| src/coding/settings.zig | docs/design/decided/v2.16-multimodel-review.md | 100% | 🔽 |
| src/coding/modes/print.zig | docs/design/decided/v2.17-self-restart.md | 60% | 🔽 |
| settings.json | src/coding/tools/edit.zig | 27% | 🔺 |
| src/coding/tools/bash.zig | src/coding/tools/write.zig | 67% | 🔺 |
| src/coding/modes/interactive.zig | test/kitchen_sink_test.zig | 100% | 🔺 |
| .frank-workflow.yaml | src/agent/guardrails/compilation_guard.zig | 100% | 🔽 |
| src/coding/permissions.zig | build.zig.zon | 75% | 🔺 |
| src/coding/tools/subagent.zig | src/agent/loop.zig | 45% | 🔽 |
| src/coding/tools/read.zig | src/coding/modes/proxy.zig | 44% | 🔺 |
| src/coding/modes/proxy.zig | README.md | 67% | 🔺 |
| build.zig.zon | src/agent/loop.zig | 48% | 🔺 |
| src/coding/mod.zig | franky-spec-v2.md | 75% | 🔺 |
| src/coding/cli.zig | src/coding/tools/edit.zig | 38% | ➡️ |
| src/coding/modes/rpc.zig | franky-spec-v1.md | 56% | 🔺 |
| src/coding/tools/bash.zig | src/ai/http.zig | 56% | 🔺 |
| src/ai/providers/google_gemini.zig | src/ai/providers/openai_chat.zig | 73% | 🔺 |
| build.zig.zon | refactoring.md | 100% | 🔺 |
| src/ai/stream.zig | test/agent_loop_test.zig | 50% | 🔺 |
| src/coding/cli.zig | src/coding/modes/rpc.zig | 55% | 🔺 |
| src/coding/modes/interactive.zig | src/root.zig | 41% | 🔺 |
| src/coding/modes/print.zig | src/sdk.zig | 75% | 🔺 |
| docs/spec/v2.md | src/ai/providers/google_gemini.zig | 36% | 🔺 |
| src/root.zig | test/parallel_tools_test.zig | 100% | 🔺 |
| src/ai/providers/anthropic.zig | pi-mono-spec.md | 57% | 🔺 |
| src/coding/modes/print.zig | docs/spec/v2.md | 55% | 🔺 |
| src/coding/modes/print.zig | src/coding/modes/web/style.css | 50% | 🔺 |
| build.zig.zon | src/coding/modes/web/app.js | 36% | 🔺 |
| src/coding/diagnostics.zig | src/coding/modes/interactive.zig | 38% | 🔺 |
| src/coding/tools/ls.zig | pi-mono-spec.md | 43% | 🔺 |
| src/ai/http.zig | src/ai/providers/google_gemini.zig | 80% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/role.zig | 80% | 🔽 |
| src/coding/tools/find.zig | src/coding/tools/ls.zig | 100% | 🔺 |
| src/root.zig | src/ai/providers/anthropic.zig | 71% | 🔺 |
| src/ai/partial_json.zig | src/ai/sse.zig | 100% | 🔽 |
| src/coding/modes/rpc.zig | src/ai/providers/openai_responses.zig | 42% | 🔺 |
| build.zig | src/agent/proxy.zig | 38% | 🔺 |
| src/ai/stream.zig | src/ai/providers/openai_responses.zig | 43% | 🔺 |
| src/coding/modes/proxy.zig | src/agent/proxy.zig | 75% | ➡️ |
| build.zig.zon | franky-spec-v0.md | 100% | 🔺 |
| src/coding/mod.zig | src/coding/compaction.zig | 71% | 🔺 |
| docs/spec/v2.md | README.md | 33% | 🔺 |
| src/agent/guardrails/guardrails.zig | src/coding/settings.zig | 60% | 🔽 |
| franky-spec-v0.md | franky-spec-v1.md | 100% | 🔺 |
| src/coding/session.zig | src/coding/tools/bash.zig | 44% | 🔺 |
| src/coding/tools/grep.zig | src/coding/modes/proxy.zig | 50% | 🔽 |
| src/coding/gitignore.zig | src/ai/registry.zig | 60% | 🔽 |
| src/ai/stream.zig | src/coding/cli.zig | 43% | 🔺 |
| franky-spec-v1.md | franky-spec-v2.md | 75% | 🔺 |
| src/coding/permissions.zig | franky-spec-v1.md | 75% | 🔺 |
| src/coding/tools/edit.zig | src/agent/types.zig | 56% | 🔺 |
| src/coding/mod.zig | src/ai/providers/openai_chat.zig | 53% | 🔺 |
| src/coding/modes/proxy.zig | src/root.zig | 31% | 🔺 |
| src/coding/mod.zig | src/coding/modes/web/app.js | 27% | 🔺 |
| src/coding/profiles.zig | src/coding/modes/proxy.zig | 88% | 🔺 |
| src/coding/branching.zig | src/coding/tools/read.zig | 75% | 🔺 |
| src/coding/tools/read.zig | build.zig | 33% | 🔺 |
| src/agent/loop.zig | docs/design/decided/v2.13-model-service-unavailabl.md | 100% | 🔽 |
| Dockerfile.sandbox | settings.json | 27% | 🔽 |
| src/coding/mod.zig | src/coding/oauth/listener.zig | 100% | 🔺 |
| src/coding/mod.zig | src/coding/tools/ls.zig | 67% | 🔺 |
| src/coding/modes/print.zig | src/coding/tools/edit.zig | 44% | 🔺 |
| src/coding/tools/write.zig | build.zig | 50% | 🔺 |
| src/ai/providers/openai_chat.zig | franky-spec-v2.md | 75% | 🔺 |
| src/coding/session.zig | src/ai/providers/google_gemini.zig | 44% | 🔺 |
| src/coding/compaction.zig | src/coding/tools/edit.zig | 43% | 🔺 |
| src/coding/modes/proxy.zig | src/ai/providers/openai_responses.zig | 42% | 🔺 |
| src/coding/branching.zig | src/ai/providers/google_gemini.zig | 75% | 🔺 |
| src/coding/session.zig | src/ai/http.zig | 44% | 🔺 |
| src/coding/tools/subagent.zig | src/coding/modes/web/app.js | 36% | ➡️ |
| src/agent/loop.zig | src/ai/providers/openai_responses.zig | 67% | 🔺 |
| src/coding/modes/proxy.zig | src/ai/registry.zig | 40% | 🔺 |
| src/agent/guardrails/finish_task.zig | src/coding/modes/interactive.zig | 100% | 🔽 |
| src/ai/providers/google_vertex.zig | src/ai/providers/openai_chat.zig | 83% | 🔺 |
| src/coding/diagnostics.zig | src/ai/providers/google_vertex.zig | 38% | 🔺 |
| src/coding/modes/print.zig | src/ai/providers/anthropic.zig | 71% | 🔺 |
| src/coding/profiles.zig | src/ai/providers/google_gemini.zig | 38% | 🔺 |
| src/coding/modes/rpc.zig | src/ai/registry.zig | 30% | 🔺 |
| src/coding/tools/subagent.zig | src/agent/proxy.zig | 38% | 🔽 |
| src/agent/agent.zig | src/ai/http.zig | 42% | 🔺 |
| docs/todos/todos.md | src/agent/guardrails/guardrails.zig | 60% | 🔽 |
| src/ai/stream.zig | src/ai/registry.zig | 43% | 🔽 |
| src/ai/stream.zig | src/agent/loop.zig | 71% | 🔺 |
| src/agent/types.zig | test/agent_loop_test.zig | 50% | 🔺 |
| src/coding/tools/write.zig | src/agent/types.zig | 50% | 🔺 |
| src/coding/cli.zig | src/ai/registry.zig | 50% | 🔺 |
| src/coding/settings.zig | src/coding/tools/bash.zig | 33% | 🔺 |
| src/ai/registry.zig | build.zig | 40% | 🔺 |
| src/coding/mod.zig | franky-spec-v1.md | 67% | 🔺 |
| build.zig | src/ai/providers/anthropic.zig | 36% | 🔺 |
| docs/spec/v2.md | src/coding/tools/find.zig | 44% | 🔽 |
| src/coding/mod.zig | src/coding/auth.zig | 75% | 🔺 |
| src/coding/mod.zig | src/coding/tools/subagent.zig | 27% | 🔺 |
| src/ai/providers/anthropic.zig | franky-spec-v1.md | 33% | 🔺 |
| src/coding/tools/read.zig | src/ai/registry.zig | 44% | 🔺 |
| src/agent/types.zig | src/agent/loop.zig | 78% | 🔺 |
| src/coding/cli.zig | src/coding/settings.zig | 67% | ➡️ |
| src/coding/modes/rpc.zig | CHANGELOG.md | 50% | 🔺 |
| build.zig.zon | src/agent/agent.zig | 58% | 🔺 |
| src/coding/tools/find.zig | src/root.zig | 67% | 🔺 |
| src/coding/modes/rpc.zig | src/agent/proxy.zig | 63% | 🔺 |
| src/ai/providers/google_gemini.zig | CHANGELOG.md | 50% | 🔺 |
| docs/todos/todos.md | src/coding/modes/web/app.js | 55% | 🔽 |
| src/coding/modes/print.zig | src/coding/compaction.zig | 57% | 🔺 |
| src/coding/profiles.zig | src/coding/tools/edit.zig | 38% | 🔽 |
| src/coding/object_store.zig | build.zig.zon | 75% | 🔺 |
| src/coding/modes/interactive.zig | docs/design/decided/v2.16-multimodel-review.md | 100% | 🔽 |
| src/coding/profiles.zig | src/agent/loop.zig | 63% | 🔺 |
| Dockerfile.sandbox | src/ai/stream.zig | 57% | 🔽 |
| Dockerfile.sandbox | src/coding/modes/print.zig | 36% | ➡️ |
| src/agent/agent.zig | src/ai/providers/anthropic.zig | 42% | 🔺 |
| docs/spec/v2.md | src/coding/tools/bash.zig | 33% | 🔽 |
| src/ai/stream.zig | src/agent/agent.zig | 57% | 🔺 |
| src/coding/modes/interactive.zig | build.zig.zon | 46% | 🔺 |
| src/coding/modes/print.zig | src/coding/tools/bash.zig | 78% | 🔺 |
| src/coding/object_store.zig | src/coding/tools/grep.zig | 75% | 🔺 |
| src/agent/types.zig | src/ai/providers/anthropic.zig | 44% | 🔺 |
| src/ai/providers/google_vertex.zig | src/ai/providers/openai_responses.zig | 92% | 🔺 |
| docs/spec/v2.md | docs/spec/v1.md | 45% | 🔺 |
| src/coding/modes/print.zig | src/agent/guardrails/finish_task.zig | 75% | 🔽 |
| src/coding/branching.zig | src/coding/object_store.zig | 100% | 🔺 |
| src/coding/tools/find.zig | src/ai/providers/openai_chat.zig | 56% | 🔺 |
| src/coding/session.zig | src/coding/tools/write.zig | 67% | 🔺 |
| src/coding/mod.zig | src/coding/session.zig | 67% | 🔺 |
| src/coding/tools/edit.zig | src/agent/loop.zig | 44% | 🔺 |
| src/coding/tools/bash.zig | src/ai/providers/anthropic.zig | 56% | 🔺 |
| src/coding/tools/ls.zig | src/ai/http.zig | 67% | 🔺 |
| src/agent/guardrails/finish_task.zig | src/coding/cli.zig | 75% | 🔽 |
| src/coding/tools/grep.zig | src/agent/proxy.zig | 38% | 🔽 |
| docs/spec/v1.md | src/ai/providers/openai_responses.zig | 36% | 🔺 |
| src/coding/modes/interactive.zig | docs/design/decided/v2.13-model-service-unavailabl.md | 100% | 🔽 |
| src/coding/tools/edit.zig | test/kitchen_sink_test.zig | 100% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/object_store.zig | 100% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/settings.zig | 67% | ➡️ |
| src/coding/tools/subagent.zig | src/coding/modes/rpc.zig | 55% | 🔺 |
| src/coding/diagnostics.zig | src/root.zig | 50% | 🔺 |
| src/coding/modes/proxy.zig | docs/spec/v3.md | 75% | 🔽 |
| src/coding/tools/grep.zig | src/coding/tools/common.zig | 75% | 🔽 |
| src/coding/settings.zig | src/root.zig | 33% | 🔺 |
| src/coding/tools/bash.zig | build.zig.zon | 78% | 🔺 |
| settings.json | src/coding/modes/web/style.css | 38% | 🔽 |
| src/coding/compaction.zig | src/coding/tools/read.zig | 43% | 🔺 |
| CHANGELOG.md | refactoring.md | 100% | 🔺 |
| src/coding/cli.zig | src/ai/providers/openai_chat.zig | 41% | 🔺 |
| src/ai/errors.zig | test/agent_loop_test.zig | 50% | 🔺 |
| src/coding/cli.zig | src/ai/errors.zig | 38% | 🔺 |
| src/coding/settings.zig | src/coding/tools/read.zig | 44% | ➡️ |
| src/agent/types.zig | src/coding/modes/web/app.js | 33% | 🔺 |
| build.zig.zon | src/coding/modes/web/index.html | 43% | 🔺 |
| build.zig.zon | franky-spec-v1.md | 100% | 🔺 |
| src/coding/tools/read.zig | src/ai/providers/openai_chat.zig | 56% | 🔺 |
| src/coding/branching.zig | src/ai/providers/google_vertex.zig | 75% | 🔺 |
| src/coding/mod.zig | src/coding/permissions.zig | 75% | 🔺 |
| src/coding/cli.zig | src/coding/object_store.zig | 75% | 🔺 |
| src/root.zig | test/gitignore_test.zig | 100% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/modes/web/app.js | 55% | 🔺 |
| src/ai/channel.zig | src/ai/providers/faux.zig | 100% | 🔺 |
| src/agent/agent.zig | src/ai/providers/openai_responses.zig | 42% | 🔺 |
| docs/todos/todos.md | src/coding/tools/edit.zig | 31% | 🔽 |
| src/agent/agent.zig | src/ai/providers/google_gemini.zig | 50% | 🔺 |
| src/coding/object_store.zig | src/coding/tools/bash.zig | 75% | 🔺 |
| src/coding/modes/print.zig | src/coding/cli.zig | 95% | 🔺 |
| src/agent/loop.zig | src/coding/modes/web/app.js | 36% | 🔺 |
| src/coding/tools/read.zig | build.zig.zon | 56% | 🔺 |
| src/coding/modes/interactive.zig | build.zig | 50% | 🔺 |
| src/coding/modes/print.zig | src/coding/tools/subagent.zig | 55% | 🔺 |
| src/coding/tools/find.zig | src/coding/tools/subagent.zig | 33% | 🔽 |
| docs/spec/v2.md | src/coding/tools/grep.zig | 36% | 🔽 |
| src/coding/object_store.zig | src/coding/tools/read.zig | 75% | 🔺 |
| src/coding/session.zig | src/coding/tools/read.zig | 44% | 🔺 |
| src/coding/tools/edit.zig | src/coding/tools/ls.zig | 78% | 🔺 |
| docs/todos/todos.md | build.zig | 31% | 🔽 |
| build.zig.zon | src/agent/proxy.zig | 50% | 🔺 |
| src/coding/modes/proxy.zig | src/coding/modes/web/index.html | 86% | ➡️ |
| src/ai/providers/openai_responses.zig | CHANGELOG.md | 38% | 🔺 |
| src/coding/mod.zig | docs/todos/todos.md | 25% | 🔺 |
| src/root.zig | CHANGELOG.md | 88% | 🔺 |
| src/coding/mod.zig | src/ai/registry.zig | 40% | 🔺 |
| docs/spec/v2.md | src/coding/tools/write.zig | 50% | 🔽 |
| test/agent_loop_test.zig | src/ai/http.zig | 67% | 🔺 |
| src/ai/types.zig | src/agent/agent.zig | 60% | 🔺 |
| src/coding/compaction.zig | src/coding/tools/find.zig | 43% | 🔺 |
| src/coding/mod.zig | src/ai/providers/google_vertex.zig | 58% | 🔺 |
| Dockerfile.sandbox | src/ai/providers/anthropic.zig | 27% | 🔺 |
| src/coding/modes/interactive.zig | README.md | 56% | 🔺 |
| src/ai/stream.zig | src/ai/providers/openai_chat.zig | 43% | 🔺 |
| src/agent/proxy.zig | src/ai/providers/openai_responses.zig | 38% | 🔺 |
| src/coding/tools/edit.zig | src/agent/proxy.zig | 63% | 🔽 |
| src/coding/tools/read.zig | src/coding/tools/write.zig | 100% | ➡️ |
| src/coding/tools/edit.zig | src/coding/modes/web/app.js | 55% | ➡️ |
| src/coding/tools/edit.zig | src/ai/providers/openai_chat.zig | 25% | 🔺 |
| src/coding/tools/grep.zig | build.zig.zon | 50% | 🔺 |
| src/coding/mod.zig | src/ai/mod.zig | 75% | 🔺 |
| src/root.zig | src/ai/providers/google_gemini.zig | 67% | 🔺 |
| Dockerfile.sandbox | docs/spec/v2.md | 27% | 🔺 |
| src/coding/settings.zig | test/agent_class_test.zig | 43% | 🔺 |
| docs/spec/v1.md | src/ai/providers/google_vertex.zig | 45% | 🔺 |
| src/coding/tools/write.zig | src/coding/tools/common.zig | 75% | 🔽 |
| Dockerfile.sandbox | src/coding/tools/grep.zig | 36% | ➡️ |
| src/coding/modes/web/app.js | src/agent/proxy.zig | 63% | 🔺 |
| src/root.zig | src/ai/http.zig | 59% | 🔺 |
| src/agent/loop.zig | src/ai/providers/google_vertex.zig | 58% | 🔺 |
| src/ai/errors.zig | src/agent/agent.zig | 50% | 🔺 |
| src/coding/mod.zig | src/coding/modes/interactive.zig | 54% | 🔺 |
| src/coding/diagnostics.zig | src/coding/modes/print.zig | 63% | 🔺 |
| Dockerfile.sandbox | src/ai/registry.zig | 30% | 🔽 |
| src/coding/profiles.zig | src/coding/settings.zig | 63% | 🔽 |
| src/ai/errors.zig | src/agent/loop.zig | 75% | 🔺 |
| src/coding/compaction.zig | test/agent_class_test.zig | 57% | 🔺 |
| src/coding/compaction.zig | src/agent/agent.zig | 43% | 🔺 |
| src/coding/tools/find.zig | src/ai/mod.zig | 38% | 🔺 |
| src/agent/guardrails/guardrails.zig | src/coding/cli.zig | 60% | 🔽 |
| src/agent/loop.zig | CHANGELOG.md | 38% | 🔺 |
| docs/spec/v2.md | src/coding/gitignore.zig | 60% | 🔽 |
| src/coding/compaction.zig | src/coding/settings.zig | 57% | ➡️ |
| src/ai/errors.zig | src/ai/providers/anthropic.zig | 38% | 🔺 |
| src/coding/tools/grep.zig | README.md | 33% | 🔺 |
| src/agent/loop.zig | src/ai/http.zig | 59% | 🔺 |
| src/root.zig | pi-mono-spec.md | 100% | 🔺 |
| src/coding/modes/interactive.zig | src/ai/registry.zig | 50% | 🔺 |
| src/coding/settings.zig | src/agent/proxy.zig | 38% | 🔽 |
| src/coding/modes/print.zig | pi-mono-spec.md | 71% | 🔺 |
| src/agent/guardrails/guardrails.zig | src/agent/guardrails/compilation_guard.zig | 75% | 🔽 |
| docs/spec/v2.md | src/coding/modes/interactive.zig | 45% | 🔺 |
| src/coding/modes/print.zig | docs/design/decided/v2.13-model-service-unavailabl.md | 100% | 🔽 |
| docs/spec/v2.md | docs/README.md | 50% | 🔺 |
| Dockerfile.sandbox | docs/todos/todos.md | 27% | 🔽 |
| src/ai/http.zig | src/ai/retry.zig | 100% | 🔽 |
| src/coding/modes/rpc.zig | src/coding/modes/web/app.js | 45% | 🔺 |
| build.zig | src/ai/providers/openai_chat.zig | 31% | 🔺 |
| src/coding/object_store.zig | src/coding/settings.zig | 75% | 🔺 |
| src/coding/settings.zig | src/coding/tools/grep.zig | 33% | 🔽 |
| src/ai/channel.zig | test/agent_class_test.zig | 75% | 🔺 |
| src/coding/session.zig | src/root.zig | 56% | 🔺 |
| src/coding/cli.zig | src/coding/tools/read.zig | 67% | 🔺 |
| src/coding/tools/grep.zig | src/coding/tools/subagent.zig | 45% | 🔽 |
| src/coding/modes/interactive.zig | src/ai/providers/google_gemini.zig | 60% | 🔺 |
| docs/spec/v2.md | src/coding/tools/read.zig | 44% | 🔽 |
| src/root.zig | test/agent_class_test.zig | 71% | 🔺 |
| src/coding/object_store.zig | src/coding/tools/find.zig | 75% | 🔺 |
| src/coding/mod.zig | test/agent_loop_test.zig | 50% | 🔺 |
| src/coding/modes/interactive.zig | .frank-workflow.yaml | 100% | 🔽 |
| src/coding/settings.zig | src/agent/agent.zig | 33% | ➡️ |
| src/root.zig | src/agent/loop.zig | 36% | 🔺 |
| src/agent/agent.zig | src/ai/providers/google_vertex.zig | 42% | 🔺 |
| src/ai/providers/google_vertex.zig | src/coding/templates.zig | 100% | 🔺 |
| src/coding/tools/write.zig | src/ai/registry.zig | 50% | 🔺 |
| src/coding/cli.zig | src/ai/providers/anthropic.zig | 43% | 🔺 |
| build.zig.zon | src/ai/providers/openai_responses.zig | 75% | 🔺 |
| src/agent/types.zig | src/ai/http.zig | 44% | 🔺 |
| src/coding/compaction.zig | src/coding/tools/write.zig | 50% | 🔺 |
| src/coding/tools/bash.zig | pi-mono-spec.md | 43% | 🔺 |
| src/coding/modes/proxy.zig | CHANGELOG.md | 75% | 🔺 |
| docs/todos/todos.md | src/coding/profiles.zig | 38% | 🔽 |
| src/coding/modes/interactive.zig | docs/README.md | 67% | 🔺 |
| src/coding/branching.zig | src/coding/settings.zig | 75% | 🔺 |
| src/coding/tools/edit.zig | src/coding/tools/grep.zig | 75% | ➡️ |
| src/coding/mod.zig | pi-mono-spec.md | 71% | 🔺 |
| src/coding/modes/interactive.zig | src/ai/providers/anthropic.zig | 43% | 🔺 |
| src/coding/modes/print.zig | src/coding/modes/web/app.js | 45% | 🔺 |
| src/coding/cli.zig | src/root.zig | 60% | 🔺 |
| src/coding/gitignore.zig | src/coding/tools/write.zig | 60% | 🔽 |
| src/coding/modes/print.zig | src/coding/tools/read.zig | 78% | 🔺 |
| src/ai/providers/anthropic.zig | CHANGELOG.md | 38% | 🔺 |
| src/ai/providers/openai_chat.zig | pi-mono-spec.md | 71% | 🔺 |
| src/coding/modes/print.zig | franky-spec-v2.md | 75% | 🔺 |
| src/ai/stream.zig | src/ai/providers/google_gemini.zig | 43% | 🔺 |
| src/coding/mod.zig | src/bin/main.zig | 100% | 🔺 |
| docs/spec/v2.md | src/ai/http.zig | 36% | 🔺 |
| src/coding/cli.zig | src/agent/proxy.zig | 75% | 🔺 |
| build.zig.zon | src/ai/http.zig | 71% | 🔺 |
| src/coding/tools/find.zig | src/coding/tools/grep.zig | 89% | 🔺 |
| src/coding/cli.zig | CHANGELOG.md | 63% | 🔺 |
| src/coding/modes/interactive.zig | src/sdk.zig | 75% | 🔺 |
| src/coding/session.zig | src/coding/tools/edit.zig | 56% | 🔺 |
| src/coding/modes/proxy.zig | src/ai/providers/google_vertex.zig | 42% | 🔺 |
| src/coding/permissions.zig | src/coding/modes/proxy.zig | 75% | 🔺 |
| src/coding/tools/read.zig | src/coding/tools/common.zig | 75% | 🔽 |
| src/coding/modes/interactive.zig | src/ai/providers/openai_chat.zig | 41% | 🔺 |
| src/coding/tools/grep.zig | src/coding/modes/rpc.zig | 33% | 🔺 |
| docs/todos/todos.md | docs/design/decided/v2.17-self-restart.md | 60% | 🔽 |
| src/ai/http.zig | README.md | 44% | 🔺 |
| src/coding/session.zig | src/coding/modes/proxy.zig | 33% | 🔽 |
| src/coding/cli.zig | src/coding/compaction.zig | 57% | 🔺 |
| src/agent/proxy.zig | src/ai/providers/google_vertex.zig | 38% | 🔺 |
| src/coding/tools/ls.zig | src/agent/types.zig | 33% | 🔺 |
| src/coding/mod.zig | src/coding/modes/print.zig | 75% | 🔺 |
| src/coding/modes/interactive.zig | test/agent_class_test.zig | 71% | 🔺 |
| build.zig.zon | src/ai/mod.zig | 88% | 🔺 |
| build.zig.zon | docs/spec/v1.md | 55% | 🔺 |
| src/ai/registry.zig | src/ai/providers/google_gemini.zig | 50% | 🔺 |
| src/coding/gitignore.zig | src/coding/tools/ls.zig | 80% | 🔽 |
| src/coding/tools/read.zig | src/ai/providers/anthropic.zig | 56% | 🔺 |
| src/agent/agent.zig | pi-mono-spec.md | 43% | 🔺 |
| src/coding/modes/proxy.zig | src/coding/regex.zig | 75% | 🔽 |
| src/coding/modes/proxy.zig | franky-spec-v2.md | 100% | 🔺 |
| src/ai/providers/anthropic.zig | src/ai/providers/openai_responses.zig | 92% | 🔺 |
| test/agent_loop_test.zig | src/ai/providers/anthropic.zig | 50% | 🔺 |
| src/coding/modes/proxy.zig | src/ai/errors.zig | 63% | 🔺 |
| src/coding/profiles.zig | src/coding/tools/subagent.zig | 38% | 🔺 |
| src/coding/modes/print.zig | src/root.zig | 55% | 🔺 |
| src/coding/modes/print.zig | src/coding/modes/interactive.zig | 76% | 🔺 |
| src/coding/session.zig | src/agent/loop.zig | 44% | 🔺 |
| test/agent_loop_test.zig | build.zig.zon | 67% | 🔺 |
| src/coding/session.zig | src/ai/providers/openai_responses.zig | 44% | 🔺 |
| src/coding/tools/find.zig | src/coding/tools/common.zig | 75% | 🔽 |
| src/coding/modes/print.zig | src/ai/providers/google_gemini.zig | 80% | 🔺 |
| src/coding/modes/print.zig | build.zig | 50% | 🔺 |
| docs/spec/v2.md | src/ai/providers/openai_responses.zig | 27% | 🔺 |
| src/coding/modes/print.zig | src/ai/registry.zig | 70% | 🔺 |
| docs/todos/todos.md | src/coding/modes/rpc.zig | 40% | 🔽 |
| src/ai/stream.zig | build.zig | 57% | ➡️ |
| src/coding/mod.zig | src/coding/improvement.zig | 100% | 🔺 |
| test/agent_loop_test.zig | test/agent_class_test.zig | 50% | 🔺 |
| src/coding/mod.zig | src/coding/object_store.zig | 100% | 🔺 |
| src/coding/tools/grep.zig | test/agent_loop_test.zig | 50% | 🔺 |
| src/coding/mod.zig | src/coding/oauth/http_client.zig | 100% | 🔺 |
| src/coding/tools/edit.zig | src/root.zig | 38% | 🔺 |
| src/coding/modes/print.zig | src/ai/log.zig | 100% | 🔺 |
| README.md | src/coding/modes/web/index.html | 57% | ➡️ |
| src/coding/tools/grep.zig | src/ai/providers/google_vertex.zig | 33% | 🔺 |
| src/coding/tools/grep.zig | src/coding/regex.zig | 75% | 🔺 |
| src/coding/tools/bash.zig | src/coding/tools/find.zig | 56% | 🔺 |
| src/ai/stream.zig | src/ai/http.zig | 57% | 🔺 |
| src/coding/session.zig | src/coding/tools/ls.zig | 44% | 🔺 |
| src/coding/mod.zig | src/coding/cli.zig | 60% | 🔺 |
| src/coding/tools/bash.zig | src/ai/providers/openai_chat.zig | 67% | 🔺 |
| src/ai/registry.zig | src/ai/providers/openai_chat.zig | 60% | 🔺 |
| src/ai/channel.zig | build.zig.zon | 75% | 🔺 |
| docs/spec/v2.md | src/ai/providers/openai_chat.zig | 27% | 🔺 |
| src/coding/tools/bash.zig | src/coding/modes/rpc.zig | 44% | 🔺 |
| src/coding/settings.zig | src/coding/tools/ls.zig | 33% | 🔽 |
| src/coding/tools/grep.zig | src/agent/loop.zig | 50% | 🔺 |
| src/coding/modes/print.zig | docs/spec/v1.md | 36% | 🔺 |
| src/coding/settings.zig | src/coding/tools/write.zig | 50% | 🔽 |
| src/coding/tools/find.zig | src/coding/modes/rpc.zig | 33% | 🔺 |
| src/ai/errors.zig | src/root.zig | 50% | 🔺 |
| docs/todos/todos.md | src/coding/modes/interactive.zig | 40% | 🔽 |
| src/ai/errors.zig | src/ai/providers/google_gemini.zig | 38% | 🔺 |
| src/agent/types.zig | build.zig.zon | 44% | 🔺 |
| build.zig.zon | src/ai/providers/google_gemini.zig | 67% | 🔺 |
| src/ai/providers/openai_chat.zig | franky-spec-v1.md | 44% | 🔺 |
| test/agent_loop_test.zig | src/agent/loop.zig | 83% | 🔺 |
| settings.json | src/coding/modes/print.zig | 55% | 🔽 |
| src/coding/modes/interactive.zig | franky-spec-v1.md | 78% | 🔺 |
| src/coding/compaction.zig | src/root.zig | 57% | 🔺 |
| src/coding/tools/read.zig | src/agent/agent.zig | 33% | 🔺 |
| src/coding/diagnostics.zig | src/ai/http.zig | 38% | 🔺 |
| src/coding/tools/ls.zig | src/root.zig | 67% | 🔺 |
| Dockerfile.sandbox | build.zig.zon | 27% | 🔺 |
| src/agent/types.zig | build.zig | 56% | 🔺 |
| src/ai/errors.zig | build.zig | 38% | 🔺 |
| src/agent/guardrails/guardrails.zig | src/coding/modes/interactive.zig | 80% | 🔽 |
| docs/todos/todos.md | src/coding/diagnostics.zig | 38% | 🔺 |
| src/coding/tools/bash.zig | src/agent/loop.zig | 56% | 🔺 |
| src/coding/tools/write.zig | src/ai/http.zig | 67% | 🔺 |
| src/coding/tools/find.zig | build.zig.zon | 67% | 🔺 |
| docs/spec/v2.md | build.zig | 27% | 🔽 |
| src/coding/modes/interactive.zig | src/ai/http.zig | 41% | 🔺 |
| src/coding/mod.zig | src/ai/http.zig | 53% | 🔺 |
| src/coding/modes/proxy.zig | src/ai/providers/anthropic.zig | 36% | 🔺 |
| src/coding/compaction.zig | src/coding/tools/bash.zig | 43% | 🔺 |
| src/coding/settings.zig | src/agent/loop.zig | 50% | ➡️ |
| src/coding/modes/print.zig | src/coding/object_store.zig | 75% | 🔺 |
| src/coding/cli.zig | src/coding/tools/bash.zig | 67% | 🔺 |
| src/coding/modes/interactive.zig | docs/spec/v1.md | 45% | 🔺 |
| docs/todos/todos.md | src/coding/tools/subagent.zig | 55% | 🔽 |
| src/ai/errors.zig | src/ai/providers/google_vertex.zig | 38% | 🔺 |
| README.md | franky-spec-v1.md | 44% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/tools/edit.zig | 50% | 🔺 |
| src/ai/http.zig | docs/spec/v1.md | 55% | 🔺 |
| src/coding/compaction.zig | src/ai/providers/openai_responses.zig | 43% | 🔺 |
| src/ai/http.zig | franky-spec-v1.md | 33% | 🔺 |
| src/coding/tools/grep.zig | src/coding/tools/write.zig | 100% | ➡️ |
| src/coding/mod.zig | src/ai/types.zig | 60% | 🔺 |
| docs/todos/todos.md | README.md | 33% | 🔽 |
| build.zig.zon | pi-mono-spec.md | 100% | 🔺 |
| src/root.zig | src/agent/proxy.zig | 38% | 🔺 |
| src/ai/providers/faux.zig | src/root.zig | 100% | 🔺 |
| src/coding/compaction.zig | src/ai/providers/google_vertex.zig | 43% | 🔺 |
| src/coding/cli.zig | src/coding/profiles.zig | 88% | 🔺 |
| src/coding/cli.zig | build.zig | 38% | 🔺 |
| src/coding/diagnostics.zig | src/coding/modes/proxy.zig | 38% | 🔺 |
| settings.json | src/coding/settings.zig | 45% | 🔽 |
| src/coding/tools/ls.zig | src/coding/modes/rpc.zig | 33% | 🔺 |
| src/coding/tools/edit.zig | src/coding/tools/find.zig | 78% | 🔺 |
| src/agent/loop.zig | src/coding/tools/common.zig | 75% | 🔺 |
| src/coding/tools/bash.zig | src/ai/registry.zig | 33% | 🔺 |
| src/coding/modes/print.zig | src/coding/role.zig | 60% | 🔺 |
| src/coding/modes/print.zig | .frank-workflow.yaml | 100% | 🔽 |
| src/coding/cli.zig | src/coding/tools/subagent.zig | 36% | ➡️ |
| build.zig.zon | README.md | 67% | 🔺 |
| src/coding/mod.zig | build.zig | 50% | 🔺 |
| src/root.zig | franky-spec-v0.md | 100% | 🔺 |
| src/coding/modes/print.zig | src/ai/http.zig | 65% | 🔺 |
| src/coding/tools/write.zig | src/ai/providers/google_vertex.zig | 50% | 🔺 |
| src/agent/loop.zig | test/agent_class_test.zig | 57% | 🔺 |
| src/coding/branching.zig | src/coding/tools/edit.zig | 75% | 🔺 |
| src/root.zig | docs/spec/v1.md | 73% | 🔺 |
| src/coding/tools/subagent.zig | src/coding/regex.zig | 75% | 🔽 |
| src/coding/tools/edit.zig | src/coding/modes/rpc.zig | 31% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/modes/proxy.zig | 76% | ➡️ |
| docs/spec/v1.md | docs/README.md | 67% | 🔺 |
| src/coding/tools/bash.zig | src/ai/providers/google_gemini.zig | 44% | 🔺 |
| src/coding/modes/print.zig | src/coding/auth.zig | 75% | 🔺 |
| docs/design/v2.10-harness-enforced-guardrails.md | docs/design/v2.11-model-stuck-detector.md | 100% | 🔽 |
| src/coding/modes/interactive.zig | src/coding/tools/grep.zig | 42% | 🔺 |
| Dockerfile.sandbox | src/agent/types.zig | 33% | 🔽 |
| src/ai/registry.zig | src/ai/mod.zig | 50% | 🔺 |
| src/coding/tools/grep.zig | build.zig | 50% | ➡️ |
| src/coding/cli.zig | src/coding/modes/web/app.js | 27% | 🔺 |
| Dockerfile.sandbox | src/root.zig | 27% | 🔺 |
| src/coding/tools/edit.zig | src/ai/providers/anthropic.zig | 36% | 🔺 |
| settings.json | src/coding/modes/proxy.zig | 73% | 🔽 |
| src/agent/loop.zig | src/ai/mod.zig | 38% | 🔺 |
| src/ai/registry.zig | test/parallel_tools_test.zig | 100% | 🔺 |
| src/coding/mod.zig | CHANGELOG.md | 50% | 🔺 |
| src/agent/types.zig | src/ai/providers/google_vertex.zig | 33% | 🔺 |
| src/coding/tools/read.zig | src/agent/types.zig | 44% | 🔺 |
| src/coding/modes/proxy.zig | docs/README.md | 83% | 🔺 |
| docs/todos/todos.md | src/coding/modes/proxy.zig | 56% | 🔽 |
| src/coding/mod.zig | src/coding/modes/proxy.zig | 42% | 🔺 |
| src/coding/tools/find.zig | src/ai/providers/google_vertex.zig | 44% | 🔺 |
| src/coding/tools/bash.zig | src/coding/tools/read.zig | 67% | 🔺 |
| src/coding/tools/edit.zig | README.md | 44% | ➡️ |
| src/ai/providers/google_gemini.zig | src/coding/templates.zig | 100% | 🔺 |
| settings.json | src/agent/loop.zig | 27% | 🔽 |
| docs/spec/v1.md | src/ai/providers/google_gemini.zig | 45% | 🔺 |
| src/coding/mod.zig | src/coding/tools/read.zig | 56% | 🔺 |
| src/ai/registry.zig | src/ai/providers/openai_responses.zig | 40% | ➡️ |
| src/coding/cli.zig | src/ai/providers/google_gemini.zig | 47% | 🔺 |
| src/coding/compaction.zig | src/coding/modes/proxy.zig | 43% | 🔽 |
| src/sdk.zig | src/root.zig | 75% | 🔺 |
| docs/todos/todos.md | src/coding/cli.zig | 30% | ➡️ |
| docs/todos/todos.md | src/coding/modes/web/index.html | 57% | 🔽 |
| build.zig | src/ai/providers/google_gemini.zig | 20% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/extensions.zig | 100% | 🔺 |
| src/ai/providers/openai_chat.zig | src/ai/mod.zig | 63% | 🔺 |
| build.zig | src/ai/providers/openai_responses.zig | 25% | 🔺 |
| src/root.zig | src/coding/modes/web/app.js | 27% | 🔺 |
| src/agent/guardrails/finish_task.zig | src/agent/guardrails/compilation_guard.zig | 75% | 🔽 |
| src/ai/types.zig | build.zig.zon | 80% | 🔺 |
| src/coding/modes/rpc.zig | src/agent/guardrails/compilation_guard.zig | 75% | 🔽 |
| src/coding/mod.zig | docs/spec/v2.md | 45% | 🔺 |
| README.md | CHANGELOG.md | 38% | 🔺 |
| src/coding/settings.zig | src/ai/providers/anthropic.zig | 25% | 🔺 |
| src/coding/modes/web/app.js | docs/spec/v1.md | 27% | 🔺 |
| src/coding/profiles.zig | src/agent/agent.zig | 38% | 🔺 |
| src/ai/channel.zig | src/root.zig | 100% | 🔺 |
| src/ai/registry.zig | pi-mono-spec.md | 43% | 🔺 |
| src/coding/modes/interactive.zig | src/agent/agent.zig | 75% | 🔺 |
| src/coding/diagnostics.zig | src/ai/providers/google_gemini.zig | 38% | 🔺 |
| docs/todos/todos.md | src/agent/proxy.zig | 50% | 🔽 |
| src/agent/types.zig | src/agent/agent.zig | 56% | 🔺 |
| src/coding/cli.zig | test/agent_class_test.zig | 57% | 🔺 |
| src/ai/stream.zig | src/ai/types.zig | 80% | ➡️ |
| src/coding/modes/interactive.zig | CHANGELOG.md | 63% | 🔺 |
| src/root.zig | refactoring.md | 100% | 🔺 |
| src/coding/session.zig | src/ai/providers/openai_chat.zig | 33% | 🔺 |
| src/coding/tools/grep.zig | src/ai/mod.zig | 38% | 🔺 |
| src/coding/tools/bash.zig | src/ai/providers/openai_responses.zig | 44% | 🔺 |
| src/coding/session.zig | src/ai/providers/anthropic.zig | 44% | 🔺 |
| src/coding/modes/proxy.zig | .frank-workflow.yaml | 100% | 🔽 |
| src/ai/providers/openai_chat.zig | src/ai/providers/openai_responses.zig | 92% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/session.zig | 67% | 🔺 |
| test/agent_class_test.zig | franky-spec-v1.md | 43% | 🔺 |
| Dockerfile.sandbox | docs/design/v2.14-agentic-engineering.md | 75% | 🔽 |
| src/agent/types.zig | src/ai/errors.zig | 50% | ➡️ |
| src/coding/gitignore.zig | src/coding/tools/read.zig | 60% | 🔽 |
| src/coding/cli.zig | src/coding/permissions.zig | 75% | 🔺 |
| src/agent/types.zig | src/ai/providers/google_gemini.zig | 33% | 🔺 |
| src/coding/modes/print.zig | franky-spec-v1.md | 78% | 🔺 |
| src/coding/tools/find.zig | src/ai/providers/anthropic.zig | 67% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/oauth/mod.zig | 100% | 🔺 |
| src/coding/modes/rpc.zig | src/ai/providers/google_gemini.zig | 40% | 🔺 |
| src/coding/mod.zig | src/agent/proxy.zig | 38% | 🔺 |
| src/coding/mod.zig | src/coding/tools/web_search.zig | 100% | 🔽 |
| src/coding/mod.zig | src/coding/tools/find.zig | 67% | 🔺 |
| src/root.zig | build.zig | 44% | 🔺 |
| src/agent/guardrails/finish_task.zig | src/coding/modes/proxy.zig | 75% | 🔽 |
| src/coding/mod.zig | src/coding/tools/write.zig | 67% | 🔺 |
| src/coding/tools/find.zig | docs/spec/v1.md | 33% | 🔺 |
| src/coding/modes/print.zig | src/ai/providers/openai_chat.zig | 71% | 🔺 |
| src/coding/modes/print.zig | src/coding/tools/common.zig | 75% | 🔺 |
| src/coding/modes/print.zig | src/coding/tools/ls.zig | 56% | 🔺 |
| src/coding/tools/grep.zig | src/agent/types.zig | 44% | 🔺 |
| src/coding/modes/proxy.zig | docs/spec/v1.md | 55% | 🔺 |
| docs/spec/v1.md | src/ai/providers/openai_chat.zig | 36% | 🔺 |
| src/root.zig | build.zig.zon | 85% | 🔺 |
| src/coding/tools/read.zig | src/ai/http.zig | 56% | 🔺 |
| src/root.zig | src/ai/providers/google_vertex.zig | 58% | 🔺 |
| .teller.yml | Dockerfile.sandbox | 100% | 🔽 |
| src/coding/tools/bash.zig | src/ai/providers/google_vertex.zig | 44% | 🔺 |
| src/coding/tools/edit.zig | src/ai/providers/openai_responses.zig | 33% | 🔺 |
| src/coding/settings.zig | src/coding/tools/find.zig | 33% | 🔽 |
| src/coding/tools/read.zig | src/ai/providers/google_vertex.zig | 44% | 🔺 |
| src/coding/tools/edit.zig | src/ai/providers/google_gemini.zig | 27% | 🔺 |
| src/ai/http.zig | CHANGELOG.md | 38% | 🔺 |
| src/coding/tools/find.zig | src/agent/loop.zig | 44% | 🔺 |
| src/coding/profiles.zig | src/coding/modes/rpc.zig | 63% | 🔺 |
| src/coding/tools/edit.zig | test/agent_loop_test.zig | 50% | 🔺 |
| src/coding/modes/print.zig | src/coding/tools/grep.zig | 50% | 🔺 |
| src/agent/guardrails/finish_task.zig | src/coding/tools/edit.zig | 75% | 🔽 |
| src/agent/loop.zig | test/kitchen_sink_test.zig | 100% | 🔺 |
| docs/spec/v2.md | src/ai/providers/anthropic.zig | 27% | 🔺 |
| src/coding/modes/print.zig | docs/design/decided/v2.16-multimodel-review.md | 100% | 🔽 |
| src/coding/compaction.zig | src/coding/object_store.zig | 100% | 🔺 |
| src/ai/errors.zig | src/ai/types.zig | 80% | ➡️ |
| Dockerfile.sandbox | src/coding/tools/find.zig | 33% | 🔺 |
| src/coding/cli.zig | src/coding/modes/web/style.css | 38% | 🔺 |
| src/coding/modes/proxy.zig | src/coding/modes/web/style.css | 88% | 🔺 |
| src/coding/modes/print.zig | test/agent_loop_test.zig | 67% | 🔺 |
| test/agent_class_test.zig | src/ai/providers/google_gemini.zig | 43% | 🔺 |
| Dockerfile.sandbox | src/ai/http.zig | 27% | 🔺 |
| src/coding/cli.zig | src/ai/mod.zig | 50% | 🔺 |
| src/coding/modes/interactive.zig | src/agent/loop.zig | 64% | 🔺 |
| src/coding/tools/edit.zig | src/coding/tools/common.zig | 75% | 🔽 |
| src/coding/modes/rpc.zig | src/agent/types.zig | 56% | 🔺 |
| src/coding/session.zig | build.zig | 33% | 🔺 |
| src/coding/cli.zig | src/coding/replay.zig | 100% | 🔽 |
| src/coding/modes/interactive.zig | src/coding/tools/common.zig | 75% | 🔺 |
| src/agent/loop.zig | build.zig | 50% | 🔺 |
| src/coding/tools/write.zig | src/agent/agent.zig | 50% | 🔺 |
| src/coding/modes/rpc.zig | docs/design/decided/v2.16-multimodel-review.md | 100% | 🔽 |
| src/coding/settings.zig | src/ai/providers/openai_responses.zig | 33% | 🔺 |
| src/coding/modes/print.zig | src/ai/mod.zig | 75% | 🔺 |
| src/coding/session.zig | test/agent_class_test.zig | 57% | 🔺 |
| src/coding/branching.zig | src/root.zig | 75% | 🔺 |
| src/ai/http.zig | src/ai/providers/openai_chat.zig | 71% | 🔺 |
| src/agent/proxy.zig | src/ai/providers/google_gemini.zig | 38% | 🔺 |
| build.zig | README.md | 33% | 🔺 |
| src/coding/modes/proxy.zig | src/coding/modes/rpc.zig | 85% | ➡️ |
| src/coding/tools/edit.zig | src/ai/http.zig | 38% | 🔺 |
| src/coding/modes/proxy.zig | src/agent/agent.zig | 58% | 🔺 |
| src/coding/session.zig | src/ai/channel.zig | 75% | 🔺 |
| src/coding/mod.zig | src/root.zig | 63% | 🔺 |
| src/coding/modes/proxy.zig | src/agent/loop.zig | 60% | ➡️ |
| src/coding/modes/rpc.zig | src/agent/agent.zig | 50% | 🔺 |
| src/agent/agent.zig | build.zig | 42% | 🔺 |
| src/ai/registry.zig | src/ai/http.zig | 70% | 🔺 |
| src/ai/stream.zig | src/ai/providers/google_vertex.zig | 43% | 🔺 |
| src/agent/loop.zig | docs/spec/v3.md | 75% | 🔽 |
| src/agent/agent.zig | test/agent_class_test.zig | 71% | 🔺 |
| src/coding/session.zig | src/coding/tools/find.zig | 44% | 🔺 |
| src/coding/modes/rpc.zig | src/ai/providers/anthropic.zig | 36% | 🔺 |
| src/ai/providers/anthropic.zig | src/ai/providers/google_gemini.zig | 79% | 🔺 |
| src/coding/tools/subagent.zig | src/ai/providers/google_gemini.zig | 27% | 🔺 |
| src/coding/modes/rpc.zig | src/ai/http.zig | 29% | 🔺 |
| src/coding/tools/ls.zig | src/agent/loop.zig | 44% | 🔺 |
| src/coding/modes/print.zig | src/agent/loop.zig | 80% | 🔺 |
| settings.json | src/coding/modes/rpc.zig | 36% | 🔽 |
| src/coding/modes/proxy.zig | franky-spec-v1.md | 56% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/tools/read.zig | 67% | 🔺 |
| src/coding/tools/grep.zig | pi-mono-spec.md | 43% | 🔺 |
| src/ai/http.zig | src/coding/modes/web/app.js | 27% | 🔺 |
| src/agent/types.zig | src/root.zig | 56% | 🔺 |
| src/coding/auth.zig | src/coding/compaction.zig | 75% | 🔺 |
| src/coding/tools/edit.zig | build.zig | 25% | 🔺 |
| src/coding/tools/ls.zig | src/coding/tools/common.zig | 75% | 🔽 |
| src/ai/http.zig | src/coding/tools/common.zig | 75% | 🔺 |
| src/coding/tools/bash.zig | src/coding/tools/edit.zig | 56% | 🔺 |
| src/coding/tools/ls.zig | docs/spec/v1.md | 33% | 🔺 |
| src/ai/errors.zig | build.zig.zon | 50% | 🔺 |
| src/agent/types.zig | src/agent/proxy.zig | 63% | 🔺 |
| src/coding/session.zig | src/ai/mod.zig | 38% | 🔺 |
| src/coding/tools/find.zig | pi-mono-spec.md | 43% | 🔺 |
| docs/spec/v2.md | src/coding/replay.zig | 100% | 🔽 |
| src/coding/tools/write.zig | src/agent/loop.zig | 67% | 🔺 |
| docs/spec/v2.md | src/coding/modes/proxy.zig | 45% | 🔺 |
| src/coding/cli.zig | build.zig.zon | 55% | 🔺 |
| src/coding/tools/bash.zig | src/agent/agent.zig | 33% | 🔺 |
| src/coding/tools/write.zig | build.zig.zon | 50% | 🔺 |
| src/coding/tools/edit.zig | src/coding/modes/proxy.zig | 44% | 🔺 |
| src/coding/tools/bash.zig | src/root.zig | 78% | 🔺 |
| src/coding/tools/ls.zig | build.zig | 44% | 🔺 |
| src/coding/modes/print.zig | src/coding/extensions.zig | 100% | 🔺 |
| src/coding/gitignore.zig | src/coding/tools/edit.zig | 60% | 🔽 |
| src/coding/modes/interactive.zig | src/agent/proxy.zig | 88% | 🔺 |
| src/coding/tools/grep.zig | src/ai/providers/anthropic.zig | 50% | 🔺 |
| src/coding/settings.zig | src/coding/modes/rpc.zig | 50% | 🔽 |
| src/coding/tools/subagent.zig | src/coding/modes/proxy.zig | 82% | ➡️ |
| src/ai/providers/anthropic.zig | src/coding/tools/common.zig | 75% | 🔺 |
| build.zig.zon | franky-spec-v2.md | 100% | 🔺 |
| src/coding/diagnostics.zig | docs/spec/v1.md | 38% | 🔺 |
| src/agent/types.zig | src/ai/providers/openai_chat.zig | 33% | 🔺 |
| src/coding/auth.zig | src/coding/branching.zig | 75% | 🔺 |
| src/coding/mod.zig | src/coding/oauth/mod.zig | 100% | 🔺 |
| src/coding/modes/proxy.zig | src/ai/http.zig | 47% | 🔺 |
| src/ai/providers/google_gemini.zig | src/ai/providers/google_vertex.zig | 100% | 🔺 |
| src/coding/cli.zig | src/ai/http.zig | 35% | 🔺 |
| src/coding/tools/grep.zig | src/ai/http.zig | 58% | 🔺 |
| src/coding/cli.zig | src/coding/modes/interactive.zig | 70% | 🔺 |
| src/ai/providers/anthropic.zig | src/ai/providers/google_vertex.zig | 83% | 🔺 |
| src/root.zig | src/ai/mod.zig | 100% | 🔺 |
| src/coding/modes/print.zig | build.zig.zon | 62% | 🔺 |
| src/coding/tools/find.zig | src/coding/tools/read.zig | 78% | 🔺 |
| src/coding/tools/read.zig | src/coding/tools/subagent.zig | 44% | ➡️ |
| src/coding/modes/interactive.zig | src/ai/providers/google_vertex.zig | 67% | 🔺 |
| src/ai/providers/openai_responses.zig | franky-spec-v1.md | 33% | 🔺 |
| src/coding/tools/read.zig | src/agent/loop.zig | 56% | 🔺 |
| src/coding/tools/edit.zig | src/ai/providers/google_vertex.zig | 33% | 🔺 |
| src/coding/settings.zig | src/coding/tools/edit.zig | 33% | 🔽 |
| src/coding/modes/print.zig | src/coding/modes/proxy.zig | 64% | ➡️ |
| src/coding/cli.zig | src/agent/agent.zig | 67% | 🔺 |
| test/agent_class_test.zig | src/ai/mod.zig | 43% | 🔺 |
| Dockerfile.sandbox | src/coding/tools/edit.zig | 36% | 🔺 |
| src/coding/settings.zig | src/ai/providers/google_vertex.zig | 25% | 🔺 |
| src/ai/registry.zig | src/coding/tools/common.zig | 75% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/tools/subagent.zig | 64% | ➡️ |
| src/coding/cli.zig | src/coding/tools/write.zig | 67% | ➡️ |
| src/agent/proxy.zig | src/coding/modes/web/style.css | 63% | 🔺 |
| src/coding/tools/bash.zig | test/agent_loop_test.zig | 50% | 🔺 |
| src/ai/stream.zig | src/ai/errors.zig | 57% | ➡️ |
| src/ai/types.zig | src/root.zig | 80% | 🔺 |
| src/coding/auth.zig | src/ai/providers/google_gemini.zig | 75% | 🔺 |
| src/coding/mod.zig | src/coding/tools/edit.zig | 31% | 🔺 |
| src/coding/session.zig | src/agent/agent.zig | 44% | 🔺 |
| docs/todos/todos.md | src/ai/stream.zig | 43% | 🔽 |
| src/coding/mod.zig | README.md | 44% | 🔺 |
| docs/todos/todos.md | src/coding/modes/web/style.css | 63% | 🔽 |
| src/coding/mod.zig | build.zig.zon | 54% | 🔺 |
| src/coding/modes/proxy.zig | src/agent/types.zig | 56% | 🔺 |
| src/ai/providers/openai_chat.zig | src/coding/tools/common.zig | 75% | 🔺 |
| src/ai/http.zig | pi-mono-spec.md | 43% | 🔺 |
| src/coding/tools/grep.zig | src/coding/modes/web/app.js | 27% | 🔺 |
| src/ai/stream.zig | src/coding/modes/print.zig | 86% | ➡️ |
| src/coding/modes/print.zig | test/agent_class_test.zig | 71% | 🔺 |
| src/coding/modes/rpc.zig | README.md | 33% | 🔺 |
| src/coding/object_store.zig | src/coding/tools/edit.zig | 75% | 🔺 |
| src/coding/mod.zig | src/coding/branching.zig | 100% | 🔺 |
| src/coding/object_store.zig | src/coding/session.zig | 100% | 🔺 |
| src/coding/tools/find.zig | src/ai/providers/google_gemini.zig | 44% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/templates.zig | 100% | 🔺 |
| README.md | src/agent/proxy.zig | 38% | 🔽 |
| src/coding/modes/rpc.zig | src/ai/providers/openai_chat.zig | 35% | 🔺 |
| src/coding/modes/print.zig | src/agent/guardrails/compilation_guard.zig | 75% | 🔽 |
| src/coding/auth.zig | src/ai/providers/google_vertex.zig | 75% | 🔺 |
| src/coding/modes/proxy.zig | src/agent/guardrails/compilation_guard.zig | 75% | 🔽 |
| src/coding/compaction.zig | src/coding/modes/interactive.zig | 86% | 🔺 |
| src/coding/modes/interactive.zig | src/ai/errors.zig | 75% | 🔺 |
| src/coding/tools/find.zig | build.zig | 44% | 🔺 |
| src/agent/guardrails/finish_task.zig | .frank-workflow.yaml | 100% | 🔽 |
| src/coding/cli.zig | src/agent/types.zig | 67% | 🔺 |
| src/ai/stream.zig | build.zig.zon | 57% | 🔺 |
| src/coding/mod.zig | src/coding/diagnostics.zig | 50% | 🔺 |
| src/coding/compaction.zig | src/coding/session.zig | 86% | ➡️ |
| docs/todos/todos.md | src/coding/modes/print.zig | 52% | 🔽 |
| src/ai/providers/openai_chat.zig | CHANGELOG.md | 50% | 🔺 |
| src/coding/settings.zig | src/ai/http.zig | 25% | 🔺 |
| src/coding/mod.zig | src/ai/providers/anthropic.zig | 64% | 🔺 |
| src/agent/loop.zig | src/coding/modes/web/style.css | 38% | 🔺 |
| src/coding/session.zig | src/ai/errors.zig | 38% | 🔺 |
| src/coding/branching.zig | src/ai/providers/openai_responses.zig | 75% | 🔺 |
| src/coding/modes/interactive.zig | src/ai/providers/openai_responses.zig | 58% | 🔺 |
| src/coding/mod.zig | src/ai/providers/openai_responses.zig | 67% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/profiles.zig | 75% | 🔺 |
| src/ai/providers/google_gemini.zig | src/ai/providers/openai_responses.zig | 100% | 🔺 |
| src/coding/tools/write.zig | src/root.zig | 50% | 🔺 |
| src/ai/registry.zig | src/agent/loop.zig | 70% | 🔺 |
| docs/todos/todos.md | src/ai/http.zig | 24% | 🔽 |
| src/coding/modes/print.zig | src/coding/modes/web/index.html | 43% | 🔺 |
| src/ai/registry.zig | build.zig.zon | 50% | 🔺 |
| build.zig | src/ai/providers/google_vertex.zig | 25% | 🔺 |
| src/ai/registry.zig | test/agent_loop_test.zig | 50% | 🔺 |
| docs/design/decided/v2.17-self-restart.md | src/coding/modes/interactive.zig | 60% | 🔽 |
| src/coding/tools/write.zig | src/ai/providers/anthropic.zig | 67% | 🔺 |
| src/agent/types.zig | src/ai/providers/openai_responses.zig | 33% | 🔺 |
| src/coding/modes/interactive.zig | test/agent_loop_test.zig | 50% | 🔺 |
| src/coding/tools/grep.zig | src/ai/providers/openai_chat.zig | 42% | 🔺 |
| src/agent/guardrails/compilation_guard.zig | src/agent/guardrails/stuck_detector.zig | 100% | 🔽 |
| src/coding/modes/print.zig | src/ai/types.zig | 80% | 🔺 |
| src/agent/guardrails/finish_task.zig | src/coding/settings.zig | 75% | 🔽 |
| src/coding/cli.zig | src/coding/tools/grep.zig | 42% | 🔺 |
| src/coding/cli.zig | test/agent_loop_test.zig | 50% | 🔺 |
| src/ai/errors.zig | src/ai/http.zig | 50% | 🔺 |
| src/coding/modes/proxy.zig | docs/design/v2.14-agentic-engineering.md | 75% | 🔽 |
| src/coding/compaction.zig | src/coding/tools/ls.zig | 43% | 🔺 |
| src/agent/agent.zig | src/ai/providers/openai_chat.zig | 33% | 🔺 |
| src/coding/modes/rpc.zig | build.zig | 31% | 🔽 |
| src/agent/guardrails/finish_task.zig | src/agent/guardrails/guardrails.zig | 100% | 🔽 |
| src/agent/loop.zig | src/ai/providers/openai_chat.zig | 53% | 🔺 |
| build.zig.zon | test/agent_class_test.zig | 71% | 🔺 |
| src/coding/modes/interactive.zig | src/coding/tools/find.zig | 44% | ➡️ |
| src/agent/types.zig | src/coding/modes/web/style.css | 38% | 🔺 |
| src/coding/auth.zig | src/coding/modes/interactive.zig | 100% | 🔺 |
| src/ai/providers/faux.zig | src/ai/registry.zig | 100% | 🔺 |
| src/ai/providers/faux.zig | test/agent_loop_test.zig | 100% | 🔺 |
| Dockerfile.sandbox | src/coding/modes/proxy.zig | 36% | 🔽 |
| src/coding/modes/rpc.zig | build.zig.zon | 40% | 🔺 |
| src/coding/tools/ls.zig | src/coding/tools/subagent.zig | 33% | 🔽 |
| docs/spec/v1.md | src/ai/providers/anthropic.zig | 36% | 🔺 |
| src/coding/tools/ls.zig | src/ai/providers/google_vertex.zig | 44% | 🔺 |
| src/coding/mod.zig | src/ai/channel.zig | 75% | 🔺 |
| src/coding/modes/proxy.zig | refactoring.md | 100% | 🔺 |

<details>
<summary>📖 What is Temporal Coupling?</summary>

**Temporal coupling** (also called *change coupling*) measures how often two files are modified together in the same commit. It detects logical dependencies without needing a language-specific parser.

### How to Read the Degree

The degree answers: *"If I change file A, what's the chance I also need to change file B?"*

| Range | Meaning |
|-------|---------|
| 0–15% | Noise — filtered out |
| 15–40% | Occasional co-change; may be legitimate API boundaries |
| 40–70% | Suspicious — likely a missing abstraction or copy-paste |
| 70%+ | Almost always co-changed — files are logically welded together |

### The Trend Arrow

- **🔺 Rising** — coupling is getting stronger. The architectural boundary is eroding.
- **🔽 Falling** — coupling is weakening. Files are becoming more independent.
- **➡️ Stable** — coupling is consistent over time.

Rising trends are the most actionable signal. They indicate that refactoring should be scheduled before the entanglement gets worse.

### Cross-Package Coupling

The most interesting pairs are those in **different packages/directories**. These suggest:

- A missing abstraction that should be extracted into a shared module
- A copy-paste relationship between unrelated parts of the codebase
- An architectural dependency that violates the intended layering

</details>

---

*Thresholds auto-calibrated to this repository's history.*
