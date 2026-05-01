local config = require("code-assist.config")
local session = require("code-assist.session")
local ghost = require("code-assist.ghost")
local agent = require("code-assist.agent")

local M = {}

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("CodeAssist", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "BufLeave" }, {
    group = group,
    callback = function(ev)
      local sb = session.current_bufnr()
      if sb and ev.buf == sb and session.is_active() then
        session.cancel("buffer/cursor changed")
      end
      local gb = ghost.active_bufnr()
      if gb and ev.buf == gb and (ev.event == "TextChanged" or ev.event == "TextChangedI" or ev.event == "BufLeave") then
        ghost.dismiss()
      end
    end,
  })
end

local function setup_commands()
  vim.api.nvim_create_user_command("CodeAssistComplete", function() M.complete() end, {})
  vim.api.nvim_create_user_command("CodeAssistCancel", function() M.cancel() end, {})
  vim.api.nvim_create_user_command("CodeAssistAccept", function() M.accept() end, {})
  vim.api.nvim_create_user_command("CodeAssistDismiss", function() M.dismiss() end, {})
  vim.api.nvim_create_user_command("CodeAssistFindAgent", function()
    agent.invalidate_cache()
    agent.find_agent({}, function(found, err)
      if err then
        vim.notify("code-assist: " .. err, vim.log.levels.ERROR)
      else
        vim.notify("code-assist: " .. found.kind .. " at " .. found.target .. " (pid " .. tostring(found.pid) .. ")")
      end
    end)
  end, {})
end

function M.setup(opts)
  config.merge(opts or {})
  setup_autocmds()
  setup_commands()
  if config.options.keymap then
    vim.keymap.set({ "n", "i", "v", "s" }, config.options.keymap, function() M.complete() end,
      { silent = true, desc = "code-assist: complete at cursor" })
  end
end

function M.complete()
  session.start(config.options)
end

function M.cancel()
  session.cancel("user requested")
  ghost.dismiss()
end

function M.accept()
  return ghost.accept()
end

function M.dismiss()
  return ghost.dismiss()
end

return M
