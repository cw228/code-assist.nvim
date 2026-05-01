local M = {}

function M.system(cmd, opts, on_exit)
  opts = opts or {}
  opts.text = opts.text ~= false
  return vim.system(cmd, opts, function(out)
    vim.schedule(function() on_exit(out) end)
  end)
end

function M.strip_ansi(s)
  s = s:gsub("\27%[[%d;?]*[%a@]", "")
  s = s:gsub("\27%][^\7]*\7", "")
  s = s:gsub("\27%][^\27]*\27\\", "")
  return s
end

function M.notify(msg, level)
  vim.schedule(function()
    vim.notify("code-assist: " .. msg, level or vim.log.levels.INFO)
  end)
end

function M.log(cfg, ...)
  if not cfg.debug then return end
  local args = { ... }
  for i, v in ipairs(args) do
    if type(v) ~= "string" then args[i] = vim.inspect(v) end
  end
  vim.schedule(function()
    vim.notify("[code-assist] " .. table.concat(args, " "), vim.log.levels.DEBUG)
  end)
end

function M.dump(cfg, name, content)
  if not cfg.debug then return end
  local dir = vim.fn.stdpath("cache") .. "/code-assist"
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name
  local f = io.open(path, "w")
  if f then
    f:write(content)
    f:close()
  end
  return path
end

function M.nonce()
  local t = vim.uv.hrtime()
  local hi = math.floor(t / 0x100000000) % 0x10000
  local lo = t % 0x100000000
  return string.format("%04x%08x", hi, lo)
end

function M.has_cmd(name)
  return vim.fn.executable(name) == 1
end

return M
