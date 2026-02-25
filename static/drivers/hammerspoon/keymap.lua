-- keymap.lua
-- Implémentation simplifiée de hotstrings pour Hammerspoon

local eventtap = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke = hs.eventtap.keyStroke

local M = {}

-- Gestion des groupes de mappings (pour permettre enable/disable par fichier)
local groups = {}
local current_group = nil
local mappings = {}

local function record_group(name, path)
    local seqs = {}
    for _, m in ipairs(mappings) do
        if m.group == name then table.insert(seqs, m.seq) end
    end
    groups[name] = { path = path, seqs = seqs, enabled = true }
end

function M.load_file(name, path)
    current_group = name
    dofile(path)
    current_group = nil
    record_group(name, path)
end

function M.disable_group(name)
    if not groups[name] or not groups[name].enabled then return end
    groups[name].enabled = false
    local new_mappings = {}
    for _, m in ipairs(mappings) do
        if m.group ~= name then table.insert(new_mappings, m) end
    end
    mappings = new_mappings
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

function M.enable_group(name)
    local g = groups[name]
    if not g then return end
    if g.enabled then return end
    -- re-load the file to re-add mappings under the same group name
    M.load_file(name, g.path)
end

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local BASE_DELAY_SEC = 0.5 

local buffer = ""
local is_replacing = false
local last_key_time = 0
local last_key_was_complex = false
local seq_counter = 0 
local DEBUG_EXPANSION = false

---------------------------------------------------------------------------
-- Utilitaires UTF-8 (Casse & Ponctuation)
---------------------------------------------------------------------------
local UPPER_LETTERS = {
    ['à']='À', ['â']='Â', ['ä']='Ä', ['é']='É', ['è']='È', ['ê']='Ê', ['ë']='Ë',
    ['î']='Î', ['ï']='Ï', ['ô']='Ô', ['ö']='Ö', ['ù']='Ù', ['û']='Û', ['ü']='Ü',
    ['ç']='Ç', ['œ']='Œ', ['æ']='Æ'
}

local LOWER_LETTERS = {}
for k, v in pairs(UPPER_LETTERS) do LOWER_LETTERS[v] = k end

-- Symboles spéciaux pour la MONTÉE en majuscule des triggers
local UPPER_TRIGGERS = {}
for k, v in pairs(UPPER_LETTERS) do UPPER_TRIGGERS[k] = v end
UPPER_TRIGGERS["'"] = " ?" -- Espace fine insécable + ?
UPPER_TRIGGERS[","] = {" :", " ;"} -- Tableau : Espace insécable + : ET Espace fine + ;
UPPER_TRIGGERS["."] = " :" -- Espace insécable + :

-- Retourne un tableau de toutes les combinaisons possibles de majuscules
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

-- Retourne un tableau de chaînes en Titlecase
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
-- Ajout de raccourcis
---------------------------------------------------------------------------
function M.add(trigger, replacement, mid_word, auto_expand, case_sensitive)
    local is_mid = (mid_word == true)
    local is_auto = (auto_expand == true)
    local is_case_sensitive = (case_sensitive == true)

    local function add_mapping_raw(t, r, a)
        for _, m in ipairs(mappings) do
            if m.trigger == t and m.repl == r and m.mid == is_mid and m.auto == a then return end
        end
        seq_counter = seq_counter + 1
        local entry = { trigger = t, repl = r, mid = is_mid, auto = a, seq = seq_counter }
        if current_group then entry.group = current_group end
        table.insert(mappings, entry)
    end

    local function set_spaces(str, space_char)
        str = str:gsub(" ", space_char)
        str = str:gsub(" ", space_char) 
        str = str:gsub(" ", space_char) 
        return str
    end

    local function add_mapping(t, r)
        add_mapping_raw(t, r, is_auto)
        if t:match(" ") or t:match(" ") or t:match(" ") then
            add_mapping_raw(set_spaces(t, " "), r, is_auto)  
            add_mapping_raw(set_spaces(t, " "), r, is_auto) 
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

        -- Variantes standards
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

    -- Variante spéciale pour les triggers commençant par une virgule
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

    -- Tri par longueur, puis par priorité
    table.sort(mappings, function(a, b)
        local len_a = utf8.len(a.trigger) or #a.trigger
        local len_b = utf8.len(b.trigger) or #b.trigger
        if len_a == len_b then return a.seq > b.seq end
        return len_a > len_b
    end)
end

