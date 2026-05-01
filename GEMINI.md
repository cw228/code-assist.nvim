# CLAUDE.md

Project-specific notes for working on `code-assist.nvim`. Companion to the
user-facing `README.md` — this file is for someone *editing* the plugin, not
installing it.

## What this is

Nvim plugin that asks a terminal-based coding agent (Claude Code today,
gemini-cli later) for inline ghost-text completions. The user presses a
keybind; ghost text appears under the cursor; `<Tab>` accepts.

## Architecture (two processes, three transports)

```
nvim plugin ──unix socket──► MCP server (python) ◄──stdio MCP──► claude agent
                                                                       │
       tmux paste "/code-complete <nonce>" ──────────────────► claude pane
```

Three components:

1. **nvim plugin** (`lua/code-assist/`) — Lua. Owns ghost text and triggers
   completions.
2. **MCP server sidecar** (`mcp-server/code_assist_mcp.py`) — Python 3.10+,
   depends on `mcp`. Started by `claude mcp add code-assist -- ...` (so its
   stdin/stdout belong to the agent for MCP framing). Concurrently listens on
   a unix socket for the plugin.
3. **Slash command** (`commands/code-complete.md`) — symlinked into
   `~/.claude/commands/` by `:CodeAssistInstall`. The agent expands it on
   `/code-complete <nonce>`.

## Request flow (memorize this — every code path serves it)

1. User presses keybind. `init.lua` → `session.start(cfg)`.
2. `prompt.build` makes a nonce + payload `{file, row, col, language}`. No
   buffer body is ever sent.
3. `mcp.submit(nonce, payload, on_delivery, on_error)` opens (or reuses) the
   unix socket and sends `{"type":"submit", ...}`. The on_delivery callback
   is the only path that paints ghost text.
4. In parallel, `agent.find_agent` locates the claude pane. `tmux.paste`
   sends `/code-complete <nonce>` + Enter into it.
5. The agent's slash command tells it to call MCP tool
   `mcp__code-assist__get_request(nonce)` (returns the payload), do its own
   `Read`/`Grep`/`Glob`, and call `mcp__code-assist__deliver_completion(nonce, text)`.
6. The Python server forwards the delivery on the socket connection that
   submitted the nonce. Plugin's on_delivery fires, `ghost.show` renders.

Cancellation is symmetric: plugin sends `{"type":"cancel", "nonce"}`;
server marks the nonce so a late `deliver_completion` returns
`{ok: false, reason: "cancelled"}`. The agent does not need to know it was
cancelled.

## Key files

| File | Role |
|------|------|
| `lua/code-assist/init.lua` | setup, autocmds, user commands (`:CodeAssistComplete`, `:CodeAssistInstall`, ...) |
| `lua/code-assist/session.lua` | request lifecycle: submit → kick → wait → render/cancel/timeout |
| `lua/code-assist/mcp.lua` | unix-socket client (`vim.uv.new_pipe`, NDJSON) |
| `lua/code-assist/agent.lua` | tmux pane discovery, classify by `pane_current_command` and walk `ps -A` for descendants (claude shows up as `node`) |
| `lua/code-assist/tmux.lua` | thin wrapper around `tmux list-panes` / `load-buffer` / `paste-buffer` / `send-keys`. **No `capture-pane`** — return path is MCP, not pane scraping. |
| `lua/code-assist/prompt.lua` | builds the trigger string and payload. Trivially small now. |
| `lua/code-assist/ghost.lua` | extmark-based ghost text + buffer-local `<Tab>`/`<Esc>` mappings while it's visible. Handles first-line dedent for cursor alignment. |
| `lua/code-assist/config.lua` | defaults + deep-merge |
| `lua/code-assist/util.lua` | `vim.system` wrapper, `nonce`, `notify`, `log`, `dump` |
| `mcp-server/code_assist_mcp.py` | both transports (stdio MCP + unix socket); shared state behind a single `STATE_LOCK` |
| `commands/code-complete.md` | the slash-command prompt (the "skill") |

## Invariants and gotchas

- **Socket path parity.** Lua uses `vim.uv.getuid()`; Python uses
  `os.getuid()`. Both produce the same uid → both compute the same default
  socket path `${XDG_RUNTIME_DIR:-$TMPDIR:-/tmp}/code-assist-<uid>.sock`.
  Don't switch one side to username without switching the other.
- **`vim.uv.os_getuid` doesn't exist on all Neovim builds.** Use
  `vim.uv.getuid()` — confirmed missing on 0.11.5 darwin.
- **Stale-callback guard:** every async callback in `session.lua` starts
  with `if s ~= current then return end`. `current = nil` is the kill
  signal; both `cancel()` and `on_failure()` set it. Don't check
  `s.state == STATE.cancelled` — `on_failure` transitions to `done`, not
  `cancelled`.
- **Agent pane discovery walks the pid tree.** Claude Code's pane shows
  `node`, not `claude`, as `pane_current_command`. `agent.lua` runs
  `ps -A -o pid=,ppid=,command=`, builds a child-of map, and DFS-walks
  descendants of each pane's pid looking for `claude` / `gemini`.
- **First match wins.** Pane ranking: cwd-match first, then order in
  `agents`. There is no disambiguation UI.
- **Buffer must have a path.** `prompt.build` requires `nvim_buf_get_name`
  to be non-empty so the agent has a path to `Read`. `session.start`
  surfaces a warn-level notify and exits early otherwise.
- **No buffer body in the prompt.** If you find yourself adding one to
  `prompt.build`, you're undoing the architecture. The agent reads the
  file via the `Read` tool.
- **Server is per-claude-session.** `claude mcp add` spawns its own
  subprocess. If the user has two claude sessions, the second server's
  `is_socket_alive` check fails and it serves only stdio MCP — no editor
  bridge. Last-spawned does not steal the socket.

## Running and testing

There is no automated test suite. Everything is manual.

- **Syntax check Lua:** `for f in lua/code-assist/*.lua; do luajit -bl "$f" /dev/null > /dev/null && echo OK $f; done`
- **Syntax check Python:** `python3 -m py_compile mcp-server/code_assist_mcp.py`
- **Probe vim.uv API on the local Neovim:** `nvim --headless -c "lua print(type(vim.uv.foo))" -c "qa"`
- **Manual end-to-end:** see the "Smoke test" section in `README.md`.
- **MCP server logs:** run it directly with
  `code-assist-mcp --log-level DEBUG` (stderr) to watch
  `submit`/`cancel`/`deliver` activity.

## When making changes

- If you change the **socket protocol** (message types/fields), update both
  `mcp.lua` (`submit`, `cancel`, `process_line`) and
  `code_assist_mcp.py` (`handle_plugin_client`, `tool_deliver_completion`)
  in the same commit.
- If you add an **MCP tool**, register it in both `list_tools` and
  `call_tool` (the lowlevel `mcp` API requires both). Document it in
  `commands/code-complete.md` so the agent knows to call it.
- If you add a **config key**, default it in `config.lua`'s `M.defaults`
  and document the default in `README.md`'s `setup({...})` block.
- Don't reintroduce ANSI/sentinel parsing. The previous design used
  `tmux capture-pane` and a parser; both are gone for a reason
  (parser regressions every time the agent UI shifted).

## Deferred work

- **gemini-cli support.** Gemini's slash command + MCP story needs to be wired up. Discovery code in `agent.lua` is already gemini-aware.
