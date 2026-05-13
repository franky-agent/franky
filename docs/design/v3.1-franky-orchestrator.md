# franky orchestrator (v3.1)

A standalone web application that discovers, monitors and controls multiple franky agents through their REST API. No shared code with franky — all communication is via documented HTTP endpoints.

**Table of Contents**
- [1. Overview](#1-overview)
- [2. Architecture](#2-architecture)
- [3. Agent API — complete schema reference](#3-agent-api--complete-schema-reference)
- [4. Agent Discovery & Registration](#4-agent-discovery--registration)
- [5. Orchestrator API](#5-orchestrator-api)
- [6. Orchestrator state model](#6-orchestrator-state-model)
- [7. Wireframes](#7-wireframes)
- [8. Error model](#8-error-model)
- [9. Technology choices](#9-technology-choices)
- [10. Open questions](#10-open-questions)

---

## 1. Overview

The orchestrator is a separate project (new repo, separate build, no imports from franky). It communicates with running franky agents exclusively through the HTTP API exposed by `franky --mode proxy`.

### Scope

- Visual dashboard of all registered agents
- Send prompts to any agent
- Watch all agents' event streams in one place
- Inspect transcripts and tool usage of any agent
- Slash-command routing to individual agents

### Out of scope (v3.1)

- Spawning agents (the orchestrator only discovers already-running agents)
- Cross-agent collaboration / message passing
- Multi-user auth
- Persistent transcript archive in the orchestrator

---

## 2. Architecture

```
┌─────────────────────────────────┐
│  Browser                        │
│  ── orchestrator dashboard      │
│     ┌── Dashboard (grid)         │
│     ├── Agent detail (chat)      │
│     └── Timeline (activity)      │
└──────────┬──────────────────────┘
           │  HTTP (orchestrator API)
┌──────────▼──────────────────────┐
│  franky-orchestrator            │
│  ── HTTP server (own port)      │
│  ── Registry of known agents    │
│  ── SSE multiplexing            │
└──────┬──────────┬─────────────────┘
       │          │  HTTP (agent API)
┌──────▼──┐  ┌────▼──┐  ┌────▼──┐
│ proxy-1 │  │proxy-2│  │proxy-3│  … franky --mode proxy
│ :8787   │  │:8788  │  │:8789  │
└─────────┘  └───────┘  └───────┘
```

### Agent lifecycle

1. User starts a franky agent: `franky --mode proxy --port 8787`
2. Agent self-registers with the orchestrator via `POST /register`
3. Orchestrator starts consuming the agent's SSE stream (`GET /events`)
4. Agent sends periodic `POST /heartbeat`
5. Agent sends `POST /unregister` on graceful exit, or orchestrator marks stale after missed heartbeats

---

## 3. Agent API — complete schema reference

The orchestrator consumes these endpoints. All franky agents expose them.

### 3.1 Health

```
GET /health
  → 200 {"ok":true}
```

### 3.2 Events (SSE)

```
GET /events
  Accept: text/event-stream
  Last-Event-ID: <number>     // optional — replay from this id

  → 200 text/event-stream
  // Preamble:
  : connected

  // Frames (each event):
  id: 1
  event: turn_start
  data: {"kind":"turn_start"}

  id: 2
  event: message_start
  data: {"kind":"message_start","role":"assistant","customRole":null}

  id: 3
  event: message_update
  data: {"kind":"message_update","deltaKind":"text","blockIndex":0,"delta":"hello"}

  id: 4
  event: message_end
  data: {"kind":"message_end","role":"assistant","contentBlocks":2}

  id: 5
  event: tool_execution_start
  data: {"kind":"tool_execution_start","callId":"123","name":"read","argsJson":"{\"path\":\"/tmp/foo.txt\"}"}

  id: 6
  event: tool_execution_update
  data: {"kind":"tool_execution_update","callId":"123","update":{"progress":50}}

  id: 7
  event: tool_execution_end
  data: {"kind":"tool_execution_end","callId":"123","isError":false,"toolCode":null,"resultText":"file contents...","detailsJson":null}

  id: 8
  event: tool_permission_request
  data: {"kind":"tool_permission_request","callId":"123","toolName":"bash","argsJson":"{\"command\":\"rm -rf /\"}","fingerprint":"fingerprint_bash_rm"}

  id: 9
  event: turn_end
  data: {"kind":"turn_end"}

  id: 10
  event: agent_interrupted
  data: {"kind":"agent_interrupted"}

  id: 11
  event: provider_retry
  data: {"kind":"provider_retry","attempt":2,"maxAttempts":3,"delayMs":1000,"reason":"rate_limited","providerCode":"429","providerMessage":null,"httpStatus":429}

  id: 12
  event: agent_error
  data: {"kind":"agent_error","code":"aborted","message":"Turn was aborted","isFatal":false}
```

**Event JSON schema (common):**

Every `data:` payload is a JSON object with `"kind"` matching the event name. Additional fields:

| Event | Extra fields |
|-------|-------------|
| `turn_start` | none |
| `turn_end` | none |
| `agent_interrupted` | none |
| `message_start` | `role: string` (`"assistant"` \| `"user"` \| `"toolResult"`), `customRole: string?` |
| `message_update` | `deltaKind: string` (`"text"` \| `"thinking"` \| `"toolcall_args"`), `blockIndex: number`, `delta: string` |
| `message_end` | `role: string`, `contentBlocks: number` |
| `tool_execution_start` | `callId: string`, `name: string`, `argsJson: string` |
| `tool_execution_update` | `callId: string`, `update: JSON` (free-form) |
| `tool_execution_end` | `callId: string`, `isError: boolean`, `toolCode: string?`, `resultText: string`, `detailsJson: string?` |
| `tool_permission_request` | `callId: string`, `toolName: string`, `argsJson: string`, `fingerprint: string` |
| `provider_retry` | `attempt: number`, `maxAttempts: number`, `delayMs: number`, `reason: string`, `providerCode: string?`, `providerMessage: string?`, `httpStatus: number?` |
| `agent_error` | `code: string`, `message: string`, `isFatal: boolean` |

**Replay gap:**
When `Last-Event-ID` is too old, the server emits a synthetic event before replaying:
```
event: replay_gap
data: {"missed_from":42,"missed_to":100}
```

### 3.3 Prompt

```
POST /prompt
  Content-Type: text/plain
  Body: <user message text>

  → 200 {"ok":true}
  // The response is immediate. The turn's events stream on /events.
```

### 3.4 Abort

```
POST /abort
  → 200 {"ok":true,"aborted":true}
  // Cancels the in-flight turn immediately.
```

### 3.5 Interrupt (graceful stop)

```
POST /interrupt
  → 200 {"ok":true,"interrupted":true}
  // Lets the current turn finish, then stops.
```

### 3.6 Restart

```
POST /restart
  → 200 {"ok":true,"restarting":true}
  // Agent exits and re-spawns itself. The orchestrator must detect the disconnect
  // and wait for re-registration on the new process.
```

### 3.7 Permission resolve

```
POST /permission/resolve
  Content-Type: application/json
  Body: {"call_id":"<id>","resolution":"allow_once"}

  // resolution enum: "allow_once" | "always_allow" | "deny_once" | "always_deny"

  → 200 {"ok":true}
  → 409 Conflict      // no pending permission request
  → 404 Not Found    // call_id not found
```

### 3.8 Slash command

```
POST /command
  Content-Type: text/plain
  Body: /<command> [args...]

  → 200 {"ok":true,"output":"...","sideEffect":"<effect>?","data":{...}?}
  → 200 {"ok":false,"error":"...","errorCode":"..."}

  // sideEffect enum (null when none):
  //   null | "clear_transcript" | "model_changed" | "thinking_changed" |
  //   "quit" | "turn_restarted" | "fill_input" | "open_design_panel" | "restarting"
```

### 3.9 Transcript

```
GET /transcript
  Accept: application/json

  → 200 {"messages":[...]}
```

**Message schema:**
```json
{
  "role": "user" | "assistant" | "toolResult" | "custom",
  "toolCallId": "string?",
  "isError": true | false,
  "customRole": "string?",
  "usage": {
    "input": 123,
    "output": 45,
    "cacheRead": 0,
    "cacheWrite": 0
  },
  "blocks": [
    {"kind": "text", "text": "..."},
    {"kind": "thinking", "text": "..."},
    {"kind": "tool_call", "id": "...", "name": "...", "args": "..."}
  ]
}
```

### 3.10 Session info

```
GET /session
  → 200 {"id":"<ulid>","messageCount":42,"persisted":true|false}
```

### 3.11 Session list

```
GET /sessions
  → 200 {"sessions":[...],"active":"<id>","persisted":true}

  // Session entry:
  // { "id": "<ulid>", "title": "...", "updatedAtMs": 1234567890,
  //   "createdAtMs": 1234567890, "messageCount": 42 }
```

### 3.12 Session transcript by id

```
GET /sessions/<id>/transcript
  → 200 {"messages":[...]}
  → 404 Not Found
```

### 3.13 New session

```
POST /session/new
  → 200 {"id":"<new-ulid>","activated":true}
```

### 3.14 Activate session

```
POST /session/activate
  Content-Type: application/json
  Body: {"id":"<ulid>"}

  → 200 {"id":"<ulid>","activated":true}
  → 404 Not Found
```

### 3.15 Role info

```
GET /role
  → 200 {
      "role": "code" | "plan" | "review" | ...,
      "sandboxed": true | false,
      "permittedTools": ["read","edit","bash",...],
      "disabledTools": ["rm",...],
      "provider": "anthropic",
      "model": "claude-sonnet-4",
      "extensions": ["git",...]
    }
```

### 3.16 Usage counters

```
GET /usage
  → 200 {"guardrails":2,"tools":{"bash":4,"read":5,"edit":6}}
```

### 3.17 Design documents

```
GET /design-docs
  → 200 {"docs":[{"path":"...","name":"...","category":"...","status":"..."}]}

POST /design-docs/archive
  Content-Type: application/json
  Body: {"src":"docs/design/foo.md"}

  → 200 {"ok":true,"archived":"docs/archive/design/foo.md"}
```

### 3.18 Static assets

```
GET /              → text/html    (embedded web UI)
GET /app.js        → text/javascript
GET /style.css     → text/css
GET /prism.js      → text/javascript
GET /prism-tomorrow.css → text/css
```

---

## 4. Agent Discovery & Registration

**Note:** Sections 4.1–4.4 describe endpoints the **orchestrator exposes** to receive registration from agents. Sections 4.5–4.6 describe how an agent is configured to discover the orchestrator. All other sections describe **agent endpoints** the orchestrator consumes.

### 4.1 Self-registration

The orchestrator exposes a registration endpoint at startup. Agents are configured with the orchestrator URL at launch.

**Orchestrator endpoint:**

```
POST http://orchestrator:9000/register
  Content-Type: application/json
  Body:
  {
    "id": "<agent session id / ulid>",
    "name": "backend-api",              // user-assigned or derived
    "apiUrl": "http://localhost:8787",  // agent's own proxy URL
    "workspace": "/Users/frank/backend",
    "model": "claude-sonnet-4",
    "role": "code",
    "pid": 12345
  }

  → 200 {"ok":true,"registeredAt":"2025-01-15T10:30:00Z"}
```

### 4.2 Heartbeat

```
POST http://orchestrator:9000/heartbeat
  Content-Type: application/json
  Body: {"id":"<agent session id>"}

  → 200 {"ok":true}
```

- Expected every 30 seconds.
- Orchestrator marks an agent `offline` after 90 seconds without heartbeat.
- Offline agents auto-removed from the registry after 5 minutes of silence.

### 4.3 Unregistration

```
POST http://orchestrator:9000/unregister
  Content-Type: application/json
  Body: {"id":"<agent session id>"}

  → 200 {"ok":true}
```

### 4.4 Agent configuration

Agents are launched with the orchestrator URL in their environment or arguments:

```bash
# Option A: CLI flag
franky --mode proxy --port 8787 --register http://localhost:9000

# Option B: environment variable
FRANKY_ORCHESTRATOR_URL=http://localhost:9000 franky --mode proxy --port 8787
```

When either is set, the agent calls `POST /register` immediately after binding its listen socket, then starts the heartbeat loop.

If the orchestrator is unreachable at startup, the agent retries with exponential backoff (1s, 2s, 4s, …, max 30s) and continues running as a standalone proxy (all agent features work; just no dashboard visibility).

---

## 5. Orchestrator API

The orchestrator exposes its own HTTP API to the browser. **The orchestrator is just for consuming agent events it's not managening the agent lifecycle (except for marking stale/offline). In case the user want to interact with the agent itself the orchestrator provides a link to the agent proxy UI that is open in a new tab. we just keep it simple update the Orchestratior API section accordingly**

### 5.1 Dashboard

```
GET /
  → text/html (embedded dashboard UI)

GET /app.js, /style.css, …
  → static assets
```

### 5.2 Health

```
GET /health
  → 200 {"ok":true}
```

### 5.3 List agents

```
GET /agents
  → 200 {
      "agents": [
        {
          "id": "<ulid>",
          "name": "backend-api",
          "apiUrl": "http://localhost:8787",
          "workspace": "/Users/frank/backend",
          "model": "claude-sonnet-4",
          "role": "code",
          "status": "idle" | "streaming" | "error" | "offline",
          "lastHeartbeatAt": "2025-01-15T10:30:00Z",
          "registeredAt": "2025-01-15T10:00:00Z"
        }
      ]
    }
```

### 5.4 Get agent

```
GET /agents/<id>
  → 200 { full agent object (same fields as list entry) }
  → 404 Not Found
```

### 5.5 Proxy: send prompt to an agent

```
POST /agents/<id>/prompt
  Content-Type: text/plain
  Body: <user message>

  → 200 {"ok":true}               // proxied from agent
  → 502 Bad Gateway              // agent unreachable
  → 404 Not Found                // agent unknown
```

### 5.6 Proxy: abort agent turn

```
POST /agents/<id>/abort
  → 200 {"ok":true,"aborted":true}
  → 502/404
```

### 5.7 Proxy: interrupt agent

```
POST /agents/<id>/interrupt
  → 200 {"ok":true,"interrupted":true}
```

### 5.8 Proxy: send command to agent

```
POST /agents/<id>/command
  Content-Type: text/plain
  Body: /<command>

  → 200 {"ok":true,"output":"...","sideEffect":"..."}
```

### 5.9 Proxy: get agent transcript

```
GET /agents/<id>/transcript
  → 200 {"messages":[...]}   // proxied from agent
```

### 5.10 Proxy: get agent role info

```
GET /agents/<id>/role
  → 200 {"role":"code",...}
```

### 5.11 Proxy: get agent usage

```
GET /agents/<id>/usage
  → 200 {"guardrails":2,"tools":{...}}
```

### 5.12 Multiplexed events

```
GET /events
  Accept: text/event-stream

  → 200 text/event-stream
  // Every event from the agent /events stream is forwarded,
  // wrapped with an "agentId" field:

  event: turn_start
  data: {"agentId":"<ulid>","kind":"turn_start"}

  event: message_update
  data: {"agentId":"<ulid>","kind":"message_update","deltaKind":"text","blockIndex":0,"delta":"hello"}
```

**Orchestrator-only events (not from agents):**

```
event: agent_registered
data: {"kind":"agent_registered","agent":{"id":"...","name":"...",...}}

event: agent_unregistered
data: {"kind":"agent_unregistered","agentId":"..."}

event: agent_status
data: {"kind":"agent_status","agentId":"...","status":"offline"}

event: error
data: {"kind":"error","message":"..."}
```

---

## 6. Orchestrator state model

```typescript
interface AgentRegistry {
  agents: Map<string, RegisteredAgent>;  // id → agent
}

interface RegisteredAgent {
  id: string;          // ULID from the agent
  name: string;
  apiUrl: string;
  workspace: string;
  model: string;
  role: string;
  pid: number | null;

  // Runtime state managed by orchestrator
  status: 'idle' | 'streaming' | 'error' | 'offline';
  lastHeartbeatAt: Date;
  registeredAt: Date;

  // Internal
  sseConnection: EventSource | null;  // to the agent's /events
  eventBuffer: RingBuffer<SseFrame>;  // last N events for replay/timeline
}
```

### Stale detection

When an agent misses heartbeats or its SSE connection drops:
1. Mark the agent `status: "offline"` in the registry immediately.
2. Stop forwarding the agent's events to the browser.
3. **Do NOT auto-remove** from the registry.
4. The user sees the agent card grayed out with a manual "Remove" or "Reconnect" action.
5. When the agent comes back (re-registers with the same `apiUrl`), flip status back to `idle` and resume SSE consumption.
6. Only after explicit user action (click "Remove") is the agent dropped from the registry.

Rationale: auto-removing makes it impossible for the user to diagnose why an agent disappeared (network blip vs. actual crash). The orchestrator is a visibility tool first; cleanup is the user's decision.
---

## 7. Wireframes

Wireframes are design artifacts stored in the franky repo at `src/coding/modes/web/`:

| File | View |
|------|------|
| `wireframe-orchestrator-dashboard.html` | **A — Dashboard:** Grid of agent cards with status, model, workspace |
| `wireframe-orchestrator-timeline.html` | **C — Activity timeline:** Cross-agent chronological event stream |

The orchestrator itself does **not** embed an agent chat UI. Instead, the Dashboard and Timeline each provide a clickable link that opens the agent's own proxy UI in a new browser tab (at `http://<agent-api-url>/`). This avoids rebuilding the full chat interface; the orchestrator focuses on multi-agent visibility.

### A — Dashboard

A bird's-eye view of all registered agents. Each card shows:
- Agent name + status dot (🟢 idle / 🔵 streaming / 🔴 error / ⚫ offline)
- Model + role
- Workspace path (truncated)
- Last activity timestamp
- Message count (fetched from `GET /session`)

Actions per card:
- **Open** — opens the agent's own proxy UI in a new tab at `http://<agent.apiUrl>/`
- **Send prompt** — quick inline prompt without leaving the dashboard
- **Abort** — fire `POST /abort` on the agent
- **Remove** — drop the agent from the registry (only shown for `offline` agents)

### C — Activity timeline

A unified chronological feed of events across all agents. Each row:
- Timestamp
- Agent name (color-coded)
- Event type icon (🗨 message, 🔧 tool, ⚠ error, ↻ retry)
- One-line summary

Clicking a row opens the agent's own proxy UI in a new tab at `http://<agent.apiUrl>/`. The orchestrator does not attempt to scroll to a specific turn — the agent's proxy UI loads from `GET /transcript` and reconstructs the full conversation.

---

## 8. Error model

| Scenario | HTTP status | Body |
|----------|-------------|------|
| Orchestrator healthy | 200 | `{"ok":true}` |
| Agent unknown | 404 | `{"ok":false,"error":"agent not found","errorCode":"agent_not_found"}` |
| Agent offline | 502 | `{"ok":false,"error":"agent offline","errorCode":"agent_offline"}` |
| Agent rejects request | 502 | proxied agent error |
| Too many agents | 503 | `{"ok":false,"error":"registry full","errorCode":"capacity_exceeded"}` |
| Invalid heartbeat (bad id) | 404 | same as unknown |

---

## 9. Technology choices

| Layer | Choice | Notes |
|-------|--------|-------|
| Backend | Go | No shared code with franky — any language that speaks HTTP + SSE works. Go chosen for stdlib HTTP server and goroutine-based SSE multiplexing. |
| Frontend | Vanilla HTML/JS | Single-page dashboard served as embedded static files (no build pipeline). Matches franky proxy UI pattern. |
| SSE multiplexing | Go goroutines | One persistent `EventSource`-equivalent connection per agent; fan-out to browser subscribers on orchestrator's own SSE stream. |
| Registry persistence | JSON file (`~/.franky-orchestrator/agents.json`) | Survives orchestrator restarts. Only agent metadata (id, name, apiUrl, status, timestamps) — no transcripts or events. |

---

## 10. Open questions

1. **Event buffer depth:** How many events should the orchestrator keep per agent for the timeline view (last 25 events)?
2. **Auto-discovery:** Should the orchestrator support UDP multicast / mDNS so agents find it without `--register`?
 * we could just add a registry endpoint in the settings of the franky agent that it calls by startup to register itself 
3. **Naming conflict:** Two proxies on the same workspace — allow or reject registration?
 * allow only the registered port has to unique like localhost:8787 can only be register once except if the agent was offline for a while the slot becomes free again.
4. **Security:** The proxy mode today binds `0.0.0.0` without auth. Should the orchestrator add token-based auth before accepting registrations (defered to v1 of the orchestrator)?