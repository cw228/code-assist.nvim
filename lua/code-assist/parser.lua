local util = require("code-assist.util")

local M = {}

local BOX_DRAWING = "[│┃║▏▎▍▌▋▊▉█┌┐└┘├┤┬┴┼─━═╭╮╰╯╔╗╚╝╠╣╦╩╬]"

local function find_last(s, pattern, plain)
  local last_start, last_end
  local pos = 1
  while true do
    local a, b = s:find(pattern, pos, plain)
    if not a then break end
    last_start, last_end = a, b
    pos = b + 1
  end
  return last_start, last_end
end

local function find_last_before(s, pattern, before, plain)
  local last_start, last_end
  local pos = 1
  while true do
    local a, b = s:find(pattern, pos, plain)
    if not a or a >= before then break end
    last_start, last_end = a, b
    pos = b + 1
  end
  return last_start, last_end
end

local function fuzzy_marker_pattern(marker)
  local parts = {}
  for ch in marker:gmatch(".") do
    parts[#parts + 1] = vim.pesc(ch)
  end
  return table.concat(parts, "%s?")
end

local function is_pure_box_or_blank(line)
  if line:match("^%s*$") then return true end
  local stripped = line:gsub("%s", ""):gsub(BOX_DRAWING, "")
  return stripped == ""
end

local function trim_blank_edges(lines)
  while #lines > 0 and lines[1]:match("^%s*$") do table.remove(lines, 1) end
  while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end
  return lines
end

local function leading_ws_len(s, max)
  local n = 0
  local limit = max or #s
  for i = 1, math.min(limit, #s) do
    local c = s:sub(i, i)
    if c == " " or c == "\t" then
      n = i
    else
      break
    end
  end
  return n
end

local function strip_ui_offset(lines, ui_offset)
  if ui_offset <= 0 then return lines end
  for i, l in ipairs(lines) do
    local strip_n = leading_ws_len(l, ui_offset)
    lines[i] = l:sub(strip_n + 1)
  end
  return lines
end

local function strip_fences(lines)
  if #lines >= 2 and lines[1]:match("^%s*```") and lines[#lines]:match("^%s*```%s*$") then
    table.remove(lines, 1)
    table.remove(lines)
  end
  return lines
end

function M.extract(capture, begin_marker, end_marker)
  local cleaned = util.strip_ansi(capture)

  local end_a = find_last(cleaned, end_marker, true)
  if not end_a then
    end_a = find_last(cleaned, fuzzy_marker_pattern(end_marker), false)
  end
  if not end_a then return nil, "end marker not found" end

  local _, begin_b = find_last_before(cleaned, begin_marker, end_a, true)
  if not begin_b then
    _, begin_b = find_last_before(cleaned, fuzzy_marker_pattern(begin_marker), end_a, false)
  end
  if not begin_b then return nil, "begin marker not found before end marker" end

  local line_start = end_a
  while line_start > 1 and cleaned:sub(line_start - 1, line_start - 1) ~= "\n" do
    line_start = line_start - 1
  end
  local end_prefix = cleaned:sub(line_start, end_a - 1)
  local ui_offset = (end_prefix:match("^[ \t]+$") and #end_prefix) or 0

  local body = cleaned:sub(begin_b + 1, end_a - 1)
  if body:sub(1, 1) == "\n" then body = body:sub(2) end
  if body:sub(-1) == "\n" then body = body:sub(1, -2) end

  local lines = vim.split(body, "\n", { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = (l:gsub("[ \t]+$", ""))
  end

  local kept = {}
  for _, l in ipairs(lines) do
    if not is_pure_box_or_blank(l) or l:match("^%s*$") then
      kept[#kept + 1] = l
    end
  end

  kept = trim_blank_edges(kept)
  kept = strip_fences(kept)
  kept = trim_blank_edges(kept)
  kept = strip_ui_offset(kept, ui_offset)

  if #kept == 0 then return "", nil end

  return table.concat(kept, "\n"), nil
end

return M
