local tmux = require("code-assist.tmux")
local agent = require("code-assist.agent")
local prompt = require("code-assist.prompt")
local parser = require("code-assist.parser")
local ghost = require("code-assist.ghost")
local util = require("code-assist.util")

local M = {}

local STATE = { idle = "idle", sending = "sending", polling = "polling", done = "done", cancelled = "cancelled" }

local current = nil

local function stop_timer(s)
  if s.timer then
    pcall(function() s.timer:stop() end)
    pcall(function() s.timer:close() end)
    s.timer = nil
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
  stop_timer(s)
  transition(s, STATE.cancelled)
  if s.cfg.tmux.cancel_remote and s.target then
    tmux.send_ctrl_c(s.target, function() end)
  end
  ghost.dismiss()
  util.log(s.cfg, "cancelled:", reason or "(no reason)")
end

local function on_done_with_text(s, text)
  if s.state == STATE.cancelled then return end
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

local function poll_once(s)
  if s.state ~= STATE.polling then return end
  tmux.capture(s.target, s.cfg.tmux.capture_lines, function(out, err)
    if s.state ~= STATE.polling then return end
    if err then
      M.cancel("capture failed: " .. err)
      util.notify("capture failed: " .. err, vim.log.levels.ERROR)
      return
    end

    local now = vim.uv.now()
    if (now - s.started_at) >= s.cfg.poll.timeout_ms then
      util.dump(s.cfg, s.nonce .. "-timeout.log", out or "")
      M.cancel("timeout")
      util.notify("timed out waiting for agent reply (" .. s.cfg.poll.timeout_ms .. "ms)", vim.log.levels.WARN)
      return
    end

    if out and out:find(s.end_marker, 1, true) then
      transition(s, STATE.done)
      stop_timer(s)
      vim.defer_fn(function()
        tmux.capture(s.target, s.cfg.tmux.capture_lines, function(final_out, ferr)
          if ferr or not final_out then
            local text, perr = parser.extract(out, s.begin_marker, s.end_marker)
            if perr then util.dump(s.cfg, s.nonce .. "-parse-fail.log", out) end
            on_done_with_text(s, text)
            return
          end
          local text, perr = parser.extract(final_out, s.begin_marker, s.end_marker)
          if perr then
            util.dump(s.cfg, s.nonce .. "-parse-fail.log", final_out)
            util.notify("could not parse agent reply: " .. perr, vim.log.levels.WARN)
            on_done_with_text(s, "")
            return
          end
          util.dump(s.cfg, s.nonce .. "-ok.log", final_out)
          on_done_with_text(s, text)
        end)
      end, s.cfg.poll.settle_ms)
      return
    end

    if s.timer then
      s.timer:start(s.cfg.poll.interval_ms, 0, vim.schedule_wrap(function()
        poll_once(s)
      end))
    end
  end)
end

function M.start(cfg)
  if M.is_active() then
    M.cancel("superseded")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

  local p = prompt.build(bufnr, cursor, cfg)

  local s = {
    cfg = cfg,
    state = STATE.sending,
    bufnr = bufnr,
    cursor = cursor,
    changedtick = changedtick,
    nonce = p.nonce,
    begin_marker = p.begin_marker,
    end_marker = p.end_marker,
    prompt_text = p.text,
    started_at = vim.uv.now(),
  }
  current = s

  util.dump(cfg, p.nonce .. "-prompt.txt", p.text)

  agent.find_agent({}, function(found, err)
    if s.state == STATE.cancelled then return end
    if err or not found then
      M.cancel("no agent: " .. (err or "unknown"))
      util.notify(err or "no agent found", vim.log.levels.ERROR)
      return
    end
    s.target = found.target
    s.agent_kind = found.kind
    util.log(cfg, "found agent", found.kind, "at", found.target)

    tmux.paste(found.target, cfg.tmux.paste_buffer, p.text, function(ok, perr)
      if s.state == STATE.cancelled then return end
      if not ok then
        M.cancel("paste failed: " .. (perr or ""))
        util.notify("paste failed: " .. (perr or ""), vim.log.levels.ERROR)
        return
      end
      tmux.send_enter(found.target, function(eok, eerr)
        if s.state == STATE.cancelled then return end
        if not eok then
          M.cancel("send-enter failed: " .. (eerr or ""))
          util.notify("send-enter failed: " .. (eerr or ""), vim.log.levels.ERROR)
          return
        end
        transition(s, STATE.polling)
        s.started_at = vim.uv.now()
        s.timer = vim.uv.new_timer()
        s.timer:start(cfg.poll.interval_ms, 0, vim.schedule_wrap(function()
          poll_once(s)
        end))
      end)
    end)
  end)
end

function M.current_bufnr()
  return current and current.bufnr or nil
end

return M
