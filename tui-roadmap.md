# TUI roadmap

Tracks UX/UI work on the interactive-mode REPL (`franky --mode
interactive`). Numbering below maps 1:1 to the original roadmap;
status reflects the code in `src/coding/modes/interactive.zig` +
`src/tui/*`.

## Original roadmap — status

| # | Item | Status | Shipped in |
|---|---|---|---|
| 1 | Typing while the model is thinking | ✅ | v1.1.0 |
| 2 | Slash / command interface | ✅ | v1.1 roadmap (v1.1.1–v1.1.3, v1.5.3), palette hint + Tab completion (v1.5.5) |
| 3 | Conversation history — scroll through past interactions | ✅ | v1.1.1 (PgUp/PgDn, End, auto-snap) |
| 4 | Model selection + configuration | ✅ | v1.1.3 (`/model <id>` live swap), `/thinking <level>` (v1.5.3) |
| 5 | Real-time token usage + response times (low priority) | ✅ | v1.1.4 (`(12s · in 8421 + out 512 tokens)`) |
| 6 | Scrollable + searchable history | ✅ | v1.1.1 (scroll) + v1.1.2 (Ctrl-F/Ctrl-S incremental search) |
| 7 | Multi-line output + scroll through past interactions | ✅ | v1.1.1 (virtual scroll region, per-line styles in v1.2.0) |

## v1.2.0 TUI polish v2 — shipped (research-driven quick wins)

Seven findings from the v1.2.0 UX/UI research pass (lazygit, k9s,
fzf, charm/bubbletea, Textual, aider, claude-code).

| QW | Feature | Shipped |
|---|---|---|
| QW1 | Ctrl-F alongside Ctrl-S (Ctrl-S collides with XON/XOFF flow control) | v1.2.0 |
| QW2 | `NO_COLOR` env-var respect via `Style.neutralize` | v1.2.0 |
| QW3 | Placeholder hint in empty editor (`Type a message or /help`) | v1.2.0 |
| QW4+5 | Semantic red + `✗` glyph for error lines in scrollback | v1.2.0 |
| QW6 | `?` help overlay (full-screen modal, two-column) | v1.2.0 |
| QW7 | Unread-below badge (`↓ N new ↓`) when scrolled away | v1.2.0 |

## Research findings — 10 TUI UX/UI design areas

Referenced during the v1.2.0 audit. Each section captures the
de-facto pattern across modern chat/dev TUIs (aider, claude-code,
lazygit, k9s, fzf, charm/bubbletea, Textual) so future roadmap
decisions can point at it.

