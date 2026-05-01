local util = require("code-assist.util")

local M = {}

local TEMPLATE = [[
You are a silent code-completion engine invoked from a Neovim plugin.

ABSOLUTE RULES — violating any of these breaks the integration:
1. DO NOT use any tools (no Read, Edit, Write, Bash, Grep, Glob, etc.). Reply with text only.
2. DO NOT modify, create, or delete any files on disk.
3. DO NOT explain, apologise, ask questions, or add commentary before or after.
4. DO NOT wrap your answer in Markdown fences.
5. Wrap your completion between two sentinel lines built from this format —
   substitute TOKEN with the request token shown below, leaving everything else
   unchanged. Do NOT add any other characters around the sentinels (no angle
   brackets, no quotes, no brackets, no fences):

     Begin sentinel: CA_BEGIN_TOKEN
     End sentinel:   CA_END_TOKEN

   Your token for this request is: %s

   Each sentinel must be on its own line, exactly as shown above with TOKEN
   substituted. The body between them must be only the new code to insert at
   %s — no surrounding context, no fences, no commentary.

6. Indentation: write each line of the body with the FULL leading whitespace
   it would have if it were written into the source file at column 0. Do NOT
   strip indentation thinking the cursor is already past it — the plugin
   handles aligning the first line with the cursor's column. For example, if
   the cursor sits at the start of an empty function body that needs four
   spaces of Python indentation, your first body line begins with four
   spaces, not zero.

If no useful completion is possible, emit the two sentinels with an empty body.

CONTEXT
File: %s
Language: %s

----- BEGIN BUFFER -----
%s
----- END BUFFER -----
]]

local function buffer_with_cursor(bufnr, row, col, token)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if row >= #lines then row = math.max(0, #lines - 1) end
  local line = lines[row + 1] or ""
  local before = line:sub(1, col)
  local after = line:sub(col + 1)
  lines[row + 1] = before .. token .. after
  return table.concat(lines, "\n"), lines
end

local function windowed(lines, row, before_n, after_n, token, col)
  local start = math.max(0, row - before_n)
  local stop = math.min(#lines, row + 1 + after_n)
  local slice = {}
  for i = start + 1, stop do
    slice[#slice + 1] = lines[i]
  end
  local rel = row - start
  local line = slice[rel + 1] or ""
  slice[rel + 1] = line:sub(1, col) .. token .. line:sub(col + 1)
  return table.concat(slice, "\n")
end

function M.build(bufnr, cursor, cfg)
  cfg = cfg or require("code-assist.config").options
  local row = cursor[1] - 1
  local col = cursor[2]
  local token = cfg.context.cursor_token

  local full_text, lines = buffer_with_cursor(bufnr, row, col, token)
  local body
  if #full_text <= cfg.context.max_bytes then
    body = full_text
  else
    body = windowed(lines, row, cfg.context.lines_before, cfg.context.lines_after, token, col)
  end

  local nonce = util.nonce()
  local begin_marker = "CA_BEGIN_" .. nonce
  local end_marker = "CA_END_" .. nonce

  local relpath = vim.api.nvim_buf_get_name(bufnr)
  if relpath ~= "" then
    local cwd = vim.fn.getcwd()
    if relpath:sub(1, #cwd) == cwd then
      relpath = relpath:sub(#cwd + 2)
    end
  else
    relpath = "(unnamed buffer)"
  end
  local filetype = vim.bo[bufnr].filetype
  if filetype == "" then filetype = "text" end

  local text = string.format(
    TEMPLATE,
    nonce, token,
    relpath, filetype, body
  )

  return {
    text = text,
    begin_marker = begin_marker,
    end_marker = end_marker,
    nonce = nonce,
  }
end

return M
