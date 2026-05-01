local M = {}

local pipe = nil
local connected = false
local connecting = false
local connect_queue = {}        -- functions(err) to run once connect resolves
local pending = {}              -- nonce -> { on_delivery, on_error }
local read_buffer = ""

local function default_socket_path()
  local base = vim.env.XDG_RUNTIME_DIR or vim.env.TMPDIR or "/tmp"
  base = base:gsub("/+$", "")
  return base .. "/code-assist-" .. tostring(vim.uv.getuid()) .. ".sock"
end

local function configured_socket_path()
  local cfg = require("code-assist.config").options
  if cfg.mcp and cfg.mcp.socket_path and cfg.mcp.socket_path ~= "" then
    return cfg.mcp.socket_path
  end
  return default_socket_path()
end

local function fire_pending_errors(reason)
  if not reason then return end
  local snapshot = pending
  pending = {}
  vim.schedule(function()
    for _, cb in pairs(snapshot) do
      if cb.on_error then cb.on_error(reason) end
    end
  end)
end

local function close_pipe(reason)
  connected = false
  connecting = false
  if pipe then
    pcall(function() pipe:read_stop() end)
    pcall(function() pipe:close() end)
    pipe = nil
  end
  read_buffer = ""
  fire_pending_errors(reason)
end

local function process_line(line)
  if line == "" then return end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then return end
  local nonce = msg.nonce
  local cb = nonce and pending[nonce] or nil
  if not cb then return end
  pending[nonce] = nil
  vim.schedule(function()
    if msg.type == "delivery" then
      if cb.on_delivery then cb.on_delivery(msg.text or "") end
    elseif msg.type == "error" then
      if cb.on_error then cb.on_error(msg.message or "server error") end
    end
  end)
end

local function on_read(err, chunk)
  if err then
    close_pipe("read: " .. err)
    return
  end
  if chunk == nil then
    close_pipe("server disconnected")
    return
  end
  read_buffer = read_buffer .. chunk
  while true do
    local nl = read_buffer:find("\n", 1, true)
    if not nl then break end
    local line = read_buffer:sub(1, nl - 1)
    read_buffer = read_buffer:sub(nl + 1)
    process_line(line)
  end
end

local function ensure_connected(callback)
  if connected and pipe then
    callback(nil)
    return
  end
  table.insert(connect_queue, callback)
  if connecting then return end
  connecting = true

  local p = vim.uv.new_pipe(false)
  pipe = p
  local path = configured_socket_path()

  p:connect(path, function(err)
    if err then
      pipe = nil
      connecting = false
      connected = false
      local q = connect_queue
      connect_queue = {}
      local reason = "connect " .. path .. ": " .. err
      vim.schedule(function()
        for _, cb in ipairs(q) do cb(reason) end
      end)
      return
    end
    connected = true
    connecting = false
    p:read_start(on_read)
    local q = connect_queue
    connect_queue = {}
    vim.schedule(function()
      for _, cb in ipairs(q) do cb(nil) end
    end)
  end)
end

local function send(line, on_done)
  ensure_connected(function(err)
    if err then
      on_done(err)
      return
    end
    local p = pipe
    if not p then
      on_done("pipe closed")
      return
    end
    p:write(line, function(werr)
      vim.schedule(function() on_done(werr) end)
    end)
  end)
end

function M.submit(nonce, payload, on_delivery, on_error)
  pending[nonce] = { on_delivery = on_delivery, on_error = on_error }
  local msg = vim.tbl_extend("force", { type = "submit", nonce = nonce }, payload)
  send(vim.json.encode(msg) .. "\n", function(err)
    if err then
      pending[nonce] = nil
      if on_error then
        vim.schedule(function() on_error(err) end)
      end
    end
  end)
end

function M.cancel(nonce)
  pending[nonce] = nil
  local msg = { type = "cancel", nonce = nonce }
  send(vim.json.encode(msg) .. "\n", function() end)
end

function M.disconnect()
  close_pipe(nil)
end

function M.socket_path()
  return configured_socket_path()
end

return M
