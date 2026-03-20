-- modules/keymap.lua
local eventtap = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke = hs.eventtap.keyStroke

local utils = require("lib.text_utils")
local ui = require("lib.ui")
local llm = require("modules.llm")
local vscode_bridge = require("lib.vscode_bridge")
if vscode_bridge.setup then vscode_bridge.setup() end

local M = {}

-- ==========================================
-- Default Configuration
-- ==========================================
M.DEFAULT_BASE_DELAY_SEC = 0.75

---------------------------------------------------------------------------
-- Global Variables & State
---------------------------------------------------------------------------
local groups = {}
local current_group = nil
local mappings = {}
local mappings_lookup = {}
local _interceptors = {}
local _preview_providers = {}

local BASE_DELAY_SEC = M.DEFAULT_BASE_DELAY_SEC
local buffer = ""
local is_replacing = false
local last_key_time = 0
local last_key_was_complex = false
local seq_counter = 0 
local processing_paused = false
local _no_rescan_until = 0

local current_llm_prediction = nil
local current_llm_model = llm.DEFAULT_LLM_MODEL
local llm_enabled = llm.DEFAULT_LLM_ENABLED
local llm_debounce_time = llm.DEFAULT_LLM_DEBOUNCE
local preview_enabled = true

---------------------------------------------------------------------------
-- Core Config API
---------------------------------------------------------------------------
function M.set_llm_model(model_name)
    current_llm_model = model_name
end

function M.set_llm_enabled(enabled)
    llm_enabled = enabled
    if not enabled then
        ui.hide_preview()
        current_llm_prediction = nil
        if M._llm_timer and M._llm_timer:running() then M._llm_timer:stop() end
    end
end

function M.set_preview_enabled(enabled)
    preview_enabled = enabled
    if not enabled then ui.hide_preview() end
end

function M.set_llm_debounce(seconds)
    llm_debounce_time = seconds
    if M._llm_timer then M._llm_timer:stop() end
    M._llm_timer = hs.timer.delayed.new(llm_debounce_time, M._perform_llm_check)
end

function M.get_base_delay() return BASE_DELAY_SEC end
function M.set_base_delay(secs) BASE_DELAY_SEC = math.max(0, secs) end

function M.pause_processing()  processing_paused = true  end
function M.resume_processing() processing_paused = false end
function M.is_processing_paused() return processing_paused end

function M.suppress_rescan(duration) 
    _no_rescan_until = hs.timer.secondsSinceEpoch() + (duration or 0.5)
    buffer = "" 
end
local function rescan_suppressed() return hs.timer.secondsSinceEpoch() < _no_rescan_until end

---------------------------------------------------------------------------
-- Group & Mapping Management
---------------------------------------------------------------------------
local function rebuild_lookup()
    mappings_lookup = {}
    for _, m in ipairs(mappings) do
        local k = m.trigger .. "\0" .. tostring(m.is_word) .. "\0" .. tostring(m.auto)
        mappings_lookup[k] = m
    end
end

function M.sort_mappings()
    table.sort(mappings, function(a, b)
        if a.tlen ~= b.tlen then return a.tlen > b.tlen end
        if a.is_word ~= b.is_word then return a.is_word end
        return a.seq < b.seq
    end)
end

function M.register_interceptor(fn) table.insert(_interceptors, fn) end
function M.register_preview_provider(fn) table.insert(_preview_providers, fn) end

local function record_group(name, path, kind)
    local seqs = {}
    for _, m in ipairs(mappings) do
        if m.group == name then table.insert(seqs, m.seq) end
    end
    groups[name] = { path = path, seqs = seqs, enabled = true, kind = kind or 'lua' }
end

function M.load_file(name, path)
    current_group = name
    pcall(dofile, path)
    current_group = nil
    record_group(name, path, 'lua')
    M.sort_mappings()
end

