-- Simplified hotstrings implementation for Hammerspoon

local eventtap = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke = hs.eventtap.keyStroke

local M = {}

-- Manage mapping groups (allow enable/disable per file)
local groups = {}
local current_group = nil
local mappings = {}
-- Hash index for O(1) duplicate detection in add_mapping_raw.
-- Key: trigger .. "\0" .. tostring(is_word) .. "\0" .. tostring(auto)
-- Value: the mapping entry table (same reference as in `mappings`).
local mappings_lookup = {}

-- Rebuild mappings_lookup from the current mappings table.
-- Called after disable_group replaces the mappings array.
local function rebuild_lookup()
    mappings_lookup = {}
    for _, m in ipairs(mappings) do
        local k = m.trigger .. "\0" .. tostring(m.is_word) .. "\0" .. tostring(m.auto)
        mappings_lookup[k] = m
    end
end

-- Sort mappings by descending trigger length, is_word priority, then seq.
-- Uses pre-cached .tlen to avoid repeated utf8.len calls.
-- Exposed as M.sort_mappings for callers that add entries outside load_toml.
local function sort_mappings()
    table.sort(mappings, function(a, b)
        if a.tlen ~= b.tlen then return a.tlen > b.tlen end
        if a.is_word ~= b.is_word then return a.is_word end
        return a.seq < b.seq
    end)
end
M.sort_mappings = sort_mappings

-- Interceptor chain: functions called on every keyDown event in registration
-- order.  Each function(event, km_buffer) may return:
--   "consume"  → keymap returns true  (event fully consumed, no hotstring check)
--   "suppress" → keymap returns false (event reaches apps, but hotstrings skipped)
--   nil / false → pass to next interceptor, then normal keymap processing
-- The chain stops at the first non-nil result.
local _interceptors = {}

-- Append fn to the interceptor chain.
function M.register_interceptor(fn)
    table.insert(_interceptors, fn)
end

local function record_group(name, path, kind)
    local seqs = {}
    for _, m in ipairs(mappings) do
        if m.group == name then table.insert(seqs, m.seq) end
    end
    groups[name] = { path = path, seqs = seqs, enabled = true, kind = kind or 'lua' }
end

function M.load_file(name, path)
    current_group = name
    dofile(path)
    current_group = nil
    record_group(name, path, 'lua')
    sort_mappings()
end

