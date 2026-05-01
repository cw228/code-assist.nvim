local M = {}

M.defaults = {
  keymap = nil,
  agents = { "claude", "gemini" },
  tmux = {
    capture_lines = 4000,
    paste_buffer = "code-assist",
    cancel_remote = false,
  },
  poll = {
    interval_ms = 250,
    timeout_ms = 30000,
    settle_ms = 400,
  },
  context = {
    max_bytes = 32 * 1024,
    lines_before = 200,
    lines_after = 80,
    cursor_token = "<CURSOR/>",
  },
  ghost = {
    hl = "Comment",
    accept_key = "<Tab>",
    dismiss_key = "<Esc>",
    pending_text = "inferring...",
  },
  debug = false,
}

M.options = vim.deepcopy(M.defaults)

function M.merge(user)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user or {})
  return M.options
end

return M
