# On the unrecoverable disconnect (Under human investigation)                                                            
Your symptom — disconnects without reload, can't recover even by reloading the page until you restart the process — is consistent with a subscriber slot leak.      
Hypothesis:

In runSseStream at proxy.zig:1772-1782, the connection-handler thread blocks on readVec to detect client disconnect:                                                
while (!sub.closed.load(.acquire)) {
    var vecs: [1][]u8 = .{&sink};
    const n = r.interface.readVec(&vecs) catch break;
    if (n == 0) break;          
}
                      
Meanwhile fanOutLocked at proxy.zig:378 writes events; on write failure it sets sub.closed = true but does not unblock the reader. If the client disconnect doesn't trigger an immediate FIN/RST that wakes readVec (browser background tab, OS-level half-close, network blip), the reader thread stays blocked, the slot stays occupied, and the defer removeSub never runs.                    
Each browser reconnect adds a fresh subscriber. After ~32 cycles (max_subs = 32), subscriber.refused fires for every new connection and you can't recover until the process restarts and frees the leaked slots.
If this is the cause, the fix is to make fanOutLocked shut down the read side of the socket when it flags sub.closed = true. That forces readVec to return immediately and removeSub to fire.      
Two questions to confirm:                                       
1. When you next see the stuck state, can you curl http://localhost:8787/events? If you get a "too many subscribers" error frame back, that confirms the leak hypothesis.    
2. Or just check the logs around the disconnect: a leak would show repeated subscriber.added without matching subscriber.removed, ending in subscriber.refused.


# Some models are to emitting end_turns

stop_reason is the model's own decision about why it stopped generating. The values are roughly:                                                                    
- tool_use — "I want a tool result, resume me"                                                                                                                      
- end_turn — "I'm done, yielding to the user"                                                                                                                       
- max_tokens / stop_sequence — externally bounded                                                                                                                   
                                                                                                                                                                    
end_turn is not a tool the harness invokes. It's the model's choice to not emit another action and to compose a final message instead. So "100 turns, zero          
end_turns" means the model never once concluded "I should stop and report back" — every single sample, the next-most-likely thing to do was another tool call.      
                                                                                                                                                                    
Why the model never yields                                                                                                                                          
                                              
A few reinforcing pressures:                                                                                                                                        
                                              
1. No completion predicate. "Debug the Go vet test" has no observable "done" state until the test passes. The model can always justify one more reproducer.         
2. Sunk cost / persistence prior. Post-training rewards finishing tasks; abandoning before success is penalized. After 50 failed attempts, "give up and report"
looks worse than "try once more" even when it shouldn't.                                                                                                            
3. No repetition awareness. The model doesn't notice it's hit the same shape of Zig API error 5 times. Each error is processed as a fresh local problem.
4. end_turn competes with tool calls in the same sampling step. If "next try a different API" has higher logit than "summarize and stop," it just keeps going.      
There's no separate "should I stop?" decision.                                                                                                                      
5. No interlocutor. In a proxy session there's no user message between turns, so the model never gets the natural "does the human want me to keep going?" signal.   
                                                                                                                                                                    
Smaller models like deepseek-v4-flash are more prone to this — weaker meta-cognition, less robust "I'm stuck" recognition.

Active interventions in the harness:         
- Checkpoint injection. Every N turns without end_turn, inject a system message: "You've made N tool calls. Before the next action, list: hypotheses ruled out,     
current hypothesis, evidence for it, and one alternative. If the same hypothesis has failed twice, switch or stop." This forces a meta-step into the context that   
the model wouldn't generate on its own.                                                                                                                             
- Hard budget with forced summarization. At a ceiling (turns or tokens), append "Tool budget exhausted. Produce a final report: what you tried, what's still        
unknown, what you'd do next." and disable tools for the next sample. This guarantees an end_turn.                                                           
- Repetition-triggered escalation. When REPEAT_ERROR fires, inject "You've hit this same error 3 times. Don't retry the same approach. Either change strategy or    
stop and report."

# Grep parsing error (Done | Verify over Time)
```
tool: grep error
{"filesGlob":"**/tools/subagent.zig","path":"/Users/frankittermann/github/franky/src/coding","pattern":"pub const Preset\\b"}
[grep_bad_regex] invalid escape sequence at position 17 in pattern pub const Preset\b\ (use regex=false for literal substring search)
tool: grep error
{"filesGlob":"**/tools/subagent.zig","path":"/Users/frankittermann/github/franky/src/coding","pattern":"pub fn register\\b"}
[grep_bad_regex] invalid escape sequence at position 16 in pattern pub fn register\b\ (use regex=false for literal substring search)
```

