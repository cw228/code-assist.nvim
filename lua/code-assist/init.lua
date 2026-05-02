local config = require("code-assist.config")
local session = require("code-assist.session")
local ghost = require("code-assist.ghost")
local agent = require("code-assist.agent")
local mcp = require("code-assist.mcp")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  -- src = <root>/lua/code-assist/init.lua
  return vim.fn.fnamemodify(src, ":h:h:h")
end

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

local function install_command(opts)
  local root = plugin_root()
  local src = root .. "/commands/code-complete.md"
  if vim.fn.filereadable(src) == 0 then
    vim.notify("code-assist: cannot find " .. src, vim.log.levels.ERROR)
    return
  end

  local agents_to_install = {}
  if opts and opts.fargs and #opts.fargs > 0 then
    agents_to_install = opts.fargs
  else
    agents_to_install = config.options.agents
  end

  local linked_any = false
  for _, agent_name in ipairs(agents_to_install) do
    local dst_dir
    if agent_name == "claude" then
      dst_dir = vim.fn.expand("~/.claude/commands")
    elseif agent_name == "gemini" then
      dst_dir = vim.fn.expand("~/.gemini/commands")
    else
      vim.notify("code-assist: unknown agent type '" .. agent_name .. "'", vim.log.levels.WARN)
      goto continue
    end

    vim.fn.mkdir(dst_dir, "p")
    local dst = dst_dir .. "/code-complete.md"

    local existing = vim.uv.fs_lstat(dst)
    if existing then
      local link = vim.uv.fs_readlink(dst)
      if link == src then
        vim.notify("code-assist: [" .. agent_name .. "] skill already linked at " .. dst)
        linked_any = true
      else
        vim.notify(
          "code-assist: [" .. agent_name .. "] " .. dst .. " already exists (link=" .. tostring(link) .. "); " ..
          "remove it manually then re-run :CodeAssistInstall",
          vim.log.levels.WARN)
      end
    else
      local ok, err = vim.uv.fs_symlink(src, dst)
      if not ok then
        vim.notify("code-assist: [" .. agent_name .. "] failed to symlink: " .. tostring(err), vim.log.levels.ERROR)
      else
        vim.notify("code-assist: [" .. agent_name .. "] linked skill " .. src .. " -> " .. dst)
        linked_any = true
      end
    end
    ::continue::
  end

  local server_invocation
  if vim.fn.executable("code-assist-mcp") == 1 then
    server_invocation = "code-assist-mcp"
  else
    server_invocation = "python3 " .. root .. "/mcp-server/code_assist_mcp.py"
  end

  local lines = {
    "Next steps:",
    "  1. Install the MCP server (one-time):",
    "       pipx install " .. root .. "/mcp-server",
    "     or with uv:",
    "       uv tool install " .. root .. "/mcp-server",
  }

  local has_claude = false
  local has_gemini = false
  for _, a in ipairs(agents_to_install) do
    if a == "claude" then has_claude = true end
    if a == "gemini" then has_gemini = true end
  end

  if has_claude and has_gemini then
    table.insert(lines, "  2. Register it with your agents (one-time):")
    table.insert(lines, "       claude mcp add code-assist -- " .. server_invocation)
    table.insert(lines, "       gemini mcp add --scope user code-assist \"" .. server_invocation .. "\"")
    table.insert(lines, "  3. Start a Claude or Gemini session in a tmux pane and trigger a completion from nvim.")
  elseif has_claude then
    table.insert(lines, "  2. Register it with Claude (one-time):")
    table.insert(lines, "       claude mcp add code-assist -- " .. server_invocation)
    table.insert(lines, "  3. Start a Claude session in a tmux pane and trigger a completion from nvim.")
  elseif has_gemini then
    table.insert(lines, "  2. Register it with Gemini (one-time):")
    table.insert(lines, "       gemini mcp add --scope user code-assist \"" .. server_invocation .. "\"")
    table.insert(lines, "  3. Start a Gemini session in a tmux pane and trigger a completion from nvim.")
  end

  table.insert(lines, "")
  table.insert(lines, "Editor socket: " .. mcp.socket_path())

  vim.notify(table.concat(lines, "\n"))
end

local function setup_commands()
  vim.api.nvim_create_user_command("CodeAssistComplete", function() M.complete() end, {})
  vim.api.nvim_create_user_command("CodeAssistCancel", function() M.cancel() end, {})
  vim.api.nvim_create_user_command("CodeAssistAccept", function() M.accept() end, {})
  vim.api.nvim_create_user_command("CodeAssistDismiss", function() M.dismiss() end, {})
  vim.api.nvim_create_user_command("CodeAssistInstall", install_command, { nargs = "*" })
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
