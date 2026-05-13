# Find tools return wrong not found files (Done | Need Verification)

Here is the real folder structure:
```
AGENTS.md
README.md
build.zig.zon
settings.json
src
zig-out
Dockerfile.sandbox
build.zig
docs
skills
test
```

```
tool: find error
{"pattern":"**/test.zig","cwd":"src/coding/tools/bash"}
[file_not_found] src/coding/tools/bash
tool: find error
{"pattern":"**/*.zig","cwd":"src/coding/regex"}
[file_not_found] src/coding/regex
tool: find error
{"pattern":"**/test.zig","cwd":"src/ai/http"}
[file_not_found] src/ai/http
```

```
tool: bash done
{"command":"grep -n \"pub fn exec\\|pub fn matches\\|step_budget\\|stepBudget\\|StepBudget\\|budget\" src/coding/regex.zig | head -30","description":"Find regex exec and budget functions"}
[exit] code=0
[stderr]
grep: src/coding/regex.zig: No such file or directory
tool: bash error
{"command":"wc -l src/coding/regex.zig","description":"Line count of regex.zig"}
[exit] code=1
[stderr]
wc: src/coding/regex.zig: No such file or directory
```

But read tool found the same path
```
tool: read done
{"path":"src/coding/tools/bash.zig","offset":1030,"limit":80}
tool: read done
{"path":"src/coding/regex.zig","offset":880,"limit":50}
tool: read done
{"path":"src/ai/http.zig","offset":1275,"limit":100}
```

# Hide .git folders in find tool results

```
ool: bash done
{"command":"find . -maxdepth 2 -type f | head -80","description":"List files in workspace to understand structure"}
[exit] code=0
[stdout]
./transcript.txt
./.containifyci/containifyci.go
./.containifyci/go.mod
./.containifyci/go.sum
./SANDBOX.md
./agent-guardrails.pdf
./.contextignore
./.goreleaser.yaml
./settings.json
./test/gitignore_test.zig
./test/agent_loop_test.zig
./test/agent_class_test.zig
./test/parallel_tools_test.zig
./test/replay_test.zig
./test/kitchen_sink_test.zig
./build.zig.zon
./.teller.yml
./build.zig
./.franky-workflow.yaml
./docs/README.md
./review-subagent-1.md
./README.md
./Dockerfile.sandbox
./review-subagent-2.md
./.gitignore
./skills/zig.md
./transcript2.txt
./AGENTS.md
./.git/ORIG_HEAD
./.git/config
./.git/HEAD
./.git/description
./.git/index
./.git/packed-refs
./.git/COMMIT_EDITMSG
```

# Prevent possible destructive bash commands

Prevent destructive bash commands like
```
git stash pop
```
May also define other commands as well

# Add retry the base_delay_ms to the settings.json profiles.models (Done)

Lets set it for mistral models to 40 seconds.


# Model Provider Feature Batch

THe mistral api have trhe batch feature https://docs.mistral.ai/studio-api/batch-processing
CHeck if this is a unified standard across other providers like opanai, ollama, openrouter.

Do a web research.


# add lsp (language server protocol) support for zig

Lets have a brainstorimg session about how add lsp (language server protocol) support atleast for ziglang and what it brings in terms of efficientcy compared to a llm that just uses plain text edit.

Do a detail web research spawn sub agent to speed up the research.

# List subagents/preset based on the available API KEYS.

Also if a subagent was started with profile gemini but gemini api key is not there return hint with please use one of the following or change the subagent model without telling the parent agent.

The list_preset tool should return the presets and also all the available profiles so
that the model can pick one.


# Deepseek multiple tool calls
```
<｜DSML｜tool_calls>
<｜DSML｜invoke name="bash">
<｜DSML｜parameter name="command" string="true">cd /Users/frankittermann/github/franky && git show HEAD:src/ai/registry.zig | head -160</｜DSML｜parameter>
<｜DSML｜parameter name="cwd" string="true">/Users/frankittermann/github/franky</｜DSML｜parameter>
</｜DSML｜invoke>
<｜DSML｜invoke name="bash">
<｜DSML｜parameter name="command" string="true">cd /Users/frankittermann/github/franky && git show HEAD:src/ai/providers/faux.zig | head -100</｜DSML｜parameter>
<｜DSML｜parameter name="cwd" string="true">/Users/frankittermann/github/franky</｜DSML｜parameter>
</｜DSML｜invoke>
<｜DSML｜invoke name="bash">
<｜DSML｜parameter name="command" string="true">cd /Users/frankittermann/github/franky && git show HEAD:src/ai/channel.zig | head -60</｜DSML｜parameter>
<｜DSML｜parameter name="cwd" string="true">/Users/frankittermann/github/franky</｜DSML｜parameter>
</｜DSML｜invoke>
<｜DSML｜invoke name="bash">
<｜DSML｜parameter name="command" string="true">cd /Users/frankittermann/github/franky && git show HEAD:src/agent/types.zig | head -80</｜DSML｜parameter>
<｜DSML｜parameter name="cwd" string="true">/Users/frankittermann/github/franky</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜tool_calls>
```

