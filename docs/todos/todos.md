
# Max turns (DONE)

No lets work on the following feature as always lets make a plan then more iterativly on it and always verify with compile and run  
the tests. Make the max turns configurable or even extendable by the user. For example, instead of hardcoding max_turns to 50,       
allow it to be set via a configuration file or command-line argument.                                                                
Also during a session the tool could ask the user if they want to extend the max turns if they reach the limit, instead of just    
ending the session. This would make it more flexible and user-friendly. Keep in mind that also applications that use this franky
agent need a way to know that the max turns have been reached, so they can handle it accordingly (e.g., by prompting the user or
stop) 

# Trace Logging Components

At the moment when the log-level is set to trace all log messages from all components are logged. How can we set indiviual trace logging for each component like:
* enable trace logging only for http
* enable trace logging only for tools
* enable trace logging only for the agent loop
* etc.


# How to interrupt the LLM loop (DONE)

**Status: Implemented.** See §4.3, §4.6, §4.7, §5.5, §7, §G.3 in `docs/spec/v1.md`.

Three layers:
- `src/agent/loop.zig`: `Config.stop_requested_fn` checked between turns — when `true`, emits `agent_interrupted` and exits without error.
- `src/agent/agent.zig`: `Agent.interrupt()` sets a `stop_requested` flag (unlike `abort()` which fires `cancel` mid-turn).
- Proxy mode: `POST /interrupt` sets `session.stop_requested` for graceful stop.
- Web UI: dedicated ⏹ Abort button in header POSTs `/interrupt`; `agent_interrupted` SSE handler transitions back to idle. Button appears after first message via CSS (`#conversation:has-child`) — no JS state needed.
- Interactive mode: renders `⏹ turn stopped gracefully` in yellow.

Currently, the LLM loop runs until it reaches the max turns or a certain condition is met. It would be useful to have a way to interrupt the loop gracefully, for example, by sending a specific stop signal. Then the user can intterupt the session and send new instructions without having to wait for the max turns to be reached.


# Tool Usage and LLM Interaction Self Improvement (DONE)

The agent could analyze the tool usage and LLM interactions after each session to identify patterns and areas for improvement. For example, if the agent notices that certain tool usage were failing frequently, it could analyze the reasons (e.g., incorrect parameters, tool errors) and adjust the tool implementation or to give better feedback to the model. Similarly, if the LLM interactions show that the model is struggling with certain types of instructions or questions, the agent could identify those patterns and adjust its codebase or the way it interacts with the model to improve performance.
Also use the already existing diagnostics command to store diagnostics data together with the self improvement data.

# Google Gemine3 Model Support

The conversation with the Gemini3 model caused the following error:
```
empty_response: google-gemini returned stop_reason=STOP but emitted no content (parts_seen=2, candidates_tokens=16, thoughts_tokens=87). Likely model regression — re-run with adjusted thinking budget or a format-reminder nudge.
```

