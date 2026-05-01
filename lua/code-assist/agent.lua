local tmux = require("code-assist.tmux")
local util = require("code-assist.util")

local M = {}

local cache = { at = 0, result = nil }
local CACHE_TTL_MS = 2000

local function classify(cmdline, agents)
  for _, name in ipairs(agents) do
    local n = vim.pesc(name)
    if cmdline:match("^" .. n .. "$")
      or cmdline:match("^" .. n .. "%s")
      or cmdline:match("/" .. n .. "$")
      or cmdline:match("/" .. n .. "%s")
      or cmdline:match("node%s+[^%s]*/" .. n .. "$")
      or cmdline:match("node%s+[^%s]*/" .. n .. "%s")
    then
      return name
    end
  end
  return nil
end

local function build_pid_tree(ps_stdout)
  local children_of = {}
  local cmd_of = {}
  for line in (ps_stdout or ""):gmatch("[^\n]+") do
    local p, pp, cmd = line:match("^%s*(%d+)%s+(%d+)%s+(.+)$")
    if p then
      p = tonumber(p)
      pp = tonumber(pp)
      cmd_of[p] = cmd
      children_of[pp] = children_of[pp] or {}
      table.insert(children_of[pp], p)
    end
  end
  return children_of, cmd_of
end

local function descendant_cmds(root_pid, children_of, cmd_of)
  local out = {}
  local stack = { root_pid }
  local seen = {}
  while #stack > 0 do
    local cur = table.remove(stack)
    if not seen[cur] then
      seen[cur] = true
      if cmd_of[cur] then table.insert(out, cmd_of[cur]) end
      for _, c in ipairs(children_of[cur] or {}) do
        table.insert(stack, c)
      end
    end
  end
  return out
end

function M.invalidate_cache()
  cache.at = 0
  cache.result = nil
end

local function rank_and_pick(matches, agents, cwd)
  table.sort(matches, function(a, b)
    local a_cwd = a.pane.cwd == cwd
    local b_cwd = b.pane.cwd == cwd
    if a_cwd ~= b_cwd then return a_cwd end
    local order_a, order_b = 99, 99
    for i, name in ipairs(agents) do
      if a.kind == name then order_a = i end
      if b.kind == name then order_b = i end
    end
    return order_a < order_b
  end)
  local pick = matches[1]
  return {
    target = pick.pane.target,
    kind = pick.kind,
    pid = pick.pane.pid,
    cwd = pick.pane.cwd,
    label = pick.pane.label,
  }
end

function M.find_agent(opts, on_done)
  opts = opts or {}
  local cfg = require("code-assist.config").options
  local agents = opts.agents or cfg.agents
  local cwd = opts.cwd or vim.fn.getcwd()

  local now = vim.uv.now()
  if cache.result and (now - cache.at) < CACHE_TTL_MS then
    on_done(cache.result, nil)
    return
  end

  if not tmux.available() then
    on_done(nil, "tmux not available (TMUX env not set or tmux missing)")
    return
  end

  tmux.list_panes(function(panes, err)
    if err then
      on_done(nil, err)
      return
    end
    if not panes or #panes == 0 then
      on_done(nil, "no tmux panes found")
      return
    end

    local matches = {}
    local needs_walk = {}
    for _, p in ipairs(panes) do
      local kind = classify(p.cmd, agents)
      if kind then
        table.insert(matches, { pane = p, kind = kind })
      else
        table.insert(needs_walk, p)
      end
    end

    local function finish()
      if #matches == 0 then
        on_done(nil, "no claude/gemini pane found in any tmux session")
        return
      end
      local result = rank_and_pick(matches, agents, cwd)
      cache.at = vim.uv.now()
      cache.result = result
      on_done(result, nil)
    end

    if #needs_walk == 0 then
      finish()
      return
    end

    util.system({ "ps", "-A", "-o", "pid=,ppid=,command=" }, {}, function(out)
      if out.code == 0 then
        local children_of, cmd_of = build_pid_tree(out.stdout)
        for _, p in ipairs(needs_walk) do
          for _, c in ipairs(descendant_cmds(p.pid, children_of, cmd_of)) do
            local kind = classify(c, agents)
            if kind then
              table.insert(matches, { pane = p, kind = kind })
              break
            end
          end
        end
      end
      finish()
    end)
  end)
end

return M
