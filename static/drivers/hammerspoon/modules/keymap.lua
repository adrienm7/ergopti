-- modules/keymap.lua
local eventtap   = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke  = hs.eventtap.keyStroke

local text_utils = require("lib.text_utils")
local llm        = require("modules.llm")

local ok_tt, tooltip = pcall(require, "ui.tooltip")
if not ok_tt then
    hs.printf("[keymap] WARNING: ui.tooltip failed to load (%s)", tostring(tooltip))
    tooltip = { show = function() end, hide = function() end,
                show_predictions = function() end, navigate = function() end,
                get_current_index = function() return 1 end,
                make_diff_styled = function() return nil end }
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

local NUM_KEYCODES = {
    [18]=2, [19]=3, [20]=4, [21]=5, [23]=6,
    [22]=7, [26]=8, [28]=9, [25]=10, [29]=11,
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
local current_trigger_char  = "★"
local group_post_load_hooks = {}

local BASE_DELAY_SEC       = M.DEFAULT_BASE_DELAY_SEC
local buffer               = ""
local is_replacing         = false
local last_key_time        = 0
local last_key_was_complex = false
local seq_counter          = 0
local processing_paused    = false
local _no_rescan_until     = 0

local _pending_predictions = {}
local _predictions_active  = false

local _shift_side = nil

local current_llm_model       = llm.DEFAULT_LLM_MODEL
local llm_enabled             = llm.DEFAULT_LLM_ENABLED
local llm_debounce_time       = llm.DEFAULT_LLM_DEBOUNCE
local preview_enabled         = true

local llm_context_length      = 500
local llm_reset_on_nav        = true
local llm_temperature         = 0.1
local llm_max_predict         = 40
local llm_num_predictions     = llm.DEFAULT_LLM_NUM_PREDICTIONS or 3
local llm_excluded_apps       = {}
local llm_arrow_nav_enabled   = false
local llm_arrow_nav_mods      = {}
local llm_show_model_name     = false
local llm_pred_indent         = 0

if tooltip.set_navigate_callback then
    tooltip.set_navigate_callback(function(_) end)
end

-- ==========================================
-- ========== 3. PUBLIC CONFIG API ==========
-- ==========================================

function M.set_llm_model(m)               current_llm_model      = m          end
function M.set_llm_context_length(l)      llm_context_length     = l          end
function M.set_llm_reset_on_nav(r)        llm_reset_on_nav       = r          end
function M.set_llm_temperature(t)         llm_temperature        = t          end
function M.set_llm_max_predict(p)         llm_max_predict        = p          end
function M.set_llm_num_predictions(n)     llm_num_predictions    = n          end
function M.set_llm_arrow_nav_enabled(v)   llm_arrow_nav_enabled  = v          end
function M.set_llm_arrow_nav_mods(m)      llm_arrow_nav_mods     = m or {}    end
function M.set_llm_show_model_name(v)     llm_show_model_name    = v          end
function M.set_llm_pred_indent(v)         llm_pred_indent        = math.max(0,math.min(5,math.floor(tonumber(v) or 0))) end
function M.get_llm_enabled()              return llm_enabled                  end

function M.set_llm_excluded_apps(apps)
    llm_excluded_apps = type(apps) == "table" and apps or {}
end

function M.set_llm_enabled(enabled)
    llm_enabled = enabled
    if not enabled then
        tooltip.hide()
        _pending_predictions = {}
        _predictions_active  = false
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

function M.get_base_delay()       return BASE_DELAY_SEC              end
function M.set_base_delay(secs)   BASE_DELAY_SEC = math.max(0, secs) end
function M.pause_processing()     processing_paused = true           end
function M.resume_processing()    processing_paused = false          end
function M.is_processing_paused() return processing_paused           end

function M.suppress_rescan(duration)
    _no_rescan_until = hs.timer.secondsSinceEpoch() + (duration or 0.5)
    buffer = ""
end

local function suppress_rescan_keep_buffer(duration)
    _no_rescan_until = hs.timer.secondsSinceEpoch() + (duration or 0.3)
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
        path = path, seqs = seqs, enabled = true, kind = "toml",
        meta_description = data.meta and data.meta.description or nil,
        sections = sections_info,
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

function M.disable_section(gn, sn)
    hs.settings.set("hotstrings_section_" .. gn .. "_" .. sn, false)
    if M.is_group_enabled(gn) then M.disable_group(gn); M.enable_group(gn) end
end

function M.enable_section(gn, sn)
    hs.settings.set("hotstrings_section_" .. gn .. "_" .. sn, nil)
    if M.is_group_enabled(gn) then M.disable_group(gn); M.enable_group(gn) end
end

function M.get_sections(n)          return groups[n] and groups[n].sections or nil        end
function M.get_meta_description(n)  return groups[n] and groups[n].meta_description or nil end
function M.set_group_context(n)     current_group = n                                      end
function M.set_post_load_hook(n, f) group_post_load_hooks[n] = f                           end

function M.disable_group(name)
    if not groups[name] or not groups[name].enabled then return end
    groups[name].enabled = false
    if groups[name].path ~= nil then
        local kept = {}
        for _, m in ipairs(mappings) do if m.group ~= name then table.insert(kept, m) end end
        mappings = kept
        rebuild_lookup()
    end
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
    { key = "space",        chars  = { " " },        label = "Espace"                },
    { key = "tab",          chars  = { "\t" },       label = "Tabulation"            },
    { key = "enter",        chars  = { "\r", "\n" }, label = "Entrée"                },
    { key = "period",       chars  = { "." },        label = "Point (.)"             },
    { key = "comma",        chars  = { "," },        label = "Virgule (,)"           },
    { key = "parenright",   chars  = { ")" },        label = "Parenthèse fermante )" },
    { key = "bracketright", chars  = { "]" },        label = "Crochet fermant ]"     },
    { key = "nbsp",         prefix = "\194\160",     label = "Espace insécable"      },
    { key = "nnbsp",        prefix = "\226\128\175", label = "Espace fine insécable" },
    { key = "star",         chars  = { current_trigger_char }, label = "Touche " .. current_trigger_char, consume = true },
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

function M.set_terminator_enabled(key, en) _terminator_enabled[key] = (en ~= false) end
function M.is_terminator_enabled(key)      return _terminator_enabled[key] ~= false  end
function M.get_terminator_defs()           return TERMINATOR_DEFS                    end

function M.set_trigger_char(char)
    current_trigger_char = char
    for _, def in ipairs(TERMINATOR_DEFS) do
        if def.key == "star" then def.chars = { char }; def.label = "Touche " .. char end
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
    
    if replacement:match("\n") or replacement:match("{Tab}") or replacement:match("{Enter}") or replacement:match("{Return}") then
        is_final = true
    end

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
        if not first then table.insert(tokens, { kind = "key", value = "return" }) end
        if segment ~= "" then table.insert(tokens, { kind = "text", value = segment }) end
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

local function reset_predictions()
    _pending_predictions = {}
    _predictions_active  = false
    tooltip.hide()
end

local function apply_prediction(idx)
    local pred = _pending_predictions[idx]
    if not pred then return false end
    reset_predictions()

    local deletes = pred.deletes or 0
    local to_type = pred.to_type or ""

    is_replacing = true
    for _ = 1, deletes do keyStroke(nil, "delete", 0) end
    local emitted = emit_text(to_type)

    if deletes == 0 then
        buffer = buffer .. to_type .. "\226\128\139"
    else
        local start = utf8.offset(buffer, -deletes)
        buffer = (start and buffer:sub(1, start - 1) or "") .. to_type .. "\226\128\139"
    end

    local delay = 0.05 + (deletes + emitted) * 0.005
    hs.timer.doAfter(delay, function()
        is_replacing = false
        suppress_rescan_keep_buffer(0.3)
        if llm_enabled and not is_replacing and M._llm_timer then
            M._llm_timer:start()
        end
    end)
    return true
end

local function llm_suppressed_for_app()
    local frontApp = hs.application.frontmostApplication()
    if not frontApp then return false end
    local ok, win = pcall(function() return frontApp:focusedWindow() end)
    if ok and win then
        local ok_title, title = pcall(function() return win:title() end)
        if ok_title and title == "Hotstrings Personnels" then return true end
    end
    local appName = frontApp:name() or ""
    for _, excluded in ipairs(llm_excluded_apps) do
        if excluded == appName then return true end
    end
    return false
end

local function arrow_mods_match(flags)
    local req = {}
    for _, mod in ipairs(llm_arrow_nav_mods) do
        if not flags[mod] then return false end
        req[mod] = true
    end
    for _, mod in ipairs({"cmd", "shift", "alt", "ctrl"}) do
        if flags[mod] and not req[mod] then return false end
    end
    return true
end

function M._perform_llm_check()
    if not llm_enabled then return end
    if llm_suppressed_for_app() then return end

    local clean_buffer = buffer:gsub("\226\128\139", "")
    local words = {}
    for w in clean_buffer:gmatch("%S+%s*") do table.insert(words, w) end
    if #words == 0 then return end
    local tail = table.concat(words, "", math.max(1, #words - 4))
    if not tail or #tail < 2 then return end

    tooltip.show("⏳ ...", true, preview_enabled)

    local num_pred = math.max(1, math.floor(tonumber(llm_num_predictions) or 3))

    llm.fetch_llm_prediction(
        clean_buffer, tail,
        current_llm_model, llm_temperature, llm_max_predict,
        num_pred,
        function(predictions)
            if not predictions or #predictions == 0 then reset_predictions(); return end
            _pending_predictions = predictions
            _predictions_active  = true
            local mn = llm_show_model_name and current_llm_model or nil
            tooltip.show_predictions(predictions, 1, preview_enabled, mn, llm_pred_indent)
        end,
        function() reset_predictions() end
    )
end

M._llm_timer = hs.timer.delayed.new(llm_debounce_time, M._perform_llm_check)

local function update_preview(buf)
    if M._llm_timer and M._llm_timer:running() then M._llm_timer:stop() end
    reset_predictions()

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
            local group_active = not m.group or not groups[m.group] or groups[m.group].enabled
            if group_active then
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

local _editor_cache_time  = 0
local _editor_cache_value = false
local function in_hotstring_editor()
    local now = hs.timer.secondsSinceEpoch()
    if now - _editor_cache_time < 0.5 then return _editor_cache_value end
    _editor_cache_time = now
    local app = hs.application.frontmostApplication()
    if not app then _editor_cache_value = false; return false end
    
    local ok, win = pcall(function() return app:focusedWindow() end)
    if not ok or not win then _editor_cache_value = false; return false end
    
    local ok_title, title = pcall(function() return win:title() end)
    _editor_cache_value = (ok_title and title == "Hotstrings Personnels")
    return _editor_cache_value
end

local function onKeyDown(e)
    if processing_paused then return false end
    local keyCode = e:getKeyCode()
    local flags   = e:getFlags()

    local in_editor = in_hotstring_editor()

    if not in_editor and _predictions_active and flags.cmd
        and not flags.shift and not flags.alt and not flags.ctrl then
        local n = NUM_KEYCODES[keyCode]
        if n and n <= #_pending_predictions then
            return apply_prediction(n)
        end
    end

    if not in_editor and keyCode == 48 and _predictions_active and #_pending_predictions > 0 then
        if flags.shift then
            if #_pending_predictions > 1 then
                if _shift_side == "left" then
                    if tooltip.navigate then tooltip.navigate(-1) end
                else
                    if tooltip.navigate then tooltip.navigate(1) end
                end
                return true
            else
                return false
            end
        else
            local idx = tooltip.get_current_index and tooltip.get_current_index() or 1
            return apply_prediction(idx)
        end
    end

    local suppress_triggers = false
    for _, interceptor in ipairs(_interceptors) do
        local ok, result = pcall(interceptor, e, buffer)
        if ok then
            if result == "consume" then return true end
            if result == "suppress" then suppress_triggers = true; break end
        end
    end

    if keyCode == 53 then
        if not in_editor and _predictions_active then
            reset_predictions(); return true
        end
        if llm_reset_on_nav then buffer = "" end
        if not in_editor then tooltip.hide() end
        return false
    end

    if is_replacing then return false end

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

        if not in_editor and _predictions_active and #_pending_predictions > 1
            and llm_arrow_nav_enabled
            and (keyCode >= 123 and keyCode <= 126) then
            if arrow_mods_match(flags) then
                local is_prev = (keyCode == 123 or keyCode == 126)
                local is_next = (keyCode == 124 or keyCode == 125)
                if is_prev then
                    if tooltip.navigate then tooltip.navigate(-1) end; return true
                elseif is_next then
                    if tooltip.navigate then tooltip.navigate(1) end; return true
                end
            end
        end

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

    if not in_editor then update_preview(buffer) end

    if suppress_triggers or rescan_suppressed() then return false end

    local function check_triggers()
        if dt <= allowed_delay then
            local char_len = text_utils.utf8_len(chars)
            for _, m in ipairs(mappings) do
                local group_active = not m.group or not groups[m.group] or groups[m.group].enabled
                if group_active then
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
                            buffer = (tstart and buffer:sub(1, tstart - 1) or "") .. repl_text .. "\226\128\139"
                            
                            local base_delay = m.final_result and 0.5 or 0.05
                            local multiplier = m.final_result and 0.015 or 0.005
                            hs.timer.doAfter(base_delay + (deletes + emitted) * multiplier, function() is_replacing = false end)
                            
                            if m.final_result then M.suppress_rescan(1.0) end
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
                                             .. repl_text .. (consume_term and "" or chars) .. "\226\128\139"
                                    
                                    local base_delay = m.final_result and 0.5 or 0.05
                                    local multiplier = m.final_result and 0.015 or 0.005
                                    hs.timer.doAfter(base_delay + (deletes + emitted) * multiplier, function() is_replacing = false end)
                                    
                                    if m.final_result then M.suppress_rescan(1.0) end
                                end

                                if in_editor then do_expansion() else hs.timer.doAfter(0, do_expansion) end
                                return true
                            end
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
                    if last_char ~= "" and not last_char:match("^%s$") and last_char ~= "\226\128\139" then
                        is_replacing = true
                        if not in_editor then tooltip.hide() end
                        if in_editor then keyStroke({}, "delete", 0) end
                        keyStrokes(last_char)
                        local tstart = utf8.offset(buffer, -char_len)
                        buffer = (tstart and buffer:sub(1, tstart - 1) or "") .. last_char
                        hs.timer.doAfter(0.05, function() is_replacing = false end)
                        return true
                    end
                end
            end
        end
        return false
    end

    if in_editor then
        hs.timer.doAfter(0, check_triggers)
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

local shift_tap = eventtap.new(
    { eventtap.event.types.flagsChanged },
    function(e)
        local kc = e:getKeyCode()
        local f  = e:getFlags()
        if kc == 56 then
            _shift_side = f.shift and "left" or (_shift_side == "left" and nil or _shift_side)
        elseif kc == 60 then
            _shift_side = f.shift and "right" or (_shift_side == "right" and nil or _shift_side)
        elseif not f.shift then
            _shift_side = nil
        end
        return false
    end
)

local mouse_tap = eventtap.new(
    {
        eventtap.event.types.leftMouseDown,
        eventtap.event.types.rightMouseDown,
        eventtap.event.types.middleMouseDown,
    },
    function()
        if llm_reset_on_nav then buffer = "" end
        reset_predictions()
        return false
    end
)

function M.start()
    tap:start()
    shift_tap:start()
    mouse_tap:start()
end

function M.stop()
    tap:stop()
    shift_tap:stop()
    mouse_tap:stop()
    reset_predictions()
end

M.start()
return M