Here is the full trace of the conversation with the Gemini3 model.
```
=== franky http trace ===
ts_ms: 1777591350581
seq: 1
provider: google-gemini
url: https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:streamGenerateContent?alt=sse&key=asasdasd
method: POST
status: 200
request_body_bytes: 7515
response_body_bytes: 1516

--- request body ---
{"systemInstruction":{"parts":[{"text":"You are franky, an AI coding agent.\n\nYou can read and edit files in the user's workspace, run shell\ncommands, and search with ls/find/grep. Prefer focused edits over\nlarge rewrites. When asked to change code, first read the relevant\nfiles, then propose and apply minimal diffs.\n\nIf a task needs information you don't have, use your tools to\ngather it. Do not guess file contents.\n\nWhen a sub-agent reports `ok: true`, trust its result and move on.\nDo not re-read files to verify the sub-agent's work — the work is\ndone. Only re-investigate when the sub-agent reports `ok: false` or\nits `final_text` describes a problem. Re-verifying successful\nsub-agent runs wastes tokens and tends to revert correct edits.\n\nYou also have a `subagent` tool that spawns an isolated agent with its own model. Use it for parallel sub-tasks or when a different profile fits the work better — skip it for single tool calls. Profiles: cerebras, cloudflare-gemma, cloudflare-llama, gemini, groq, lm-studio, ollama, openrouter."}]},"tools":[{"functionDeclarations":[{"name":"read","description":"Read a file from the workspace. Files >256 KB without `limit` are refused — paginate with `offset`+`limit` (default limit emits up to 2000 lines and a continuation hint).","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1}}}},{"name":"write","description":"Create a new file with the given content.","parameters":{"type":"object","required":["path","content"],"properties":{"path":{"type":"string"},"content":{"type":"string"},"overwrite":{"type":"boolean","default":false}}}},{"name":"edit","description":"Apply one or more find/replace edits to a file atomically.","parameters":{"type":"object","required":["path","edits"],"properties":{"path":{"type":"string"},"edits":{"type":"array","minItems":1,"items":{"type":"object","required":["old","new"],"properties":{"old":{"type":"string"},"new":{"type":"string"},"replaceAll":{"type":"boolean","default":false}}}}}}},{"name":"bash","description":"Run a shell command (via /bin/sh -c). Cwd persists via SessionBashState. Output truncates to last 2000 lines / 50 KB with on-disk spill — pipe through `head`/`tail`/`grep` for long output.","parameters":{"type":"object","required":["command"],"properties":{"command":{"type":"string","description":"The shell command to run (parsed by /bin/sh -c)."},"cwd":{"type":"string","description":"Working directory for the command. Defaults to the session cwd (if any) else the agent's cwd."},"timeoutMs":{"type":"integer","minimum":1,"description":"Hard timeout in milliseconds (default 120000)."},"background":{"type":"boolean","description":"Run detached; returns immediately with {pid, outputFile}. Default false."},"description":{"type":"string","description":"Short human-readable description of what the command does."}}}},{"name":"ls","description":"List directory entries (tree-style when recursive). Recursive=true with no focused `path` walks the whole tree — pass a specific subdir first.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Directory to list. Defaults to the agent's cwd."},"recursive":{"type":"boolean","description":"Recurse into subdirectories. Default false."},"maxDepth":{"type":"integer","minimum":1,"description":"Maximum depth when recursive is true. Default 8."},"respectGitignore":{"type":"boolean","description":"Respect .gitignore rules under the scanned path. Default true."}}}},{"name":"find","description":"Find files by glob pattern (*, **, ?, [abc]). Default limit is 1000 results. Pass a focused `cwd` first when searching a large tree — broad globs from repo root truncate.","parameters":{"type":"object","required":["pattern"],"properties":{"pattern":{"type":"string","description":"Glob pattern. Supports *, **, ?, [abc]."},"cwd":{"type":"string","description":"Root to search (default '.')."},"limit":{"type":"integer","minimum":1,"description":"Maximum number of results (default 1000)."},"respectGitignore":{"type":"boolean","description":"Respect .gitignore rules under cwd. Default true."}}}},{"name":"grep","description":"Search files for a regex (default) or literal substring. Skips binaries. Output truncates at 500 matches OR 50 KB OR 500 chars per line — whichever first. Narrow with `path` and `filesGlob` (e.g. `**/*.zig`) before searching from repo root, otherwise broad searches truncate.","parameters":{"type":"object","required":["pattern"],"properties":{"pattern":{"type":"string","description":"ECMAScript-subset regex by default: . * + ? | [abc] [^abc] [a-z] ^ $ \\w \\d \\s (and \\W \\D \\S). Non-capturing groups with (...). Set regex=false for literal substring match."},"path":{"type":"string","description":"Root path to search. Default '.'."},"filesGlob":{"type":"string","description":"Only search files matching this glob (e.g. '**/*.zig')."},"regex":{"type":"boolean","description":"Treat pattern as regex. Default true. Set false for `grep -F` literal search."},"caseSensitive":{"type":"boolean","description":"Default true."},"contextBefore":{"type":"integer","minimum":0},"contextAfter":{"type":"integer","minimum":0},"maxMatches":{"type":"integer","minimum":1,"description":"Max matches across all files. Default 500."},"respectGitignore":{"type":"boolean","description":"Respect .gitignore rules under path. Default true."}}}},{"name":"subagent","description":"Spawn an isolated sub-agent with its own model + provider, run it to completion, return the final assistant message. Sub-agents have the parent's tool set minus `subagent` itself; pick a profile from settings.json or built-ins to choose model + provider.","parameters":{"type":"object","required":["profile","prompt"],"properties":{"profile":{"type":"string","description":"Name of a profile defined in settings.json or a built-in (gemini, groq, ollama, …). Resolves provider + model + auth."},"prompt":{"type":"string","description":"The instruction the sub-agent will run. Self-contained — sub-agent has no access to parent's transcript."},"timeout_ms":{"type":"integer","minimum":1000,"maximum":7200000,"description":"Wall-clock timeout (default 1800000 = 30 min, max 7200000 = 2 h)."},"max_turns":{"type":"integer","minimum":1,"description":"Hard cap on agent-loop turns (default 20)."},"role":{"type":"string","enum":["read","plan","code","full"],"description":"Capability role (defaults to parent's; demotion only — never higher than parent)."},"system_prompt":{"type":"string","description":"Optional override for the sub-agent's system prompt."}}}}]}],"contents":[{"role":"user","parts":[{"text":"Lets plan the following feature together Currently, the LLM loop runs until it reaches the max turns or a certain condition is met. It would be useful to have a way to interrupt the loop gracefully, for example, by sending a specific stop signal. Then the user can intterupt the session and send new instructions without having to wait for the max turns to be reached."}]},{"role":"user","parts":[{"text":"Lets plan the following feature together Currently, the LLM loop runs until it reaches the max turns or a certain condition is met. It would be useful to have a way to interrupt the loop gracefully, for example, by sending a specific stop signal. Then the user can intterupt the session and send new instructions without having to wait for the max turns to be reached."}]}]}