appeared again
```
tool: grep error
{"filesGlob":"**/*.zig","maxMatches":10,"path":"/Users/frank.ittermann@goflink.com/private/github/franky/src","pattern":"fn grep|const grep|\\.name.*=.*\\\"grep\\\""}
[grep_bad_regex] invalid escape sequence at position 31 in pattern fn grep|const grep|\.name.*=.*\"grep\"\ (use regex=false for literal substring search)
```


# SubAgent final text empty (Done | Verify over time)

The transcript contains a lot of context but the final text (aka suganet summary) was empty.
```
{"ok":true,"final_text":"","turn_count":4,"tool_call_count":3,"duration_ms":160330,"session_id":"call_omeabw3t","transcript_path":"/home/agent/.franky/sessions/01KQP7P21RJAS2XK8VKBV745GT/subagents/call_omeabw3t/transcript.json"}
```

# Deepseek DSML calls (Reoccuring issue)

Analzye this tool call it was incorrectly parsed.
```
<｜DSML｜tool_calls>
<｜DSML｜invoke name="grep">
<｜DSML｜parameter name="filesGlob" string="true">**/*.zig</｜DSML｜parameter>
<｜DSML｜parameter name="maxMatches" string="false">20</｜DSML｜parameter>
<｜DSML｜parameter name="path" string="true">/Users/frankittermann/github/franky/src/coding/modes</｜DSML｜parameter>
<｜DSML｜parameter name="pattern" string="true">server.*deinit|server\.deinit|server.*close"</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜tool_calls>
tool: grep error
[file_not_found] /Users/frankittermann/github/franky/src/coding/modes</｜DSML｜parameter>
```

