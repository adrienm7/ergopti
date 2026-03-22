-- modules/keymap.lua
-- Core hotstring engine: registers text expansion mappings, intercepts
-- keyboard events, drives the preview tooltip, and delegates LLM predictions.

local eventtap   = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke  = hs.eventtap.keyStroke

local text_utils = require("lib.text_utils")
local llm        = require("modules.llm")

local ok_tt, tooltip = pcall(require, "ui.tooltip")
if not ok_tt then
    hs.printf("[keymap] WARNING: ui.tooltip failed to load (%s) — previews disabled.", tostring(tooltip))
    tooltip = { show = function() end, hide = function() end }
end

local ok_vsb, vscode_bridge = pcall(require, "lib.vscode_bridge")
if ok_vsb and vscode_bridge.setup then pcall(vscode_bridge.setup) end

local M = {}

-- =============================================
-- ========== 1. DEFAULTS & CONSTANTS ==========
-- =============================================

M.DEFAULT_BASE_DELAY_SEC = 0.75

local PASTE_THRESHOLD = 30

local KEY_COMMANDS = {
    Left = "left", Right = "right", Up = "up", Down = "down",
    Home = "home", End = "end",
    Delete = "forwarddelete", Del = "forwarddelete",
    Backspace = "delete", BackSpace = "delete", BS = "delete",
    Tab = "tab", Enter = "return", Return = "return",
    Escape = "escape", Esc = "escape",
}

-- =====================================
-- ========== 2. MODULE STATE ==========
-- =====================================

local groups             = {}
local current_group      = nil
local mappings           = {}
local mappings_lookup    = {}
local _interceptors      = {}
local _preview_providers = {}
local current_trigger_char   = "★"
local group_post_load_hooks = {}

local BASE_DELAY_SEC       = M.DEFAULT_BASE_DELAY_SEC
local buffer               = ""
local is_replacing         = false
local last_key_time        = 0
local last_key_was_complex = false
local seq_counter          = 0
local processing_paused    = false
local _no_rescan_until     = 0

local current_llm_prediction = nil
local current_llm_model      = llm.DEFAULT_LLM_MODEL
local llm_enabled            = llm.DEFAULT_LLM_ENABLED
local llm_debounce_time      = llm.DEFAULT_LLM_DEBOUNCE
local preview_enabled        = true

local llm_context_length  = 500
local llm_reset_on_nav    = true
local llm_temperature     = 0.1
local llm_max_predict     = 40
local llm_excluded_apps   = {}   -- app names where LLM is disabled

-- ==========================================
-- ========== 3. PUBLIC CONFIG API ==========
-- ==========================================

function M.set_llm_model(model_name)         current_llm_model    = model_name  end
function M.set_llm_context_length(len)       llm_context_length   = len         end
function M.set_llm_reset_on_nav(reset)       llm_reset_on_nav     = reset       end
function M.set_llm_temperature(temp)         llm_temperature      = temp        end
function M.set_llm_max_predict(max)          llm_max_predict      = max         end
function M.get_llm_enabled()                 return llm_enabled                 end

--- Set a list of application names where LLM predictions are suppressed.
---@param apps table  e.g. {"Visual Studio Code", "Xcode"}
function M.set_llm_excluded_apps(apps)
    llm_excluded_apps = type(apps) == "table" and apps or {}
end

function M.set_llm_enabled(enabled)
    llm_enabled = enabled
    if not enabled then
        tooltip.hide()
        current_llm_prediction = nil
        if M._llm_timer and M._llm_timer:running() then M._llm_timer:stop() end
    end
end

function M.set_preview_enabled(enabled)
    preview_enabled = enabled
    if not enabled then tooltip.hide() end
end

function M.set_llm_debounce(seconds)
    llm_debounce_time = seconds
    if M._llm_timer then M._llm_timer:stop() end
    M._llm_timer = hs.timer.delayed.new(llm_debounce_time, M._perform_llm_check)
end

function M.get_base_delay()       return BASE_DELAY_SEC                  end
function M.set_base_delay(secs)   BASE_DELAY_SEC = math.max(0, secs)     end
function M.pause_processing()     processing_paused = true               end
function M.resume_processing()    processing_paused = false              end
function M.is_processing_paused() return processing_paused               end

function M.suppress_rescan(duration)
    _no_rescan_until = hs.timer.secondsSinceEpoch() + (duration or 0.5)
    buffer = ""
