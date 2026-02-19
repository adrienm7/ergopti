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

  -- Unicode-aware case mapping for common Latin accented characters.
  local UNICODE_UPPER = {
    ['à'] = 'À', ['â'] = 'Â', ['ä'] = 'Ä', ['á'] = 'Á', ['ã'] = 'Ã', ['å'] = 'Å',
    ['ç'] = 'Ç', ['è'] = 'È', ['é'] = 'É', ['ê'] = 'Ê', ['ë'] = 'Ë',
    ['ì'] = 'Ì', ['í'] = 'Í', ['î'] = 'Î', ['ï'] = 'Ï',
    ['ò'] = 'Ò', ['ó'] = 'Ó', ['ô'] = 'Ô', ['ö'] = 'Ö', ['õ'] = 'Õ',
    ['ù'] = 'Ù', ['ú'] = 'Ú', ['û'] = 'Û', ['ü'] = 'Ü', ['ÿ'] = 'Ÿ',
    ['ñ'] = 'Ñ'
  }
  local UNICODE_LOWER = {}
  for k, v in pairs(UNICODE_UPPER) do UNICODE_LOWER[v] = k end

  local function unicode_upper_char(c)
    if UNICODE_UPPER[c] then return UNICODE_UPPER[c] end
    return string.upper(c)
  end

  local function unicode_lower_char(c)
    if UNICODE_LOWER[c] then return UNICODE_LOWER[c] end
    return string.lower(c)
  end

  local function unicode_map_str(s, map)
    if not s or s == "" then return s end
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
      local b = s:byte(i)
      local char
      if b >= 240 then
        char = s:sub(i, i+3); i = i + 4
      elseif b >= 224 then
        char = s:sub(i, i+2); i = i + 3
      elseif b >= 192 then
        char = s:sub(i, i+1); i = i + 2
      else
        char = s:sub(i, i); i = i + 1
      end
      table.insert(out, map(char) )
    end
    return table.concat(out)
  end

  local function unicode_upper_str(s) return unicode_map_str(s, unicode_upper_char) end
  local function unicode_lower_str(s) return unicode_map_str(s, unicode_lower_char) end

  local function capitalize_first(s)
    local first, rest = split_first_char(s)
    return unicode_upper_str(first) .. unicode_lower_str(rest)
  end

  -- Remember whether the original trigger ended with a star
  local had_star = false
  do
    local ok, offs = pcall(utf8.offset, trigger, -1)
    if ok and offs then
      local last = trigger:sub(offs)
      if STAR_CHARS[last] then had_star = true end
    end
  end

  local lowerKey = string.lower(key)
  local capKey   = capitalize_first(lowerKey)
  local upperKey = string.upper(key)

  -- If the trigger starts with a comma, make the "Cap" variant start with
  -- a semicolon instead of a comma (e.g. ",f" -> ";F"). Preserve the
  -- capitalization semantics for the remainder of the key.
  do
    local first_char, rest = split_first_char(lowerKey)
    if first_char == ',' then
      capKey = ';' .. capitalize_first(rest)
    end
  end

  local lowerRepl = unicode_lower_str(replacement)
  local capRepl   = capitalize_first(replacement)
  local upperRepl = unicode_upper_str(replacement)

  local function mapping_exists(k, mid, req_star)
    for _, m in ipairs(mappings) do
      if m.key == k and m.mid == mid and m.requires_star == req_star then return true end
    end
    return false
  end

  local function insert_mapping(k, repl, mid)
    if not mapping_exists(k, mid, had_star) then
      table.insert(mappings, { trigger = k, key = k, repl = repl, mid = mid, requires_star = had_star })
    end
  end

  -- Insert three variants: all-lower, FirstCap, ALLCAPS
  insert_mapping(lowerKey, lowerRepl, allow_mid)
  insert_mapping(capKey,   capRepl,   allow_mid)
  insert_mapping(upperKey, upperRepl, allow_mid)

  -- If trigger starts with a comma, also create semicolon-prefixed
  -- variants so that `;f` produces the Cap replacement and `;F`
  -- produces the UPPER replacement.
  do
    local first_char, rest = split_first_char(lowerKey)
    if first_char == ',' and rest ~= '' then
      insert_mapping(';' .. rest, capRepl, allow_mid)
      insert_mapping(';' .. string.upper(rest), upperRepl, allow_mid)
    end
  end

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
local token_timestamps = {} -- per-character timestamps (seconds)

