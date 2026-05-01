local tmux = require("code-assist.tmux")
local agent = require("code-assist.agent")
local prompt = require("code-assist.prompt")
local mcp = require("code-assist.mcp")
local ghost = require("code-assist.ghost")
local util = require("code-assist.util")

local M = {}

local STATE = { idle = "idle", submitting = "submitting", waiting = "waiting", done = "done", cancelled = "cancelled" }

local current = nil

local function stop_timeout(s)
  if s.timeout_timer then
    pcall(function() s.timeout_timer:stop() end)
    pcall(function() s.timeout_timer:close() end)
    s.timeout_timer = nil
  end
end

local function transition(s, new_state)
  s.state = new_state
end

local function buffer_unchanged(s)
  if not vim.api.nvim_buf_is_valid(s.bufnr) then return false end
  local tick = vim.api.nvim_buf_get_changedtick(s.bufnr)
  if tick ~= s.changedtick then return false end
  return true
end

function M.is_active()
  return current ~= nil and current.state ~= STATE.done and current.state ~= STATE.cancelled
end

function M.cancel(reason)
  if not current then return end
  local s = current
  current = nil
  stop_timeout(s)
  transition(s, STATE.cancelled)
  mcp.cancel(s.nonce)
  if s.cfg.tmux.cancel_remote and s.target then
    tmux.send_ctrl_c(s.target, function() end)
  end
  ghost.dismiss()
  util.log(s.cfg, "cancelled:", reason or "(no reason)")
end

local function on_done_with_text(s, text)
  if s ~= current then return end
  if not buffer_unchanged(s) then
    util.log(s.cfg, "discarding completion: buffer changed")
    transition(s, STATE.done)
    current = nil
    return
  end
  transition(s, STATE.done)
  current = nil
  if text == nil or text == "" then
    util.notify("agent returned an empty completion", vim.log.levels.INFO)
    return
  end
  ghost.show(s.bufnr, s.cursor[1] - 1, s.cursor[2], text, s.cfg)
end

local function on_failure(s, msg, level)
  if s ~= current then return end
  current = nil
  stop_timeout(s)
  transition(s, STATE.done)
  ghost.dismiss()
  util.notify(msg, level or vim.log.levels.WARN)
end

function M.start(cfg)
  if M.is_active() then
    M.cancel("superseded")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

  local p = prompt.build(bufnr, cursor)
  if not p.has_file then
    util.notify("buffer has no file path; save it first", vim.log.levels.WARN)
    return
  end

  local s = {
    cfg = cfg,
    state = STATE.submitting,
    bufnr = bufnr,
    cursor = cursor,
    changedtick = changedtick,
    nonce = p.nonce,
    trigger_text = p.trigger_text,
    payload = p.payload,
    started_at = vim.uv.now(),
  }
  current = s

  ghost.show_pending(bufnr, cursor[1] - 1, cursor[2], cfg)

  mcp.submit(s.nonce, s.payload,
    function(text)
      if s ~= current then return end
      stop_timeout(s)
      on_done_with_text(s, text)
    end,
    function(err)
      if s ~= current then return end
      on_failure(s, "code-assist server: " .. err, vim.log.levels.ERROR)
    end
  )

  agent.find_agent({}, function(found, err)
    if s ~= current then return end
    if err or not found then
      on_failure(s, err or "no agent found", vim.log.levels.ERROR)
      mcp.cancel(s.nonce)
      return
    end
    s.target = found.target
    s.agent_kind = found.kind
    util.log(cfg, "found agent", found.kind, "at", found.target)

    tmux.paste(found.target, cfg.tmux.paste_buffer, s.trigger_text, function(ok, perr)
      if s ~= current then return end
      if not ok then
        on_failure(s, "paste failed: " .. (perr or ""), vim.log.levels.ERROR)
        mcp.cancel(s.nonce)
        return
      end
      tmux.send_enter(found.target, function(eok, eerr)
        if s ~= current then return end
        if not eok then
          on_failure(s, "send-enter failed: " .. (eerr or ""), vim.log.levels.ERROR)
          mcp.cancel(s.nonce)
          return
        end
        transition(s, STATE.waiting)
        s.timeout_timer = vim.uv.new_timer()
        s.timeout_timer:start(cfg.request.timeout_ms, 0, vim.schedule_wrap(function()
          if s ~= current or s.state == STATE.cancelled then return end
          mcp.cancel(s.nonce)
          on_failure(s,
            "timed out waiting for agent reply (" .. cfg.request.timeout_ms .. "ms)",
            vim.log.levels.WARN)
        end))
      end)
    end)
  end)
end

function M.current_bufnr()
  return current and current.bufnr or nil
end

return M
