# Franky Test Coverage Report

**Generated:** 2026-04-28 01:08:04 UTC  
**Total Test Suites Run:** 6  
**Total Tests Passed:** 853/853  

## Overall Summary

| Metric | Value |
|---|---|
| **Overall Line Coverage** | 91.3% (15,731 / 17,234 lines) |
| **Uncovered Lines** | 1,503 |
| **Source Files Tracked** | 90 |
| **Total Tests** | 853 passed |
| **Instrumented Lines** (kcov) | 17,234 |
| **Executed Lines** (kcov) | 15,731 |

### Coverage Legend

- 🟢 **Excellent** (≥90%) — Well-tested, safe to modify
- 🟡 **Good** (75–89%) — Adequately tested
- 🟠 **Fair** (50–74%) — Needs more tests
- 🔴 **Poor** (<50%) — Significant gaps

## Test Suite Results

| Suite | Tests | Coverage | Status |
|---|---|---|---|
| franky-gitignore_test | franky-gitignore_test | 59.6% | 🟠 |
| franky-test | franky-test | 89.9% | 🟡 |
| franky-kitchen_sink_test | franky-kitchen_sink_test | 62.9% | 🟠 |
| franky-agent_loop_test | franky-agent_loop_test | 55.0% | 🟠 |
| franky-parallel_tools_test | franky-parallel_tools_test | 59.2% | 🟠 |
| franky-agent_class_test | franky-agent_class_test | 41.0% | 🔴 |

## Coverage by Module

| Module | Files | Coverage | Covered Lines | Total Lines |
|---|---|---|---|---|
| 🟡 **agent** | 5 | 86.9% | 793 | 913 |
| 🟡 **ai** | 21 | 89.0% | 3,160 | 3,549 |
| 🟢 **coding** | 52 | 92.0% | 10,732 | 11,664 |
| 🟢 **root.zig** | 1 | 100.0% | 1 | 1 |
| 🟢 **sdk.zig** | 1 | 100.0% | 26 | 26 |
| 🟢 **test_helpers.zig** | 1 | 100.0% | 2 | 2 |
| 🟢 **tui** | 9 | 94.3% | 1,017 | 1,079 |

## Coverage by Submodule