---------------------------------------------------------------------------
-- Écoute du clavier
---------------------------------------------------------------------------
local function onKeyDown(e)
    if is_replacing then return false end

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
        return false
    end

    if keyCode == 51 then
        if #buffer > 0 then
            local offset = utf8.offset(buffer, -1)
            buffer = offset and string.sub(buffer, 1, offset - 1) or ""
        end
        return false
    end

    if keyCode == 53 or (keyCode >= 123 and keyCode <= 126) then
        buffer = ""
        return false
    end

    local chars = e:getCharacters(false)
    if not chars or chars == "" then return false end

    buffer = buffer .. chars
    if #buffer > 100 then
        buffer = string.sub(buffer, utf8.offset(buffer, -50) or 1)
    end

    if time_since_last_key <= allowed_delay then
        local char_count = utf8.len(chars) or #chars
        local prefix_before = string.sub(buffer, 1, (utf8.offset(buffer, -char_count) or (#buffer+1)) - 1)
        local function utf8_len(s) return utf8.len(s) or #s end
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
            return string.upper(c) ~= string.lower(c)
        end
        for _, m in ipairs(mappings) do
            local trigger = m.trigger

                    -- immediate expansion: trigger ends right at buffer end
                    if utf8_ends_with(buffer, trigger) then
                -- avoid immediate expansion for triggers that start with
                -- a non-letter (punctuation/dead-key) because those
                -- often represent composing sequences and can steal
                -- matches from longer word triggers (e.g. ",e" vs "jeuner").
                local trig_first = trigger:match("^[%z\1-\127\194-\244][\128-\191]*")
                -- Only skip immediate expansion for non-letter-starting triggers
                -- when the mapping is NOT allowed mid-word. If m.mid==true
                -- (comma compose mappings), keep immediate expansion.
                if trig_first and not is_letter_char(trig_first) and not m.mid then
                    -- skip immediate expansion; let deferred expansion handle boundary
                else
                        local valid = true
                if not m.mid and utf8_len(buffer) > utf8_len(trigger) then
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
                        is_replacing = true

                        local trigger_len = utf8_len(trigger)
                        local chars_len = utf8_len(chars)
                        local deletes = trigger_len - chars_len

                        if deletes > 0 then
                            for _ = 1, deletes do
                                keyStroke({}, 'delete', 0)
                            end
                        end

                        keyStrokes(m.repl)

                        local start = utf8.offset(buffer, -(utf8_len(buffer) - trigger_len))
                        buffer = (start and string.sub(buffer, 1, start - 1) or "") .. m.repl

                        hs.timer.doAfter(0.01, function()
                            is_replacing = false
                            if DEBUG_EXPANSION then print("[keymap] finished immediate expand, buffer=", buffer) end
                        end)

                        return true
                    end
                end
                end

            -- Deferred expansion: expand on boundary chars (apply to both auto and non-auto mappings)
            if chars == " " or chars == "\t" or chars == "\r" or chars == "\n" or chars == "." then
                local end_pos = utf8.offset(buffer, -char_count) or (#buffer + 1)
                local start_pos = utf8.offset(buffer, -(char_count + utf8_len(trigger)))
                local seg = nil
                if start_pos and end_pos and start_pos <= end_pos - 1 then
                    seg = string.sub(buffer, start_pos, end_pos - 1)
                end
                if seg == trigger then
                    local valid = true
                    if not m.mid then
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

                        hs.timer.doAfter(0, function()
                            if DEBUG_EXPANSION then print("[keymap] performing deferred expand trigger=", trigger) end
                            is_replacing = true
                            -- move caret left one to be before the boundary char
                            keyStroke({}, 'left', 0)
                            -- delete the trigger characters
                            for _ = 1, trigger_len do keyStroke({}, 'delete', 0) end
                            -- type replacement (it will be inserted before the boundary char)
                            keyStrokes(m.repl)

                            -- update buffer: remove trigger from prefix_before, append repl and the boundary char
                            buffer = before_trigger .. m.repl .. chars

                            hs.timer.doAfter(0.01, function()
                                is_replacing = false
                                if DEBUG_EXPANSION then print("[keymap] finished deferred expand, buffer=", buffer) end
                            end)
                        end)

                        -- do not consume the event: let the boundary char be processed by the app
                        return false
                    end
                end
            end
        end
    end

    return false
end

local tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)

function M.start() tap:start() end
function M.stop() if tap then tap:stop() end end

M.start()

return M
