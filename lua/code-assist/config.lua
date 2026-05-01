local M = {}

M.defaults = {
  keymap = nil,
  agents = { "claude" },
  tmux = {
    paste_buffer = "code-assist",
    cancel_remote = false,
  },
  request = {
    timeout_ms = 30000,
  },
  mcp = {
    socket_path = nil,             -- nil = ${XDG_RUNTIME_DIR:-$TMPDIR:-/tmp}/code-assist-<uid>.sock
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
