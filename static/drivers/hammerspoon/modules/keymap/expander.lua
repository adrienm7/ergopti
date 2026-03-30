--- modules/keymap/expander.lua

--- ==============================================================================
--- MODULE: Keymap Expander
--- DESCRIPTION:
--- Handles the execution of text expansions, auto-corrections, and replacements
--- using the active buffer and the registry database.
---
--- FEATURES & RATIONALE:
--- 1. Safe Injection: Utilizes safe simulated keystrokes and text utilities.
--- 2. Intelligent Conflict Resolution: Identifies prefixes and trailing chars.
--- ==============================================================================

local M = {}

local hs         = hs
local keyStroke  = hs.eventtap.keyStroke
local keyStrokes = hs.eventtap.keyStrokes

local text_utils = require("lib.text_utils")
local km_utils   = require("modules.keymap.utils")

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local ok_tt, tooltip = pcall(require, "ui.tooltip")
if not ok_tt then tooltip = { hide = function() end } end

local _state    = nil
local _registry = nil
local _llm      = nil





-- =====================================
-- =====================================
-- ======= 1/ Core Replacements ========
-- =====================================
-- =====================================

--- Internal helper executing character manipulation via backspaces and pasting.
--- @param deletes number Quantity of backspaces to issue.
--- @param emit_action function Routine to fire the text replacement.
--- @param buffer_action function Routine syncing the internal tracker logic.
--- @param is_final boolean Whether to pause predictions temporarily post execution.
--- @param is_ignored boolean Disables tooltip and AI reactions.
--- @param source_type string Specifies the module triggering the generation.
function M.perform_text_replacement(deletes, emit_action, buffer_action, is_final, is_ignored, source_type)
    _state.expected_synthetic_deletes = _state.expected_synthetic_deletes + deletes
    if not is_ignored and tooltip.hide then tooltip.hide() end
    
    for _ = 1, deletes do keyStroke({}, "delete", 0) end
    local ok, _, emitted_str = pcall(emit_action)
    if not ok then emitted_str = "" end
    
    _state.expected_synthetic_chars = _state.expected_synthetic_chars .. (emitted_str or "")
    
    -- Notifying the Keylogger of the exact provenance of the sequence
    if keylogger and type(keylogger.notify_synthetic) == "function" and emitted_str ~= "" then
        keylogger.notify_synthetic(emitted_str, source_type or "hotstring")
    end
    
    if type(buffer_action) == "function" then pcall(buffer_action) end

    -- Sync keylogger so its logged text matches actual on-screen content
    if keylogger and type(keylogger.set_buffer) == "function" then
        keylogger.set_buffer(_state.buffer)
    end

    if is_final then _state.suppress_rescan(1.0) end

    -- Triggers an AI prediction as soon as the hotstring is expanded
    if not is_ignored and _llm.get_llm_enabled() then
        _llm.start_timer()
    end
end





-- =========================================
-- =========================================
-- ======= 2/ Expansion Scenarios ==========
-- =========================================
-- =========================================

--- Attempts to resolve and execute an auto-expanding hotstring sequence.
--- @param m table The dictionary mapping matched sequence.
--- @param char_len number Byte length of the latest character.
--- @param is_ignored boolean Silences auxiliary systems like the LLM when active.
--- @return boolean True if sequence resolved successfully.
function M.try_auto_expand(m, char_len, is_ignored)
    local trigger = m.trigger
    if not text_utils.utf8_ends_with(_state.buffer, trigger) then return false end
    
    if m.is_word and text_utils.utf8_len(_state.buffer) > text_utils.utf8_len(trigger)
        and not trigger:match("^[ \194\160\226\128\175]") then
        local tstart  = utf8.offset(_state.buffer, -text_utils.utf8_len(trigger))
        local before  = tstart and _state.buffer:sub(1, tstart - 1) or ""
        local last_ch = utf8.offset(before, -1)
        if text_utils.is_letter_char(last_ch and before:sub(last_ch) or "") then
            return false
        end
    end

    local tokens    = km_utils and type(km_utils.tokens_from_repl) == "function" and km_utils.tokens_from_repl(m.repl) or {}
    local repl_text = km_utils and type(km_utils.plain_text) == "function" and km_utils.plain_text(tokens) or m.repl
    
    if repl_text == trigger then
        if m.final_result then _state.suppress_rescan() end
        if not is_ignored and tooltip.hide then tooltip.hide() end
        return true
    end

    local char_offset = is_ignored and 0 or char_len
    local deletes, to_type = text_utils.utf8_len(trigger) - char_offset, repl_text

    if repl_text == m.repl then
        local screen = text_utils.utf8_sub(trigger, 1, text_utils.utf8_len(trigger) - char_offset)
        local common = text_utils.get_common_prefix_utf8(screen, repl_text)
        deletes = text_utils.utf8_len(screen) - common
        to_type = text_utils.utf8_sub(repl_text, common + 1)
    end

    M.perform_text_replacement(deletes, 
        function() 
            if repl_text == m.repl and km_utils and type(km_utils.emit_text) == "function" then
                return km_utils.emit_text(to_type)
            elseif km_utils and type(km_utils.emit_tokens) == "function" then
                return km_utils.emit_tokens(tokens) 
            end
            return 0, ""
        end,
        function()
            local tstart = utf8.offset(_state.buffer, -text_utils.utf8_len(trigger))
            _state.buffer = (tstart and _state.buffer:sub(1, tstart - 1) or "") .. repl_text
        end,
        m.final_result,
        is_ignored,
        "hotstring"
    )
    return true
