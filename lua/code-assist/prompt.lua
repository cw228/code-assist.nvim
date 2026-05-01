local util = require("code-assist.util")

local M = {}

local function buffer_filepath(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  return name
end

function M.build(bufnr, cursor)
  local row = cursor[1] - 1
  local col = cursor[2]

  local file = buffer_filepath(bufnr)
  local language = vim.bo[bufnr].filetype
  if language == "" then language = "text" end

  local nonce = util.nonce()

  return {
    nonce = nonce,
    trigger_text = "/code-complete " .. nonce,
    payload = {
      file = file or "",
      row = row,
      col = col,
      language = language,
    },
    has_file = file ~= nil,
  }
end

return M