1. **Input affordances.** Bottom-anchored input region with a
   prominent prompt glyph + dim placeholder that clears on
   keystroke. Multi-line via `\` continuation (aider) or
   **Alt-Enter** (claude-code, gemini-cli) — Shift-Enter is
   terminal-dependent and unreliable. Bracketed paste is the
   default. Reference: Textual `Input.placeholder`, charm/bubbles
   `textarea`.

2. **Progress + streaming feedback.** Spinners tick on a decoupled
   ~10 Hz clock, never driven by token arrival. Repaint is
   **throttled** (60–100 ms debounce) — this is what separates
   "fast-feeling" from "janky." Reference: bubbles/spinner,
   claude-code's `✦ Thinking…` throttle, aider's word-boundary
   repaint, Textual reactive attributes.

3. **Scrollback + history UX.** Two schools. Terminal-native
   (aider CLI mode): write lines sequentially, let the user's
   terminal own scrollback — cheap, `Ctrl-click` links work. Alt-
   screen + virtual scroll (k9s, lazygit, Textual, our current
   model): app owns the region; `PgUp`/`PgDn`/`g`/`G` jump; a
   `● N new ↓` badge appears when scrolled away and new content
   arrived. Auto-follow disengages on upward scroll, re-engages
   on `G`/`End`. Reference: Textual `RichLog`, bubbles `viewport`.

4. **Search + navigation.** **Ctrl-F is the emerging default**
   for forward incremental search (Textual, lazygit `/`, k9s
   `/`). **Ctrl-S is avoided** because it's XON/XOFF flow-control
   on many terminals. Incremental-as-you-type with dim highlight
   on all matches + reverse-video on the current match is the
   less/fzf/lazygit convention. `n`/`N` for next/prev (vim
   lineage); `Esc` cancels and restores scroll position.

5. **Status bar / footer conventions.** One-line footer, left-
   aligned = app state (mode, model), right-aligned = ephemeral
   state (tokens, elapsed, branch). Separator ` · ` or `│`.
   **Dim** (code 2) for metadata, **bold** for the current mode,
   **reverse-video** reserved for key hints (`^C quit`). Nerd
   Font glyphs avoided — most TUIs default to ASCII because
   fonts aren't universal. Reference: lazygit, k9s, bubbles
   `statusbar`, Textual `Footer`.

6. **Color + theming.** Respect `NO_COLOR=1` (no-color.org,
   adopted by bat, fd, fzf, delta, charm `lipgloss`). Use
   16-color ANSI names (not RGB) so user themes apply. Semantic
   palette: red=error, yellow=warn, cyan/blue=info, dim-grey=
   metadata, green=success. WCAG AA contrast (4.5:1) against
   likely backgrounds. Colorblind-safe: never rely on red/green
   alone — pair with `✗`/`✓` glyphs.

7. **Slash/command palette UX.** Two discoverability paths
   coexist. **Typing `/` in the input** opens an inline
   fuzzy-filtered dropdown (claude-code, Discord, Slack). **A
   dedicated keybinding** (`Ctrl-P`/`Ctrl-Shift-P` in VS Code,
   `?` in lazygit) opens a full-screen modal palette. fzf-style
   fuzzy match (not prefix), up/down navigation, Enter executes,
   Esc dismisses. Reference: Textual `CommandPalette`,
   charmbracelet/huh, junegunn/fzf `--preview`.

8. **Error / confirm / modal patterns.** Errors render **inline**
   in the transcript with a red prefix (`✗ Error: …`) — not as a
   modal, so the flow stays intact (aider, claude-code).
   Destructive confirms use a centered modal with `[y/N]`
   defaulting to safe. Two-key confirm (`dd` vim, `X` twice in
   k9s) is used for common destructive ops. Never block streaming
   for a confirm — queue the tool call.

9. **Copy-to-clipboard + text selection.** Two strategies. **Don't
   capture the mouse** — users `Shift`-drag to select natively
   (aider, claude-code default, fzf). **OSC 52** (`\e]52;c;<b64>\a`)
   for programmatic copy without mouse — works through SSH/tmux,
   supported by iTerm2, WezTerm, kitty, Alacritty, tmux. Bracketed
   paste prevents pasted content triggering keybindings.

10. **Keybinding discoverability.** `?` opens a help overlay —
    universal convention (k9s, lazygit, tig, fzf, Textual
    `Footer`). Persistent one-line footer showing 4–6 most-
    relevant bindings is the lazygit/k9s pattern. Contextual help
    (bindings change when palette is open) beats a static cheat
    sheet. Reference: bubbles/help, Textual bindings system.

## Three non-obvious findings (worth flagging)

- **Shift-Enter is a trap.** Terminals can't reliably distinguish
  it from plain Enter; Alt-Enter or `\` + newline is what ships
  in practice. See charmbracelet/bubbles#303, neovim #17035.

- **Render throttling matters more than streaming speed.** A
  60–100 ms repaint debounce is cheap and transforms the feel.
  Textual perf docs + aider v0.40 changelog both call this out.

- **OSC 52 quietly replaced xclip/pbcopy.** Modern TUIs copy
  through SSH without platform-specific shell-outs. Worth
  adopting even in Zig where clipboard libs are immature.

## Post-v1.2 candidates

Concrete next-step items surfaced by the research. Ordered by
(impact × ease).

### Candidates — medium effort

| Candidate | Rationale |
|---|---|
| **Alt-Enter multi-line** as primary (keep Shift-Enter as best-effort fallback) | Closes the "Shift-Enter is a trap" finding; matches claude-code / gemini-cli |
| **Render throttling** — gate `renderer.render` calls to a ~60 ms minimum interval regardless of event arrival rate | Research's "single most impactful polish" — cheap and big payoff on long transcripts |
| **OSC 52 clipboard** — `y` in scroll mode yanks the current line; `/copy` slash dumps the transcript; bracketed-paste already enabled | Works through SSH/tmux without platform shims; idiomatic for remote coding sessions |
| **Full command palette** via `Ctrl-P` — fuzzy-filtered modal with command + description + keybinding hint | Complements the inline `/` hint for users who don't remember command names |
| **Different styles for "all matches" vs "current match"** in search | Matches less/fzf/lazygit convention; currently all matches use the same reverse-video |

### Candidates — larger effort

| Candidate | Rationale |
|---|---|
| **Two-key confirm** for destructive slash commands (`/clear` → `/clear` again within 3s commits) | vim/k9s convention; avoids accidental transcript loss |
| **Theme layer** — adaptive light/dark palettes, wired to the existing `--theme <name>` flag (currently a no-op) | Spec'd but never shipped; one-time lift that unlocks user customization |
| **Right-aligned status** — pack `model · elapsed · tokens` right-aligned, key hints left-aligned | lazygit/k9s pattern; denser info without visual noise |
| **Spinner glyph** on `thinking…` — rotating dots decoupled from token arrival | Cosmetic but signals "working" under low-token-rate conditions |
