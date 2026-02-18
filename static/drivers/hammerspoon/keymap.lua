-- keymap.lua
-- Simple hotstrings implementation for Hammerspoon
--
-- Bugs fixed vs previous version:
--   1. perform_replace used usleep (blocking ~1s total) causing garbled output
--   2. keyStroke({}, 'delete') used default 200ms delay per backspace
--   3. `chars` was referenced before being defined (emitted-char suppression never worked)
--   4. #m.key (byte length) was used as backspace count — wrong for multi-byte UTF-8
--   5. Backspace in token removed last byte, not last UTF-8 character
--   6. STAR_CHARS was defined twice
--   7. Sort didn't prioritise start-only over mid-word for same-length keys

local eventtap = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke = hs.eventtap.keyStroke

local M = {}

local mappings = {}

local DEBUG = false

-- Accept both the star character and the asterisk key as trigger
local STAR_CHARS = { ["★"] = true, ["*"] = true }

local utf8 = utf8

---------------------------------------------------------------------------
-- UTF-8 helpers
---------------------------------------------------------------------------

-- Count the number of UTF-8 characters (code points) in a string
local function utf8_len(s)
  local count = 0
  local i = 1
  local n = #s
  while i <= n do
    local b = s:byte(i)
    if     b >= 240 then i = i + 4
    elseif b >= 224 then i = i + 3
    elseif b >= 192 then i = i + 2
    else                  i = i + 1 end
    count = count + 1
  end
  return count
end

-- Remove the last UTF-8 character from a string
local function utf8_remove_last(s)
  if #s == 0 then return s end
  local ok, offs = pcall(utf8.offset, s, -1)
  if ok and offs then
    return s:sub(1, offs - 1)
  end
  -- Fallback: scan backwards for the start of the last UTF-8 sequence
  local i = #s
  while i > 1 and s:byte(i) >= 128 and s:byte(i) < 192 do
    i = i - 1
  end
  if i > 1 then return s:sub(1, i - 1) else return "" end
end

-- Strip trailing star char if present (UTF-8 aware)
local function strip_star(s)
  local ok, offs = pcall(utf8.offset, s, -1)
  if ok and offs then
    local last = s:sub(offs)
    if STAR_CHARS[last] then
      return s:sub(1, offs - 1)
    end
  end
  if s:sub(-1) == "*" then
    return s:sub(1, -2)
  end
  return s
end

---------------------------------------------------------------------------
-- M.add — register a hotstring (with automatic lower / Cap / UPPER variants)
---------------------------------------------------------------------------

function M.add(trigger, replacement, mode)
  local key = strip_star(trigger)
  local allow_mid = (mode == true or mode == 'mid')

  local function split_first_char(s)
    local ok, second = pcall(utf8.offset, s, 2)
    if ok and second then
      return s:sub(1, second - 1), s:sub(second)
    else
      return s, ""
    end
  end

  local function capitalize_first(s)
    local first, rest = split_first_char(s)
    return string.upper(first) .. string.lower(rest)
  end

  -- Determine original star char (if any) to re-append to generated triggers
  local star_char = ""
  do
    local ok, offs = pcall(utf8.offset, trigger, -1)
    if ok and offs then
      local last = trigger:sub(offs)
      if STAR_CHARS[last] then star_char = last end
    end
  end

  local lowerKey = string.lower(key)
  local capKey   = capitalize_first(lowerKey)
  local upperKey = string.upper(key)

  local lowerRepl = string.lower(replacement)
  local capRepl   = capitalize_first(replacement)
  local upperRepl = string.upper(replacement)

  local function mapping_exists(k, mid)
    for _, m in ipairs(mappings) do
      if m.key == k and m.mid == mid then return true end
    end
    return false
  end

  local function insert_mapping(k, repl, mid)
    if not mapping_exists(k, mid) then
      table.insert(mappings, { trigger = k .. star_char, key = k, repl = repl, mid = mid })
    end
  end

  -- Insert three variants: all-lower, FirstCap, ALLCAPS
  insert_mapping(lowerKey, lowerRepl, allow_mid)
  insert_mapping(capKey,   capRepl,   allow_mid)
  insert_mapping(upperKey, upperRepl, allow_mid)

  -- Sort: longest key first; for same length, start-only before mid-word
  table.sort(mappings, function(a, b)
    if #a.key ~= #b.key then return #a.key > #b.key end
    if a.mid ~= b.mid then return not a.mid end
    return false
  end)
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local token = "" -- characters since last separator