--- response body ---
data: {"candidates": [{"content": {"parts": [{"functionCall": {"name": "bash","args": {"command": "ls -R"},"id": "flveizpn"},"thoughtSignature": "EvwDCvkDAQw51sd/F0fGZWxWmQvo9up+111jCBDvq2HxXQ9j7A0wTRfgz5LwQ7w/3wP7j1Qi++vw2ntq7jWPC843DfoU7plOfDqZ8Y4s8XUe1siNsa47Bx2VTv+IJSvIWGP0Svze+7keEuNIYh3nBj03uv7saR0U+Jj4k/7BRuusSBPfASoROyiWL8HInjItx7CzsGPgq8qmf+C2pMqFP5de+ICte+cLEul2Cau1+ijpu1CPEMWZVhDmSRGP25D5Cj6lEn78PHDdpICSQ9HOk7v3365KcD1SkUsLMQIp6O8/RxyNIBpKGRkZnfVDZEF6BUJQXiHzQdDiyTTZCRFDD6lRwkag1I3AMpLCZv3/kQgP8x6LdrFfFNx8QaXG6CH21tAHiTLqmtS5i7HSpHnsr+DQrAmZjOTErBiytdpjbUSI5vpa7kVdT1QOs3oupAorwW9hPvCrSWlUaH10zEM6JhWcL7qeNHopHLozO1bUAp6wi8NeL9IG1utjlFwM8MUc6B/sX0UV40seCdUINQiRQ0ykqr24RXfqg5CGhDpuXTJ+v6Z6mz3GQTia128gDA/MM1EmSl3nsw0VVQK5fNnIh31ly3gJcucY1C5mUs8XkxKVZBrqPLjGsYRLguAMzkUimozoy2UFe2mKtYbZOTExpCI+320FtfbgWhkRvLYNqw=="}],"role": "model"},"index": 0}],"usageMetadata": {"promptTokenCount": 1964,"candidatesTokenCount": 16,"totalTokenCount": 2067,"promptTokensDetails": [{"modality": "TEXT","tokenCount": 1964}],"thoughtsTokenCount": 87},"modelVersion": "gemini-3.1-pro-preview","responseId": "3XX0aaTKIOSpvdIPoYGLsAM"}

data: {"candidates": [{"content": {"parts": [{"text": ""}],"role": "model"},"finishReason": "STOP","index": 0}],"usageMetadata": {"promptTokenCount": 1964,"candidatesTokenCount": 16,"totalTokenCount": 2067,"promptTokensDetails": [{"modality": "TEXT","tokenCount": 1964}],"thoughtsTokenCount": 87},"modelVersion": "gemini-3.1-pro-preview","responseId": "3XX0aaTKIOSpvdIPoYGLsAM"}
```