| Module / Submodule | Files | Coverage | Covered Lines | Total Lines |
|---|---|---|---|---|
| 🟡 **agent** / agent.zig | 1 | 85.2% | 127 | 149 |
| 🟡 **agent** / loop.zig | 1 | 89.7% | 539 | 601 |
| 🟢 **agent** / mod.zig | 1 | 100.0% | 1 | 1 |
| 🟠 **agent** / proxy.zig | 1 | 74.0% | 94 | 127 |
| 🟢 **agent** / types.zig | 1 | 91.4% | 32 | 35 |
| 🟢 **ai** / channel.zig | 1 | 97.7% | 169 | 173 |
| 🟢 **ai** / error_map.zig | 1 | 97.7% | 126 | 129 |
| 🟢 **ai** / errors.zig | 1 | 100.0% | 44 | 44 |
| 🟢 **ai** / http.zig | 1 | 91.2% | 447 | 490 |
| 🟢 **ai** / log.zig | 1 | 99.2% | 122 | 123 |
| 🟢 **ai** / mod.zig | 1 | 100.0% | 1 | 1 |
| 🟡 **ai** / partial_json.zig | 1 | 83.8% | 285 | 340 |
| 🟡 **ai** / providers | 7 | 82.9% | 1,177 | 1,420 |
| 🟢 **ai** / registry.zig | 1 | 100.0% | 46 | 46 |
| 🟢 **ai** / retry.zig | 1 | 99.2% | 122 | 123 |
| 🟢 **ai** / sse.zig | 1 | 100.0% | 165 | 165 |
| 🟢 **ai** / stream.zig | 1 | 94.6% | 175 | 185 |
| 🟢 **ai** / transform.zig | 1 | 92.9% | 79 | 85 |
| 🟢 **ai** / types.zig | 1 | 92.8% | 116 | 125 |
| 🟡 **ai** / utils.zig | 1 | 86.0% | 86 | 100 |
| 🟢 **coding** / auth.zig | 1 | 96.5% | 275 | 285 |
| 🟢 **coding** / branching.zig | 1 | 96.3% | 288 | 299 |
| 🟡 **coding** / cli.zig | 1 | 87.5% | 231 | 264 |
| 🟢 **coding** / compaction.zig | 1 | 95.0% | 362 | 381 |
| 🟢 **coding** / env_denylist.zig | 1 | 98.9% | 92 | 93 |
| 🟢 **coding** / extensions.zig | 1 | 96.7% | 89 | 92 |
| 🟢 **coding** / extensions_builtin | 2 | 100.0% | 49 | 49 |
| 🟢 **coding** / gitignore.zig | 1 | 94.0% | 298 | 317 |
| 🟢 **coding** / mod.zig | 1 | 100.0% | 1 | 1 |
| 🟢 **coding** / models.zig | 1 | 95.0% | 113 | 119 |
| 🟢 **coding** / models_fetch.zig | 1 | 95.2% | 357 | 375 |
| 🟢 **coding** / models_render.zig | 1 | 96.6% | 196 | 203 |
| 🟡 **coding** / modes | 5 | 89.1% | 2,891 | 3,243 |
| 🟡 **coding** / oauth | 13 | 87.4% | 857 | 980 |
| 🟢 **coding** / object_store.zig | 1 | 97.8% | 220 | 225 |
| 🟢 **coding** / path_safety.zig | 1 | 99.2% | 120 | 121 |
| 🟢 **coding** / permissions.zig | 1 | 95.7% | 695 | 726 |
| 🟢 **coding** / profiles.zig | 1 | 90.3% | 524 | 580 |
| 🟢 **coding** / regex.zig | 1 | 91.1% | 401 | 440 |
| 🟢 **coding** / role.zig | 1 | 93.2% | 110 | 118 |
| 🟡 **coding** / rpc.zig | 1 | 88.0% | 183 | 208 |
| 🟢 **coding** / session.zig | 1 | 94.3% | 626 | 664 |
| 🟢 **coding** / settings.zig | 1 | 96.5% | 138 | 143 |
| 🟢 **coding** / slash.zig | 1 | 93.1% | 108 | 116 |
| 🟢 **coding** / templates.zig | 1 | 100.0% | 91 | 91 |
| 🟢 **coding** / terminal.zig | 1 | 100.0% | 17 | 17 |
| 🟢 **coding** / tools | 9 | 92.5% | 1,400 | 1,514 |
| 🟢 **root.zig** / (root) | 1 | 100.0% | 1 | 1 |
| 🟢 **sdk.zig** / (root) | 1 | 100.0% | 26 | 26 |
| 🟢 **test_helpers.zig** / (root) | 1 | 100.0% | 2 | 2 |
| 🟢 **tui** / buffer.zig | 1 | 92.4% | 85 | 92 |
| 🟢 **tui** / cell.zig | 1 | 100.0% | 70 | 70 |
| 🟡 **tui** / diff_renderer.zig | 1 | 88.7% | 157 | 177 |
| 🟢 **tui** / editor.zig | 1 | 93.0% | 226 | 243 |
| 🟢 **tui** / key_decoder.zig | 1 | 93.1% | 188 | 202 |
| 🟢 **tui** / keybindings.zig | 1 | 98.5% | 66 | 67 |
| 🟢 **tui** / mod.zig | 1 | 100.0% | 1 | 1 |
| 🟢 **tui** / region.zig | 1 | 96.9% | 93 | 96 |
| 🟢 **tui** / text_buffer.zig | 1 | 100.0% | 131 | 131 |

## Detailed File Coverage