-- Load hotstring entries from a TOML file produced by generate_hotstrings.py.
-- Sections disabled via hs.settings are skipped (their entries are not loaded).
-- Stores section info (name, description, count) in the group record so that
-- the menu can display a sub-menu per section.
function M.load_toml(name, path)
    local toml_reader = require("lib.toml_reader")
    local data = toml_reader.parse(path)

    -- Register all entries under the parent group name
    current_group = name
    local total = 0
    local sections_info = {}

    for _, sec_name in ipairs(data.sections_order) do
        -- Separator entries: carry ordering info but have no hotstrings.
        if sec_name == '-' then
            table.insert(sections_info, { name = '-', description = '-', count = 0 })
            goto continue_sec
        end

        do
            local sec = data.sections[sec_name]
            if not sec then goto continue_sec end
            if sec.is_placeholder then
                -- Section listed in __Order with a description but no TOML entries:
                -- handled by a separate Lua module (e.g. personal_info).  Insert
                -- a placeholder so that the menu renders it at the right position.
                table.insert(sections_info, {
                    name                  = sec_name,
                    description           = sec.description,
                    count                 = 0,
                    is_module_placeholder = true,
                })
                goto continue_sec
            end
            local sec_enabled = M.is_section_enabled(name, sec_name)
            if sec_enabled then
                for _, entry in ipairs(sec.entries) do
                    M.add(entry.trigger, entry.output, {
                        is_word           = entry.is_word,
                        auto_expand       = entry.auto_expand,
                        is_case_sensitive = entry.is_case_sensitive,
                        final_result      = entry.final_result,
                    })
                    total = total + 1
                end
            end
            table.insert(sections_info, {
                name        = sec_name,
                description = sec.description,
                count       = #sec.entries,
            })
        end

        ::continue_sec::
    end

    current_group = nil

    -- Single sort pass after all entries have been inserted (O(N log N) once
    -- instead of O(N² log N) from sorting after every M.add call).
    sort_mappings()

    -- Build the seqs list (entries added above are now in mappings)
    local seqs = {}
    for _, m in ipairs(mappings) do
        if m.group == name then table.insert(seqs, m.seq) end
    end

    groups[name] = {
        path             = path,
        seqs             = seqs,
        enabled          = true,
        kind             = 'toml',
        meta_description = data.meta.description,
        sections         = sections_info,
    }

    print(string.format('[keymap] %s: loaded %d entries in %d sections',
        name, total, #sections_info))
end

-- ── Section-level enable / disable ──────────────────────────────────────────
-- State is persisted via hs.settings (survives reloads).
-- Key pattern: "hotstrings_section_<group>_<section>"

-- Return whether a specific section within a TOML group is enabled.
-- Default is true (absent key ≡ enabled).
function M.is_section_enabled(group_name, section_name)
    local key = "hotstrings_section_" .. group_name .. "_" .. section_name
    return hs.settings.get(key) ~= false
end

-- Rebuild the in-memory mappings for a group immediately, taking the current
-- hs.settings section flags into account (used after a section toggle).
local function reload_group_inplace(group_name)
    if not M.is_group_enabled(group_name) then return end
    -- disable_group removes all mappings for this group and marks it disabled.
    M.disable_group(group_name)
    -- enable_group calls load_toml which re-adds only the enabled sections.
    M.enable_group(group_name)
end

-- Persistently disable a section and rebuild the group immediately.
function M.disable_section(group_name, section_name)
    local key = "hotstrings_section_" .. group_name .. "_" .. section_name
    hs.settings.set(key, false)
    reload_group_inplace(group_name)
end

-- Re-enable a section (remove the persisted disabled flag) and rebuild immediately.
function M.enable_section(group_name, section_name)
    local key = "hotstrings_section_" .. group_name .. "_" .. section_name
    hs.settings.set(key, nil)
    reload_group_inplace(group_name)
end

-- Return the ordered list of sections for a TOML group, or nil for Lua groups.
-- Each element: { name, description, count }
function M.get_sections(name)
    local g = groups[name]
    if not g or not g.sections then return nil end
    return g.sections
end

-- Return the file-level description stored in [_meta] for a TOML group.
function M.get_meta_description(name)
    local g = groups[name]
    return g and g.meta_description or nil
end

-- Set the current group context for subsequent M.add() calls.
-- Pass nil to clear the context.
-- Used to register Lua-defined entries (e.g. repeat_keys) under a named group
-- so that disable_group / reload_group_inplace manage them correctly.
function M.set_group_context(name)
    current_group = name
end

-- Per-group callbacks invoked at the end of enable_group(), after load_toml /
-- load_file has run.  Used to re-register Lua-defined entries (e.g. repeat_keys)
-- that are not part of the TOML file but must live in the same group so that
-- disable_group / reload_group_inplace can remove and re-add them correctly.
local group_post_load_hooks = {}

function M.set_post_load_hook(name, fn)
    group_post_load_hooks[name] = fn
end

function M.disable_group(name)
    if not groups[name] or not groups[name].enabled then return end
    groups[name].enabled = false
    local new_mappings = {}
    for _, m in ipairs(mappings) do
        if m.group ~= name then table.insert(new_mappings, m) end
    end
    mappings = new_mappings
    rebuild_lookup()
end

-- Return whether a group is currently enabled
function M.is_group_enabled(name)
    return groups[name] and groups[name].enabled or false
end

-- Return a shallow copy of known groups and their enabled state
function M.list_groups()
    local out = {}
    for name, g in pairs(groups) do out[name] = g.enabled end
    return out
end

-- Register a pure-Lua group that has no source file.
-- Sections is an array of { name, description, count } tables.
-- Actual hotstring entries must be added by a post_load_hook so that
-- enable_group() can re-register them after a disable_group() call.
function M.register_lua_group(name, meta_description, sections)
    groups[name] = {
        path             = nil,
        seqs             = {},
        enabled          = true,
        kind             = 'lua',
        meta_description = meta_description,
        sections         = sections or {},
    }
end

function M.enable_group(name)
    local g = groups[name]
    if not g then return end
    if g.enabled then return end
    -- Pure-Lua groups have no source file: re-add entries via post_load_hook.
    if g.path == nil then
        g.enabled = true
        if group_post_load_hooks[name] then
            group_post_load_hooks[name]()
            sort_mappings()
        end
        return
    end
    -- re-load the source (Lua or TOML) to re-add mappings under the same group name
    if g.kind == 'toml' then
        M.load_toml(name, g.path)
    else
        M.load_file(name, g.path)
    end
    -- Re-run any Lua-defined entries that are not in the source file but belong
    -- to this group (e.g. repeat_keys entries registered under "magickey").
    if group_post_load_hooks[name] then
        group_post_load_hooks[name]()
        -- Re-sort because the hook appended entries after load_toml's sort.
        sort_mappings()
    end
end

---------------------------------------------------------------------------
-- Expansion terminators
---------------------------------------------------------------------------
-- Characters that trigger deferred expansion for non-auto hotstrings.
-- Each entry has a unique `key`, a list `chars` of exact byte strings or a
-- `prefix` for variable-length sequences, and a `label` for the menu.
local TERMINATOR_DEFS = {
    { key = "space",  chars  = { " " },                  label = "Espace" },
    { key = "tab",    chars  = { "\t" },                 label = "Tabulation" },
    { key = "enter",  chars  = { "\r", "\n" },           label = "Entrée" },
    { key = "period", chars  = { "." },                  label = "Point (.)" },
    { key = "comma",  chars  = { "," },                  label = "Virgule (,)" },
    { key = "nbsp",   prefix = "\194\160",               label = "Espace insécable" },
    { key = "nnbsp",  prefix = "\226\128\175",           label = "Espace fine insécable" },
    -- ★ is listed last so that any hotstring whose trigger already ends with ★
    -- (auto_expand=true, handled in the immediate path) takes precedence.
    -- consume=true: the ★ char is deleted along with the trigger and NOT re-sent
    -- (unlike space/tab/period which are preserved after the replacement).
    { key = "star",   chars  = { "★" },                  label = "Touche ★", consume = true },
}

local _terminator_enabled = {}
for _, def in ipairs(TERMINATOR_DEFS) do
    _terminator_enabled[def.key] = true
end

local function is_terminator(chars)
    for _, def in ipairs(TERMINATOR_DEFS) do
        if _terminator_enabled[def.key] then
            if def.chars then
                for _, c in ipairs(def.chars) do
                    if chars == c then return true end
                end
            elseif def.prefix then
                if chars:sub(1, #def.prefix) == def.prefix then return true end
            end
        end
    end
    return false
end

-- Return true when the terminator that matches `chars` has consume=true,
-- meaning it must be deleted along with the trigger and NOT re-emitted.
local function terminator_is_consumed(chars)
    for _, def in ipairs(TERMINATOR_DEFS) do
        if _terminator_enabled[def.key] and def.consume then
            if def.chars then
                for _, c in ipairs(def.chars) do
                    if chars == c then return true end
                end
            elseif def.prefix then
                if chars:sub(1, #def.prefix) == def.prefix then return true end
            end
        end
    end
    return false
end

--- Enable or disable a single terminator character.
function M.set_terminator_enabled(key, enabled)
    _terminator_enabled[key] = (enabled ~= false)
end

--- Return whether a terminator is currently enabled.
function M.is_terminator_enabled(key)
    return _terminator_enabled[key] ~= false
end

--- Return the full ordered list of terminator definitions (read-only).
function M.get_terminator_defs()
    return TERMINATOR_DEFS
end

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local BASE_DELAY_SEC = 0.75

--- Return the current expansion timing threshold (seconds).
function M.get_base_delay() return BASE_DELAY_SEC end

--- Set the expansion timing threshold (seconds).  Must be >= 0.
function M.set_base_delay(secs)
    BASE_DELAY_SEC = math.max(0, secs)
end

local buffer = ""
local is_replacing = false
-- Number of synthetic keydown events still pending (deletes + replacement chars).
-- is_replacing is cleared once this counter reaches zero instead of a fixed timer,
-- which eliminates the race condition that corrupted the buffer when auto-expanded
-- text was typed faster than the 10 ms timer (e.g. ,ê → ju followed by ' → jusqu').
local synthetic_remaining = 0
local last_key_time = 0
local last_key_was_complex = false
local seq_counter = 0 
local DEBUG_EXPANSION = false

---------------------------------------------------------------------------
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- UTF-8 utilities (Case & Punctuation)
---------------------------------------------------------------------------
local UPPER_LETTERS = {
    ['à']='À', ['â']='Â', ['ä']='Ä', ['é']='É', ['è']='È', ['ê']='Ê', ['ë']='Ë',
    ['î']='Î', ['ï']='Ï', ['ô']='Ô', ['ö']='Ö', ['ù']='Ù', ['û']='Û', ['ü']='Ü',
    ['ç']='Ç', ['œ']='Œ', ['æ']='Æ'
}

local LOWER_LETTERS = {}
for k, v in pairs(UPPER_LETTERS) do LOWER_LETTERS[v] = k end

-- Special symbols for uppercase variants of triggers
local UPPER_TRIGGERS = {}
for k, v in pairs(UPPER_LETTERS) do UPPER_TRIGGERS[k] = v end
UPPER_TRIGGERS["'"] = " ?" -- Espace fine insécable + ?
UPPER_TRIGGERS[","] = {" :", " ;"} -- Tableau : Espace insécable + : ET Espace fine + ;
UPPER_TRIGGERS["."] = " :" -- Espace insécable + :

-- Returns all possible uppercase trigger combinations
local function trig_upper(s)
    local results = {""}
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local map_val = UPPER_TRIGGERS[c]
        local uppers = {}
        
        if type(map_val) == "table" then
            uppers = map_val
        elseif type(map_val) == "string" then
            table.insert(uppers, map_val)
        else
            table.insert(uppers, string.upper(c))
        end
        
        local new_results = {}
        for _, res in ipairs(results) do
            for _, u in ipairs(uppers) do
                table.insert(new_results, res .. u)
            end
        end
        results = new_results
    end
    return results
end

local function trig_lower(s)
    return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return LOWER_LETTERS[c] or string.lower(c)
    end))
end

-- Returns all possible Titlecase trigger strings
local function trig_title(s)
    local first = s:match("^[%z\1-\127\194-\244][\128-\191]*")
    if not first then return {s} end
    
    local first_uppers = trig_upper(first)
    local rest = trig_lower(s:sub(#first + 1))
    
    local results = {}
    for _, fu in ipairs(first_uppers) do
        table.insert(results, fu .. rest)
    end
    return results
end

local function repl_upper(s)
    return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return UPPER_LETTERS[c] or string.upper(c)
    end))
end

local function repl_title(s)
    local first = s:match("^[%z\1-\127\194-\244][\128-\191]*")
    if not first then return s end
    return repl_upper(first) .. s:sub(#first + 1)
end

---------------------------------------------------------------------------
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Adding shortcuts (hotstrings)
---------------------------------------------------------------------------
function M.add(trigger, replacement, opts)
    -- New calling convention: M.add(trigger, replacement, {
    --   is_word = true/false,
    --   auto_expand = true/false,
    --   is_case_sensitive = true/false,
    --   final_result = true/false,  -- when true, expanded text is never re-scanned
    -- })
    opts = opts or {}
    local is_word = opts.is_word == true
    local is_auto = opts.auto_expand == true
    local is_case_sensitive = opts.is_case_sensitive == true
    local is_final = opts.final_result == true

    local function add_mapping_raw(t, r, a)
        local k = t .. "\0" .. tostring(is_word) .. "\0" .. tostring(a)
        local existing = mappings_lookup[k]
        if existing then
            if existing.repl == r then return end  -- exact duplicate, skip
            -- Same trigger with different output: last write wins.
            existing.repl = r
            if current_group then existing.group = current_group end
            return
        end
        seq_counter = seq_counter + 1
        local entry = {
            trigger      = t,
            repl         = r,
            is_word      = is_word,
            auto         = a,
            seq          = seq_counter,
            tlen         = utf8.len(t) or #t,  -- pre-cache for sort
            final_result = is_final,
        }
        if current_group then entry.group = current_group end
        table.insert(mappings, entry)
        mappings_lookup[k] = entry
    end

    local function set_spaces(str, space_char)
        str = str:gsub(" ", space_char)
        str = str:gsub(" ", space_char) 
        str = str:gsub(" ", space_char) 
        return str
    end

    local function add_mapping(t, r)
        add_mapping_raw(t, r, is_auto)
        -- Do not add space variants for triggers that start with a space character.
        -- Those come from comma-uppercase expansions (e.g. " :D" from ",d") and
        -- the leading non-breaking space is intentional; adding a regular-space
        -- variant would match unintended sequences like " :D" (colon+D smiley).
        local first_is_space = t:match("^[ \194\160\226\128\175]") ~= nil
        if not first_is_space and (t:match(" ") or t:match(" ") or t:match(" ")) then
            add_mapping_raw(set_spaces(t, " "), r, is_auto)  
            add_mapping_raw(set_spaces(t, " "), r, is_auto) 
            add_mapping_raw(set_spaces(t, " "), r, is_auto) 
        end
    end

    local base_repl = replacement
    local lower_trig = trig_lower(trigger)
    local title_repl = repl_title(base_repl)
    local upper_repl = repl_upper(base_repl)
    -- If case-sensitive, only add the trigger as provided (preserve case).
    if is_case_sensitive then
        add_mapping(trigger, base_repl)
    else
        local title_trigs = trig_title(lower_trig)
        local upper_trigs = trig_upper(lower_trig)

    -- Standard variants
        add_mapping(lower_trig, base_repl)
        
        for _, tt in ipairs(title_trigs) do
            if tt ~= lower_trig then 
                add_mapping(tt, title_repl) 
            end
        end
        
        for _, ut in ipairs(upper_trigs) do
            local is_title = false
            for _, tt in ipairs(title_trigs) do
                if ut == tt then is_title = true; break end
            end
            if ut ~= lower_trig and not is_title then 
                add_mapping(ut, upper_repl) 
            end
        end
    end

    -- Special variant for triggers starting with a comma
    local first_char_source = is_case_sensitive and trigger or trig_lower(trigger)
    local first_char = string.match(first_char_source, "^[%z\1-\127\194-\244][\128-\191]*")
    if first_char == "," then
        local rest = string.sub(lower_trig, #first_char + 1)
        if rest ~= "" then
            local short_title_trig = ";" .. trig_lower(rest)
            add_mapping(short_title_trig, title_repl)
            
            local rest_uppers = trig_upper(rest)
            for _, ru in ipairs(rest_uppers) do
                local short_upper_trig = ";" .. ru
                if short_upper_trig ~= short_title_trig then
                    add_mapping(short_upper_trig, upper_repl)
                end
            end
        end
    end

    -- Sort by descending trigger length is now deferred to the end of
    -- load_toml / load_file (called once per bulk load, not per entry).
end

---------------------------------------------------------------------------
-- Pause flag: when true, the keydown handler passes all events through
-- without expanding any hotstring. The tap itself keeps running so that
-- script_control shortcuts (pause toggle / reload) remain reachable.
---------------------------------------------------------------------------
local processing_paused = false

function M.pause_processing()  processing_paused = true  end
function M.resume_processing() processing_paused = false end
function M.is_processing_paused() return processing_paused end

-- Timestamp (seconds) until which hotstring matching is suppressed after a
-- final_result expansion.  Prevents the expanded text from being re-scanned
-- by other hotstrings (e.g. "axa" inside an e-mail address).
local _no_rescan_until = 0

-- Mark the buffer as off-limits for hotstring matching for `duration` seconds.
-- Also clears the buffer so that residual characters cannot participate in a
-- future match that spans the expansion boundary.
-- Exposed as M.suppress_rescan so external modules (e.g. personal_info) that
-- emit replacement text directly via eventtap can trigger the same protection.
local function suppress_rescan(duration)
    _no_rescan_until = hs.timer.secondsSinceEpoch() + (duration or 0.5)
    buffer = ""
end
function M.suppress_rescan(duration) suppress_rescan(duration) end

-- Return true when re-scan suppression is currently active.
local function rescan_suppressed()
    return hs.timer.secondsSinceEpoch() < _no_rescan_until
end

-- Return whether a case-sensitive TOML trigger is registered in the mappings.
-- Used by personal_info.lua to yield priority to explicit TOML shortcuts like
-- "@am★" so they are never swallowed by the @<letters>★ interceptor.
function M.has_exact_trigger(trigger)
    for _, m in ipairs(mappings) do
        if m.trigger == trigger then return true end
    end
    return false
end

-- Return whether any registered trigger starts with the given prefix.
-- Used by `personal_info` to avoid stealing input when a TOML trigger
-- contains an `@` that may be completed in subsequent keystrokes.
function M.has_trigger_prefix(prefix)
    for _, m in ipairs(mappings) do
        if m.trigger:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- Return whether any registered trigger matches the end (suffix) of `s`.
-- Used when the buffer may contain preceding characters (e.g. " <@").
function M.has_trigger_suffix(s)
    if not s then return false end
    for _, m in ipairs(mappings) do
        local t = m.trigger
        if #s >= #t and s:sub(-#t) == t then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Replacement-emission helpers
---------------------------------------------------------------------------

-- UTF-8 aware length helper used both here and inside onKeyDown.
local function utf8_len(s) return utf8.len(s) or #s end

-- Text tokens longer than this (in UTF-8 codepoints) are inserted via
-- clipboard paste (Cmd+V) instead of keyStrokes to avoid per-character
-- timing issues that corrupt long replacements.
local PASTE_THRESHOLD = 30

-- Maps AHK-style {Key} token names to Hammerspoon key names.
-- Token matching is tried with the exact case first, then Title-case.
local KEY_COMMANDS = {
    Left      = "left",
    Right     = "right",
    Up        = "up",
    Down      = "down",
    Home      = "home",
    End       = "end",
    Delete    = "forwarddelete",
    Del       = "forwarddelete",
    Backspace = "delete",
    BS        = "delete",
    Tab       = "tab",
    Enter     = "return",
    Return    = "return",
    Escape    = "escape",
    Esc       = "escape",
}

-- Split a replacement string into a flat list of tokens.
-- Each token: { kind = "text", value = "..." }
--          or { kind = "key",  value = "<hs-key-name>" }
-- Unrecognised {Foo} sequences are treated as literal text.
local function tokens_from_repl(repl)
    local tokens = {}
    local i = 1
    while i <= #repl do
        local s, e, name = repl:find("{(%w+)}", i)
        if s then
            if s > i then
                table.insert(tokens, { kind = "text", value = repl:sub(i, s - 1) })
            end
            -- Try exact case, then Title-case (e.g. "left" → "Left").
            local title = name:sub(1, 1):upper() .. name:sub(2):lower()
            local hs_key = KEY_COMMANDS[name] or KEY_COMMANDS[title]
            if hs_key then
                table.insert(tokens, { kind = "key", value = hs_key })
            else
                -- Unknown token – preserve as literal text.
                table.insert(tokens, { kind = "text", value = "{" .. name .. "}" })
            end
            i = e + 1
        else
            table.insert(tokens, { kind = "text", value = repl:sub(i) })
            break
        end
    end
    return tokens
end

-- Emit all tokens as actual key events.
-- Text tokens longer than PASTE_THRESHOLD codepoints are sent via
-- clipboard paste (Cmd+V = 1 synthetic keyDown) instead of keyStrokes
-- (N synthetic keyDowns) to avoid per-character errors on long strings.
-- Returns the number of synthetic keyDown events generated so callers can
-- prime synthetic_remaining correctly.
local function emit_tokens(tokens)
    local count = 0
    for _, tok in ipairs(tokens) do
        if tok.kind == "key" then
            keyStroke({}, tok.value, 0)
            count = count + 1
        elseif utf8_len(tok.value) > PASTE_THRESHOLD then
            -- Save and restore the clipboard so the user's content is preserved.
            local prev_clip = hs.pasteboard.getContents()
            hs.pasteboard.setContents(tok.value)
            keyStroke({"cmd"}, "v", 0)
            count = count + 1  -- only the Cmd+V keyDown reaches our eventtap
            hs.timer.doAfter(1, function()
                hs.pasteboard.setContents(prev_clip or "")
            end)
        else
            keyStrokes(tok.value)
            count = count + utf8_len(tok.value)
        end
    end
    return count
end

-- Return only the plain-text portion of a replacement (key-command tokens
-- do not contribute printable characters to the tracked buffer).
local function text_from_tokens(tokens)
    local parts = {}
    for _, tok in ipairs(tokens) do
        if tok.kind == "text" then table.insert(parts, tok.value) end
    end
    return table.concat(parts)
end

-- Count how many synthetic keyDown events a list of tokens will generate
-- without emitting anything.  Mirrors the logic in emit_tokens exactly:
-- long text tokens count as 1 (the Cmd+V), short ones count per codepoint.
local function count_token_events(tokens)
    local count = 0
    for _, tok in ipairs(tokens) do
        if tok.kind == "key" then
            count = count + 1
        elseif utf8_len(tok.value) > PASTE_THRESHOLD then
            count = count + 1  -- Cmd+V = 1 keyDown
        else
            count = count + utf8_len(tok.value)
        end
    end
    return count
end


---------------------------------------------------------------------------
-- UI: Boîte de prévisualisation (Preview Canvas)
---------------------------------------------------------------------------
local preview_canvas = hs.canvas.new({x = 0, y = 0, w = 0, h = 0})
preview_canvas:level(hs.canvas.windowLevels.cursor) -- Reste au-dessus
preview_canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

-- Design type macOS natif (sombre, arrondi)
preview_canvas:appendElements({
    type = "rectangle",
    action = "fill",
    fillColor = {white = 0.15, alpha = 0.90}, 
    roundedRectRadii = {xRadius = 6, yRadius = 6},
}, {
    type = "text",
    text = "",
    -- Plus besoin de textAlignment, on va forcer la position exacte
})

local function hide_preview()
    if preview_canvas then preview_canvas:hide() end
end

local function update_preview(buf)
    if not buf or #buf == 0 then
        hide_preview()
        return
    end

    -- On extrait la fin du buffer depuis le dernier espace
    -- ([^%s]+ permet de garder la ponctuation si elle fait partie du trigger)
    local last_word = buf:match("([^%s]+)$")
    if not last_word then 
        hide_preview()
        return 
    end

    local match_repl = nil

    -- On cherche UNIQUEMENT si le mot tapé correspond à un trigger suivi de "★"
    for _, m in ipairs(mappings) do
        if m.trigger == last_word .. "★" then
            match_repl = m.repl
            break
        end
    end

    if match_repl then
        -- Nettoyer les tokens genre {Left}, {Enter} pour l'affichage visuel pur
        local clean_repl = text_from_tokens(tokens_from_repl(match_repl))
        
        local styledText = hs.styledtext.new(clean_repl, {
            font = {name = ".AppleSystemUIFont", size = 14}, 
            color = {white = 1.0}
        })
        
        local size = preview_canvas:minimumTextSize(2, styledText)
        
        -- Définition des marges (padding) pour un centrage parfait
        local padding_x = 12
        local padding_y = 6
        local w = size.w + (padding_x * 2)
        local h = size.h + (padding_y * 2)

        -- Position globale de la fenêtre par rapport à la souris
        local mouse_pt = hs.mouse.absolutePosition()
        preview_canvas:frame({
            x = mouse_pt.x + 16,
            y = mouse_pt.y + 16,
            w = w,
            h = h
        })
        
        -- Contraint le texte à l'intérieur de la boîte avec les marges
        preview_canvas[2].frame = { x = padding_x, y = padding_y, w = size.w, h = size.h }
        preview_canvas[2].text = styledText
        
        preview_canvas:show()
    else
        hide_preview()
    end
end


---------------------------------------------------------------------------
-- Keyboard listener
---------------------------------------------------------------------------

local function onKeyDown(e)
    if processing_paused then return false end
    if is_replacing then
        -- Consume one expected synthetic event; clear the guard once all are done.
        if synthetic_remaining > 0 then
            synthetic_remaining = synthetic_remaining - 1
            if synthetic_remaining <= 0 then
                is_replacing = false
                synthetic_remaining = 0
            end
        end
        return false
    end

    local keyCode = e:getKeyCode()
    local flags = e:getFlags()
    local now = hs.timer.secondsSinceEpoch()
    local time_since_last_key = now - last_key_time
    
    last_key_time = now

    local is_complex = flags.shift or flags.alt
    local allowed_delay = BASE_DELAY_SEC
    if is_complex or last_key_was_complex then
        allowed_delay = BASE_DELAY_SEC * 2
    end
    last_key_was_complex = is_complex

    if flags.cmd or flags.ctrl then
        buffer = ""
        hide_preview()
        return false
    end

    -- Give registered interceptors first look at every event (before backspace,
    -- escape, and getCharacters processing so that Unicode trigger chars like ★
    -- that produce getCharacters("") are still catchable).
    -- Interceptors are called in registration order; the chain stops at the
    -- first non-nil result.
    local _interceptor_suppress = false
    for _, iceptor in ipairs(_interceptors) do
        local result = iceptor(e, buffer)
        if result == "consume" then return true end
        if result == "suppress" then _interceptor_suppress = true; break end
    end

    if keyCode == 51 then -- Backspace
        if #buffer > 0 then
            local offset = utf8.offset(buffer, -1)
            buffer = offset and string.sub(buffer, 1, offset - 1) or ""
            update_preview(buffer)
        end
        return false
    end

    if keyCode == 53 or (keyCode >= 123 and keyCode <= 126) then -- Escape or Arrow keys
        buffer = ""
        hide_preview()
        return false
    end

    local chars = e:getCharacters(false)
    if not chars or chars == "" then return false end

    buffer = buffer .. chars
    if #buffer > 100 then
        buffer = string.sub(buffer, utf8.offset(buffer, -50) or 1)
    end
    
    update_preview(buffer)

    if _interceptor_suppress then return false end

    -- If a final_result expansion just finished, skip all hotstring matching
    -- for this event.  The buffer was already cleared by suppress_rescan().
    if rescan_suppressed() then return false end

    if time_since_last_key <= allowed_delay then
        local char_count = utf8.len(chars) or #chars
        local prefix_before = string.sub(buffer, 1, (utf8.offset(buffer, -char_count) or (#buffer+1)) - 1)
        local function utf8_ends_with(s, suffix)
            local n = utf8_len(suffix)
            local start = utf8.offset(s, -n)
            if not start then return false end
            return string.sub(s, start) == suffix
        end
        local function utf8_sub_from_end(s, n)
            local start = utf8.offset(s, -n)
            if not start then return s end
            return string.sub(s, start)
        end
        local function is_letter_char(c)
            if not c or c == "" then return false end
            if c:match("[%w]") then return true end
            -- Lua/LuaJIT string.upper does not handle UTF-8 accented characters,
            -- so we fall back to the known accent tables defined at module level.
            if UPPER_LETTERS[c] or LOWER_LETTERS[c] then return true end
            return string.upper(c) ~= string.lower(c)
        end
        for _, m in ipairs(mappings) do
            local trigger = m.trigger

                -- immediate expansion: trigger ends right at buffer end
                if utf8_ends_with(buffer, trigger) then
                    -- Only perform immediate expansion for mappings explicitly marked
                    -- as auto (m.auto == true). Non-auto mappings must wait for
                    -- a boundary (space/tab/enter) and are handled by deferred expansion.
                    if not m.auto then
                        -- skip immediate expansion for non-auto mappings
                    else
                        -- avoid immediate expansion for triggers that start with
                        -- a non-letter (punctuation/dead-key) because those
                        -- often represent composing sequences and can steal
                        -- matches from longer word triggers (e.g. ",e" vs "jeuner").
                        local trig_first = trigger:match("^[%z\1-\127\194-\244][\128-\191]*")
                        -- Only skip immediate expansion for non-letter-starting triggers
                        -- when the mapping is NOT allowed is_word-word. If m.is_word==true
                        -- (comma compose mappings), keep immediate expansion.
                        -- If the trigger starts with a non-letter (punctuation/dead-key),
                        -- we normally skip immediate expansion to avoid stealing matches
                        -- from longer word triggers. However, if the mapping is marked
                        -- `auto` (auto_expand==true) we should allow immediate expansion
                        -- (useful for comma compose mappings like ",c").
                        if trig_first and not is_letter_char(trig_first) and not m.is_word and not m.auto then
                            -- skip immediate expansion; let deferred expansion handle boundary
                        else
                            local valid = true
                            if m.is_word and utf8_len(buffer) > utf8_len(trigger) then
                                local trigger_starts_with_space = trigger:match("^[   ]")
                                if not trigger_starts_with_space then
                                    local start = utf8.offset(buffer, -utf8_len(trigger))
                                    local prefix = (start and string.sub(buffer, 1, start - 1)) or ""
                                    local offset = utf8.offset(prefix, -1)
                                    local prev_char = offset and string.sub(prefix, offset) or ""
                                    if is_letter_char(prev_char) then
                                        valid = false
                                    end
                                end
                            end
                            if valid then
                                local trigger_len = utf8_len(trigger)
                                local chars_len = utf8_len(chars)
                                local deletes = trigger_len - chars_len
                                -- Tokenise the replacement so that {Left}/{Right}/etc. become
                                -- real key strokes rather than literal characters.
                                local repl_tokens = tokens_from_repl(m.repl)
                                local repl_text   = text_from_tokens(repl_tokens)
                                -- Identity guard: trigger and output are the same string.
                                -- No keystroke manipulation needed; the triggering char already
                                -- reached the app naturally and the buffer is already up to date.
                                if repl_text == trigger then
                                    if m.final_result then suppress_rescan() end
                                    hide_preview()
                                    return false
                                end
                                -- Pre-compute synthetic event count BEFORE emitting anything.
                                -- Each keyStroke(delete) = 1; text chars = 1 each; key
                                -- commands ({Left} etc.) = 1 each.
                                synthetic_remaining = (deletes > 0 and deletes or 0)
                                    + count_token_events(repl_tokens)
                                is_replacing = true

                                hide_preview()

                                if deletes > 0 then
                                    for _ = 1, deletes do
                                        keyStroke({}, 'delete', 0)
                                    end
                                end

                                emit_tokens(repl_tokens)

                                -- Keep everything before the trigger, then append the replacement.
                                -- utf8.offset(buffer, -trigger_len) gives the byte position of the
                                -- first character of the trigger inside buffer, so sub(1, pos-1)
                                -- is exactly the prefix that precedes it.
                                local trig_start = utf8.offset(buffer, -trigger_len)
                                buffer = (trig_start and string.sub(buffer, 1, trig_start - 1) or "") .. repl_text

                                -- When final_result is set, prevent any further hotstring from
                                -- re-scanning the expanded text (e.g. "axa" inside an e-mail).
                                if m.final_result then suppress_rescan() end

                                -- Safety fallback: if the counter somehow gets off, release the
                                -- guard after 100 ms so the system doesn't stay frozen.
                                hs.timer.doAfter(0.1, function()
                                    if is_replacing then
                                        is_replacing = false
                                        synthetic_remaining = 0
                                        if DEBUG_EXPANSION then print("[keymap] fallback reset after immediate expand, buffer=", buffer) end
                                    end
                                end)

                                return true
                            end
                        end
                    end
                end

            -- Deferred expansion: expand on boundary chars (non-auto mappings only).
            -- auto=true mappings are expanded immediately (above) based on the timing
            -- between the last two chars of the trigger; the boundary char has no role
            -- and must not re-trigger them.
            if not m.auto and is_terminator(chars) then
                local end_pos = utf8.offset(buffer, -char_count) or (#buffer + 1)
                local start_pos = utf8.offset(buffer, -(char_count + utf8_len(trigger)))
                local seg = nil
                if start_pos and end_pos and start_pos <= end_pos - 1 then
                    seg = string.sub(buffer, start_pos, end_pos - 1)
                end
                if seg == trigger then
                    local valid = true
                    if m.is_word then
                        local trigger_starts_with_space = trigger:match("^[   ]")
                        if not trigger_starts_with_space then
                            local before_trigger = (start_pos and string.sub(buffer, 1, start_pos - 1)) or ""
                            local offset2 = utf8.offset(before_trigger, -1)
                            local prev_char = offset2 and string.sub(before_trigger, offset2) or ""
                            if is_letter_char(prev_char) then
                                valid = false
                            end
                        end
                    end
                    if valid then
                        -- schedule replacement after the boundary char has been handled by the app
                        if DEBUG_EXPANSION then print("[keymap] scheduling deferred expand trigger=", trigger, "repl=", m.repl, "chars=", chars) end
                        local trigger_len = utf8_len(trigger)
                        local start_trigger = utf8.offset(prefix_before, -utf8_len(trigger))
                        local before_trigger = (start_trigger and string.sub(prefix_before, 1, start_trigger - 1)) or ""
                        local is_final_mapping = m.final_result

                        local consume_term = terminator_is_consumed(chars)

                        -- Identity guard: trigger and output are the same string.
                        -- No keystroke manipulation needed; let the boundary char pass
                        -- through naturally (buffer already has trigger + boundary).
                        if m.repl == trigger then
                            if is_final_mapping then suppress_rescan() end
                            hide_preview()
                            return false
                        end

                        hs.timer.doAfter(0, function()
                            if DEBUG_EXPANSION then print("[keymap] performing deferred expand trigger=", trigger) end
                            local repl_tokens = tokens_from_repl(m.repl)
                            local repl_text   = text_from_tokens(repl_tokens)
                            -- Pre-compute synthetic event count: trigger deletes + repl events.
                            -- consume_term: terminator already consumed (e.g. ★), no re-send.
                            -- Otherwise add 1 per boundary codepoint (re-sent below).
                            synthetic_remaining = trigger_len
                                + count_token_events(repl_tokens)
                                + (consume_term and 0 or utf8_len(chars))
                            is_replacing = true
                            
                            hide_preview()
                            
                            -- delete the trigger characters (caret is after the trigger)
                            for _ = 1, trigger_len do keyStroke({}, 'delete', 0) end
                            -- type replacement (handles {Left} / {Right} / etc.)
                            emit_tokens(repl_tokens)
                            -- re-send the boundary char only if it must be preserved
                            if not consume_term then keyStrokes(chars) end

                            -- update buffer: remove trigger, append repl text (and boundary if kept)
                            buffer = before_trigger .. repl_text .. (consume_term and "" or chars)

                            -- When final_result is set, prevent any further hotstring from
                            -- re-scanning the expanded text (e.g. "axa" inside an e-mail).
                            if is_final_mapping then suppress_rescan() end

                            -- Safety fallback in case the counter gets off.
                            hs.timer.doAfter(0.1, function()
                                if is_replacing then
                                    is_replacing = false
                                    synthetic_remaining = 0
                                    if DEBUG_EXPANSION then print("[keymap] fallback reset after deferred expand, buffer=", buffer) end
                                end
                            end)
                        end)

                        -- consume the boundary event (we re-send it above), avoid double-insert
                        return true
                    end
                end
            end
        end
    end

    return false
end

local tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)

-- Clear the buffer whenever the user repositions the cursor with the mouse,
-- otherwise stale typed characters cause false "inside a word" rejections.
local mouse_tap = eventtap.new(
    { eventtap.event.types.leftMouseDown,
      eventtap.event.types.rightMouseDown,
      eventtap.event.types.middleMouseDown },
    function()
        buffer = ""
        hide_preview()
        return false
    end
)

function M.start()
    tap:start()
    mouse_tap:start()
end

function M.stop()
    if tap then tap:stop() end
    if mouse_tap then mouse_tap:stop() end
    hide_preview()
end

M.start()

return M