# Edit Diff View (Web-UI)

Add the following header in the richt edit view.

This example is from the edit fallback view
```
applied 1 edit(s) to /Users/frankittermann/github/franky/src/coding/modes/print.zig
```

# Sub Agent Header View improvement

Lets add the used preset to the subagent overlay view in the header. 
```
<div class="sa-overlay-head">
    <span class="sa-badge sa-overlay-badge done">done</span>
    <span class="sa-overlay-title">go-dev</span>
    <button class="sa-overlay-close" id="sa-overlay-close" aria-label="Close">×</button>
</div>
```

# Finish Task

It could check if the worked on document was updated recently before the finish task was called and also take hash of it before the work and compare it after finish task to check changes as well. Or just send a final hint to the model please update the document you were working on if not already happended.

# Nudging Modeles

Some models (gpt) need constant nudging like `go on` or `Continue` how can the agent loop decide when to send this nugdes to keep the model working. 


# For failing http request that fail after all retries add error message (Done)

When a http provider request fails add the error message to log not just the error code like transient. When the retries are exhausted also throw the error back to the user with the status and the error message if possible. This will help a lot in debugging and also in understanding what went wrong instead of just knowing that it was a transient error.

Here is an example from the log
```
--- response body ---
{"error":"model 'deepseek-v4-flash' is temporarily overloaded, please retry shortly or try a different model (ref: d65cad69-0c45-4e58-83bf-7c388293faa4)"}
```

# Lets add the file icon to all path args in tool calls (failed)

```
<span class="file-icon">📄</span>
```

Here is a failed example. The path value was deleted not the path field name the `<th>path</th>` is still there but the value is gone. We need to make sure to keep the value and just add the icon instead of the th print text.
```
<div class="tool-card"><div class="tool-head">tool: <span class="tool-name">ls</span> <span class="tool-status">done</span><button type="button" class="tool-args-raw-toggle" aria-label="Toggle raw JSON" aria-pressed="false">{ }</button><button type="button" class="tool-result-toggle" aria-expanded="false">▶</button></div><div class="tool-args"><div class="tool-args-wrapper"><table class="tool-args-table"><tbody><tr><th>path</th><td><span class="file-icon">📄</span></td></tr><tr><th>maxDepth</th><td><code>2</code></td></tr></tbody></table><div class="tool-args-raw" hidden=""><pre>{"path":"/Users/frank.ittermann@goflink.com/private/github/franky","maxDepth":2}</pre></div></div></div><div class="tool-result-log" hidden="">/Users/frank.ittermann@goflink.com/private/github/franky
.soteria/
</div></div>
```

# Web-UI Disconnect

For long session without activity the web-ui disconnects and the user needs to refresh the page to reconnect.
We need to add a reconnect logic to the web-ui to handle this case and also show a message to the user that the connection was lost and we are trying to reconnect.

# Write Tool Content parameter should be in the collapsable log

```
<div class="tool-card is-error"><div class="tool-head">tool: <span class="tool-name">write</span> <span class="tool-status">error</span><button type="button" class="tool-args-raw-toggle" aria-label="Toggle raw JSON" aria-pressed="false">{ }</button><button type="button" class="tool-result-toggle" aria-expanded="false">▶</button></div><div class="tool-args"><div class="tool-args-wrapper"><table class="tool-args-table"><tbody><tr><th>path</th><td><span class="file-icon">📄</span>docs/design/v3.1-franky-orchestrator.md</td></tr><tr><th>content</th><td># franky orch....
</td></tr></tbody></table><div class="tool-args-raw" hidden=""><pre>{"path":"docs/design/v3.1-franky-orchestrator.md","content":"# franky orchestrator ... registrations?\n"}</pre></div></div></div><div class="tool-result-log" hidden="">[write_exists] file already exists; set overwrite=true to replace</div></div>
```

# Sub Agent open button spacing

The sa-card-open button icon is to close to the tool-result-toggle button and it can easily be miss clicked. Then just create a little space between them.
```
<div class="tool-card tool-card-subagent is-error"><div class="tool-head">tool: <span class="tool-name">subagent</span> <span class="tool-status">error</span><button type="button" class="tool-args-raw-toggle" aria-label="Toggle raw JSON" aria-pressed="false">{ }</button><button type="button" class="tool-result-toggle" aria-expanded="false">▶</button><button type="button" class="sa-card-open" title="Open full sub-agent conversation">↗</button></div><div class="tool-args"><div class="tool-args-wrapper"><table class="tool-args-table"><tbody><tr><th>preset</th><td>code</td></tr></tbody></table><div class="tool-args-raw" hidden="">
```