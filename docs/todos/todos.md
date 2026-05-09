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


# SubAgent final text empty (Done | Verify over time)

The transcript contains a lot of context but the final text (aka suganet summary) was empty.
```
{"ok":true,"final_text":"","turn_count":4,"tool_call_count":3,"duration_ms":160330,"session_id":"call_omeabw3t","transcript_path":"/home/agent/.franky/sessions/01KQP7P21RJAS2XK8VKBV745GT/subagents/call_omeabw3t/transcript.json"}
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

# Lets increase max_turn

Increase max_turn = 100 by default and also check i think its defined in to many places.
Also check if we can set it in the settings.json and as cli arg.


# Compile Guard has to run after finish_task (Done)

# Add retry the base_delay_ms to the settings.json profiles.models (Done)

Lets set it for mistral models to 40 seconds.


# Model Provider Feature Batch

THe mistral api have trhe batch feature https://docs.mistral.ai/studio-api/batch-processing
CHeck if this is a unified standard across other providers like opanai, ollama, openrouter.

Do a web research.


# add lsp (language server protocol) support for zig

Lets have a brainstorimg session about how add lsp (language server protocol) support atleast for ziglang and what it brings in terms of efficientcy compared to a llm that just uses plain text edit.

Do a detail web research spawn sub agent to speed up the research.

# Check the Intent Integrity Chain Approach (Deep Research)

Use web search if need. https://github.com/intent-integrity-chain/kit
The headline is never trust a monkey how to verify code without reading it.

How we can add the core idea as guardrail implementation to franky agent.

Then save an open design doc in docs/design/open/

# List subagents/preset based on the available API KEYS.

Also if a subagent was started with profile gemini but gemini api key is not there return hint with please use one of the following or change the subagent model without telling the parent agent.