function M.load_toml(name, path)
    local toml_reader = require("lib.toml_reader")
    local ok, data = pcall(toml_reader.parse, path)
    if not ok or not data then return end

    current_group = name
    local total = 0
    local sections_info = {}

    for _, sec_name in ipairs(data.sections_order) do
        if sec_name == '-' then
            table.insert(sections_info, { name = '-', description = '-', count = 0 })
            goto continue_sec
        end

        local sec = data.sections[sec_name]
        if sec then
            if sec.is_placeholder then
                table.insert(sections_info, { name = sec_name, description = sec.description, count = 0, is_module_placeholder = true })
                goto continue_sec
            end
            
            if M.is_section_enabled(name, sec_name) then
                for _, entry in ipairs(sec.entries) do
                    M.add(entry.trigger, entry.output, {
                        is_word = entry.is_word,
                        auto_expand = entry.auto_expand,
                        is_case_sensitive = entry.is_case_sensitive,
                        final_result = entry.final_result,
                    })
                    total = total + 1
                end
            end
            table.insert(sections_info, { name = sec_name, description = sec.description, count = #sec.entries })
        end
        ::continue_sec::
    end

    current_group = nil
    M.sort_mappings()

    local seqs = {}
    for _, m in ipairs(mappings) do
        if m.group == name then table.insert(seqs, m.seq) end
    end

    groups[name] = {
        path = path, seqs = seqs, enabled = true, kind = 'toml',
        meta_description = data.meta.description, sections = sections_info,
    }
end

function M.is_section_enabled(group_name, section_name)
    return hs.settings.get("hotstrings_section_" .. group_name .. "_" .. section_name) ~= false
end

local function reload_group_inplace(group_name)
    if not M.is_group_enabled(group_name) then return end
    M.disable_group(group_name)
    M.enable_group(group_name)
end

function M.disable_section(group_name, section_name)
    hs.settings.set("hotstrings_section_" .. group_name .. "_" .. section_name, false)
    reload_group_inplace(group_name)
end

function M.enable_section(group_name, section_name)
    hs.settings.set("hotstrings_section_" .. group_name .. "_" .. section_name, nil)
    reload_group_inplace(group_name)
end

function M.get_sections(name) return groups[name] and groups[name].sections or nil end
function M.get_meta_description(name) return groups[name] and groups[name].meta_description or nil end
function M.set_group_context(name) current_group = name end

local group_post_load_hooks = {}
function M.set_post_load_hook(name, fn) group_post_load_hooks[name] = fn end

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

function M.is_group_enabled(name) return groups[name] and groups[name].enabled or false end

function M.list_groups()
    local out = {}
    for name, g in pairs(groups) do out[name] = g.enabled end
    return out
end

function M.register_lua_group(name, meta_description, sections)
    groups[name] = { path = nil, seqs = {}, enabled = true, kind = 'lua', meta_description = meta_description, sections = sections or {} }
end

function M.enable_group(name)
    local g = groups[name]
    if not g or g.enabled then return end
    
    if g.path == nil then
        g.enabled = true
        if group_post_load_hooks[name] then
            group_post_load_hooks[name]()
            M.sort_mappings()
        end
        return
    end
    
    if g.kind == 'toml' then M.load_toml(name, g.path) else M.load_file(name, g.path) end
    
    if group_post_load_hooks[name] then
        group_post_load_hooks[name]()
        M.sort_mappings()
    end
end

---------------------------------------------------------------------------
-- Terminators
---------------------------------------------------------------------------
local TERMINATOR_DEFS = {
    { key = "space",  chars  = { " " },                 label = "Espace" },
    { key = "tab",    chars  = { "\t" },                label = "Tabulation" },
    { key = "enter",  chars  = { "\r", "\n" },          label = "Entrée" },
    { key = "period", chars  = { "." },                 label = "Point (.)" },
    { key = "comma",  chars  = { "," },                 label = "Virgule (,)" },
    { key = "nbsp",   prefix = "\194\160",              label = "Espace insécable" },
    { key = "nnbsp",  prefix = "\226\128\175",          label = "Espace fine insécable" },
    { key = "star",   chars  = { "★" },                 label = "Touche ★", consume = true },
}

local _terminator_enabled = {}
for _, def in ipairs(TERMINATOR_DEFS) do _terminator_enabled[def.key] = true end

local function is_terminator(chars)
    for _, def in ipairs(TERMINATOR_DEFS) do
        if _terminator_enabled[def.key] then
            if def.chars then
                for _, c in ipairs(def.chars) do if chars == c then return true end end
            elseif def.prefix then
                if chars:sub(1, #def.prefix) == def.prefix then return true end
            end
        end
    end
    return false
end

local function terminator_is_consumed(chars)
    for _, def in ipairs(TERMINATOR_DEFS) do
        if _terminator_enabled[def.key] and def.consume then
            if def.chars then
                for _, c in ipairs(def.chars) do if chars == c then return true end end
            elseif def.prefix then
                if chars:sub(1, #def.prefix) == def.prefix then return true end
            end
        end
    end
    return false
end

function M.set_terminator_enabled(key, enabled) _terminator_enabled[key] = (enabled ~= false) end
function M.is_terminator_enabled(key) return _terminator_enabled[key] ~= false end
function M.get_terminator_defs() return TERMINATOR_DEFS end

---------------------------------------------------------------------------
-- Adding Shortcuts (Hotstrings)
---------------------------------------------------------------------------
function M.add(trigger, replacement, opts)
    opts = opts or {}
    local is_word = opts.is_word == true
    local is_auto = opts.auto_expand == true
    local is_case_sensitive = opts.is_case_sensitive == true
    local is_final = opts.final_result == true

    local function add_mapping_raw(t, r, a)
        local k = t .. "\0" .. tostring(is_word) .. "\0" .. tostring(a)
        local existing = mappings_lookup[k]
        if existing then
            existing.repl = r
            if current_group then existing.group = current_group end
            return
        end
        seq_counter = seq_counter + 1
        local entry = { trigger = t, repl = r, is_word = is_word, auto = a, seq = seq_counter, tlen = utils.utf8_len(t), final_result = is_final }
        if current_group then entry.group = current_group end
        table.insert(mappings, entry)
        mappings_lookup[k] = entry
    end

    local function add_mapping(t, r)
        add_mapping_raw(t, r, is_auto)
        local first_is_space = t:match("^[ \194\160\226\128\175]") ~= nil
        if not first_is_space and (t:match(" ")) then
            add_mapping_raw((t:gsub(" ", " ")), r, is_auto)  
            add_mapping_raw((t:gsub(" ", " ")), r, is_auto) 
        end
    end

    local base_repl = replacement
    local lower_trig = utils.trig_lower(trigger)
    local title_repl = utils.repl_title(base_repl)
    local upper_repl = utils.repl_upper(base_repl)

    if is_case_sensitive then
        add_mapping(trigger, base_repl)
    else
        local title_trigs = utils.trig_title(lower_trig)
        local upper_trigs = utils.trig_upper(lower_trig)
        add_mapping(lower_trig, base_repl)
        
        for _, tt in ipairs(title_trigs) do
            if tt ~= lower_trig then add_mapping(tt, title_repl) end
        end
        for _, ut in ipairs(upper_trigs) do
            local is_title = false
            for _, tt in ipairs(title_trigs) do
                if ut == tt then is_title = true; break end
            end
            if ut ~= lower_trig and not is_title then add_mapping(ut, upper_repl) end
        end
    end

    local first_char_source = is_case_sensitive and trigger or utils.trig_lower(trigger)
    local first_char = string.match(first_char_source, "^[%z\1-\127\194-\244][\128-\191]*")
    if first_char == "," then
        local rest = string.sub(lower_trig, #first_char + 1)
        if rest ~= "" then
            local short_title_trig = ";" .. utils.trig_lower(rest)
            add_mapping(short_title_trig, title_repl)
            local rest_uppers = utils.trig_upper(rest)
            for _, ru in ipairs(rest_uppers) do
                local short_upper_trig = ";" .. ru
                if short_upper_trig ~= short_title_trig then
                    add_mapping(short_upper_trig, upper_repl)
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Emit Helpers
---------------------------------------------------------------------------
local PASTE_THRESHOLD = 30
local KEY_COMMANDS = {
    Left = "left", Right = "right", Up = "up", Down = "down", Home = "home", End = "end",
    Delete = "forwarddelete", Del = "forwarddelete", Backspace = "delete", BS = "delete",
    Tab = "tab", Enter = "return", Return = "return", Escape = "escape", Esc = "escape",
}

local function tokens_from_repl(repl)
    local tokens = {}
    local i = 1
    while i <= #repl do
        local s, e, name = repl:find("{(%w+)}", i)
        if s then
            if s > i then table.insert(tokens, { kind = "text", value = repl:sub(i, s - 1) }) end
            local title = name:sub(1, 1):upper() .. name:sub(2):lower()
            local hs_key = KEY_COMMANDS[name] or KEY_COMMANDS[title]
            if hs_key then
                table.insert(tokens, { kind = "key", value = hs_key })
            else
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

local function emit_tokens(tokens)
    local count = 0
    for _, tok in ipairs(tokens) do
        if tok.kind == "key" then
            keyStroke({}, tok.value, 0)
            count = count + 1
        elseif utils.utf8_len(tok.value) > PASTE_THRESHOLD then
            local prev_clip = hs.pasteboard.getContents()
            hs.pasteboard.setContents(tok.value)
            keyStroke({"cmd"}, "v", 0)
            count = count + 1
            hs.timer.doAfter(0.5, function() hs.pasteboard.setContents(prev_clip or "") end)
        else
            keyStrokes(tok.value)
            count = count + utils.utf8_len(tok.value)
        end
    end
    return count
end

local function emit_raw_text(text)
    if utils.utf8_len(text) > PASTE_THRESHOLD then
        local prev_clip = hs.pasteboard.getContents()
        hs.pasteboard.setContents(text)
        keyStroke({"cmd"}, "v", 0)
        hs.timer.doAfter(0.5, function() hs.pasteboard.setContents(prev_clip or "") end)
        return 1
    else
        keyStrokes(text)
        return utils.utf8_len(text)
    end
end

local function text_from_tokens(tokens)
    local parts = {}
    for _, tok in ipairs(tokens) do
        if tok.kind == "text" then table.insert(parts, tok.value) end
    end
    return table.concat(parts)
end

---------------------------------------------------------------------------
-- Engine Logic (LLM + Previews + Keyboard Events)
---------------------------------------------------------------------------
function M._perform_llm_check()
    if not llm_enabled then return end
    local words = {}
    for w in buffer:gmatch("%S+%s*") do table.insert(words, w) end
    
    if #words > 0 then
        local start_idx = math.max(1, #words - 4) 
        local tail_text = table.concat(words, "", start_idx)
        
        if tail_text and #tail_text >= 2 then
            ui.show_custom_preview("⏳ ...", true, preview_enabled) 
            llm.fetch_llm_prediction(buffer, tail_text, current_llm_model, function(deletes, to_type, nw, chunks)
                current_llm_prediction = { deletes = deletes, to_type = to_type }
                
                local display_text = hs.styledtext.new("✨ ", { font = {name = ".AppleSystemUIFont", size = 14, traits={bold=true}}, color = {white = 1.0, alpha = 1.0} })
                for _, chunk in ipairs(chunks) do
                    local traits = chunk.color == "grey" and {italic=true} or {bold=true}
                    local hex_color = chunk.color == "green" and {red=0.2, green=0.8, blue=0.2, alpha=1.0} or 
                                      (chunk.color == "orange" and {red=1.0, green=0.6, blue=0.0, alpha=1.0} or {white=0.6, alpha=1.0})
                    display_text = display_text .. hs.styledtext.new(chunk.text, { font = {name = ".AppleSystemUIFont", size = 14, traits=traits}, color = hex_color })
                end
                
                if nw and nw ~= "" then
                    local nw_display = (#chunks == 0) and (nw:match("^%s*(.-)$") or nw) or nw
                    display_text = display_text .. hs.styledtext.new(nw_display, { font = {name = ".AppleSystemUIFont", size = 14, traits={bold=true}}, color = {red = 1.0, green = 0.6, blue = 0.0, alpha = 1.0} })
                end
                
                ui.show_custom_preview(display_text, true, preview_enabled)
            end, function()
                ui.hide_preview()
                current_llm_prediction = nil
            end)
        end
    end
end
M._llm_timer = hs.timer.delayed.new(llm_debounce_time, M._perform_llm_check)

local function update_preview(buf)
    if M._llm_timer and M._llm_timer:running() then M._llm_timer:stop() end
    current_llm_prediction = nil

    if not buf or #buf == 0 then
        ui.hide_preview()
        return
    end

    local last_word = buf:match("([^%s]+)$")
    if not last_word then 
        ui.hide_preview()
        return 
    end

    local match_repl = nil

    -- 1. Query external dynamic providers (@lettres, dt, etc.)
    for _, provider in ipairs(_preview_providers) do
        match_repl = provider(buf)
        if match_repl then break end
    end

    -- 2. Search in static mappings if no match
    if not match_repl then
        for _, m in ipairs(mappings) do
            -- Case A: Waiting for final character ★ (e.g., "mot" + ★)
            if m.trigger == last_word .. "★" then
                local clean_repl = text_from_tokens(tokens_from_repl(m.repl))
                -- Exclude basic fallback that doubles the letter (e.g., a★ -> a)
                if clean_repl ~= last_word then
                    match_repl = m.repl
                    break
                end
            
            -- Case B: The whole word was typed (waiting for terminator, or auto)
            elseif m.trigger == last_word then
                -- Exclude "rolls" (is_word=false AND auto=true, e.g., "hc"->"wh")
                if not (m.is_word == false and m.auto == true) then
                    local clean_repl = text_from_tokens(tokens_from_repl(m.repl))
                    -- Ensure output is strictly different from what was typed
                    if clean_repl ~= last_word then
                        match_repl = m.repl
                        break
                    end
                end
            end
        end
    end

    -- 3. Display or LLM fallback
    if match_repl then
        local clean_repl = text_from_tokens(tokens_from_repl(match_repl))
        ui.show_custom_preview(clean_repl, false, preview_enabled)
    else
        ui.hide_preview()
        if llm_enabled and M._llm_timer then M._llm_timer:start() end
    end
end

local function onKeyDown(e)
    if processing_paused then return false end
    
    local keyCode = e:getKeyCode()

    -- 1. Intercept TAB for LLM (Highest Priority)
    if keyCode == 48 and current_llm_prediction then 
        local deletes = current_llm_prediction.deletes
        local to_type = current_llm_prediction.to_type
        
        ui.hide_preview()
        current_llm_prediction = nil
        is_replacing = true
        
        if deletes > 0 then
            for _ = 1, deletes do keyStroke(nil, 'delete', 0) end
        end
        
        local strokes_emitted = emit_raw_text(to_type)

        if deletes == 0 then
            buffer = buffer .. to_type
        else
            local trig_start = utf8.offset(buffer, -deletes)
            buffer = (trig_start and string.sub(buffer, 1, trig_start - 1) or "") .. to_type
        end
        
        hs.timer.doAfter(0.05 + ((deletes + strokes_emitted) * 0.005), function() is_replacing = false end)
        return true 
    end

    -- 2. Let Interceptors see the event EARLY. This allows submodules (like personal_info)
    -- to reset their internal state if Esc, Enter, or Nav keys are pressed.
    local _interceptor_suppress = false
    for _, iceptor in ipairs(_interceptors) do
        local result = iceptor(e, buffer)
        if result == "consume" then return true end
        if result == "suppress" then _interceptor_suppress = true; break end
    end

    -- 3. Intercept ESC to hide preview and reset buffer entirely
    if keyCode == 53 then
        if current_llm_prediction then
            ui.hide_preview()
            current_llm_prediction = nil
            return true 
        else
            buffer = ""
            ui.hide_preview()
            return false
        end
    end

    if is_replacing then return false end

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
        ui.hide_preview()
        return false
    end

    -- 4. Backspace
    if keyCode == 51 then 
        if flags.cmd or flags.alt then
            buffer = ""; ui.hide_preview(); return false
        end
        if #buffer > 0 then
            local offset = utf8.offset(buffer, -1)
            buffer = offset and string.sub(buffer, 1, offset - 1) or ""
            update_preview(buffer)
        end
        return false
    end

    -- 5. Navigation & structure keys that MUST reset the buffer to prevent ghost hotstrings
    -- Note: Enter (36) and Tab (48) are intentionally EXCLUDED here so they can act as Terminators!
    -- FwdDel(117), Home(115), PgUp(116), End(119), PgDn(121), Arrows(123-126)
    if keyCode == 117 or keyCode == 115 or keyCode == 116 or keyCode == 119 or keyCode == 121 or (keyCode >= 123 and keyCode <= 126) then
        buffer = ""
        ui.hide_preview()
        return false
    end

    local chars = e:getCharacters(false)
    if not chars or chars == "" then return false end

    buffer = buffer .. chars
    if #buffer > 500 then buffer = string.sub(buffer, utf8.offset(buffer, -500) or 1) end
    
    update_preview(buffer)

    if _interceptor_suppress or rescan_suppressed() then return false end

    -- 6. Trigger Checking
    if time_since_last_key <= allowed_delay then
        local char_count = utils.utf8_len(chars)
        local prefix_before = string.sub(buffer, 1, (utf8.offset(buffer, -char_count) or (#buffer+1)) - 1)
        
        local function utf8_ends_with(s, suffix)
            local n = utils.utf8_len(suffix)
            local start = utf8.offset(s, -n)
            return start and string.sub(s, start) == suffix or false
        end

        for _, m in ipairs(mappings) do
            local trigger = m.trigger

            -- Auto expansion
            if utf8_ends_with(buffer, trigger) then
                if m.auto then
                    local valid = true
                    if m.is_word and utils.utf8_len(buffer) > utils.utf8_len(trigger) then
                        if not trigger:match("^[   ]") then
                            local start = utf8.offset(buffer, -utils.utf8_len(trigger))
                            local prefix = start and string.sub(buffer, 1, start - 1) or ""
                            local offset = utf8.offset(prefix, -1)
                            if utils.is_letter_char(offset and string.sub(prefix, offset) or "") then valid = false end
                        end
                    end
                    if valid then
                        local repl_tokens = tokens_from_repl(m.repl)
                        local repl_text = text_from_tokens(repl_tokens)
                        if repl_text == trigger then
                            if m.final_result then M.suppress_rescan() end
                            ui.hide_preview()
                            return false
                        end

                        local smart_deletes = utils.utf8_len(trigger) - char_count
                        local smart_type = repl_text
                        if repl_text == m.repl then
                            local screen_text = utils.utf8_sub(trigger, 1, utils.utf8_len(trigger) - char_count)
                            local common_len = utils.get_common_prefix_utf8(screen_text, repl_text)
                            smart_deletes = utils.utf8_len(screen_text) - common_len
                            smart_type = utils.utf8_sub(repl_text, common_len + 1)
                        end

                        is_replacing = true
                        ui.hide_preview()

                        if smart_deletes > 0 then
                            for _ = 1, smart_deletes do keyStroke({}, 'delete', 0) end
                        end

                        local strokes_emitted = repl_text == m.repl and emit_raw_text(smart_type) or emit_tokens(repl_tokens)
                        local b_len = utils.utf8_len(buffer)
                        local trig_start_offset = utf8.offset(buffer, -smart_deletes)
                        buffer = (trig_start_offset and string.sub(buffer, 1, trig_start_offset - 1) or "") .. smart_type

                        if m.final_result then M.suppress_rescan() end
                        hs.timer.doAfter(0.05 + ((smart_deletes + strokes_emitted) * 0.005), function() is_replacing = false end)
                        return true
                    end
                end
            end

            -- Manual expansion (with terminator like Space, Enter, Tab)
            if not m.auto and is_terminator(chars) then
                local end_pos = utf8.offset(buffer, -char_count) or (#buffer + 1)
                local start_pos = utf8.offset(buffer, -(char_count + utils.utf8_len(trigger)))
                local seg = (start_pos and end_pos and start_pos <= end_pos - 1) and string.sub(buffer, start_pos, end_pos - 1) or nil
                
                if seg == trigger then
                    local valid = true
                    if m.is_word and not trigger:match("^[   ]") then
                        local before_trigger = start_pos and string.sub(buffer, 1, start_pos - 1) or ""
                        local offset2 = utf8.offset(before_trigger, -1)
                        if utils.is_letter_char(offset2 and string.sub(before_trigger, offset2) or "") then valid = false end
                    end

                    if valid then
                        local trigger_len = utils.utf8_len(trigger)
                        local consume_term = terminator_is_consumed(chars)

                        if m.repl == trigger then
                            if m.final_result then M.suppress_rescan() end
                            ui.hide_preview()
                            return false
                        end

                        hs.timer.doAfter(0, function()
                            local repl_tokens = tokens_from_repl(m.repl)
                            local repl_text   = text_from_tokens(repl_tokens)
                            
                            local smart_deletes = trigger_len
                            local smart_type = repl_text
                            if repl_text == m.repl then
                                local common_len = utils.get_common_prefix_utf8(trigger, repl_text)
                                smart_deletes = trigger_len - common_len
                                smart_type = utils.utf8_sub(repl_text, common_len + 1)
                            end
                            
                            is_replacing = true
                            ui.hide_preview()
                            
                            if smart_deletes > 0 then for _ = 1, smart_deletes do keyStroke({}, 'delete', 0) end end
                            
                            local strokes_emitted = repl_text == m.repl and emit_raw_text(smart_type) or emit_tokens(repl_tokens)
                            
                            if not consume_term then 
                                if chars == "\r" or chars == "\n" then
                                    keyStroke({}, "return", 0)
                                elseif chars == "\t" then
                                    keyStroke({}, "tab", 0)
                                else
                                    keyStrokes(chars)
                                end
                                strokes_emitted = strokes_emitted + utils.utf8_len(chars)
                            end

                            local trig_start_offset = utf8.offset(buffer, -smart_deletes)
                            buffer = (trig_start_offset and string.sub(buffer, 1, trig_start_offset - 1) or "") .. smart_type .. (consume_term and "" or chars)

                            if m.final_result then M.suppress_rescan() end
                            hs.timer.doAfter(0.05 + ((smart_deletes + strokes_emitted) * 0.005), function() is_replacing = false end)
                        end)

                        return true
                    end
                end
            end
        end
    end
    
    -- Optional: If we reach this point, it means no rule intercepted Enter (36) or Tab (48).
    -- We reset the buffer to prevent ghost words from bridging across a line break.
    if keyCode == 36 or keyCode == 48 then
        buffer = ""
    end

    return false
end

local tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)
local mouse_tap = eventtap.new(
    { eventtap.event.types.leftMouseDown, eventtap.event.types.rightMouseDown, eventtap.event.types.middleMouseDown },
    function() buffer = ""; ui.hide_preview(); current_llm_prediction = nil; return false end
)

function M.start() tap:start(); mouse_tap:start() end
function M.stop() tap:stop(); mouse_tap:stop(); ui.hide_preview(); current_llm_prediction = nil end

M.start()
return M