Still occured in a different wasy now.
```
--- begin tool_args ---
{"filesGlob":"**/*.zig</｜DSML｜parameter>","maxMatches":"20</｜DSML｜parameter>","path":"/Users/frankittermann/github/franky/src/coding/modes</｜DSML｜parameter>","pattern":"server.*deinit|server\\.deinit|server.*close\"</｜DSML｜parameter>\n</｜DSML｜invoke>\n</｜DSML｜tool_calls>\ntool: grep error\n[file_not_found] /Users/frankittermann/github/franky/src/coding/modes</parameter>\n```\n\nThis is a tool call made by the AI agent (the one who has this conversation). The `grep` tool was called with:\n- `filesGlob`: `**/*.zig`\n- `maxMatches`: `20`\n- `path`: `/Users/frankittermann/github/franky/src/coding/modes`\n- `pattern`: `server.*deinit|server\\.deinit|server.*close\"`\n\nThe error from the system is:\n```\ntool: grep error\n[file_not_found] /Users/frankittermann/github/franky/src/coding/modes</parameter>\n```\n\nWait, but this is a tool RESPONSE from the system, not a tool CALL from a DeepSeek model. The `</parameter>` in the error message is from the system's own rendering.\n\nHmm, but the user says \"Analyze this tool call it was incorrectly parsed.\" So the user is saying that the DSML parser incorrectly parsed this tool call. Let me re-think.\n\nActually, I think the user is showing me a tool call that was made by an AI (the parent agent), and the response came back with `</parameter>` leaked into the error message. The user wants to understand how this happened and fix it.\n\nBut wait - the tool call shown uses standard XML-like tags (`","path":"`. This is NOT DSML format (which would use `<\\xef\\xbd\\x9cDSML\\xef\\xbd\\x9cparameter ...>`). So maybe the DSML parser wasn't even involved.\n\nLet me look at this differently. The tool call shown is:\n```xml","filesGlob":"**/*.zig</｜DSML｜parameter>","maxMatches":"20</｜DSML｜parameter>","path":"/Users/frankittermann/github/franky/src/coding/modes</｜DSML｜parameter>","pattern":"server.*deinit|server\\.deinit|server.*close\"</｜DSML｜parameter>\n</｜DSML｜invoke>\n</｜DSML｜tool_calls>\n```\n\nNotice that the `pattern` parameter value is `server.*deinit|server\\.deinit|server.*close\"` — it ends with a double quote `\"` that's part of the value! The `pattern` attribute's value should be closed before the `\"` that closes the attribute. The model accidentally included the closing `\"` as part of the value.\n\nAnd for `path`, the value is `/Users/frankittermann/github/franky/src/coding/modes` — there's no closing quote shown before `</parameter>`. Wait, actually looking at the raw text:\n\n```","path":"/Users/frankittermann/github/franky/src/coding/modes</｜DSML｜parameter>\n```\n\nThis looks well-formed. The `path` value is `/Users/frankittermann/github/franky/src/coding/modes` and the `</parameter>` closes it. So where does the `</parameter>` come from in the error?\n\nOH WAIT. I think I misread. Let me re-read the error output:\n\n```\ntool: grep error\n[file_not_found] /Users/frankittermann/github/franky/src/coding/modes</parameter>\n```\n\nThe `</parameter>` is in the error message TEXT. But the error code is `file_not_found` and the message should be just the path. So the rendered error is:\n\n```\n[file_not_found] /Users/frankittermann/github/franky/src/coding/modes</parameter>\n```\n\nThis is the text returned by `common.toolError(allocator, \"file_not_found\", cwd)` where `cwd` (which is the path argument) somehow includes `</parameter>` at the end.\n\nHow? Let me trace: if the DSML parser extracted the `path` parameter value and it included `</parameter>` because the value-end search didn't find a next opening tag...\n\nBut as I said, the tags in this tool call use standard ASCII angle brackets, not DSML fullwidth vbars. So maybe there's a different path.\n\nActually, I think the key insight is: this tool call could have been made by a different AI (like DeepSeek) that uses REGULAR XML tags (not DSML fullwidth vbars). The `","filesGlob":"**/*.zig</｜DSML｜parameter>\n...\n```\n\n`stripToolCallWrappers` looks for `<tool_call>` wrapper, not `","path":"/Users/frankittermann/github/franky/src/coding/modes</｜DSML｜parameter>\n
… [truncated]
--- end tool_args ---
```

# Edit tool cause memorry kill (Done)

```dmesg
[43193.653284] 9707 pages reserved
[43193.653313] Tasks state (memory values in pages):
[43193.653349] [ pid  ]   uid  tgid total_vm      rss rss_anon rss_file rss_shmem pgtables_bytes swapents oom_score_adj name
[43193.653430] [   119]  1000   119      167        0        0        0         0   114688        0             0 tini
[43193.653509] [   124]  1000   124      173       32        0       32         0   114688        0             0 sh
[43193.653591] [   125]  1000   125      913       72       64        8         0   114688        0             0 sleep
[43193.653668] [   190]     0   190      742       38       32        6         0   114688        0             0 socat
[43193.653751] [   197]  1000   197      303       73       32       41         0   131072        0             0 bash
[43193.653833] [ 11507]  1000 11507   997347   766412   766412        0         0  6406144        0             0 franky
[43193.653907] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=e098be74819f9728e44a7141f3a84a6ebd2520719cb65bb9e15ad92c0ef081a3,mems_allowed=0,global_oom,task_memcg=/docker/e098be74819f9728e44a7141f3a84a6ebd2520719cb65bb9e15ad92c0ef081a3,task=franky,pid=11507,uid=1000
[43193.655041] Out of memory: Killed process 11507 (franky) total-vm:15957552kB, anon-rss:12262592kB, file-rss:0kB, shmem-rss:0kB, UID:1000 pgtables:6256kB oom_score_adj:0
```

```tool call
{"edits":[{"new":"Update at 06.05.2026","old":"","replaceAll":true}],"path":"README.md"}
```

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

# Tool Status bar (Done)

During one session show the user which tool was used how often also count the fired guardrails (int total not by type). like
```
guardrails: 2 bash: 4 read: 5 edit: 6 ...
```

Implemented: GuardrailState.guardrail_fire_count, Session.tool_usage map (StringHashMap(u32)), GET /usage endpoint in proxy.zig, async refreshStatusLineUsage() fetches /usage + /transcript on turn_end.

# Auto Commit Message (Done)

Updated finish_task tool:
- Tool description now teaches the Conventional Commits format (<type>(<scope>): <subject>)
- Parameter JSON description includes the format + example + allowed types
- Server-side validation enforces colon-separated type: subject with valid type characters
- Allowed type characters: a-z, A-Z, 0-9, _, -, (, ), !
- Enforces a space after the colon

# Role tool tip (Done)

Add a role tool tip to the Web-UI the tool tip shows the available tools for this role.

Done: replaced the native browser `title` attribute on `.role-pill` with a custom-positioned
styled tooltip (`#role-tooltip`) that appears on hover. It shows:
- The role description as a heading
- A sandbox badge when running inside a sandbox
- The list of allowed tools, each rendered as a styled monospace name
- Tool names use the `.rt-tool-name` class (accent colour, monospace font)

The tooltip lives as a child of `.role-pill` in the HTML, positioned absolutely below the
pill via CSS. The server-side `/role` endpoint (`renderRoleStatusJson` in `role.zig`) already
provided all the necessary data — the JS side just needed to route it into the new DOM elements.

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