end

local function rescan_suppressed()
    return hs.timer.secondsSinceEpoch() < _no_rescan_until
end

-- ===================================================
-- ========== 4. GROUP & MAPPING MANAGEMENT ==========
-- ===================================================

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

function M.register_interceptor(fn)      table.insert(_interceptors, fn)      end
function M.register_preview_provider(fn) table.insert(_preview_providers, fn) end

local function record_group(name, path, kind)
    local seqs = {}
    for _, m in ipairs(mappings) do
        if m.group == name then table.insert(seqs, m.seq) end
    end
    groups[name] = { path = path, seqs = seqs, enabled = true, kind = kind or "lua" }
end

function M.load_file(name, path)
    current_group = name
    local ok, err = pcall(dofile, path)
    if not ok then hs.printf("[keymap] Error loading '%s': %s", path, tostring(err)) end
    current_group = nil
    record_group(name, path, "lua")
    M.sort_mappings()
end

function M.load_toml(name, path)
    local toml_reader = require("lib.toml_reader")
    local ok, data = pcall(toml_reader.parse, path)
    if not ok or not data then
        hs.printf("[keymap] Failed to parse TOML '%s': %s", path, tostring(data))
        return
    end

    current_group = name
    local sections_info = {}

    for _, sec_name in ipairs(data.sections_order) do
        if sec_name == "-" then
            table.insert(sections_info, { name = "-", description = "-", count = 0 })
            goto continue_sec
        end
        local sec = data.sections[sec_name]
        if sec then
            if sec.is_placeholder then
                table.insert(sections_info, {
                    name = sec_name, description = sec.description,
                    count = 0, is_module_placeholder = true,
                })
                goto continue_sec
            end
            if M.is_section_enabled(name, sec_name) then
                for _, entry in ipairs(sec.entries) do
                    M.add(entry.trigger, entry.output, {
                        is_word           = entry.is_word,
                        auto_expand       = entry.auto_expand,
                        is_case_sensitive = entry.is_case_sensitive,
                        final_result      = entry.final_result,
                    })
                end
            end
            table.insert(sections_info, {
                name = sec_name, description = sec.description, count = #sec.entries,
            })
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
        path             = path, seqs = seqs, enabled = true, kind = "toml",
        meta_description = data.meta and data.meta.description or nil,
        sections         = sections_info,
    }
end

function M.is_section_enabled(group_name, section_name)
    return hs.settings.get("hotstrings_section_" .. group_name .. "_" .. section_name) ~= false
end

function M.is_repeat_feature_enabled()
    for name, g in pairs(groups) do
        if g.enabled and g.sections then
            for _, sec in ipairs(g.sections) do
                if sec.name == "repeat" then return M.is_section_enabled(name, "repeat") end
            end
        end
    end
    return false
end

function M.disable_section(group_name, section_name)
    hs.settings.set("hotstrings_section_" .. group_name .. "_" .. section_name, false)
    if M.is_group_enabled(group_name) then M.disable_group(group_name); M.enable_group(group_name) end
end

function M.enable_section(group_name, section_name)
    hs.settings.set("hotstrings_section_" .. group_name .. "_" .. section_name, nil)
    if M.is_group_enabled(group_name) then M.disable_group(group_name); M.enable_group(group_name) end
end

function M.get_sections(name)         return groups[name] and groups[name].sections or nil         end
function M.get_meta_description(name) return groups[name] and groups[name].meta_description or nil end
function M.set_group_context(name)    current_group = name                                         end
function M.set_post_load_hook(name, fn) group_post_load_hooks[name] = fn end

function M.disable_group(name)
    if not groups[name] or not groups[name].enabled then return end
    groups[name].enabled = false
    local kept = {}
    for _, m in ipairs(mappings) do if m.group ~= name then table.insert(kept, m) end end
    mappings = kept
    rebuild_lookup()
end

function M.is_group_enabled(name) return groups[name] and groups[name].enabled or false end

function M.list_groups()
    local out = {}
    for name, g in pairs(groups) do out[name] = g.enabled end
    return out
end

function M.register_lua_group(name, meta_description, sections)
    groups[name] = {
        path = nil, seqs = {}, enabled = true, kind = "lua",
        meta_description = meta_description, sections = sections or {},
    }
end

