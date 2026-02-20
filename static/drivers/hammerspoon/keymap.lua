-- keymap.lua
-- Implémentation simplifiée de hotstrings pour Hammerspoon

local eventtap = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke = hs.eventtap.keyStroke

local M = {}

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local BASE_DELAY_SEC = 0.5 

local mappings = {}
local buffer = ""
local is_replacing = false
local last_key_time = 0
local last_key_was_complex = false
local seq_counter = 0 

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
function M.add(trigger, replacement, mid_word)
    local is_mid = (mid_word == true)

    local function add_mapping_raw(t, r)
        for _, m in ipairs(mappings) do
            if m.trigger == t and m.repl == r and m.mid == is_mid then return end
        end
        seq_counter = seq_counter + 1
        table.insert(mappings, { trigger = t, repl = r, mid = is_mid, seq = seq_counter })
    end

    local function set_spaces(str, space_char)
        str = str:gsub(" ", space_char)
        str = str:gsub(" ", space_char) 
        str = str:gsub(" ", space_char) 
        return str
    end

    local function add_mapping(t, r)
        add_mapping_raw(t, r)
        if t:match(" ") or t:match(" ") or t:match(" ") then
            add_mapping_raw(set_spaces(t, " "), r)  
            add_mapping_raw(set_spaces(t, " "), r) 
            add_mapping_raw(set_spaces(t, " "), r) 
        end
    end

    local lower_trig = trig_lower(trigger)
    local title_trigs = trig_title(lower_trig)
    local upper_trigs = trig_upper(lower_trig)

    local base_repl = replacement
    local title_repl = repl_title(base_repl)
    local upper_repl = repl_upper(base_repl)

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

    -- Variante spéciale pour les triggers commençant par une virgule
    local first_char = string.match(lower_trig, "^[%z\1-\127\194-\244][\128-\191]*")
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
        for _, m in ipairs(mappings) do
            local trigger = m.trigger
            
            if string.sub(buffer, -#trigger) == trigger then
                local valid = true
                
                if not m.mid and #buffer > #trigger then
                    -- Exception vitale : si le trigger demande LUI-MÊME un espace, 
                    -- on ne fait pas le test de frontière de mot, c'est forcément bon.
                    local trigger_starts_with_space = trigger:match("^[   ]")
                    
                    if not trigger_starts_with_space then
                        local prefix = string.sub(buffer, 1, #buffer - #trigger)
                        local offset = utf8.offset(prefix, -1)
                        local prev_char = offset and string.sub(prefix, offset) or ""
                        
                        if prev_char:match("[%w]") or prev_char:match("^[À-ÖØ-öø-ÿœŒ]$") then
                            valid = false
                        end
                    end
                end

                if valid then
                    is_replacing = true
                    M.stop()

                    local trigger_len = utf8.len(trigger) or #trigger
                    local chars_len = utf8.len(chars) or #chars
                    local deletes = trigger_len - chars_len
                    
                    if deletes > 0 then
                        for _ = 1, deletes do
                            keyStroke({}, 'delete', 0)
                        end
                    end

                    keyStrokes(m.repl)

                    buffer = string.sub(buffer, 1, #buffer - #trigger) .. m.repl

                    hs.timer.doAfter(0.01, function()
                        is_replacing = false
                        M.start()
                    end)

                    return true
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