| File | Module | Coverage | Covered | Uncovered | Total |
|---|---|---|---|---|---|
| 🟢 catalog.zig | coding | 100.0% | 8 | 0 | 8 |
| 🟢 mod.zig | tui | 100.0% | 1 | 0 | 1 |
| 🟢 root.zig | root.zig | 100.0% | 1 | 0 | 1 |
| 🟢 google_vertex.zig | ai | 100.0% | 20 | 0 | 20 |
| 🟢 sse.zig | ai | 100.0% | 165 | 0 | 165 |
| 🟢 echo.zig | coding | 100.0% | 41 | 0 | 41 |
| 🟢 sdk.zig | sdk.zig | 100.0% | 26 | 0 | 26 |
| 🟢 mod.zig | agent | 100.0% | 1 | 0 | 1 |
| 🟢 browser.zig | coding | 100.0% | 15 | 0 | 15 |
| 🟢 flow_gemini.zig | coding | 100.0% | 8 | 0 | 8 |
| 🟢 templates.zig | coding | 100.0% | 91 | 0 | 91 |
| 🟢 terminal.zig | coding | 100.0% | 17 | 0 | 17 |
| 🟢 registry.zig | ai | 100.0% | 46 | 0 | 46 |
| 🟢 common.zig | coding | 100.0% | 15 | 0 | 15 |
| 🟢 cell.zig | tui | 100.0% | 70 | 0 | 70 |
| 🟢 openai_gateway.zig | ai | 100.0% | 24 | 0 | 24 |
| 🟢 flow_anthropic.zig | coding | 100.0% | 12 | 0 | 12 |
| 🟢 text_buffer.zig | tui | 100.0% | 131 | 0 | 131 |
| 🟢 errors.zig | ai | 100.0% | 44 | 0 | 44 |
| 🟢 mod.zig | ai | 100.0% | 1 | 0 | 1 |
| 🟢 mod.zig | coding | 100.0% | 1 | 0 | 1 |
| 🟢 test_helpers.zig | test_helpers.zig | 100.0% | 2 | 0 | 2 |
| 🟢 mod.zig | coding | 100.0% | 1 | 0 | 1 |
| 🟢 pkce.zig | coding | 100.0% | 53 | 0 | 53 |
| 🟢 gemini.zig | coding | 100.0% | 43 | 0 | 43 |
| 🟢 retry.zig | ai | 99.2% | 122 | 1 | 123 |
| 🟢 path_safety.zig | coding | 99.2% | 120 | 1 | 121 |
| 🟢 log.zig | ai | 99.2% | 122 | 1 | 123 |
| 🟢 interactive.zig | coding | 99.0% | 495 | 5 | 500 |
| 🟢 env_denylist.zig | coding | 98.9% | 92 | 1 | 93 |
| 🟢 keybindings.zig | tui | 98.5% | 66 | 1 | 67 |
| 🟢 rpc.zig | coding | 98.1% | 51 | 1 | 52 |
| 🟢 object_store.zig | coding | 97.8% | 220 | 5 | 225 |
| 🟢 error_map.zig | ai | 97.7% | 126 | 3 | 129 |
| 🟢 channel.zig | ai | 97.7% | 169 | 4 | 173 |
| 🟢 bash.zig | coding | 97.2% | 308 | 9 | 317 |
| 🟢 region.zig | tui | 96.9% | 93 | 3 | 96 |
| 🟢 extensions.zig | coding | 96.7% | 89 | 3 | 92 |
| 🟢 read.zig | coding | 96.6% | 143 | 5 | 148 |
| 🟢 models_render.zig | coding | 96.6% | 196 | 7 | 203 |
| 🟢 settings.zig | coding | 96.5% | 138 | 5 | 143 |
| 🟢 auth.zig | coding | 96.5% | 275 | 10 | 285 |
| 🟢 grep.zig | coding | 96.4% | 320 | 12 | 332 |
| 🟢 branching.zig | coding | 96.3% | 288 | 11 | 299 |
| 🟢 permissions.zig | coding | 95.7% | 695 | 31 | 726 |
| 🟢 models_fetch.zig | coding | 95.2% | 357 | 18 | 375 |
| 🟢 anthropic.zig | coding | 95.0% | 152 | 8 | 160 |
| 🟢 models.zig | coding | 95.0% | 113 | 6 | 119 |
| 🟢 compaction.zig | coding | 95.0% | 362 | 19 | 381 |
| 🟢 login.zig | coding | 94.7% | 18 | 1 | 19 |
| 🟢 stream.zig | ai | 94.6% | 175 | 10 | 185 |
| 🟢 session.zig | coding | 94.3% | 626 | 38 | 664 |
| 🟢 gitignore.zig | coding | 94.0% | 298 | 19 | 317 |
| 🟢 ls.zig | coding | 93.6% | 161 | 11 | 172 |
| 🟢 faux.zig | ai | 93.6% | 175 | 12 | 187 |
| 🟢 workspace.zig | coding | 93.3% | 56 | 4 | 60 |
| 🟢 role.zig | coding | 93.2% | 110 | 8 | 118 |
| 🟢 slash.zig | coding | 93.1% | 108 | 8 | 116 |
| 🟢 key_decoder.zig | tui | 93.1% | 188 | 14 | 202 |
| 🟢 editor.zig | tui | 93.0% | 226 | 17 | 243 |
| 🟢 transform.zig | ai | 92.9% | 79 | 6 | 85 |
| 🟢 types.zig | ai | 92.8% | 116 | 9 | 125 |
| 🟢 vertex.zig | coding | 92.7% | 203 | 16 | 219 |
| 🟢 buffer.zig | tui | 92.4% | 85 | 7 | 92 |
| 🟢 find.zig | coding | 91.5% | 182 | 17 | 199 |
| 🟢 types.zig | agent | 91.4% | 32 | 3 | 35 |
| 🟢 http.zig | ai | 91.2% | 447 | 43 | 490 |
| 🟢 regex.zig | coding | 91.1% | 401 | 39 | 440 |
| 🟢 profiles.zig | coding | 90.3% | 524 | 56 | 580 |
| 🟡 openai_chat.zig | ai | 89.7% | 321 | 37 | 358 |
| 🟡 loop.zig | agent | 89.7% | 539 | 62 | 601 |
| 🟡 openai_responses.zig | ai | 89.4% | 227 | 27 | 254 |
| 🟡 copilot.zig | coding | 88.8% | 238 | 30 | 268 |
| 🟡 diff_renderer.zig | tui | 88.7% | 157 | 20 | 177 |
| 🟡 rpc.zig | coding | 88.0% | 183 | 25 | 208 |
| 🟡 listener.zig | coding | 87.8% | 86 | 12 | 98 |
| 🟡 proxy.zig | coding | 87.6% | 1978 | 280 | 2258 |
| 🟡 cli.zig | coding | 87.5% | 231 | 33 | 264 |
| 🟡 utils.zig | ai | 86.0% | 86 | 14 | 100 |
| 🟡 agent.zig | agent | 85.2% | 127 | 22 | 149 |
| 🟡 print.zig | coding | 84.3% | 349 | 65 | 414 |
| 🟡 partial_json.zig | ai | 83.8% | 285 | 55 | 340 |
| 🟡 edit.zig | coding | 82.8% | 159 | 33 | 192 |
| 🟡 flow_copilot.zig | coding | 80.0% | 12 | 3 | 15 |
| 🟠 proxy.zig | agent | 74.0% | 94 | 33 | 127 |
| 🟠 anthropic.zig | ai | 71.8% | 224 | 88 | 312 |
| 🟠 write.zig | coding | 70.9% | 56 | 23 | 79 |
| 🟠 google_gemini.zig | ai | 70.2% | 186 | 79 | 265 |
| 🔴 http_client.zig | coding | 46.7% | 7 | 8 | 15 |
| 🔴 flow_vertex.zig | coding | 37.0% | 27 | 46 | 73 |