local separators = {
  [' '] = true, ['\t'] = true, ['\n'] = true,
  [','] = true, ['.'] = true,  [';'] = true, [':'] = true,
  ['!'] = true, ['?'] = true,  ['('] = true, [')'] = true,
  ['['] = true, [']'] = true,  ['{'] = true, ['}'] = true,
  ['"'] = true, ["'"] = true,  ['-'] = true,
}

local tap
local replacing = false   -- true while we are emitting synthetic events
local last_separator_char = nil -- most recent separator typed (if any)

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

local function set_token_from_text(text)
  token = token_after_text(text)
  token_timestamps = {}
  local now = hs.timer.secondsSinceEpoch()
  local count = utf8_len(token)
  for i = 1, count do table.insert(token_timestamps, now) end
  last_separator_char = nil
end

-- Return the last `n` UTF-8 characters of `s` (as a string)
local function utf8_sub_tail(s, n)
  if n == 0 then return "" end
  local ok, offs = pcall(utf8.offset, s, -n)
  if ok and offs then
    return s:sub(offs)
  end
  -- Fallback: naive byte-scan backwards
  local i = #s
  local cnt = 0
  while i > 0 and cnt < n do
    local b = s:byte(i)
    while i > 1 and b >= 128 and b < 192 do
      i = i - 1
      b = s:byte(i)
    end
    cnt = cnt + 1
    if cnt < n then i = i - 1 end
  end
  if i < 1 then return s end
  return s:sub(i)
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
local function perform_replace(matchKey, text, had_star)
  local delCount = utf8_len(matchKey)
  -- If the trigger does not require a trailing star, we used to delete
  -- one fewer character. However for triggers that start with a
  -- separator (e.g. ";f"), we must delete the entire trigger so the
  -- separator does not remain. Detect the first UTF-8 character and
  -- only subtract 1 when that first character is NOT a separator.
  if not had_star then delCount = delCount - 1 end
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
    if #token_timestamps > 0 then table.remove(token_timestamps) end
    if token == "" then last_separator_char = nil end
    return false
  end

  local chars = e:getCharacters(true)
  if not chars or #chars == 0 then return false end

  if DEBUG then hs.printf("keymap: char='%s' token='%s'", chars, token) end

  -- ── Star trigger: attempt expansion only for mappings that require the star ─
  if STAR_CHARS[chars] then
    -- If modifier keys are held (AltGr, Alt, Ctrl, Cmd, Fn), let the event
    -- through so AltGr+* (or modified stars) produce the expected character.
    local flags = e:getFlags()
    if flags.alt or flags.ctrl or flags.cmd or flags.fn then
      return false
    end

    for _, m in ipairs(mappings) do
      if m.requires_star then
        if m.mid then
          -- Mid-word: trigger matches suffix of token
          if #m.key > 0 and token:sub(-#m.key) == m.key then
            -- require last char typed within 500ms
            local now = hs.timer.secondsSinceEpoch()
            local last_ts = token_timestamps[#token_timestamps] or 0
            if now - last_ts <= 0.5 then
              if DEBUG then hs.printf("keymap: mid '%s' -> '%s'", m.key, m.repl) end
              local prefix = token:sub(1, #token - #m.key)
              set_token_from_text(prefix .. m.repl)
              perform_replace(m.key, m.repl, m.requires_star)
              return true
            end
          end
        else
          -- Start-only: the whole token must equal the key
          if token == m.key then
            local now = hs.timer.secondsSinceEpoch()
            local last_ts = token_timestamps[#token_timestamps] or 0
            if now - last_ts <= 0.5 then
              if DEBUG then hs.printf("keymap: start '%s' -> '%s'", m.key, m.repl) end
              set_token_from_text(m.repl)
              perform_replace(m.key, m.repl, m.requires_star)
              return true
            end
          end
        end
      end
    end
    -- No match: if token is empty (e.g. user typed a separator like space
    -- just before the star), let the star through. Otherwise swallow it
    -- and reset token state.
    if token == "" then
      token = ""
      token_timestamps = {}
      return false
    end
    token = ""
    token_timestamps = {}
    return true
  end

  -- ── Separator: remember it and reset token ───────────────────────────
  if separators[chars] then
    last_separator_char = chars
    token = ""
    token_timestamps = {}
    return false
  end

  -- ── Regular character: append to token and attempt immediate expansion
  token = token .. chars
  table.insert(token_timestamps, hs.timer.secondsSinceEpoch())

  -- Attempt expansion immediately after each typed character for mappings
  -- that do NOT require the trailing star.
  for _, m in ipairs(mappings) do
    if not m.requires_star then
      -- Support mappings whose first char is a separator (e.g. ",f") by
      -- treating the separator as a prefix that was typed just before the
      -- current token (tracked in last_separator_char). The `body` is the
      -- mapping without that leading separator.
      local first_char = m.key:sub(1,1)
      local body = m.key
      local has_leading_sep = separators[first_char]
      if has_leading_sep then body = m.key:sub(2) end
      local body_len = utf8_len(body)

      if m.mid then
        if body_len > 0 and utf8_sub_tail(token, body_len) == body then
          -- require the last letter timing for the body
          local idx_last = #token_timestamps
          local key_len = body_len
          local ok_time = false
          if idx_last >= 1 then
            if key_len >= 2 then
              local prev_idx = idx_last - 1
              if prev_idx >= 1 then
                ok_time = (token_timestamps[idx_last] - token_timestamps[prev_idx]) <= 0.5
              end
            else
              if idx_last >= 2 then
                ok_time = (token_timestamps[idx_last] - token_timestamps[idx_last - 1]) <= 0.5
              else
                ok_time = (hs.timer.secondsSinceEpoch() - token_timestamps[idx_last]) <= 0.5
              end
            end
          end
          if ok_time and (not has_leading_sep or last_separator_char == first_char) then
            if DEBUG then hs.printf("keymap: mid '%s' -> '%s'", m.key, m.repl) end
            local prefix = token:sub(1, #token - #body)
            set_token_from_text(prefix .. m.repl)
            perform_replace(m.key, m.repl, m.requires_star)
            last_separator_char = nil
            return true
          end
        end
      else
        if token == body then
          local idx_last = #token_timestamps
          local key_len = body_len
          local ok_time = false
          if idx_last >= 1 then
            if key_len >= 2 then
              local prev_idx = idx_last - 1
              if prev_idx >= 1 then
                ok_time = (token_timestamps[idx_last] - token_timestamps[prev_idx]) <= 0.5
              end
            else
              if idx_last >= 2 then
                ok_time = (token_timestamps[idx_last] - token_timestamps[idx_last - 1]) <= 0.5
              else
                ok_time = (hs.timer.secondsSinceEpoch() - token_timestamps[idx_last]) <= 0.5
              end
            end
          end
          if ok_time and (not has_leading_sep or last_separator_char == first_char) then
            if DEBUG then hs.printf("keymap: start '%s' -> '%s'", m.key, m.repl) end
            set_token_from_text(m.repl)
            perform_replace(m.key, m.repl, m.requires_star)
            last_separator_char = nil
            return true
          end
        end
      end
    end
  end

  return false
end

tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)
tap:start()

function M.stop()
  if tap then tap:stop(); tap = nil end
end

return M