end

--- Attempts to resolve a non-automatic hotstring sequence triggered by a special trailing terminator.
--- @param m table The mapping dictionary entry to resolve against.
--- @param chars string The specific trailing trigger sequence injected.
--- @param char_len number UTF-8 token length of the trailing sequence.
--- @param is_ignored boolean Disables LLM AI checks for current context.
--- @return boolean True if triggered successfully, false otherwise.
function M.try_terminator_expand(m, chars, char_len, is_ignored)
    if not _registry.is_terminator(chars) then return false end

    local trigger = m.trigger
    local buf_end   = utf8.offset(_state.buffer, -char_len) or (#_state.buffer + 1)
    local trig_len  = text_utils.utf8_len(trigger)
    local buf_start = utf8.offset(_state.buffer, -(char_len + trig_len))
    local segment   = (buf_start and buf_start <= buf_end - 1) and _state.buffer:sub(buf_start, buf_end - 1) or nil
    
    if segment ~= trigger then return false end

    if m.is_word and not trigger:match("^[ \194\160\226\128\175]") then
        local before  = buf_start and _state.buffer:sub(1, buf_start - 1) or ""
        local last_ch = utf8.offset(before, -1)
        if text_utils.is_letter_char(last_ch and before:sub(last_ch) or "") then
            return false
        end
    end

    local consume_term = _registry.terminator_is_consumed(chars)
    
    if m.repl == trigger then
        if m.final_result then _state.suppress_rescan() end
        if not is_ignored and tooltip.hide then tooltip.hide() end
        return true
    end

    local function do_expansion()
        local tokens    = km_utils and type(km_utils.tokens_from_repl) == "function" and km_utils.tokens_from_repl(m.repl) or {}
        local repl_text = km_utils and type(km_utils.plain_text) == "function" and km_utils.plain_text(tokens) or m.repl
        local deletes, to_type = trig_len, repl_text
        
        if repl_text == m.repl then
            local common = text_utils.get_common_prefix_utf8(trigger, repl_text)
            deletes = trig_len - common
            to_type = text_utils.utf8_sub(repl_text, common + 1)
        end
        
        if is_ignored then deletes = deletes + char_len end

        M.perform_text_replacement(deletes, 
            function()
                local emitted_count, emitted_str = 0, ""
                if repl_text == m.repl and km_utils and type(km_utils.emit_text) == "function" then
                    emitted_count, emitted_str = km_utils.emit_text(to_type)
                elseif km_utils and type(km_utils.emit_tokens) == "function" then
                    emitted_count, emitted_str = km_utils.emit_tokens(tokens)
                end
                
                if not consume_term then
                    if chars == "\r" or chars == "\n" then keyStroke({}, "return", 0)
                    elseif chars == "\t" then keyStroke({}, "tab", 0)
                    else 
                        keyStrokes(chars) 
                        emitted_str = emitted_str .. chars
                    end
                    emitted_count = emitted_count + text_utils.utf8_len(chars)
                end
                return emitted_count, emitted_str
            end,
            function()
                local tstart = utf8.offset(_state.buffer, -(char_len + trig_len))
                _state.buffer = (tstart and _state.buffer:sub(1, tstart - 1) or "") .. repl_text .. (consume_term and "" or chars)
            end,
            m.final_result,
            is_ignored,
            "hotstring"
        )
    end

    if is_ignored then do_expansion() else hs.timer.doAfter(0, do_expansion) end
    return true
end

--- Validates and manages immediate repetition hotstrings natively.
--- @param chars string Keystroke trailing trigger.
--- @param is_ignored boolean Skips notification propagation on match.
--- @return boolean Valid repetition fired flag.
function M.try_repeat_feature(chars, is_ignored)
    if not _state.is_repeat_feature_enabled() or chars ~= _state.magic_key then return false end

    local char_len = text_utils.utf8_len(chars)
    local buf_len  = text_utils.utf8_len(_state.buffer)
    if buf_len <= char_len then return false end

    local before = _state.buffer:sub(1, utf8.offset(_state.buffer, -char_len) - 1)
    local last_char_offset = utf8.offset(before, -1)
    if not last_char_offset then return false end

    local last_char = before:sub(last_char_offset)
    if last_char == "" or last_char:match("^%s$") then return false end

    if not is_ignored and tooltip.hide then tooltip.hide() end
    if is_ignored then 
        _state.expected_synthetic_deletes = _state.expected_synthetic_deletes + 1
        keyStroke({}, "delete", 0) 
    end
    
    _state.expected_synthetic_chars = _state.expected_synthetic_chars .. last_char
    
    if keylogger and type(keylogger.notify_synthetic) == "function" then
        keylogger.notify_synthetic(last_char, "hotstring")
    end
    keyStrokes(last_char)

    local tstart = utf8.offset(_state.buffer, -char_len)
    _state.buffer = (tstart and _state.buffer:sub(1, tstart - 1) or "") .. last_char
    
    if not is_ignored and _llm.get_llm_enabled() then
        _llm.start_timer()
    end
    
    return true
end





-- =============================
-- =============================
-- ======= 3/ Module API =======
-- =============================
-- =============================

--- Mounts the shared state and submodules to the expander module.
--- @param core_state table The shared state object.
--- @param registry_mod table The registry submodule reference.
--- @param llm_mod table The LLM bridge submodule reference.
function M.init(core_state, registry_mod, llm_mod)
    _state    = core_state
    _registry = registry_mod
    _llm      = llm_mod
end

return M