## Files Needing Attention

| File | Module | Coverage | Covered | Uncovered | Total |
|---|---|---|---|---|---|
| 🔴 flow_vertex.zig | coding | 37.0% | 27 | 46 | 73 |
| 🔴 http_client.zig | coding | 46.7% | 7 | 8 | 15 |
| 🟠 google_gemini.zig | ai | 70.2% | 186 | 79 | 265 |
| 🟠 write.zig | coding | 70.9% | 56 | 23 | 79 |
| 🟠 anthropic.zig | ai | 71.8% | 224 | 88 | 312 |
| 🟠 proxy.zig | agent | 74.0% | 94 | 33 | 127 |

## Perfect / Near-Perfect Coverage (100%)

- ✅ **catalog.zig** (8 lines)
- ✅ **mod.zig** (1 lines)
- ✅ **root.zig** (1 lines)
- ✅ **google_vertex.zig** (20 lines)
- ✅ **sse.zig** (165 lines)
- ✅ **echo.zig** (41 lines)
- ✅ **sdk.zig** (26 lines)
- ✅ **mod.zig** (1 lines)
- ✅ **browser.zig** (15 lines)
- ✅ **flow_gemini.zig** (8 lines)
- ✅ **templates.zig** (91 lines)
- ✅ **terminal.zig** (17 lines)
- ✅ **registry.zig** (46 lines)
- ✅ **common.zig** (15 lines)
- ✅ **cell.zig** (70 lines)
- ✅ **openai_gateway.zig** (24 lines)
- ✅ **flow_anthropic.zig** (12 lines)
- ✅ **text_buffer.zig** (131 lines)
- ✅ **errors.zig** (44 lines)
- ✅ **mod.zig** (1 lines)
- ✅ **mod.zig** (1 lines)
- ✅ **test_helpers.zig** (2 lines)
- ✅ **mod.zig** (1 lines)
- ✅ **pkce.zig** (53 lines)
- ✅ **gemini.zig** (43 lines)

## Notes

- Coverage collected using **kcov** after running unit and integration tests.
- The `gen_models.zig` binary (CLI tool) was excluded from coverage tracking.
- Integration tests cover end-to-end agent behavior and are merged with unit test coverage data.