function M.enable_group(name)
    local g = groups[name]
    if not g or g.enabled then return end
    if g.path == nil then
        g.enabled = true
        local hook = group_post_load_hooks[name]
        if hook then hook(); M.sort_mappings() end
        return
    end
    if g.kind == "toml" then M.load_toml(name, g.path) else M.load_file(name, g.path) end
    local hook = group_post_load_hooks[name]
    if hook then hook(); M.sort_mappings() end
end

-- ====================================
-- ========== 5. TERMINATORS ==========
-- ====================================

local TERMINATOR_DEFS = {
    { key = "space",  chars  = { " " },           label = "Espace"                },
    { key = "tab",    chars  = { "\t" },           label = "Tabulation"            },
    { key = "enter",  chars  = { "\r", "\n" },     label = "Entrée"                },
    { key = "period", chars  = { "." },            label = "Point (.)"             },
    { key = "comma",  chars  = { "," },            label = "Virgule (,)"           },
    { key = "nbsp",   prefix = "\194\160",         label = "Espace insécable"      },
    { key = "nnbsp",  prefix = "\226\128\175",     label = "Espace fine insécable" },
    { key = "star",   chars  = { current_trigger_char }, label = "Touche " .. current_trigger_char, consume = true },
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
function M.is_terminator_enabled(key)           return _terminator_enabled[key] ~= false        end
function M.get_terminator_defs()                return TERMINATOR_DEFS                          end

function M.set_trigger_char(char)
    current_trigger_char = char
    for _, def in ipairs(TERMINATOR_DEFS) do
        if def.key == "star" then
            def.chars = { char }
            def.label = "Touche " .. char
        end
    end
end

-- ===============================================
-- ========== 6. HOTSTRING REGISTRATION ==========
-- ===============================================

function M.add(trigger, replacement, opts)
    if current_trigger_char ~= "★" then
        trigger = trigger:gsub("★", current_trigger_char)
    end
    opts = opts or {}
    local is_word           = opts.is_word            == true
    local is_auto           = opts.auto_expand        == true
    local is_case_sensitive = opts.is_case_sensitive  == true
    local is_final          = opts.final_result       == true

    local function add_raw(t, r, a)
        local k = t .. "\0" .. tostring(is_word) .. "\0" .. tostring(a)
        local existing = mappings_lookup[k]
        if existing then
            existing.repl = r
            if current_group then existing.group = current_group end
            return
        end
        seq_counter = seq_counter + 1
        local entry = {
            trigger = t, repl = r, is_word = is_word, auto = a,
            seq = seq_counter, tlen = text_utils.utf8_len(t), final_result = is_final,
        }
        if current_group then entry.group = current_group end
        table.insert(mappings, entry)
        mappings_lookup[k] = entry
    end

    local function add_with_space_variants(t, r)
        add_raw(t, r, is_auto)
        local starts_with_space = t:match("^[ \194\160\226\128\175]") ~= nil
        if not starts_with_space and t:match(" ") then
            add_raw((t:gsub(" ", "\194\160")),     r, is_auto)
            add_raw((t:gsub(" ", "\226\128\175")), r, is_auto)
        end
    end

    local lower_trig = text_utils.trig_lower(trigger)
    local title_repl = text_utils.repl_title(replacement)
    local upper_repl = text_utils.repl_upper(replacement)

    if is_case_sensitive then
        add_with_space_variants(trigger, replacement)
    else
        local title_trigs = text_utils.trig_title(lower_trig)
        local upper_trigs = text_utils.trig_upper(lower_trig)
        add_with_space_variants(lower_trig, replacement)
        for _, tt in ipairs(title_trigs) do
            if tt ~= lower_trig then add_with_space_variants(tt, title_repl) end
        end
        for _, ut in ipairs(upper_trigs) do
            local is_title = false
            for _, tt in ipairs(title_trigs) do
                if ut == tt then is_title = true; break end
            end
            if ut ~= lower_trig and not is_title then
                add_with_space_variants(ut, upper_repl)
            end
        end
    end

    local first_char_src = is_case_sensitive and trigger or lower_trig
    local first_char = first_char_src:match("^[%z\1-\127\194-\244][\128-\191]*")
    if first_char == "," then
        local rest = lower_trig:sub(#first_char + 1)
        if rest ~= "" then
            add_with_space_variants(";" .. text_utils.trig_lower(rest), title_repl)
            for _, ru in ipairs(text_utils.trig_upper(rest)) do
                local alias = ";" .. ru
                if alias ~= ";" .. text_utils.trig_lower(rest) then
                    add_with_space_variants(alias, upper_repl)
                end
            end
        end
    end
end

-- ======================================
-- ========== 7. TEXT EMISSION ==========
-- ======================================

local function should_paste(text)
    if text_utils.utf8_len(text) > PASTE_THRESHOLD then return true end
    return text_utils.contains_high_unicode(text)
end

local function push_text_tokens(tokens, text)
    local first = true
    for segment in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not first then
            table.insert(tokens, { kind = "key", value = "return" })
        end
        if segment ~= "" then
            table.insert(tokens, { kind = "text", value = segment })
        end
        first = false
    end
end

local function tokens_from_repl(repl)
    local tokens = {}
    local i = 1
    while i <= #repl do
        local s, e, name = repl:find("{(%w+)}", i)
        if s then
            if s > i then push_text_tokens(tokens, repl:sub(i, s - 1)) end
            local title  = name:sub(1,1):upper() .. name:sub(2):lower()
            local hs_key = KEY_COMMANDS[name] or KEY_COMMANDS[title]
            if hs_key then
                table.insert(tokens, { kind = "key", value = hs_key })
            else
                table.insert(tokens, { kind = "text", value = "{" .. name .. "}" })
            end
            i = e + 1
        else
            push_text_tokens(tokens, repl:sub(i))
            break
        end
    end
    return tokens
end

local function emit_tokens(tokens)
    local count = 0
    for _, tok in ipairs(tokens) do
        if tok.kind == "key" then
            keyStroke({}, tok.value, 0); count = count + 1
        elseif should_paste(tok.value) then
            local prev = hs.pasteboard.getContents()
            hs.pasteboard.setContents(tok.value)
            keyStroke({ "cmd" }, "v", 0); count = count + 1
            hs.timer.doAfter(0.5, function() hs.pasteboard.setContents(prev or "") end)
        else
            keyStrokes(tok.value); count = count + text_utils.utf8_len(tok.value)
        end
    end
    return count
end

local function emit_text(text)
    if should_paste(text) then
        local prev = hs.pasteboard.getContents()
        hs.pasteboard.setContents(text)
        keyStroke({ "cmd" }, "v", 0)
        hs.timer.doAfter(0.5, function() hs.pasteboard.setContents(prev or "") end)
        return 1
    end
    keyStrokes(text)
    return text_utils.utf8_len(text)
end

local function plain_text(tokens)
    local parts = {}
    for _, tok in ipairs(tokens) do
        if tok.kind == "text" then table.insert(parts, tok.value) end
    end
    return table.concat(parts)
end

-- =============================================
-- ========== 8. PREVIEW & LLM ENGINE ==========
-- =============================================

-- Returns true if LLM should be suppressed for the current front app.
local function llm_suppressed_for_app()
    local frontApp = hs.application.frontmostApplication()
    if not frontApp then return false end
    -- Always suppress inside the hotstring editor window
    local win = frontApp:focusedWindow()
    if win and win:title() == "Hotstrings Personnels" then return true end
    -- Check user-configured exclusion list
    local appName = frontApp:name() or ""
    for _, excluded in ipairs(llm_excluded_apps) do
        if excluded == appName then return true end
    end
    return false
end

function M._perform_llm_check()
    if not llm_enabled then return end
    if llm_suppressed_for_app() then return end

    local words = {}
    for w in buffer:gmatch("%S+%s*") do table.insert(words, w) end
    if #words == 0 then return end
    local tail = table.concat(words, "", math.max(1, #words - 4))
    if not tail or #tail < 2 then return end

    tooltip.show("⏳ ...", true, preview_enabled)

    local color_map = {
        green  = { red = 0.2, green = 0.8, blue = 0.2, alpha = 1.0 },
        orange = { red = 1.0, green = 0.6, blue = 0.0, alpha = 1.0 },
        grey   = { white = 0.6, alpha = 1.0 },
    }

    llm.fetch_llm_prediction(buffer, tail, current_llm_model, llm_temperature, llm_max_predict,
        function(deletes, to_type, new_word, chunks)
            current_llm_prediction = { deletes = deletes, to_type = to_type }
            local styled = hs.styledtext.new("✨ ", {
                font  = { name = ".AppleSystemUIFont", size = 14, traits = { bold = true } },
                color = { white = 1.0, alpha = 1.0 },
            })
            for _, chunk in ipairs(chunks) do
                styled = styled .. hs.styledtext.new(chunk.text, {
                    font  = { name = ".AppleSystemUIFont", size = 14,
                              traits = chunk.color == "grey" and { italic = true } or { bold = true } },
                    color = color_map[chunk.color] or color_map.grey,
                })
            end
            if new_word and new_word ~= "" then
                local display = (#chunks == 0) and (new_word:match("^%s*(.-)$") or new_word) or new_word
                styled = styled .. hs.styledtext.new(display, {
                    font  = { name = ".AppleSystemUIFont", size = 14, traits = { bold = true } },
                    color = color_map.orange,
                })
            end
            tooltip.show(styled, true, preview_enabled)
        end,
        function() tooltip.hide(); current_llm_prediction = nil end
    )
end

M._llm_timer = hs.timer.delayed.new(llm_debounce_time, M._perform_llm_check)

local function update_preview(buf)
    if M._llm_timer and M._llm_timer:running() then M._llm_timer:stop() end
    current_llm_prediction = nil
    if not buf or #buf == 0 then tooltip.hide(); return end
    local last_word = buf:match("([^%s]+)$")
    if not last_word then tooltip.hide(); return end
    local match_repl = nil
    for _, provider in ipairs(_preview_providers) do
        match_repl = provider(buf)
        if match_repl then break end
    end
    if not match_repl then
        for _, m in ipairs(mappings) do
            if m.trigger == last_word .. current_trigger_char then
                local clean = plain_text(tokens_from_repl(m.repl))
                if clean ~= last_word then match_repl = m.repl; break end
            elseif m.trigger == last_word then
                if not (m.is_word == false and m.auto == true) then
                    local clean = plain_text(tokens_from_repl(m.repl))
                    if clean ~= last_word then match_repl = m.repl; break end
                end
            end
        end
    end
    local is_fallback_repetition = false
    if match_repl and M.is_repeat_feature_enabled() then
        local clean = plain_text(tokens_from_repl(match_repl))
        local last_char_offset = utf8.offset(last_word, -1)
        if last_char_offset then
            local last_char = last_word:sub(last_char_offset)
            if clean == last_word .. last_char then is_fallback_repetition = true end
        end
    end
    if match_repl and not is_fallback_repetition then
        tooltip.show(plain_text(tokens_from_repl(match_repl)), false, preview_enabled)
    else
        tooltip.hide()
        if llm_enabled and M._llm_timer then M._llm_timer:start() end
    end
end

-- ===============================================
-- ========== 9. KEYBOARD EVENT HANDLER ==========
-- ===============================================

local function onKeyDown(e)
    if processing_paused then return false end
    local keyCode = e:getKeyCode()

    -- Détection de l'éditeur placée au début
    local function in_hotstring_editor()
        local app = hs.application.frontmostApplication()
        if not app then return false end
        local win = app:focusedWindow()
        return win ~= nil and win:title() == "Hotstrings Personnels"
    end
    
    local in_editor = in_hotstring_editor()

    -- 1. On bloque l'interaction LLM si on est dans l'UI
    if not in_editor and keyCode == 48 and current_llm_prediction then
        local deletes = current_llm_prediction.deletes
        local to_type = current_llm_prediction.to_type
        tooltip.hide(); current_llm_prediction = nil; is_replacing = true
        for _ = 1, deletes do keyStroke(nil, "delete", 0) end
        local emitted = emit_text(to_type)
        if deletes == 0 then buffer = buffer .. to_type
        else
            local start = utf8.offset(buffer, -deletes)
            buffer = (start and buffer:sub(1, start - 1) or "") .. to_type
        end
        hs.timer.doAfter(0.05 + (deletes + emitted) * 0.005, function() is_replacing = false end)
        return true
    end

    local suppress_triggers = false
    for _, interceptor in ipairs(_interceptors) do
        local result = interceptor(e, buffer)
        if result == "consume" then return true end
        if result == "suppress" then suppress_triggers = true; break end
    end

    -- 2. On skip le hide() du tooltip si on est dans l'UI
    if keyCode == 53 then
        if not in_editor and current_llm_prediction then tooltip.hide(); current_llm_prediction = nil; return true end
        if llm_reset_on_nav then buffer = "" end
        if not in_editor then tooltip.hide() end
        return false
    end

    if is_replacing then return false end

    local flags = e:getFlags()
    local now   = hs.timer.secondsSinceEpoch()
    local dt    = now - last_key_time
    last_key_time = now
    local is_complex    = flags.shift or flags.alt
    local allowed_delay = BASE_DELAY_SEC * ((is_complex or last_key_was_complex) and 2 or 1)
    last_key_was_complex = is_complex

    if flags.cmd or flags.ctrl then 
        buffer = ""
        if not in_editor then tooltip.hide() end
        return false 
    end

    if keyCode == 51 then
        if flags.cmd or flags.alt then 
            buffer = ""
            if not in_editor then tooltip.hide() end
            return false 
        end
        if #buffer > 0 then
            local offset = utf8.offset(buffer, -1)
            buffer = offset and buffer:sub(1, offset - 1) or ""
            if not in_editor then update_preview(buffer) end
        end
        return false
    end

    if keyCode == 117 or keyCode == 115 or keyCode == 116
        or keyCode == 119 or keyCode == 121
        or (keyCode >= 123 and keyCode <= 126) then
        if llm_reset_on_nav then buffer = "" end
        if not in_editor then tooltip.hide() end
        return false
    end

    local chars = e:getCharacters(false)
    if not chars or chars == "" then return false end

    buffer = buffer .. chars
    if #buffer > llm_context_length then
        buffer = buffer:sub(utf8.offset(buffer, -llm_context_length) or 1)
    end
    
    -- 3. Pas de preview dans l'UI
    if not in_editor then update_preview(buffer) end

    if suppress_triggers or rescan_suppressed() then return false end

    -- ==========================================================
    -- LOGIQUE D'EXPANSION (Extraite pour être passée en async)
    -- ==========================================================
    local function check_triggers()
        if dt <= allowed_delay then
            local char_len = text_utils.utf8_len(chars)
            for _, m in ipairs(mappings) do
                local trigger = m.trigger
                if text_utils.utf8_ends_with(buffer, trigger) and m.auto then
                    local valid = true
                    if m.is_word and text_utils.utf8_len(buffer) > text_utils.utf8_len(trigger)
                        and not trigger:match("^[ \194\160\226\128\175]") then
                        local tstart  = utf8.offset(buffer, -text_utils.utf8_len(trigger))
                        local before  = tstart and buffer:sub(1, tstart - 1) or ""
                        local last_ch = utf8.offset(before, -1)
                        if text_utils.is_letter_char(last_ch and before:sub(last_ch) or "") then
                            valid = false
                        end
                    end
                    if valid then
                        local tokens    = tokens_from_repl(m.repl)
                        local repl_text = plain_text(tokens)
                        if repl_text == trigger then
                            if m.final_result then M.suppress_rescan() end
                            if not in_editor then tooltip.hide() end
                            return true
                        end
                        
                        -- 4. Ajustement des backspaces: si on a laissé l'OS imprimer (in_editor),
                        -- on doit effacer TOUT le trigger, sans soustraire char_len.
                        local char_offset = in_editor and 0 or char_len
                        local deletes, to_type = text_utils.utf8_len(trigger) - char_offset, repl_text
                        
                        if repl_text == m.repl then
                            local screen = text_utils.utf8_sub(trigger, 1, text_utils.utf8_len(trigger) - char_offset)
                            local common = text_utils.get_common_prefix_utf8(screen, repl_text)
                            deletes = text_utils.utf8_len(screen) - common
                            to_type = text_utils.utf8_sub(repl_text, common + 1)
                        end
                        
                        is_replacing = true
                        if not in_editor then tooltip.hide() end
                        for _ = 1, deletes do keyStroke({}, "delete", 0) end
                        local emitted = (repl_text == m.repl) and emit_text(to_type) or emit_tokens(tokens)
                        local tstart = utf8.offset(buffer, -text_utils.utf8_len(trigger))
                        buffer = (tstart and buffer:sub(1, tstart - 1) or "") .. repl_text
                        if m.final_result then M.suppress_rescan() end
                        hs.timer.doAfter(0.05 + (deletes + emitted) * 0.005, function() is_replacing = false end)
                        return true
                    end
                end

                if not m.auto and is_terminator(chars) then
                    local buf_end   = utf8.offset(buffer, -char_len) or (#buffer + 1)
                    local trig_len  = text_utils.utf8_len(trigger)
                    local buf_start = utf8.offset(buffer, -(char_len + trig_len))
                    local segment   = (buf_start and buf_start <= buf_end - 1)
                                      and buffer:sub(buf_start, buf_end - 1) or nil
                    if segment == trigger then
                        local valid = true
                        if m.is_word and not trigger:match("^[ \194\160\226\128\175]") then
                            local before  = buf_start and buffer:sub(1, buf_start - 1) or ""
                            local last_ch = utf8.offset(before, -1)
                            if text_utils.is_letter_char(last_ch and before:sub(last_ch) or "") then
                                valid = false
                            end
                        end
                        if valid then
                            local consume_term = terminator_is_consumed(chars)
                            if m.repl == trigger then
                                if m.final_result then M.suppress_rescan() end
                                if not in_editor then tooltip.hide() end
                                return true
                            end
                            
                            local function do_expansion()
                                local tokens    = tokens_from_repl(m.repl)
                                local repl_text = plain_text(tokens)
                                local deletes, to_type = trig_len, repl_text
                                if repl_text == m.repl then
                                    local common = text_utils.get_common_prefix_utf8(trigger, repl_text)
                                    deletes = trig_len - common
                                    to_type = text_utils.utf8_sub(repl_text, common + 1)
                                end
                                
                                -- 5. Ajustement: le système a déjà tapé le terminateur
                                if in_editor then deletes = deletes + char_len end
                                
                                is_replacing = true
                                if not in_editor then tooltip.hide() end
                                for _ = 1, deletes do keyStroke({}, "delete", 0) end
                                local emitted = (repl_text == m.repl) and emit_text(to_type) or emit_tokens(tokens)
                                if not consume_term then
                                    if     chars == "\r" or chars == "\n" then keyStroke({}, "return", 0)
                                    elseif chars == "\t"                  then keyStroke({}, "tab", 0)
                                    else                                       keyStrokes(chars)
                                    end
                                    emitted = emitted + text_utils.utf8_len(chars)
                                end
                                local tstart = utf8.offset(buffer, -(char_len + trig_len))
                                buffer = (tstart and buffer:sub(1, tstart - 1) or "")
                                         .. repl_text .. (consume_term and "" or chars)
                                if m.final_result then M.suppress_rescan() end
                                hs.timer.doAfter(0.05 + (deletes + emitted) * 0.005, function() is_replacing = false end)
                            end

                            -- Exécution immédiate si on est déjà dans le runloop asynchrone
                            if in_editor then do_expansion() else hs.timer.doAfter(0, do_expansion) end
                            return true
                        end
                    end
                end
            end
        end

        if M.is_repeat_feature_enabled() and chars == current_trigger_char then
            local char_len = text_utils.utf8_len(chars)
            local buf_len  = text_utils.utf8_len(buffer)
            if buf_len > char_len then
                local before = buffer:sub(1, utf8.offset(buffer, -char_len) - 1)
                local last_char_offset = utf8.offset(before, -1)
                if last_char_offset then
                    local last_char = before:sub(last_char_offset)
                    is_replacing = true
                    if not in_editor then tooltip.hide() end
                    if in_editor then keyStroke({}, "delete", 0) end -- 6. Retirer l'étoile imprimée par l'OS
                    keyStrokes(last_char)
                    local tstart = utf8.offset(buffer, -char_len)
                    buffer = (tstart and buffer:sub(1, tstart - 1) or "") .. last_char
                    hs.timer.doAfter(0.05, function() is_replacing = false end)
                    return true
                end
            end
        end
        return false
    end

    -- 7. C'est ici que s'opère le choix Synchrone vs Asynchrone
    if in_editor then
        hs.timer.doAfter(0, check_triggers)
        -- On continue vers le return false final pour rendre la main
    else
        if check_triggers() then return true end
    end

    if keyCode == 36 or keyCode == 48 then
        if llm_reset_on_nav then buffer = "" end
    end
    
    return false
end

-- ==========================================
-- ========== 10. MODULE LIFECYCLE ==========
-- ==========================================

local tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)

local mouse_tap = eventtap.new(
    {
        eventtap.event.types.leftMouseDown,
        eventtap.event.types.rightMouseDown,
        eventtap.event.types.middleMouseDown,
    },
    function()
        if llm_reset_on_nav then buffer = "" end
        tooltip.hide(); current_llm_prediction = nil; return false
    end
)

function M.start() tap:start(); mouse_tap:start() end

function M.stop()
    tap:stop(); mouse_tap:stop()
    tooltip.hide(); current_llm_prediction = nil
end

M.start()
return M
