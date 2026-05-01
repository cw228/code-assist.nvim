local M = {}

local ns = vim.api.nvim_create_namespace("code_assist")

local active = nil

local function clear_keymaps(bufnr, keys)
  for _, k in ipairs(keys) do
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "i", k)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", k)
  end
end

local function set_keymaps(bufnr, accept_key, dismiss_key)
  vim.api.nvim_buf_set_keymap(bufnr, "i", accept_key, "",
    { noremap = true, silent = true, callback = function() M.accept() end })
  vim.api.nvim_buf_set_keymap(bufnr, "n", accept_key, "",
    { noremap = true, silent = true, callback = function() M.accept() end })
  vim.api.nvim_buf_set_keymap(bufnr, "i", dismiss_key, "",
    { noremap = true, silent = true, callback = function() M.dismiss() end })
end

function M.show(bufnr, row, col, text, cfg)
  M.dismiss()
  if text == nil or text == "" then
    return false
  end

  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 0 and col > 0 then
    local l = lines[1]
    local strip_n = 0
    for i = 1, math.min(col, #l) do
      local c = l:sub(i, i)
      if c == " " or c == "\t" then
        strip_n = i
      else
        break
      end
    end
    lines[1] = l:sub(strip_n + 1)
  end
  local first = lines[1] or ""
  local rest = {}
  for i = 2, #lines do rest[#rest + 1] = lines[i] end

  local virt_lines = {}
  for _, l in ipairs(rest) do
    virt_lines[#virt_lines + 1] = { { l, cfg.ghost.hl } }
  end

  local opts = {
    virt_text = { { first, cfg.ghost.hl } },
    virt_text_pos = "inline",
    hl_mode = "combine",
  }
  if #virt_lines > 0 then
    opts.virt_lines = virt_lines
  end

  local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, opts)
  if not ok then
    opts.virt_text_pos = nil
    mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, opts)
  end

  active = {
    bufnr = bufnr,
    row = row,
    col = col,
    text = text,
    lines = lines,
    mark_id = mark_id,
    accept_key = cfg.ghost.accept_key,
    dismiss_key = cfg.ghost.dismiss_key,
  }
  set_keymaps(bufnr, cfg.ghost.accept_key, cfg.ghost.dismiss_key)
  return true
end

function M.has_active()
  return active ~= nil
end

function M.accept()
  if not active then return false end
  local a = active
  active = nil
  pcall(vim.api.nvim_buf_del_extmark, a.bufnr, ns, a.mark_id)
  clear_keymaps(a.bufnr, { a.accept_key, a.dismiss_key })

  if vim.api.nvim_buf_is_valid(a.bufnr) then
    vim.api.nvim_buf_set_text(a.bufnr, a.row, a.col, a.row, a.col, a.lines)
    local last = a.lines[#a.lines] or ""
    local end_row = a.row + #a.lines - 1
    local end_col = (#a.lines == 1) and (a.col + #last) or #last
    if vim.api.nvim_get_current_buf() == a.bufnr then
      vim.api.nvim_win_set_cursor(0, { end_row + 1, end_col })
    end
  end
  return true
end

function M.dismiss()
  if not active then return false end
  local a = active
  active = nil
  pcall(vim.api.nvim_buf_del_extmark, a.bufnr, ns, a.mark_id)
  clear_keymaps(a.bufnr, { a.accept_key, a.dismiss_key })
  return true
end

function M.active_bufnr()
  return active and active.bufnr or nil
end

return M
