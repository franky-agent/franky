// franky web UI — talks to the streamProxy listener (§4.7).
//
// Wire format: each SSE frame is `event: <kind>\ndata: <json>\n\n`,
// matching what the in-process agent loop emits. We reuse browser-
// native EventSource and just dispatch by event name.

// ─── Markdown renderer (v1.6.0) ──────────────────────────────────
//
// Hand-rolled subset — no external deps. Why hand-roll: the LLM
// output rarely needs the full CommonMark surface, and shipping a
// dependency would put the binary back into supply-chain territory
// the v1.5.0 zero-build-pipeline decision explicitly avoided.
//
// Supported:
//   - Headings:       # H1, ## H2, ### H3
//   - Code fences:    ```lang\ncode\n```  (lang optional)
//   - Inline code:    `code`
//   - Bold:           **text** or __text__
//   - Italic:         *text* or _text_
//   - Links:          [text](url) — http(s)/mailto/relative only
//   - Lists:          - item / * item / 1. item
//   - Paragraphs:     anything else, joined by blank lines
//
// XSS posture: HTML-escape **before** any markdown pattern runs so
// `<script>` from the LLM never reaches the DOM. Code spans/fences
// keep escaped content verbatim. Link URLs are passed through
// `sanitizeUrl` which rejects `javascript:`, `data:`, etc.
const Markdown = (function () {
    function escapeHtml(s) {
        return s
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function escapeAttr(s) {
        return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
    }

    function sanitizeUrl(url) {
        const u = url.trim();
        if (/^https?:\/\//i.test(u)) return u;
        if (/^mailto:/i.test(u)) return u;
        if (/^[#/]/.test(u)) return u;          // anchors + relative paths
        return null;                            // reject javascript:, data:, file:, …
    }

    // Inline-level transforms applied to already-HTML-escaped text.
    function inline(text) {
        let r = escapeHtml(text);

        // Code spans first — their contents are protected from later
        // transforms by being wrapped in <code>.
        r = r.replace(/`([^`\n]+)`/g, function (_, code) {
            return '<code>' + code + '</code>';
        });

        // Bold (**…** and __…__) before italic so the asterisks/
        // underscores get consumed by the bold matcher.
        r = r.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
        r = r.replace(/__([^_\n]+)__/g, '<strong>$1</strong>');

        // Italic — match with a leading boundary so we don't mangle
        // identifiers like `snake_case_var`.
        r = r.replace(/(^|[^*\w])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>');
        r = r.replace(/(^|[^_\w])_([^_\n]+)_(?!_)/g, '$1<em>$2</em>');

        // Links — sanitize href before emit.
        r = r.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (_, label, url) {
            const safe = sanitizeUrl(url);
            if (!safe) return label;
            return '<a href="' + escapeAttr(safe) + '" target="_blank" rel="noopener noreferrer">' + label + '</a>';
        });

        return r;
    }

    function isHeading(line)   { return /^#{1,3}\s+/.test(line); }
    function isUlItem(line)    { return /^\s*[-*]\s+/.test(line); }
    function isOlItem(line)    { return /^\s*\d+\.\s+/.test(line); }
    function isFenceOpen(line) { return /^```/.test(line); }

    function render(text) {
        if (!text) return '';
        const lines = text.split('\n');
        const out = [];
        let i = 0;

        while (i < lines.length) {
            const line = lines[i];

            // Code fence — consume until closing ``` (or EOF, mid-stream).
            if (isFenceOpen(line)) {
                const langRaw = line.slice(3).trim();
                const langClass = langRaw ? ' class="lang-' + escapeAttr(langRaw) + '"' : '';
                const codeLines = [];
                i += 1;
                while (i < lines.length && !isFenceOpen(lines[i])) {
                    codeLines.push(lines[i]);
                    i += 1;
                }
                if (i < lines.length) i += 1; // skip the closing fence
                out.push('<pre><code' + langClass + '>' + escapeHtml(codeLines.join('\n')) + '</code></pre>');
                continue;
            }

            // Heading.
            const h = line.match(/^(#{1,3})\s+(.*)$/);
            if (h) {
                const lvl = h[1].length;
                out.push('<h' + lvl + '>' + inline(h[2]) + '</h' + lvl + '>');
                i += 1;
                continue;
            }

            // Unordered list.
            if (isUlItem(line)) {
                const items = [];
                while (i < lines.length && isUlItem(lines[i])) {
                    items.push(lines[i].replace(/^\s*[-*]\s+/, ''));
                    i += 1;
                }
                out.push('<ul>' + items.map(function (it) {
                    return '<li>' + inline(it) + '</li>';
                }).join('') + '</ul>');
                continue;
            }

            // Ordered list.
            if (isOlItem(line)) {
                const items = [];
                while (i < lines.length && isOlItem(lines[i])) {
                    items.push(lines[i].replace(/^\s*\d+\.\s+/, ''));
                    i += 1;
                }
                out.push('<ol>' + items.map(function (it) {
                    return '<li>' + inline(it) + '</li>';
                }).join('') + '</ol>');
                continue;
            }

            // Blank line — paragraph separator.
            if (line.trim() === '') {
                i += 1;
                continue;
            }

            // Paragraph — collect contiguous non-block lines.
            const para = [];
            while (i < lines.length
                && lines[i].trim() !== ''
                && !isFenceOpen(lines[i])
                && !isHeading(lines[i])
                && !isUlItem(lines[i])
                && !isOlItem(lines[i])) {
                para.push(lines[i]);
                i += 1;
            }
            if (para.length > 0) {
                out.push('<p>' + inline(para.join('\n')).replace(/\n/g, '<br>') + '</p>');
            }
        }

        return out.join('');
    }

    return { render: render, sanitizeUrl: sanitizeUrl, escapeHtml: escapeHtml };
})();

(function () {
    'use strict';

    // Mirrors `agent.types.role_denied_code` — wire-format string
    // the runtime role gate emits as `tool_code` on a denied tool
    // call. Kept in sync by hand; if you rename one, rename both.
    const ROLE_DENIED = 'role_denied';

    const conversation = document.getElementById('conversation');
    const form = document.getElementById('composer');
    const input = document.getElementById('input');
    const sendBtn = document.getElementById('send');
    const statusEl = document.getElementById('status');
    // v1.7.0 — sidebar elements
    const sessionList = document.getElementById('session-list');
    const newSessionBtn = document.getElementById('new-session');
    const sidebarToggle = document.getElementById('sidebar-toggle');
    // v1.7.2 — header activity pill (out-of-flow streaming feedback)
    const activityEl = document.getElementById('activity');
    const activityLabel = activityEl ? activityEl.querySelector('.activity-label') : null;
    // v1.7.3 — slash command palette
    const cmdPaletteEl = document.getElementById('cmd-palette');
    // v1.7.7 — status line + help overlay
    const statusLineEl = document.getElementById('status-line');
    const helpOverlayEl = document.getElementById('help-overlay');
    const helpCloseBtn = document.getElementById('help-close');
    const helpToggleBtn = document.getElementById('help-toggle');
    const helpCmdsEl = document.getElementById('help-commands');

    /**
     * State for the in-progress assistant message.
     * `blocks[i]` holds the accumulated text for content block `i`,
     * keyed by block_index so concurrent text + thinking streams
     * stay separated. `el` is the message bubble element; null
     * between turns.
     */
    let active = {
        el: null,
        contentEl: null,
        blocks: new Map(),
        thinkingEl: null,
        thinkingBlocks: new Map(),
        // v1.6.2 — live tool-arg streaming. While the assistant
        // message is mid-stream, `toolcall_args` deltas arrive keyed
        // by block_index. We open a "pending" tool card per
        // block_index on first delta and append text into it as
        // more deltas arrive. When `message_end` fires, these cards
        // get moved into `pendingToolCards` (sorted by block_index)
        // for `tool_execution_start` to claim by binding a call_id.
        toolArgs: new Map(), // blockIndex → { el, argsText, argsEl }
    };

    /** call_id → tool-card element. Keeps tool start/end paired. */
    const toolCards = new Map();

    /**
     * v1.6.2 — tool cards that opened from streaming `toolcall_args`
     * but are still waiting for their `tool_execution_start` to
     * arrive (which carries the resolved `call_id` + tool `name`).
     * Drained in source order — the agent loop emits
     * `tool_execution_start` events in the same order as the
     * tool_call blocks in the assistant message, so popping the
     * front matches them by position.
     */
    const pendingToolCards = [];

    /** Single "assistant is thinking..." indicator between turn_start and message_start. */
    let turnIndicator = null;

    /**
     * v1.7.1 — single source of truth for "a turn is in flight".
     * Set in `submitPrompt`, cleared on `turn_end` / `agent_error`.
     * The `sendBtn.disabled` flag only stops mouse clicks; the
     * Enter-key keydown bypasses it, so we need an explicit guard
     * to prevent double-submission.
     */
    let isStreaming = false;

    /**
     * v1.7.2 — watchdog state. `lastEventAt` is refreshed on every
     * SSE frame (including server-side keepalive `ping` frames in
     * v1.7.4). Tick runs every few seconds; once
     * `watchdogTimeoutMs` of silence has elapsed during a
     * streaming turn we surface an advisory banner — once per
     * turn — without resetting state. The user can choose to
     * keep waiting or click Stop.
     *
     * v1.7.4 — bumped to 5 minutes (was 60 s). The previous
     * threshold false-fired during long thinking phases on
     * slow models. Server keepalive `ping` events fire every
     * 15 s, so under healthy server conditions the watchdog
     * never trips even on multi-minute turns.
     */
    let lastEventAt = 0;
    const watchdogTimeoutMs = 300_000;
    let watchdogWarned = false;

    function setStatus(text, cls) {
        statusEl.textContent = text;
        statusEl.className = 'status ' + cls;
    }

    /**
     * v1.7.2 — update the header activity pill. `label` is a
     * short string ("thinking…", "responding…", "running:
     * read"); empty/null hides the pill (idle state).
     *
     * The pill lives in the header — outside the scrollable
     * conversation pane — so it's always visible regardless of
     * how far the user has scrolled. Animation cue (pulsing dot)
     * confirms the model is alive even when no new content is
     * landing on screen.
     */
    function setActivity(label) {
        if (!activityEl) return;
        if (!label) {
            activityEl.classList.remove('activity-active');
            return;
        }
        if (activityLabel) activityLabel.textContent = label;
        activityEl.classList.add('activity-active');
    }

    /**
     * v1.7.2 — flip Send into a Stop button while streaming.
     * Clicking Stop POSTs `/abort` so the server can fire
     * `session.cancel`; the resulting `agent_error{code=aborted}`
     * + `turn_end` events restore the idle UI.
     */
    function setStreaming(streaming) {
        isStreaming = streaming;
        if (streaming) {
            sendBtn.textContent = 'Stop';
            sendBtn.classList.add('is-stop');
            sendBtn.disabled = false;       // keep clickable so Stop works
        } else {
            sendBtn.textContent = 'Send';
            sendBtn.classList.remove('is-stop');
            sendBtn.disabled = false;
            setActivity(null);
        }
    }

    async function abortTurn() {
        // v1.7.9 — reset UI state immediately on user click. The
        // pre-1.7.9 path waited for an `agent_error{code=aborted}`
        // SSE event before flipping back to idle, but that ties
        // the button's recovery to whether a loop is actually
        // running server-side. If the SSE stream missed the prior
        // `turn_end` (or the loop already finished), `cancel.fire()`
        // is a no-op — no follow-up event ever lands and the
        // button stays wedged in Stop forever. Frank flagged this
        // after a real conversation where the model had already
        // replied but the UI insisted it was still responding.
        // Clicking Stop is an unambiguous intent: drop streaming
        // state locally first, then best-effort the POST so any
        // genuinely in-flight loop still gets cancelled.
        setStreaming(false);
        hideTurnIndicator();
        endAssistantMessage();
        stopStatusLineTimer();
        setStatusLine('');
        try {
            await fetch('/abort', { method: 'POST' });
        } catch (_) { /* best-effort — UI already reset above */ }
    }

    /**
     * v1.7.1 — smart auto-scroll. Only stick to the bottom if the
     * user is already pinned there (within `pinSlack` px tolerance).
     * If they've scrolled up to read earlier content (thinking
     * blocks, code, etc.) we leave their viewport alone and let the
     * conversation grow off-screen.
     *
     * Without this, every text delta yanked the page back to the
     * bottom, hiding any thinking content the assistant emitted
     * above its main answer (the bug Frank flagged in v1.7.0
     * feedback).
     */
    const pinSlack = 24;

    function isPinnedToBottom() {
        const el = conversation;
        return el.scrollHeight - el.scrollTop - el.clientHeight <= pinSlack;
    }

    function scrollToBottom(force) {
        const shouldScroll = force === true || isPinnedToBottom();
        if (!shouldScroll) return;
        requestAnimationFrame(() => {
            conversation.scrollTop = conversation.scrollHeight;
        });
    }

    function appendUserMessage(text) {
        const el = document.createElement('div');
        el.className = 'message message-user';
        const role = document.createElement('span');
        role.className = 'role';
        role.textContent = 'you';
        const content = document.createElement('span');
        content.className = 'content';
        content.textContent = text;
        el.appendChild(role);
        el.appendChild(content);
        conversation.appendChild(el);
        // User just sent a message — force scroll so they see their
        // own bubble even if they were reading scrollback.
        scrollToBottom(true);
    }

    /**
     * v1.6.1 — render a finalized assistant message from the
     * transcript. Unlike the streaming path, this builds the bubble
     * in one shot from the persisted text/thinking blocks.
     */
    function appendFinalizedAssistantMessage(blocks, role) {
        // Skip empty messages (e.g. assistant turn that only emitted
        // a tool call and the call already rendered as a card).
        const hasRenderable = blocks.some(b => b.kind === 'text' || b.kind === 'thinking');
        if (!hasRenderable) return;

        const el = document.createElement('div');
        el.className = 'message message-assistant';
        const roleEl = document.createElement('span');
        roleEl.className = 'role';
        roleEl.textContent = role || 'assistant';
        el.appendChild(roleEl);

        // Thinking first (if any), then text — matches the live render.
        const thinkingText = blocks.filter(b => b.kind === 'thinking').map(b => b.text || '').join('');
        if (thinkingText.length > 0) {
            const t = document.createElement('div');
            t.className = 'thinking';
            t.textContent = thinkingText;
            el.appendChild(t);
        }
        const mainText = blocks.filter(b => b.kind === 'text').map(b => b.text || '').join('');
        if (mainText.length > 0) {
            const c = document.createElement('span');
            c.className = 'content';
            c.innerHTML = Markdown.render(mainText);
            el.appendChild(c);
        }
        conversation.appendChild(el);
    }

    function appendFinalizedToolCard(callId, name, isError) {
        const el = document.createElement('div');
        el.className = 'tool-card' + (isError ? ' is-error' : '');
        const head = document.createElement('div');
        head.className = 'tool-head';
        head.innerHTML =
            'tool: <span class="tool-name"></span> <span class="tool-status"></span>';
        head.querySelector('.tool-name').textContent = name;
        head.querySelector('.tool-status').textContent = isError ? 'error' : 'done';
        el.appendChild(head);
        conversation.appendChild(el);
    }

    function appendError(message) {
        const el = document.createElement('div');
        el.className = 'error-banner';
        el.textContent = message;
        conversation.appendChild(el);
        // Errors are worth showing — force scroll so the user sees
        // them even if they were reading earlier content.
        scrollToBottom(true);
    }

    function showTurnIndicator() {
        if (turnIndicator) return;
        turnIndicator = document.createElement('div');
        turnIndicator.className = 'indicator';
        turnIndicator.textContent = 'thinking…';
        conversation.appendChild(turnIndicator);
        scrollToBottom();
    }

    function hideTurnIndicator() {
        if (!turnIndicator) return;
        turnIndicator.remove();
        turnIndicator = null;
    }

    function startAssistantMessage(role) {
        // v1.7.1 — defensive: a previous assistant message was
        // never closed (missed `message_end`, mid-stream
        // disconnect, server hiccup, …). Force-close it before
        // opening the new one. The pre-v1.7.1 code early-returned,
        // which silently merged the new message's deltas into the
        // previous bubble — causing the "answer above the question"
        // bug when a user submitted twice in quick succession.
        if (active.el) endAssistantMessage();
        const el = document.createElement('div');
        el.className = 'message message-assistant';
        const roleEl = document.createElement('span');
        roleEl.className = 'role';
        roleEl.textContent = role || 'assistant';
        const content = document.createElement('span');
        content.className = 'content';
        el.appendChild(roleEl);
        el.appendChild(content);
        conversation.appendChild(el);
        active = {
            el,
            contentEl: content,
            blocks: new Map(),
            thinkingEl: null,
            thinkingBlocks: new Map(),
            toolArgs: new Map(),
        };
        hideTurnIndicator();
        scrollToBottom();
    }

    function ensureActiveMessage() {
        if (!active.el) startAssistantMessage('assistant');
    }

    function appendTextDelta(blockIndex, delta) {
        ensureActiveMessage();
        const prev = active.blocks.get(blockIndex) || '';
        active.blocks.set(blockIndex, prev + delta);
        // Re-render content as the concatenation of all block deltas in
        // index order. This keeps multi-block messages stable even if
        // deltas arrive interleaved.
        const ordered = [...active.blocks.entries()]
            .sort((a, b) => a[0] - b[0])
            .map(([, t]) => t)
            .join('');
        // Markdown render — Markdown.render escapes HTML internally so
        // setting innerHTML is safe (no `<script>` from the model can
        // reach the DOM). Mid-stream code fences with no closing ```
        // still render as a code block (the parser treats EOF as the
        // close), so partial markdown looks right while streaming.
        active.contentEl.innerHTML = Markdown.render(ordered);
        scrollToBottom();
    }

    function appendThinkingDelta(blockIndex, delta) {
        ensureActiveMessage();
        if (!active.thinkingEl) {
            active.thinkingEl = document.createElement('div');
            active.thinkingEl.className = 'thinking';
            // Insert before the main content so thinking appears above.
            active.el.insertBefore(active.thinkingEl, active.contentEl);
        }
        const prev = active.thinkingBlocks.get(blockIndex) || '';
        active.thinkingBlocks.set(blockIndex, prev + delta);
        const ordered = [...active.thinkingBlocks.entries()]
            .sort((a, b) => a[0] - b[0])
            .map(([, t]) => t)
            .join('');
        active.thinkingEl.textContent = ordered;
        scrollToBottom();
    }

    function endAssistantMessage() {
        if (!active.el) return;
        // If the message ended up empty (tool-only turn), drop the bubble.
        if (active.contentEl.textContent.length === 0 && !active.thinkingEl) {
            active.el.remove();
        }
        // v1.6.2 — move any streaming tool-arg cards into the
        // pending queue, ordered by block_index ascending so the
        // first `tool_execution_start` gets the first card.
        // Defensive: a missing `toolArgs` Map (regression from a
        // bad reset elsewhere) used to throw out of the SSE
        // listener and wedge `setStreaming(false)`. Fall back to
        // an empty iteration instead of throwing.
        if (active.toolArgs) {
            const orderedKeys = [...active.toolArgs.keys()].sort(function (a, b) { return a - b; });
            for (const k of orderedKeys) {
                pendingToolCards.push(active.toolArgs.get(k));
            }
        }
        active = { el: null, contentEl: null, blocks: new Map(), thinkingEl: null, thinkingBlocks: new Map(), toolArgs: new Map() };
    }

    /**
     * v1.6.2 — append a `toolcall_args` delta. Opens a pending
     * tool card on first delta for this block_index; later deltas
     * accumulate into the same card. Arg text renders as plain
     * monospace (it's JSON; no markdown). Truncates to 4 KiB so
     * a runaway provider can't blow up the DOM.
     */
    function appendToolArgsDelta(blockIndex, delta) {
        if (!active.toolArgs) active.toolArgs = new Map();
        let entry = active.toolArgs.get(blockIndex);
        if (!entry) {
            const el = document.createElement('div');
            el.className = 'tool-card is-pending';
            const head = document.createElement('div');
            head.className = 'tool-head';
            head.innerHTML =
                'tool: <span class="tool-name">…</span> <span class="tool-status">streaming args…</span>';
            const argsEl = document.createElement('div');
            argsEl.className = 'tool-args';
            el.appendChild(head);
            el.appendChild(argsEl);
            conversation.appendChild(el);
            entry = { el: el, argsText: '', argsEl: argsEl };
            active.toolArgs.set(blockIndex, entry);
        }
        entry.argsText += delta;
        if (entry.argsText.length > 4096) {
            entry.argsEl.textContent = entry.argsText.slice(0, 4096) + '… [truncated]';
        } else {
            entry.argsEl.textContent = entry.argsText;
        }
        scrollToBottom();
    }

    function startToolCall(callId, name) {
        // Tools render between assistant messages, so close out any
        // active assistant bubble first — the next message_start will
        // open a new one. `endAssistantMessage` also drains streaming
        // `toolcall_args` cards into `pendingToolCards`.
        endAssistantMessage();

        // v1.6.2 — if we already opened a card from streaming args,
        // claim it now: bind the call_id, surface the tool name,
        // flip status from "streaming args…" to "running…".
        if (pendingToolCards.length > 0) {
            const card = pendingToolCards.shift();
            card.el.classList.remove('is-pending');
            const nameEl = card.el.querySelector('.tool-name');
            if (nameEl) nameEl.textContent = name;
            const status = card.el.querySelector('.tool-status');
            if (status) status.textContent = 'running…';
            toolCards.set(callId, card.el);
            scrollToBottom();
            return;
        }

        // No pending card (provider didn't stream toolcall_args, or
        // the args came outside an assistant message) — open a
        // fresh card. Matches the v1.5.0 behavior.
        const el = document.createElement('div');
        el.className = 'tool-card';
        const head = document.createElement('div');
        head.className = 'tool-head';
        head.innerHTML =
            'tool: <span class="tool-name"></span> <span class="tool-status">running…</span>';
        head.querySelector('.tool-name').textContent = name;
        const args = document.createElement('div');
        args.className = 'tool-args';
        el.appendChild(head);
        el.appendChild(args);
        conversation.appendChild(el);
        toolCards.set(callId, el);
        scrollToBottom();
    }

    function endToolCall(callId, isError, toolCode) {
        const el = toolCards.get(callId);
        if (!el) return;
        toolCards.delete(callId);
        const denied = toolCode === ROLE_DENIED;
        const status = el.querySelector('.tool-status');
        if (status) status.textContent = denied ? 'denied (role)' : isError ? 'error' : 'done';
        if (isError) el.classList.add('is-error');
        if (denied) el.classList.add('is-role-denied');
    }

    // v1.11.4 — permission-prompt modal. Renders an inline card
    // in the conversation pane (not a dialog overlay) so the
    // request stays in the transcript context. Buttons POST to
    // /permission/resolve and dismiss the card on success;
    // server-side resolve wakes the worker, the next tool event
    // appends below.
    function renderPermissionModal(req) {
        const el = document.createElement('div');
        el.className = 'permission-modal';
        el.dataset.callId = req.callId;

        const head = document.createElement('div');
        head.className = 'permission-head';
        head.textContent = '🔒 permission required: ' + req.toolName +
            ' (fingerprint: ' + req.fingerprint + ')';
        el.appendChild(head);

        const args = document.createElement('pre');
        args.className = 'permission-args';
        args.textContent = req.argsJson;
        el.appendChild(args);

        const buttons = document.createElement('div');
        buttons.className = 'permission-buttons';
        const choices = [
            { key: 'allow_once', label: 'Allow once', kind: 'allow' },
            { key: 'always_allow', label: 'Always allow', kind: 'allow' },
            { key: 'deny_once', label: 'Deny once', kind: 'deny' },
            { key: 'always_deny', label: 'Always deny', kind: 'deny' },
        ];
        let resolving = false;
        for (const c of choices) {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'permission-btn permission-btn-' + c.kind;
            btn.textContent = c.label;
            btn.addEventListener('click', async () => {
                if (resolving) return;
                resolving = true;
                for (const b of buttons.querySelectorAll('button')) b.disabled = true;
                try {
                    const r = await fetch('/permission/resolve', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ call_id: req.callId, resolution: c.key }),
                    });
                    if (r.ok) {
                        // Replace the modal with a compact result line.
                        const result = document.createElement('div');
                        result.className = 'permission-result permission-result-' + c.kind;
                        result.textContent = (c.kind === 'allow' ? '✓ allowed: ' : '✗ denied: ') +
                            req.toolName + ' (' + c.key + ')';
                        el.replaceWith(result);
                    } else {
                        head.textContent = '⚠ resolve failed (HTTP ' + r.status + ') — try again';
                        for (const b of buttons.querySelectorAll('button')) b.disabled = false;
                        resolving = false;
                    }
                } catch (_) {
                    head.textContent = '⚠ network error — try again';
                    for (const b of buttons.querySelectorAll('button')) b.disabled = false;
                    resolving = false;
                }
            });
            buttons.appendChild(btn);
        }
        el.appendChild(buttons);

        conversation.appendChild(el);
        scrollToBottom();
    }

    // ── EventSource wiring ───────────────────────────────────────

    function connect() {
        setStatus('connecting…', 'status-idle');
        const es = new EventSource('/events');

        es.addEventListener('open', () => setStatus('live', 'status-live'));

        es.addEventListener('error', () => {
            setStatus('disconnected', 'status-error');
        });

        // v1.7.2 — refresh the watchdog timestamp on every SSE
        // frame. Each named handler below stamps `lastEventAt`
        // inline. The watchdog tick reads it to decide whether
        // a missed `turn_end` left us hanging.
        function noteEvent() { lastEventAt = Date.now(); }

        es.addEventListener('turn_start', () => {
            noteEvent();
            // v1.7.2 — header pill replaces the in-flow "thinking…"
            // indicator as the canonical activity cue. We keep the
            // in-flow indicator too for backwards compat but the
            // pill is what users see when they've scrolled away.
            setActivity('thinking…');
            if (!active.el && toolCards.size === 0) showTurnIndicator();
        });

        es.addEventListener('turn_end', () => {
            noteEvent();
            endAssistantMessage();
            hideTurnIndicator();
            setStreaming(false);            // v1.7.2 (replaces v1.7.1 plumbing)
            stopStatusLineTimer();          // v1.7.7
            refreshStatusLineUsage();
            input.focus();
        });

        es.addEventListener('message_start', (e) => {
            noteEvent();
            const data = parseData(e.data);
            startAssistantMessage(data && data.role);
            // v1.7.2 — assistant just started speaking; flip the
            // pill from "thinking…" to "responding…".
            if (data && data.role === 'assistant') setActivity('responding…');
        });

        es.addEventListener('message_update', (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data) return;
            switch (data.deltaKind) {
                case 'text':
                    appendTextDelta(data.blockIndex || 0, data.delta || '');
                    setActivity('responding…');
                    break;
                case 'thinking':
                    appendThinkingDelta(data.blockIndex || 0, data.delta || '');
                    setActivity('thinking…');
                    break;
                case 'toolcall_args':
                    // v1.6.2 — open a pending tool card on first
                    // delta for this block_index, append further
                    // deltas into it. `tool_execution_start` claims
                    // the card later by binding a call_id.
                    appendToolArgsDelta(data.blockIndex || 0, data.delta || '');
                    break;
            }
        });

        es.addEventListener('message_end', () => {
            noteEvent();
            endAssistantMessage();
        });

        es.addEventListener('tool_execution_start', (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data) return;
            startToolCall(data.callId, data.name || 'tool');
            setActivity('running: ' + (data.name || 'tool'));
        });

        es.addEventListener('tool_execution_end', (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data) return;
            endToolCall(data.callId, !!data.isError, data.toolCode || null);
            // After a tool completes the loop usually starts the
            // next assistant turn — show "thinking…" until the
            // next message_start arrives.
            setActivity('thinking…');
        });

        // v1.11.4 — pause-and-prompt permission overlay. Server
        // suspends the worker on `ask`; we render a modal in the
        // conversation pane and POST the user's choice to
        // /permission/resolve to wake it.
        es.addEventListener('tool_permission_request', (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data || !data.callId) return;
            renderPermissionModal({
                callId: data.callId,
                toolName: data.toolName || 'tool',
                argsJson: data.argsJson || '',
                fingerprint: data.fingerprint || data.toolName || '',
            });
        });

        es.addEventListener('agent_error', (e) => {
            noteEvent();
            const data = parseData(e.data);
            const msg = data ? `${data.code}: ${data.message}` : 'agent error';
            // v1.7.2 — `code=aborted` is the user-driven Stop case;
            // surface it gently, not as a red error banner.
            if (!(data && data.code === 'aborted')) {
                appendError(msg);
            }
            setStreaming(false);            // v1.7.2
            hideTurnIndicator();
            endAssistantMessage();
            stopStatusLineTimer();          // v1.7.7
            setStatusLine('');
        });

        // v1.7.0 — server fires this when the active session
        // changes (via /session/activate or /session/new). Wipe
        // the conversation and rehydrate from the new transcript.
        es.addEventListener('session_switched', async (e) => {
            noteEvent();
            const data = parseData(e.data);
            if (!data || !data.id) return;
            await onSessionSwitched(data.id);
        });

        // v1.7.0 — refresh the sidebar after every turn ends so
        // the message-count + updated-at timestamps stay current.
        es.addEventListener('turn_end', () => loadSessions());

        // v1.7.2 — watchdog. Every 5s, if `isStreaming` is true
        // and no SSE event has arrived for `watchdogTimeoutMs`,
        // surface an advisory. v1.7.4 made this non-destructive:
        // we used to wipe the active assistant bubble and reset
        // streaming state, but that produced false positives on
        // long thinking phases AND fragmented mid-turn output
        // when events resumed. The current behavior leaves all
        // state untouched and just gives the user a one-time
        // heads-up — they can wait or click Stop.
        setInterval(function () {
            if (!isStreaming) return;
            if (lastEventAt === 0) return;
            if (Date.now() - lastEventAt < watchdogTimeoutMs) return;
            if (watchdogWarned) return;
            watchdogWarned = true;
            console.warn('franky watchdog: no SSE events for ' + watchdogTimeoutMs + 'ms while streaming — model is taking longer than usual.');
            appendSystemMessage('',
                '_Model is taking longer than usual to respond. Click **Stop** to cancel, or keep waiting._',
                false);
        }, 5_000);

        // v1.7.4 — server-side keepalive: refresh the watchdog
        // clock without doing anything user-visible. Server
        // broadcasts `event: ping` every 15s while a turn is
        // running.
        es.addEventListener('ping', () => { noteEvent(); });

        return es;
    }

    function parseData(raw) {
        try {
            return JSON.parse(raw);
        } catch (_) {
            return null;
        }
    }

    // ── Composer ────────────────────────────────────────────────

    async function submitPrompt(text) {
        if (isStreaming) return;       // v1.7.1 — single-flight guard

        // v1.7.7 — record the prompt in history (both LLM
        // prompts and slash commands; users want to recall both).
        pushHistory(text);
        historyReset();

        // v1.7.3 — leading "/" routes to the slash dispatcher
        // instead of the LLM. Slash commands run synchronously
        // server-side; no streaming, no agent-loop activity.
        if (text.length > 0 && text[0] === '/') {
            await dispatchSlash(text);
            return;
        }

        setStreaming(true);
        setActivity('sending…');       // v1.7.2 — show activity immediately
        lastEventAt = Date.now();      // v1.7.2 — start the watchdog clock
        watchdogWarned = false;        // v1.7.4 — fresh advisory budget per turn
        startStatusLineTimer();        // v1.7.7 — elapsed seconds counter
        appendUserMessage(text);
        try {
            const resp = await fetch('/prompt', {
                method: 'POST',
                headers: { 'Content-Type': 'text/plain' },
                body: text,
            });
            if (!resp.ok) {
                appendError(`prompt rejected: HTTP ${resp.status}`);
                setStreaming(false);
            }
        } catch (err) {
            appendError(`network error: ${err.message || err}`);
            setStreaming(false);
        }
    }

    // ─── v1.7.3 — slash command dispatch ─────────────────────────

    /**
     * Render a system bubble — a neutral card showing the command
     * the user entered + its rendered output. Distinct styling
     * from user/assistant bubbles so `/help` etc. don't read as a
     * conversational turn.
     */
    function appendSystemMessage(line, outputMd, isError) {
        const el = document.createElement('div');
        el.className = 'message message-system' + (isError ? ' is-error' : '');

        const head = document.createElement('span');
        head.className = 'role';
        head.textContent = '$ ' + line;
        el.appendChild(head);

        const content = document.createElement('span');
        content.className = 'content';
        content.innerHTML = Markdown.render(outputMd || '');
        el.appendChild(content);

        conversation.appendChild(el);
        scrollToBottom(true);
    }

    /**
     * POST a slash-command line to /command, render the result as
     * a system message, dispatch any side-effect.
     */
    async function dispatchSlash(line) {
        let data;
        try {
            const r = await fetch('/command', {
                method: 'POST',
                headers: { 'Content-Type': 'text/plain' },
                body: line,
            });
            data = await r.json();
        } catch (err) {
            appendError('command failed: ' + (err.message || err));
            return;
        }

        if (!data || data.ok !== true) {
            const msg = (data && data.error) ? data.error : 'unknown command error';
            appendSystemMessage(line, '**Error:** ' + msg, true);
            return;
        }

        appendSystemMessage(line, data.output || '', false);

        // Side-effect dispatch.
        switch (data.sideEffect) {
            case 'clear_transcript':
                // Server already wiped the transcript and persisted —
                // mirror locally so the conversation pane matches.
                clearConversation();
                // Re-append the system message for the /clear itself
                // so the user has a record of what happened.
                appendSystemMessage(line, data.output || '', false);
                loadSessions();
                break;
            case 'model_changed':
                if (data.data && data.data.model) {
                    setStatus('model: ' + data.data.model, 'status-live');
                    // Snap back to "live" after a short beat so the
                    // pill doesn't permanently show the model name.
                    setTimeout(() => setStatus('live', 'status-live'), 2_500);
                }
                break;
            case 'turn_restarted':
                // v1.7.8 — server trimmed the assistant chain
                // after the last user message; a worker is about
                // to re-run the loop. Wipe the old conversation
                // pane and rehydrate from the trimmed transcript;
                // the new turn's SSE events will then layer on
                // top. Server also broadcasts session_switched
                // for any other open tabs.
                clearConversation();
                rehydrate().then(() => {
                    appendSystemMessage(line, data.output || '', false);
                    loadSessions();
                });
                break;
            case 'fill_input':
                // v1.7.8 — server returned the previous user-
                // message text; drop it into the composer so the
                // user can edit + resubmit.
                if (data.data && typeof data.data.text === 'string') {
                    input.value = data.data.text;
                    const len = input.value.length;
                    input.setSelectionRange(len, len);
                    input.focus();
                }
                // Also clear the bubble that the trimmed user
                // message left in the conversation pane — the
                // server already removed it from the transcript.
                clearConversation();
                rehydrate().then(() => {
                    loadSessions();
                });
                break;
            case 'quit':
                // Browsers won't always allow window.close(); fall
                // back to a banner if blocked.
                try { window.close(); } catch (_) {}
                appendSystemMessage('', '_Tab closed by /quit. You can close this tab manually._', false);
                break;
            default:
                // null / thinking_changed / unknown — no client action.
                break;
        }
    }

    form.addEventListener('submit', (e) => {
        e.preventDefault();
        // v1.7.2 — while streaming, the Send button is the Stop
        // button; submitting via the form (Enter or click) routes
        // to abort instead of opening a second turn.
        if (isStreaming) {
            abortTurn();
            return;
        }
        const text = input.value.trim();
        if (!text) return;
        input.value = '';
        submitPrompt(text);
    });

    input.addEventListener('keydown', (e) => {
        // v1.7.3 — palette navigation has priority over composer
        // shortcuts when it's open.
        if (paletteIsOpen()) {
            if (e.key === 'ArrowUp')   { e.preventDefault(); paletteSelect(-1); return; }
            if (e.key === 'ArrowDown') { e.preventDefault(); paletteSelect(+1); return; }
            if (e.key === 'Escape')    { e.preventDefault(); paletteHide(); return; }
            if (e.key === 'Tab')       { e.preventDefault(); paletteAcceptSelected(); return; }
        }

        // v1.7.7 — history nav. Up/down through prior prompts when
        // the input is empty (or already navigating). Esc resets.
        if (e.key === 'ArrowUp' && canNavigateHistory()) {
            e.preventDefault();
            historyStep(+1);
            return;
        }
        if (e.key === 'ArrowDown' && historyIndex >= 0) {
            e.preventDefault();
            historyStep(-1);
            return;
        }
        if (e.key === 'Escape' && historyIndex >= 0) {
            e.preventDefault();
            historyReset();
            return;
        }

        // Enter submits; Shift-Enter inserts a newline (browser default).
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            // While streaming, Enter triggers Stop (matches the
            // Send→Stop button swap). Pre-1.7.2 this was a hard
            // bail; v1.7.2 routes to abort so users can recover.
            if (isStreaming) {
                abortTurn();
                return;
            }
            form.dispatchEvent(new Event('submit', { cancelable: true }));
        }
    });

    // ─── v1.7.7 — prompt history (localStorage-backed ring) ──────

    /**
     * Bounded ring of recent user submissions, persisted to
     * localStorage. Newest at index 0. ↑ when input empty walks
     * backward in time (toward older); ↓ walks forward (toward
     * newer). At index -1 the user is "not navigating" and the
     * input reflects whatever they typed.
     */
    const historyKey = 'franky.history';
    const historyMax = 50;
    let inputHistory = [];
    let historyIndex = -1;
    let historyDraft = '';            // what the user had typed before navigating

    function loadHistory() {
        try {
            const raw = localStorage.getItem(historyKey);
            if (!raw) return;
            const parsed = JSON.parse(raw);
            if (Array.isArray(parsed)) {
                inputHistory = parsed.filter(s => typeof s === 'string').slice(0, historyMax);
            }
        } catch (_) { /* ignore */ }
    }

    function saveHistory() {
        try { localStorage.setItem(historyKey, JSON.stringify(inputHistory)); } catch (_) {}
    }

    function pushHistory(text) {
        if (!text || typeof text !== 'string') return;
        // Dedupe consecutive identical entries.
        if (inputHistory.length > 0 && inputHistory[0] === text) return;
        inputHistory.unshift(text);
        if (inputHistory.length > historyMax) inputHistory.length = historyMax;
        saveHistory();
    }

    function canNavigateHistory() {
        if (inputHistory.length === 0) return false;
        // Allow ↑ when input is empty OR we're already navigating.
        return historyIndex >= 0 || input.value.length === 0;
    }

    function historyStep(delta) {
        // Capture the user's draft on entry so ↓ back to -1 restores it.
        if (historyIndex < 0) historyDraft = input.value;
        const next = historyIndex + delta;
        if (next < 0) {
            historyIndex = -1;
            input.value = historyDraft;
        } else if (next >= inputHistory.length) {
            // Stay at the oldest.
            historyIndex = inputHistory.length - 1;
            input.value = inputHistory[historyIndex];
        } else {
            historyIndex = next;
            input.value = inputHistory[historyIndex];
        }
        // Move caret to end so the user can edit the recalled prompt.
        const len = input.value.length;
        input.setSelectionRange(len, len);
    }

    function historyReset() {
        historyIndex = -1;
        historyDraft = '';
    }

    // ─── v1.7.3 — slash command palette ──────────────────────────

    /** Static command list. Mirrors `buildProxySlashRegistry` in proxy.zig.
     *  Kept in lockstep manually — there are nine entries and they
     *  change rarely. If the registry grows we'll fetch it via
     *  GET /commands; for the v1.7.3 batch the static list is fine. */
    const slashCommands = [
        { name: 'help',     desc: 'Show this list', argHint: '' },
        { name: 'clear',    desc: 'Clear the active conversation', argHint: '' },
        { name: 'model',    desc: 'Hot-swap the model', argHint: '<id>' },
        { name: 'tools',    desc: 'List registered tools', argHint: '' },
        { name: 'tool',     desc: "Show a tool's schema", argHint: '<name>' },
        { name: 'thinking', desc: 'Set thinking level', argHint: '<level>' },
        { name: 'cost',     desc: 'Show token usage', argHint: '' },
        { name: 'export',   desc: 'Dump transcript', argHint: 'markdown|json' },
        // v1.7.8 — retry / edit
        { name: 'retry',    desc: 'Re-run the last turn', argHint: '' },
        { name: 'edit',     desc: 'Edit the last user message', argHint: '' },
        { name: 'compact',  desc: 'Compact older messages into a summary', argHint: '' },
        { name: 'quit',     desc: 'Close this browser tab', argHint: '' },
    ];

    let paletteSelected = 0;
    let palettePrefix = '';

    function paletteIsOpen() {
        return cmdPaletteEl && cmdPaletteEl.classList.contains('is-open');
    }

    function paletteHide() {
        if (cmdPaletteEl) cmdPaletteEl.classList.remove('is-open');
    }

    function paletteCandidates() {
        if (!palettePrefix) return slashCommands;
        return slashCommands.filter(c => c.name.startsWith(palettePrefix));
    }

    function paletteRender() {
        if (!cmdPaletteEl) return;
        const items = paletteCandidates();
        if (items.length === 0) {
            paletteHide();
            return;
        }
        if (paletteSelected >= items.length) paletteSelected = 0;
        cmdPaletteEl.innerHTML = '';
        for (let i = 0; i < items.length; i++) {
            const li = document.createElement('li');
            if (i === paletteSelected) li.classList.add('is-selected');
            const name = document.createElement('span');
            name.className = 'cmd-name';
            name.textContent = '/' + items[i].name + (items[i].argHint ? ' ' + items[i].argHint : '');
            const desc = document.createElement('span');
            desc.className = 'cmd-desc';
            desc.textContent = items[i].desc;
            li.appendChild(name);
            li.appendChild(desc);
            li.addEventListener('mousedown', (ev) => {
                // mousedown (not click) so the textarea doesn't lose
                // focus before we get to handle it.
                ev.preventDefault();
                paletteSelected = i;
                paletteAcceptSelected();
            });
            cmdPaletteEl.appendChild(li);
        }
        cmdPaletteEl.classList.add('is-open');
    }

    function paletteSelect(delta) {
        const items = paletteCandidates();
        if (items.length === 0) return;
        paletteSelected = (paletteSelected + delta + items.length) % items.length;
        paletteRender();
    }

    function paletteAcceptSelected() {
        const items = paletteCandidates();
        if (items.length === 0) return;
        const cmd = items[paletteSelected];
        // Replace input with the selected command, plus a trailing
        // space so the user can type args immediately.
        input.value = '/' + cmd.name + (cmd.argHint ? ' ' : ' ');
        paletteHide();
        // Keep focus on the textarea.
        input.focus();
        // Re-evaluate state — typing more `/` shouldn't reopen.
        paletteRefreshFromInput();
    }

    function paletteRefreshFromInput() {
        const v = input.value;
        // Open only when the line starts with '/' and has no
        // whitespace yet (i.e. the user is still typing the
        // command name).
        if (v.length === 0 || v[0] !== '/' || /\s/.test(v)) {
            paletteHide();
            return;
        }
        palettePrefix = v.slice(1);
        paletteSelected = 0;
        paletteRender();
    }

    if (cmdPaletteEl) {
        input.addEventListener('input', paletteRefreshFromInput);
        input.addEventListener('blur', () => {
            // Delay slightly so a click on a palette item still
            // fires before we hide.
            setTimeout(paletteHide, 80);
        });
    }

    // ─── v1.7.7 — live status line (elapsed + tokens) ───────────

    let statusTimer = null;
    let statusStartedAt = 0;

    function setStatusLine(text) {
        if (statusLineEl) statusLineEl.textContent = text;
    }

    function startStatusLineTimer() {
        statusStartedAt = Date.now();
        const tick = () => {
            const elapsed = Math.floor((Date.now() - statusStartedAt) / 1000);
            setStatusLine(elapsed + 's');
        };
        tick();
        if (statusTimer) clearInterval(statusTimer);
        statusTimer = setInterval(tick, 1_000);
    }

    function stopStatusLineTimer() {
        if (statusTimer) {
            clearInterval(statusTimer);
            statusTimer = null;
        }
    }

    /**
     * After a turn ends, fetch the latest transcript and surface
     * the last assistant message's usage on the status line. The
     * server emits `usage` on the message in `renderTranscriptForUi`
     * (v1.7.7); models without usage just leave the line at the
     * elapsed time.
     */
    async function refreshStatusLineUsage() {
        const elapsed = Math.floor((Date.now() - statusStartedAt) / 1000);
        try {
            const r = await fetch('/transcript');
            if (!r.ok) { setStatusLine(elapsed + 's'); return; }
            const data = await r.json();
            const msgs = (data && Array.isArray(data.messages)) ? data.messages : [];
            // Walk from the end; pick the last assistant with usage.
            for (let i = msgs.length - 1; i >= 0; i--) {
                if (msgs[i].role === 'assistant' && msgs[i].usage) {
                    const u = msgs[i].usage;
                    setStatusLine(elapsed + 's · in ' + (u.input || 0) + ' / out ' + (u.output || 0));
                    return;
                }
            }
            setStatusLine(elapsed + 's');
        } catch (_) {
            setStatusLine(elapsed + 's');
        }
    }

    // ─── v1.7.7 — help overlay ──────────────────────────────────

    function showHelp() {
        if (!helpOverlayEl || !helpCmdsEl) return;
        // Re-render the slash command list each time so future
        // additions to `slashCommands` are reflected.
        helpCmdsEl.innerHTML = '';
        for (const c of slashCommands) {
            const li = document.createElement('li');
            const name = document.createElement('span');
            name.className = 'help-cmd-name';
            name.textContent = '/' + c.name + (c.argHint ? ' ' + c.argHint : '');
            const desc = document.createElement('span');
            desc.className = 'help-cmd-desc';
            desc.textContent = c.desc;
            li.appendChild(name);
            li.appendChild(desc);
            helpCmdsEl.appendChild(li);
        }
        helpOverlayEl.hidden = false;
    }

    function hideHelp() {
        if (helpOverlayEl) helpOverlayEl.hidden = true;
    }

    if (helpToggleBtn) helpToggleBtn.addEventListener('click', showHelp);
    if (helpCloseBtn)  helpCloseBtn.addEventListener('click', hideHelp);
    if (helpOverlayEl) {
        helpOverlayEl.addEventListener('click', (e) => {
            // Click on the dim backdrop (not the inner card) closes.
            if (e.target === helpOverlayEl) hideHelp();
        });
    }

    // Global ?-key opens help; Esc closes it. Skip when the user
    // is mid-typing in the textarea (so "?" inserts normally).
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && helpOverlayEl && !helpOverlayEl.hidden) {
            e.preventDefault();
            hideHelp();
            return;
        }
        if (e.key === '?' && document.activeElement !== input) {
            e.preventDefault();
            showHelp();
        }
    });

    // ─── v1.7.0 — sidebar / session management ───────────────────

    /** Most-recent session list snapshot from /sessions. */
    let sessionsCache = [];
    let activeSessionId = null;
    let sessionsPersisted = true;

    function fmtRelativeTime(ms) {
        if (!ms) return '';
        const diff = Date.now() - ms;
        if (diff < 60_000) return 'just now';
        if (diff < 3_600_000) return Math.floor(diff / 60_000) + 'm ago';
        if (diff < 86_400_000) return Math.floor(diff / 3_600_000) + 'h ago';
        return Math.floor(diff / 86_400_000) + 'd ago';
    }

    function renderSessionList() {
        sessionList.innerHTML = '';
        if (!sessionsPersisted) {
            const li = document.createElement('li');
            li.className = 'session-empty';
            li.textContent = 'Sessions disabled (--no-session). Conversations stay in memory only.';
            sessionList.appendChild(li);
            return;
        }
        if (sessionsCache.length === 0) {
            const li = document.createElement('li');
            li.className = 'session-empty';
            li.textContent = 'No saved conversations yet — say something to start.';
            sessionList.appendChild(li);
            return;
        }
        for (const s of sessionsCache) {
            const li = document.createElement('li');
            li.dataset.id = s.id;
            if (s.id === activeSessionId) li.classList.add('is-active');
            const title = document.createElement('span');
            title.className = 'session-title';
            title.textContent = s.title || s.id;
            const meta = document.createElement('span');
            meta.className = 'session-meta';
            meta.textContent = `${s.messageCount} msg · ${fmtRelativeTime(s.updatedAtMs)}`;
            li.appendChild(title);
            li.appendChild(meta);
            li.addEventListener('click', function () {
                if (s.id !== activeSessionId) activateSession(s.id);
            });
            sessionList.appendChild(li);
        }
    }

    async function loadSessions() {
        try {
            const r = await fetch('/sessions');
            if (!r.ok) return;
            const data = await r.json();
            sessionsCache = Array.isArray(data.sessions) ? data.sessions : [];
            activeSessionId = data.active || activeSessionId;
            sessionsPersisted = data.persisted !== false;
            renderSessionList();
        } catch (_) {
            /* ignore — sidebar stays empty */
        }
    }

    /** Clear the conversation pane completely. Used on session swap. */
    function clearConversation() {
        conversation.innerHTML = '';
        active = { el: null, contentEl: null, blocks: new Map(), thinkingEl: null, thinkingBlocks: new Map(), toolArgs: new Map() };
        toolCards.clear();
        pendingToolCards.length = 0;
        hideTurnIndicator();
        setStreaming(false);                // v1.7.2 (replaces v1.7.1 plumbing)
        stopStatusLineTimer();              // v1.7.7
        setStatusLine('');
    }

    async function activateSession(id) {
        try {
            const r = await fetch('/session/activate', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ id: id }),
            });
            if (!r.ok) return;
            // Activation succeeds → server broadcasts session_switched
            // to all subscribers, but the local handler's the same path.
            await onSessionSwitched(id);
        } catch (_) { /* ignore */ }
    }

    async function newSession() {
        try {
            const r = await fetch('/session/new', { method: 'POST' });
            if (!r.ok) return;
            const data = await r.json();
            await onSessionSwitched(data.id);
        } catch (_) { /* ignore */ }
    }

    async function onSessionSwitched(newId) {
        activeSessionId = newId;
        clearConversation();
        await rehydrate();
        await loadSessions();
    }

    if (newSessionBtn) newSessionBtn.addEventListener('click', newSession);
    if (sidebarToggle) {
        sidebarToggle.addEventListener('click', function () {
            document.body.classList.toggle('sidebar-collapsed');
        });
    }

    /**
     * v1.6.1 — fetch /transcript and replay each persisted message
     * into the conversation pane. Runs once on page load before
     * the EventSource connects, so reload is non-destructive.
     *
     * Tool calls are rendered as a card sourced from the assistant
     * message's `tool_call` block; the matching tool_result message
     * just upgrades the card's status. We don't re-fire any events
     * — this is a pure DOM reconstruction from server-side state.
     */
    async function rehydrate() {
        let data;
        try {
            const resp = await fetch('/transcript', { headers: { 'Accept': 'application/json' } });
            if (!resp.ok) return;
            data = await resp.json();
        } catch (_) {
            return;
        }
        if (!data || !Array.isArray(data.messages)) return;

        // Pass 1: collect tool_result statuses keyed by toolCallId so
        // pass 2 can paint each tool card with its final state in
        // one go.
        const toolStatus = new Map();
        for (const m of data.messages) {
            if (m.role === 'toolResult' && m.toolCallId) {
                toolStatus.set(m.toolCallId, !!m.isError);
            }
        }

        // Pass 2: render messages in order. user / assistant render
        // as bubbles; assistant tool_call blocks render as cards
        // inline with their resolved status; tool_result messages
        // are absorbed into the cards painted by pass 1's lookup
        // and intentionally skipped here.
        for (const m of data.messages) {
            if (m.role === 'user') {
                const text = (m.blocks || [])
                    .filter(b => b.kind === 'text')
                    .map(b => b.text || '')
                    .join('');
                if (text.length > 0) appendUserMessage(text);
            } else if (m.role === 'assistant') {
                appendFinalizedAssistantMessage(m.blocks || [], 'assistant');
                for (const b of m.blocks || []) {
                    if (b.kind === 'tool_call' && b.id) {
                        const isErr = toolStatus.get(b.id) === true;
                        appendFinalizedToolCard(b.id, b.name || 'tool', isErr);
                    }
                }
            }
            // toolResult, custom — skipped
        }
        // Page just loaded / session just switched — land at the
        // bottom (newest message) regardless of saved scroll state.
        scrollToBottom(true);
    }

    // v1.7.7 — load prompt history before connecting; it's
    // localStorage-only so this is synchronous + instant.
    loadHistory();

    // One-shot fetch at boot — role is bound at session init
    // server-side and never changes for the proxy's lifetime.
    async function loadRole() {
        const el = document.getElementById('role-pill');
        const mEl = document.getElementById('model-pill');
        if (!el) return;
        try {
            const r = await fetch('/role');
            if (!r.ok) {
                el.textContent = 'role: ?';
                if (mEl) mEl.textContent = 'model: ?';
                return;
            }
            const data = await r.json();
            const role = data.role || 'plan';
            const provider = data.provider || '?';
            const model = data.model || '?';
            el.textContent = 'role: ' + role + (data.sandbox ? ' · sandboxed' : '');
            el.title = (data.description || role) + ' — allowed: ' +
                ((data.allowed_tools || []).join(', ') || '(none)');
            el.classList.remove(
                'role-pill-read', 'role-pill-plan', 'role-pill-code', 'role-pill-full');
            el.classList.add('role-pill-' + role);
            if (mEl) {
                mEl.textContent = provider + ':' + model;
                mEl.title = 'provider: ' + provider + ' · model: ' + model;
            }
        } catch (_) {
            el.textContent = 'role: ?';
            if (mEl) mEl.textContent = 'model: ?';
        }
    }

    // `/session` resolves activeSessionId, which loadSessions +
    // rehydrate both depend on. loadRole is independent — fire
    // it in parallel with the dependent pair to overlap the
    // round-trips.
    (async function () {
        try {
            const r = await fetch('/session');
            if (r.ok) {
                const data = await r.json();
                if (data && data.id) activeSessionId = data.id;
                if (data && data.persisted === false) sessionsPersisted = false;
            }
        } catch (_) { /* ignore */ }
        await Promise.all([loadRole(), loadSessions(), rehydrate()]);
        connect();
    })();
})();
