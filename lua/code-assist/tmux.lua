local util = require("code-assist.util")

local M = {}

function M.available()
  return vim.env.TMUX ~= nil and util.has_cmd("tmux")
end

local function split_tab(line)
  local out = {}
  for field in (line .. "\t"):gmatch("([^\t]*)\t") do
    out[#out + 1] = field
  end
  return out
end

function M.list_panes(on_done)
  local fmt = "#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{session_name}:#{window_index}.#{pane_index}"
  util.system({ "tmux", "list-panes", "-a", "-F", fmt }, {}, function(out)
    if out.code ~= 0 then
      on_done(nil, "tmux list-panes failed: " .. (out.stderr or ""))
      return
    end
    local panes = {}
    for line in (out.stdout or ""):gmatch("[^\n]+") do
      local f = split_tab(line)
      if #f >= 5 then
        panes[#panes + 1] = {
          target = f[1],
          pid = tonumber(f[2]),
          cmd = f[3],
          cwd = f[4],
          label = f[5],
        }
      end
    end
    on_done(panes)
  end)
end

function M.paste(target, buffer_name, text, on_done)
  local proc = util.system(
    { "tmux", "load-buffer", "-b", buffer_name, "-" },
    { stdin = text },
    function(out)
      if out.code ~= 0 then
        on_done(false, "tmux load-buffer failed: " .. (out.stderr or ""))
        return
      end
      util.system(
        { "tmux", "paste-buffer", "-b", buffer_name, "-p", "-d", "-t", target },
        {},
        function(out2)
          if out2.code ~= 0 then
            on_done(false, "tmux paste-buffer failed: " .. (out2.stderr or ""))
            return
          end
          on_done(true)
        end
      )
    end
  )
  return proc
end

function M.send_enter(target, on_done)
  util.system({ "tmux", "send-keys", "-t", target, "Enter" }, {}, function(out)
    if on_done then
      on_done(out.code == 0, out.stderr)
    end
  end)
end

function M.send_ctrl_c(target, on_done)
  util.system({ "tmux", "send-keys", "-t", target, "C-c" }, {}, function(out)
    if on_done then
      on_done(out.code == 0, out.stderr)
    end
  end)
end

return M
