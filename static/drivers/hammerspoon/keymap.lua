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

local DEBUG = true

-- Configuration: délai (secondes) utilisé pour les vérifications de timing
local EXPAND_TIMEOUT = 0.8

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

-- Return first UTF-8 character and the remainder
local function utf8_first_char(s)
  local ok, offs = pcall(utf8.offset, s, 2)
  if ok and offs then
    return s:sub(1, offs - 1), s:sub(offs)
  end
  return s, ""
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
local next_reset_at = 0

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
local function perform_replace(matchKey, text, had_star, override_del, available_before)
  local delCount
  if override_del then
    -- Use the provided pre-change available deletion count when present;
    -- otherwise fall back to computing from current state. This avoids
    -- relying on `token` after it was updated by set_token_from_text.
    local max_del = available_before or (utf8_len(token) + ((last_separator_char ~= nil) and 1 or 0))
    if override_del > max_del then
      delCount = max_del
    else
      delCount = override_del
    end
  else
    delCount = utf8_len(matchKey)
    -- If the trigger does not require a trailing star, delete one fewer
    -- character, except when the first character of the trigger is a
    -- separator/punctuation (in which case delete the full trigger so
    -- the separator doesn't remain).
    if not had_star then
      local first_char = utf8_first_char(matchKey)
      if not (separators[first_char] or first_char:match("%p")) then
        delCount = delCount - 1
      end
    end
    -- Don't delete more characters than were actually typed (token + possibly
    -- a remembered leading separator). This prevents over-deleting when the
    -- matchKey includes characters that aren't present at the cursor.
    local max_del = utf8_len(token) + ((last_separator_char ~= nil) and 1 or 0)
    if delCount > max_del then delCount = max_del end
  end

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
  local now = hs.timer.secondsSinceEpoch()
  -- Reset token state after inactivity so the first typed word behaves
  -- like it just started (fixes missing expansions right after reload).
  if now > next_reset_at then
    token = ""
    token_timestamps = {}
    last_separator_char = nil
  end
  local flags = e:getFlags()

  -- Backspace: remove last UTF-8 char from token
  if keyCode == 51 then
    token = utf8_remove_last(token)
    if #token_timestamps > 0 then table.remove(token_timestamps) end
    if token == "" then last_separator_char = nil end
    next_reset_at = now + 1.5
    return false
  end

  local chars = e:getCharacters(true)
  -- If Alt/AltGr is held, try the alternate characters API to get the
  -- actual produced character (e.g. '+' instead of base 'p'). Use this
  -- only when it returns something different.
  if flags.alt then
    local altchars = e:getCharacters(false)
    if altchars and altchars ~= "" and altchars ~= chars then
      chars = altchars
    end
  end
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
        local first_char, rest = utf8_first_char(m.key)
        local body = m.key
        local has_leading_sep = separators[first_char] or (first_char:match("%p") ~= nil)
        if has_leading_sep then body = rest end
        if m.mid then
          -- Mid-word: trigger matches suffix of token
          if #m.key > 0 and token:sub(-#m.key) == m.key then
            -- require last char typed within 500ms
            local now = hs.timer.secondsSinceEpoch()
            local last_ts = token_timestamps[#token_timestamps] or 0
            if now - last_ts <= EXPAND_TIMEOUT then
              if DEBUG then hs.printf("keymap: mid '%s' -> '%s'", m.key, m.repl) end
              local prefix = token:sub(1, #token - #m.key)
              local delKey = m.key
              local match_len = utf8_len(delKey)
              if not m.requires_star then
                if not (separators[first_char] or first_char:match("%p")) then
                  match_len = math.max(0, match_len - 1)
                end
              end
              local available_before = utf8_len(token) + ((last_separator_char ~= nil) and 1 or 0)
              set_token_from_text(prefix .. m.repl)
              perform_replace(delKey, m.repl, m.requires_star, match_len, available_before)
              return true
            end
          end
        else
          -- Start-only: the whole token must equal the key
          if token == m.key then
            local now = hs.timer.secondsSinceEpoch()
            local last_ts = token_timestamps[#token_timestamps] or 0
            if now - last_ts <= EXPAND_TIMEOUT then
              if DEBUG then hs.printf("keymap: start '%s' -> '%s'", m.key, m.repl) end
              local delKey = m.key
              local match_len = utf8_len(delKey)
              if not m.requires_star then
                if not (separators[first_char] or first_char:match("%p")) then
                  match_len = math.max(0, match_len - 1)
                end
              end
              local available_before = utf8_len(token) + ((last_separator_char ~= nil) and 1 or 0)
              set_token_from_text(m.repl)
              perform_replace(delKey, m.repl, m.requires_star, match_len, available_before)
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
    -- If modifier keys are held (AltGr, Alt, Ctrl, Cmd, Fn), let the
    -- event through so AltGr+<sep> (or modified separators) produce
    -- the expected character and do not trigger hotstring expansion.
    local flags = e:getFlags()
    local had_modifier = flags.alt or flags.ctrl or flags.cmd or flags.fn
    -- Do NOT bail early when modifier keys are held: allow matching logic
    -- to run so sequences typed with AltGr (e.g. AltGr+p then AltGr+') can
    -- still trigger mappings like "+?". If no mapping matches, we'll
    -- fall through and let the character through as usual.
    -- Before resetting, check for mappings that include the separator
    -- as the last character (e.g. "p'"). We simulate the token as if
    -- the separator were appended and reuse the timing checks.
    local sep = chars
    local now = hs.timer.secondsSinceEpoch()
    for _, m in ipairs(mappings) do
      if not m.requires_star then
        local first_char, rest = utf8_first_char(m.key)
        local body = m.key
        local has_leading_sep = separators[first_char] or (first_char:match("%p") ~= nil)
        if has_leading_sep then body = rest end
        local body_len = utf8_len(body)

        -- Only consider mappings where the body actually ends with this separator
        if body_len > 0 and utf8_sub_tail(body, 1) == sep then
          if m.mid then
            -- For mid mappings, require the token (before sep) to end with
            -- the body without its final separator character.
            local body_without_last = utf8_remove_last(body)
            local needed = utf8_len(body_without_last)
            if needed == 0 or utf8_sub_tail(token, needed) == body_without_last then
              -- timing: simulate timestamps with `now` appended
              local temp_ts = {}
              for i = 1, #token_timestamps do table.insert(temp_ts, token_timestamps[i]) end
              table.insert(temp_ts, now)
              local idx_last = #temp_ts
              local key_len = body_len
              local ok_time = false
              if idx_last >= 1 then
                if key_len >= 2 then
                  local prev_idx = idx_last - 1
                  if prev_idx >= 1 then
                    ok_time = (temp_ts[idx_last] - temp_ts[prev_idx]) <= EXPAND_TIMEOUT
                  end
                else
                  if idx_last >= 2 then
                    ok_time = (temp_ts[idx_last] - temp_ts[idx_last - 1]) <= EXPAND_TIMEOUT
                  else
                    ok_time = (hs.timer.secondsSinceEpoch() - temp_ts[idx_last]) <= EXPAND_TIMEOUT
                  end
                end
              end
              if ok_time and (not has_leading_sep or last_separator_char == first_char) then
                if DEBUG then hs.printf("keymap: sep-mid '%s' -> '%s'", m.key, m.repl) end
                local prefix = token:sub(1, #token - needed)
                -- Compute deletion length: characters actually typed before the
                -- separator (body_without_last) plus a remembered leading
                -- separator if present.
                local del_len = needed
                if has_leading_sep and last_separator_char == first_char then del_len = del_len + 1 end
                local available_before = utf8_len(token) + ((last_separator_char ~= nil) and 1 or 0)
                set_token_from_text(prefix .. m.repl)
                perform_replace(m.key, m.repl, m.requires_star, del_len, available_before)
                last_separator_char = nil
                return true
              end
            end
          else
            -- Start-only: token + sep must equal the body
            if token .. sep == body then
              -- simulate timestamps
              local temp_ts = {}
              for i = 1, #token_timestamps do table.insert(temp_ts, token_timestamps[i]) end
              table.insert(temp_ts, now)
              local idx_last = #temp_ts
              local key_len = body_len
              local ok_time = false
              if idx_last >= 1 then
                if key_len >= 2 then
                  local prev_idx = idx_last - 1
                  if prev_idx >= 1 then
                    ok_time = (temp_ts[idx_last] - temp_ts[prev_idx]) <= EXPAND_TIMEOUT
                  end
                else
                  if idx_last >= 2 then
                    ok_time = (temp_ts[idx_last] - temp_ts[idx_last - 1]) <= EXPAND_TIMEOUT
                  else
                    ok_time = (hs.timer.secondsSinceEpoch() - temp_ts[idx_last]) <= EXPAND_TIMEOUT
                  end
                end
              end
              if ok_time and (not has_leading_sep or last_separator_char == first_char) then
                if DEBUG then hs.printf("keymap: sep-start '%s' -> '%s'", m.key, m.repl) end
                -- For a start-only mapping triggered by a separator, delete
                -- only the characters that were present before the separator
                -- (i.e. body without its trailing separator), plus any
                -- remembered leading separator.
                local body_without_last = utf8_remove_last(body)
                local del_len = utf8_len(body_without_last)
                if has_leading_sep and last_separator_char == first_char then del_len = del_len + 1 end
                local available_before = utf8_len(token) + ((last_separator_char ~= nil) and 1 or 0)
                set_token_from_text(m.repl)
                perform_replace(m.key, m.repl, m.requires_star, del_len, available_before)
                last_separator_char = nil
                return true
              end
            end
          end
        end
      end
    end

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
      local first_char, rest = utf8_first_char(m.key)
      local body = m.key
      -- Treat explicit separators and punctuation as a leading separator
      local has_leading_sep = separators[first_char] or (first_char:match("%p") ~= nil)
      if has_leading_sep then body = rest end
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
                ok_time = (token_timestamps[idx_last] - token_timestamps[prev_idx]) <= EXPAND_TIMEOUT
              end
            else
              if idx_last >= 2 then
                ok_time = (token_timestamps[idx_last] - token_timestamps[idx_last - 1]) <= EXPAND_TIMEOUT
              else
                ok_time = (hs.timer.secondsSinceEpoch() - token_timestamps[idx_last]) <= EXPAND_TIMEOUT
              end
            end
          end
            if ok_time then
            local leading_ok = (not has_leading_sep) or (last_separator_char == first_char)
            if not leading_ok and has_leading_sep then
              local needed = body_len + utf8_len(first_char)
              if DEBUG then hs.printf("keymap: check leading token='%s' first='%s' body='%s' needed=%d tail='%s'", token, first_char, body, needed, utf8_sub_tail(token, needed)) end
              if utf8_sub_tail(token, needed) == first_char .. body then leading_ok = true end
            end
            if leading_ok then
              if DEBUG then hs.printf("keymap: mid '%s' -> '%s'", m.key, m.repl) end
              local prefix = token:sub(1, #token - #body)
              local delKey = m.key
              local match_len = utf8_len(delKey)
              if not m.requires_star then
                if not (separators[first_char] or first_char:match("%p")) then
                  match_len = math.max(0, match_len - 1)
                end
              end
              local available_before = utf8_len(token) + ((last_separator_char ~= nil) and 1 or 0)
              set_token_from_text(prefix .. m.repl)
              perform_replace(delKey, m.repl, m.requires_star, match_len, available_before)
              last_separator_char = nil
              return true
            end
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
                ok_time = (token_timestamps[idx_last] - token_timestamps[prev_idx]) <= EXPAND_TIMEOUT
              end
            else
              if idx_last >= 2 then
                ok_time = (token_timestamps[idx_last] - token_timestamps[idx_last - 1]) <= EXPAND_TIMEOUT
              else
                ok_time = (hs.timer.secondsSinceEpoch() - token_timestamps[idx_last]) <= EXPAND_TIMEOUT
              end
            end
          end
          if ok_time and (not has_leading_sep or last_separator_char == first_char) then
            if DEBUG then hs.printf("keymap: start '%s' -> '%s'", m.key, m.repl) end
            local delKey = m.key
            local match_len = utf8_len(delKey)
            if not m.requires_star then
              if not (separators[first_char] or first_char:match("%p")) then
                match_len = math.max(0, match_len - 1)
              end
            end
            local available_before = utf8_len(token) + ((last_separator_char ~= nil) and 1 or 0)
            set_token_from_text(m.repl)
            perform_replace(delKey, m.repl, m.requires_star, match_len, available_before)
            last_separator_char = nil
            return true
          end
        end
      end
    end
  end

  next_reset_at = now + 1.5

  return false
end

tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)
tap:start()

function M.stop()
  if tap then tap:stop(); tap = nil end
end

return M
