# code-assist.nvim

Inline code suggestions sourced from a terminal-based coding agent (Claude Code or
gemini-cli) running in another tmux pane.

When you press the configured keybind, the plugin finds an active agent pane,
pastes a sentinel-wrapped completion prompt into it, polls the pane until the
reply arrives, then renders the result as ghost text under your cursor.
`<Tab>` accepts; `<Esc>` dismisses.

## Requirements

- Neovim 0.10+ (`vim.system`, `vim.uv`).
- `tmux` (the plugin currently requires being inside a tmux session).
- A running `claude` or `gemini` CLI in some pane on the host.

## Install (lazy.nvim)

```lua
{
  dir = "/path/to/nvim-code-assist", -- or "owner/nvim-code-assist" if published
  config = function()
    require("code-assist").setup({
      keymap = "<leader>ai",
    })
  end,
}
```

## Configuration

All defaults shown:

```lua
require("code-assist").setup({
  keymap = nil,                       -- e.g. "<leader>ai"; nil = don't register one
  agents = { "claude", "gemini" },    -- order = preference

  tmux = {
    capture_lines = 4000,
    paste_buffer = "code-assist",
    cancel_remote = false,            -- send C-c to agent on cancel
  },

  poll = {
    interval_ms = 250,
    timeout_ms = 30000,
    settle_ms = 400,                  -- re-capture this long after seeing END marker
  },

  context = {
    max_bytes = 32 * 1024,            -- send full buffer if under this; else windowed
    lines_before = 200,
    lines_after = 80,
    cursor_token = "<CURSOR/>",
  },

  ghost = {
    hl = "Comment",
    accept_key = "<Tab>",
    dismiss_key = "<Esc>",
  },

  debug = false,                      -- write prompt + capture dumps to stdpath('cache')/code-assist/
})
```

## Commands

- `:CodeAssistComplete` — request a completion at cursor.
- `:CodeAssistCancel` — cancel an in-flight request and dismiss ghost text.
- `:CodeAssistAccept` / `:CodeAssistDismiss` — same as `<Tab>` / `<Esc>` while ghost text is showing.
- `:CodeAssistFindAgent` — diagnostic; prints which pane was selected.

## How it works

1. **Detect agent:** `tmux list-panes -a` is parsed and matched against the
   `agents` list. Because Claude Code's pane shows `node` (not `claude`) as
   `pane_current_command`, panes that don't match by command are walked via
   `ps -A` to look for the agent in any descendant process.
2. **Send prompt:** the prompt is sent into the agent pane via
   `tmux load-buffer -` (stdin) + `tmux paste-buffer -p` (bracketed) + a single
   `Enter`. Bracketed paste is what triggers Claude Code's
   "[Pasted N lines]" indicator so a single `Enter` submits cleanly.
3. **Poll for reply:** `tmux capture-pane -p -J -S -<N>` is polled every
   `poll.interval_ms` until the END sentinel appears (or the timeout fires).
   `-J` joins wrapped lines so a wide marker doesn't get sliced.
4. **Parse:** ANSI sequences are stripped, pure-decoration lines are dropped,
   the body between sentinels is sliced, and the agent UI's per-line
   whitespace prefix (detected from the indent in front of the END marker)
   is removed. The agent's absolute indentation is preserved; on render the
   first line is then aligned with the cursor's column.
5. **Render:** an extmark with `virt_text` (first line) + `virt_lines` (rest)
   is placed at the cursor; buffer-local mappings for `<Tab>` and `<Esc>` are
   set while the ghost text is visible and removed once it isn't.

## Known limits

- **Tmux required.** Outside tmux you'll get a clean error.
- **Agent could still touch your files.** The prompt explicitly forbids tool
  use, but compliance isn't guaranteed. Don't run the agent with
  `--dangerously-skip-permissions` if you care.
- **One in-flight request at a time.** Triggering again or moving the cursor
  cancels the prior request.
- **First match wins.** If multiple agents are running, the plugin prefers the
  pane whose `pane_current_path` matches Neovim's cwd, then the order in
  `agents`. There's no disambiguation UI.
- **macOS / Linux only.** No Windows support.

## Debugging

Set `debug = true` and look under `stdpath('cache') .. '/code-assist/'` for
per-request dumps:

- `<nonce>-prompt.txt` — the exact prompt sent to the agent.
- `<nonce>-ok.log` — the captured pane content used for parsing on success.
- `<nonce>-parse-fail.log` / `<nonce>-timeout.log` — captures on failure.
