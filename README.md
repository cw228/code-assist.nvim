# code-assist.nvim

Inline code suggestions sourced from a terminal-based coding agent (Claude Code,
Gemini CLI) running in another tmux pane.

When you press the configured keybind, the plugin submits a tiny request to a
companion **MCP server** that the agent has access to, and tmux-pastes
`/code-complete <nonce>` into the agent pane to kick it off. The agent reads
the file itself (and may use other tools — Read, Grep, Glob — for richer
context), then delivers the completion back through the MCP server. The plugin
renders the result as ghost text. `<Tab>` accepts; `<Esc>` dismisses.

The agent is allowed to use read-only tools, so completions can take into
account sibling files, types, etc. — not just the current buffer.

## Architecture

```
nvim plugin ──unix socket──► MCP server ◄──stdio MCP──► claude / gemini agent
                                                              │
                                                              ▼
                                                  /code-complete slash command
```

- **MCP server** (Python sidecar shipped with the plugin) bridges the editor
  and the agent. It exposes two MCP tools to the agent: `get_request(nonce)`
  and `deliver_completion(nonce, text)`.
- **Slash command** at `commands/code-complete.md` is the prompt the agent
  receives. It used to live as a giant inline string sent on every request;
  now it lives in `~/.claude/commands/` and the plugin only sends the nonce.

## Requirements

- Neovim 0.10+ (`vim.uv`, `vim.json`).
- `tmux` (the plugin currently requires being inside a tmux session).
- Python 3.10+ with the `mcp` package (installed once, see below).
- A running `claude` CLI in some pane on the host.

## Install

There are four pieces: the nvim plugin, the Python MCP server, the
`/code-complete` slash command, and a one-line MCP registration with Claude.

### 1. Install the nvim plugin

With **lazy.nvim**:

```lua
{
  "cw228/code-assist.nvim",
  config = function()
    require("code-assist").setup({
      -- keymap = "<C-q>", -- <C-q> is the default, works in normal & insert mode
    })
  end,
}
```

With **packer**:

```lua
use {
  "cw228/code-assist.nvim",
  config = function()
    require("code-assist").setup({})
  end,
}
```

Open nvim once so the plugin loads. This will clone the repository to your nvim data directory (e.g., `~/.local/share/nvim/lazy/code-assist.nvim` for lazy.nvim).

### 2. Install the MCP server and register with Claude

Instead of manually hunting down where your plugin manager installed the repository, the plugin provides a helper command.

Open nvim and run:

```vim
:CodeAssistInstall
```

This command will:
1. Symlink the `/code-complete` slash command into `~/.claude/commands/`.
2. Print the exact `pipx` or `uv` commands with the correct absolute path to install the MCP server.
3. Print the exact `claude mcp add` command to register the server.

Follow the instructions printed in Neovim. Once installed and registered, verify the connection:

```sh
claude mcp list
# code-assist: code-assist-mcp - ✓ Connected
```

### 3. Smoke test

In a tmux session:

- pane A: `claude` (start a Claude session)
- pane B: `nvim some_file.py`

In nvim, place the cursor where a completion would help and press your
keymap (`<leader>ai` from the example above). You should see ghost text
appear within a few seconds, with `<Tab>` to accept and `<Esc>` to dismiss.

If you see `"buffer has no file path; save it first"`, save the buffer
first — the agent needs a path to `Read`.

If nothing happens, try `:messages` in nvim and check the Claude pane for
an error from the slash command. `code-assist-mcp --log-level DEBUG` (run
manually) will show the per-request submit/cancel/deliver flow.

## Configuration

All defaults shown:

```lua
require("code-assist").setup({
  keymap = "<C-q>",                   -- e.g. "<leader>ai" or "<C-q>"; nil = don't register one
  agents = { "claude", "gemini" },              -- order = preference
  tmux = {
    paste_buffer = "code-assist",
    cancel_remote = false,            -- send C-c to agent on cancel
  },
  request = {
    timeout_ms = 30000,
  },
  mcp = {
    socket_path = nil,                -- nil = ${XDG_RUNTIME_DIR:-$TMPDIR:-/tmp}/code-assist-<uid>.sock
  },
  ghost = {
    hl = "Comment",
    accept_key = "<Tab>",
    dismiss_key = "<Esc>",
    pending_text = "inferring...",
  },
  debug = false,
})
```

## Commands

- `:CodeAssistComplete` — request a completion at cursor.
- `:CodeAssistCancel` — cancel an in-flight request and dismiss ghost text.
- `:CodeAssistAccept` / `:CodeAssistDismiss` — same as `<Tab>` / `<Esc>` while ghost text is showing.
- `:CodeAssistInstall` — symlink the slash command into `~/.claude/commands/` and print MCP install steps.
- `:CodeAssistFindAgent` — diagnostic; prints which pane was selected.

## How it works

1. **Submit:** plugin generates a nonce, opens (or reuses) a unix-socket
   connection to the MCP server, and sends a one-line JSON
   `{type:"submit", nonce, file, row, col, language}`. No buffer body.
2. **Detect agent:** `tmux list-panes -a` is parsed and matched against the
   `agents` list. Because Claude Code's pane shows `node` (not `claude`) as
   `pane_current_command`, panes that don't match by command are walked via
   `ps -A` to look for the agent in any descendant process.
3. **Trigger:** the plugin pastes `/code-complete <nonce>` into the agent
   pane via `tmux load-buffer` + `tmux paste-buffer -p` + a single `Enter`.
4. **Agent works:** the slash command tells the agent to call
   `mcp__code-assist__get_request(nonce)` to fetch the file/row/col, read
   the file (and any sibling files it wants), then call
   `mcp__code-assist__deliver_completion(nonce, text)`.
5. **Render:** the MCP server pushes the delivery back over the unix socket;
   the plugin places an extmark with `virt_text` (first line) +
   `virt_lines` (rest) at the cursor and binds `<Tab>` / `<Esc>` until the
   ghost text is dismissed.

## Known limits

- **Tmux required** for the kick. Outside tmux you'll get a clean error.
- **Agent could touch files.** The slash command says "do not edit". If you
  care, run the agent without `--dangerously-skip-permissions` so any
  Edit/Write call requires approval — `Read`/`Grep`/`Glob` are the only
  tools the prompt actually wants used.
- **One in-flight request at a time.** Triggering again or moving the
  cursor cancels the prior request.
- **First match wins.** If multiple agents are running, the plugin prefers
  the pane whose `pane_current_path` matches Neovim's cwd, then the order
  in `agents`. There's no disambiguation UI.
- **macOS / Linux only.** No Windows support.
- **Buffer must have a file path.** Unsaved/unnamed buffers are rejected so
  the agent has something to `Read`.

## Debugging

- Set `debug = true` in `setup()` for plugin-side `:messages` logs.
- Run the MCP server manually with `code-assist-mcp --log-level DEBUG` (or
  `python3 mcp-server/code_assist_mcp.py --log-level DEBUG`) to see
  per-request submit/cancel/deliver activity on stderr.