local separators = {
  [' '] = true, ['\t'] = true, ['\n'] = true,
  [','] = true, ['.'] = true,  [';'] = true, [':'] = true,
  ['!'] = true, ['?'] = true,  ['('] = true, [')'] = true,
  ['['] = true, [']'] = true,  ['{'] = true, ['}'] = true,
  ['"'] = true, ["'"] = true,  ['-'] = true,
}

local tap
local replacing = false   -- true while we are emitting synthetic events

---------------------------------------------------------------------------
-- After replacement text is inserted, compute the token as the part after
-- the last separator inside that text (so that subsequent expansions work).
---------------------------------------------------------------------------
local function token_after_text(text)
  local last_sep = 0
  for i = 1, #text do
    if separators[text:sub(i, i)] then
      last_sep = i
    end
  end
  if last_sep > 0 then
    return text:sub(last_sep + 1)
  end
  return text
end

---------------------------------------------------------------------------
-- perform_replace — delete the trigger and type the replacement.
--
-- Strategy:
--   1. Stop the event tap so our synthetic keystrokes don't re-enter onKeyDown.
--   2. Send backspaces (with 0 delay) to delete the trigger characters.
--   3. Send the replacement text via keyStrokes.
--   4. Restart the tap after a short timer (10 ms) so the system event queue
--      has time to drain the synthetic events before the tap sees new ones.
---------------------------------------------------------------------------
local function perform_replace(matchKey, text)
  local delCount = utf8_len(matchKey)
  replacing = true
  if tap then tap:stop() end

  for i = 1, delCount do
    keyStroke({}, 'delete', 0)
  end
  keyStrokes(text)

  hs.timer.doAfter(0.01, function()
    replacing = false
    if tap then tap:start() end
  end)
end

---------------------------------------------------------------------------
-- onKeyDown — main event-tap callback
---------------------------------------------------------------------------
local function onKeyDown(e)
  -- While a replacement is in flight, let everything through untouched
  if replacing then return false end

  local keyCode = e:getKeyCode()

  -- Backspace: remove last UTF-8 char from token
  if keyCode == 51 then
    token = utf8_remove_last(token)
    return false
  end

  local chars = e:getCharacters(true)
  if not chars or #chars == 0 then return false end

  if DEBUG then hs.printf("keymap: char='%s' token='%s'", chars, token) end

  -- ── Star trigger: attempt expansion ──────────────────────────────────
  if STAR_CHARS[chars] then
    for _, m in ipairs(mappings) do
      if m.mid then
        -- Mid-word: trigger matches suffix of token
        if #m.key > 0 and token:sub(-#m.key) == m.key then
          if DEBUG then hs.printf("keymap: mid '%s' -> '%s'", m.key, m.repl) end
          perform_replace(m.key, m.repl)
          local prefix = token:sub(1, #token - #m.key)
          token = token_after_text(prefix .. m.repl)
          return true
        end
      else
        -- Start-only: the whole token must equal the key
        if token == m.key then
          if DEBUG then hs.printf("keymap: start '%s' -> '%s'", m.key, m.repl) end
          perform_replace(m.key, m.repl)
          token = token_after_text(m.repl)
          return true
        end
      end
    end
    -- No match: swallow the star, reset token
    token = ""
    return true
  end

  -- ── Separator: reset token ───────────────────────────────────────────
  if separators[chars] then
    token = ""
    return false
  end

  -- ── Regular character: append to token ───────────────────────────────
  token = token .. chars
  return false
end

tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)
tap:start()

function M.stop()
  if tap then tap:stop(); tap = nil end
end

return M
