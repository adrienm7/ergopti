--- modules/keymap/init.lua

--- ==============================================================================
--- MODULE: Keymap Core
--- DESCRIPTION:
--- Core engine for Ergopti+. Initializes the central eventtap loop, manages the
--- typing buffer, and routes interactions to the Registry, LLM Bridge, and Expander.
---
--- FEATURES & RATIONALE:
--- 1. Shared State: Centralizes state via CoreState without using globals.
--- 2. Zero-Latency Execution: Uses an ultra-fast event loop directly connected to the OS.
--- 3. Modularity: Defers specific responsibilities to specialized submodules.
--- ==============================================================================

local hs         = hs
local eventtap   = hs.eventtap
local text_utils = require("lib.text_utils")
local km_utils   = require("modules.keymap.utils")
local Logger     = require("lib.logger")

local Registry  = require("modules.keymap.registry")
local Expander  = require("modules.keymap.expander")
local LLMBridge = require("modules.keymap.llm_bridge")

local M = {}
local LOG = "keymap"





-- ===================================
-- ===================================
-- ======= 1/ Default State ==========
-- ===================================
-- ===================================

-- Initialisation des constantes par défaut exportables
M.LLM_NAV_MODIFIERS_DEFAULT   = {}
M.LLM_VAL_MODIFIERS_DEFAULT   = {"alt"}
M.LLM_DEBOUNCE_DEFAULT        = 0.5
M.LLM_CONTEXT_LENGTH_DEFAULT  = 500
M.LLM_TEMPERATURE_DEFAULT     = 0.1
M.LLM_MAX_WORDS_DEFAULT       = 5
M.LLM_NUM_PREDICTIONS_DEFAULT = 5
M.LLM_PRED_INDENT_DEFAULT     = -3
M.BASE_DELAY_SEC_DEFAULT      = 0.75

M.DELAYS_DEFAULT = {
    STAR_TRIGGER       = 2.0,  -- Manual expansions with ★ (Magickey)
    dynamichotstrings  = 2.0,  -- Phone numbers, SSN, dates...
    autocorrection     = 0.5,  -- Spell checking
    rolls              = 0.25, -- Rolls (e.g. sx -> sk)
    sfbsreduction      = 0.25, -- Comma combos (e.g. ,t -> pt)
    distancesreduction = 0.25, -- Dead keys and suffixes
}

-- Default state in the menu
M.DEFAULT_STATE = {
    keymap          = true,
    expansion_delay = M.BASE_DELAY_SEC_DEFAULT,
    delays          = {},
    trigger_char    = "★",
}





-- ====================================
-- ====================================
-- ======= 2/ Constants & State =======
-- ====================================
-- ====================================

-- Central memory struct passed via reference to all sub-modules
local CoreState = {
    buffer                     = "",
    magic_key                  = "★",
    mappings                   = {},
    mappings_lookup            = {},
    groups                     = {},
    seq_counter                = 0,
    interceptors               = {},
    preview_providers          = {},
    expected_synthetic_chars   = "",
    expected_synthetic_deletes = 0,
    shift_side                 = nil,
    processing_paused          = false,
    last_key_time              = 0,
    last_key_was_complex       = false,
    no_rescan_until            = 0,
    WORD_TIMEOUT_SEC           = 5.0,
    BASE_DELAY_SEC             = M.BASE_DELAY_SEC_DEFAULT,
    DELAYS                     = {},
    current_group              = nil,
    group_post_load_hooks      = {},
    ignored_window_titles      = {},
    ignored_window_patterns    = {},
}

-- Methods bound onto CoreState for submodules to call
CoreState.suppress_rescan = function(duration)
    CoreState.no_rescan_until = hs.timer.secondsSinceEpoch() + (tonumber(duration) or 0.5)
    CoreState.buffer = ""
end

CoreState.suppress_rescan_keep_buffer = function(duration)
    CoreState.no_rescan_until = hs.timer.secondsSinceEpoch() + (tonumber(duration) or 0.3)
end

CoreState.is_repeat_feature_enabled = Registry.is_repeat_feature_enabled

-- Seed the initial delays
for k, v in pairs(M.DELAYS_DEFAULT) do CoreState.DELAYS[k] = v end

-- Mount dependencies
Registry.init(CoreState)
LLMBridge.init(CoreState)
Expander.init(CoreState, Registry, LLMBridge)

local tap       = nil
local shift_tap = nil
local mouse_tap = nil





-- ========================================
-- ========================================
-- ======= 3/ Base API & Forwarding =======
-- ========================================
-- ========================================

function M.get_base_delay()       return CoreState.BASE_DELAY_SEC end
function M.set_base_delay(secs)   CoreState.BASE_DELAY_SEC = math.max(0, tonumber(secs) or M.BASE_DELAY_SEC_DEFAULT) end
function M.get_shift_side()       return CoreState.shift_side end

function M.pause_processing()     CoreState.processing_paused = true end
function M.resume_processing()    CoreState.processing_paused = false end
function M.is_processing_paused() return CoreState.processing_paused end

function M.set_delay(key, val)
    if M.DELAYS_DEFAULT[key] ~= nil then
        CoreState.DELAYS[key] = tonumber(val) or M.DELAYS_DEFAULT[key]
        -- Recalculate word timeout based on max delay
        local max_delay = 0
        for _, v in pairs(CoreState.DELAYS) do
            if type(v) == "number" and v > max_delay then max_delay = v end
        end
        CoreState.WORD_TIMEOUT_SEC = math.min(5.0, max_delay + 0.5)
    end
end

function M.set_trigger_char(char)
    if type(char) == "string" and char ~= "" then
        CoreState.magic_key = char
        Registry.update_trigger_char(char)
    end
end

function M.ignore_window_title(title)     
    if type(title) == "string" then CoreState.ignored_window_titles[title] = true end 
end

function M.ignore_window_pattern(pattern) 
    if type(pattern) == "string" then table.insert(CoreState.ignored_window_patterns, pattern) end 
end

function M.register_interceptor(fn)      
    if type(fn) == "function" then table.insert(CoreState.interceptors, fn) end      
end

function M.register_preview_provider(fn) 
    if type(fn) == "function" then table.insert(CoreState.preview_providers, fn) end 
end

-- Proxy Registry Methods
M.add                   = Registry.add
M.load_file             = Registry.load_file
M.load_toml             = Registry.load_toml
M.is_section_enabled    = Registry.is_section_enabled
M.disable_section       = Registry.disable_section
M.enable_section        = Registry.enable_section
M.get_sections          = Registry.get_sections
M.get_meta_description  = Registry.get_meta_description
M.set_group_context     = Registry.set_group_context
M.set_post_load_hook    = Registry.set_post_load_hook
M.disable_group         = Registry.disable_group
M.is_group_enabled      = Registry.is_group_enabled
M.list_groups           = Registry.list_groups
M.register_lua_group    = Registry.register_lua_group
M.enable_group          = Registry.enable_group
M.sort_mappings         = Registry.sort_mappings

M.set_terminator_enabled    = Registry.set_terminator_enabled
M.is_terminator_enabled     = Registry.is_terminator_enabled
M.get_terminator_defs       = Registry.get_terminator_defs
M.add_custom_terminator     = Registry.add_custom_terminator
M.remove_custom_terminator  = Registry.remove_custom_terminator

-- Proxy LLM Bridge Methods
M.set_llm_model           = LLMBridge.set_llm_model
M.set_llm_context_length  = LLMBridge.set_llm_context_length
M.set_llm_reset_on_nav    = LLMBridge.set_llm_reset_on_nav
M.set_llm_temperature     = LLMBridge.set_llm_temperature
M.set_llm_max_words       = LLMBridge.set_llm_max_words
M.set_llm_num_predictions = LLMBridge.set_llm_num_predictions
M.set_llm_show_info_bar   = LLMBridge.set_llm_show_info_bar
M.set_llm_pred_indent     = LLMBridge.set_llm_pred_indent
M.set_llm_sequential_mode = LLMBridge.set_llm_sequential_mode
M.set_llm_val_modifiers   = LLMBridge.set_llm_val_modifiers
M.set_llm_nav_modifiers         = LLMBridge.set_llm_nav_modifiers
M.get_llm_enabled               = LLMBridge.get_llm_enabled
M.set_llm_show_model_name       = LLMBridge.set_llm_show_model_name
M.set_llm_disabled_apps         = LLMBridge.set_llm_disabled_apps
M.set_llm_enabled               = LLMBridge.set_llm_enabled
M.set_preview_enabled           = LLMBridge.set_preview_enabled
M.set_preview_star_enabled      = LLMBridge.set_preview_star_enabled
M.set_preview_autocorrect_enabled = LLMBridge.set_preview_autocorrect_enabled
M.set_preview_ai_enabled        = LLMBridge.set_preview_ai_enabled
M.set_llm_after_hotstring       = LLMBridge.set_llm_after_hotstring
M.set_llm_debounce              = LLMBridge.set_llm_debounce
M.trigger_prediction            = LLMBridge._perform_llm_check
M.reset_predictions             = LLMBridge.reset_predictions





-- =========================================
-- =========================================
-- ======= 4/ Keyboard Event Handler =======
-- =========================================
-- =========================================

--- Master keyboard loop interceptor wrapped internally by eventtap.
--- @param e table The MacOS keystroke event entity payload.
--- @return boolean Always returns false to fall back out gracefully on system error.
local function onKeyDownRaw(e)
    if CoreState.processing_paused then return false end

    local now   = hs.timer.secondsSinceEpoch()
    local dt    = now - CoreState.last_key_time
    CoreState.last_key_time = now

    -- Automatically clean waiting lists to prevent deadlocks
    if dt > 0.5 then
        CoreState.expected_synthetic_deletes = 0
        CoreState.expected_synthetic_chars = ""
    end

    -- Word timeout: clear the buffer if the user took a long pause
    if dt > CoreState.WORD_TIMEOUT_SEC then
        CoreState.buffer = ""
        LLMBridge.reset_predictions()
    end

    local keyCode = e:getKeyCode()
    local flags   = e:getFlags()
    
    local is_ignored = false
    local frontApp = hs.application.frontmostApplication()
    
    if frontApp and frontApp:name() == "Hammerspoon" then
        is_ignored = true
    elseif km_utils and type(km_utils.is_ignored_window) == "function" then
        is_ignored = km_utils.is_ignored_window(CoreState.ignored_window_titles, CoreState.ignored_window_patterns)
    end

    -- 1. Ignore our own synthetic "Delete" keystrokes
    if keyCode == 51 and CoreState.expected_synthetic_deletes > 0 then
        CoreState.expected_synthetic_deletes = CoreState.expected_synthetic_deletes - 1
        return false 
    end

    -- 2. Handles LLM Prediction Execution (Enter / Numbers / Tab / Arrows)
    if LLMBridge.handle_llm_keys(keyCode, flags, is_ignored) then return true end

    -- 3. Pass event through custom interceptors
    local suppress_triggers = false
    for _, interceptor in ipairs(CoreState.interceptors) do
        local ok, result = pcall(interceptor, e, CoreState.buffer)
        if ok then
            if result == "consume" then return true end
            if result == "suppress" then suppress_triggers = true; break end
        end
    end

    -- Ignore Karabiner layer and modified keys (F13-F20)
    if keyCode == 105 or keyCode == 107 or keyCode == 113 or keyCode == 106 or keyCode == 64 or keyCode == 79 or keyCode == 80 or keyCode == 90 then
        return false
    end

    -- 4. Clear states on escape, navigation and modifications shortcuts
    if keyCode == 53 then return LLMBridge.check_escape_reset() end

    if flags.cmd or flags.ctrl then
        CoreState.buffer = ""
        LLMBridge.check_nav_reset()
        return false
    end

    -- Handle standard Backspace
    if keyCode == 51 then
        if flags.cmd or flags.alt then
            CoreState.buffer = ""
            LLMBridge.check_nav_reset()
            return false
        end
        if #CoreState.buffer > 0 then
            local offset = utf8.offset(CoreState.buffer, -1)
            CoreState.buffer = offset and CoreState.buffer:sub(1, offset - 1) or ""
            if not is_ignored then LLMBridge.update_preview(CoreState.buffer) end
        end
        return false
    end

    -- Handle Arrow Keys
    if keyCode == 117 or keyCode == 115 or keyCode == 116 or keyCode == 119 or keyCode == 121
        or (keyCode >= 123 and keyCode <= 126) then

        LLMBridge.check_nav_reset()
        return false
    end

    -- 5. Gather character
    local chars = e:getCharacters(false)
    if not chars or chars == "" then return false end

    -- CRUCIAL SYNTHETIC FILTER:
    -- Ignore the character if it is part of our requested synthetic typing.
    -- It is emitted to the screen, BUT not added twice to the buffer.
    if #CoreState.expected_synthetic_chars > 0 then
        if CoreState.expected_synthetic_chars:sub(1, #chars) == chars then
            CoreState.expected_synthetic_chars = CoreState.expected_synthetic_chars:sub(#chars + 1)
            return false
        elseif dt < 0.02 then
            -- Tolerance for macOS UTF-8 decomposition
            return false
        end
    end

    CoreState.buffer = CoreState.buffer .. chars
    if #CoreState.buffer > 500 then
        CoreState.buffer = CoreState.buffer:sub(utf8.offset(CoreState.buffer, -500) or 1)
    end

    if not is_ignored then LLMBridge.update_preview(CoreState.buffer) end

    -- 6. Trigger Checks
    local function rescan_suppressed()
        return hs.timer.secondsSinceEpoch() < CoreState.no_rescan_until
    end
    
    if suppress_triggers or rescan_suppressed() then return false end
    
    local is_complex    = flags.shift or flags.alt
    local complex_mult  = (is_complex or CoreState.last_key_was_complex) and 2 or 1
    CoreState.last_key_was_complex = is_complex

    local function run_trigger_checks()
        local char_len = text_utils.utf8_len(chars)
        
        for _, m in ipairs(CoreState.mappings) do
            local group_active = not m.group or not CoreState.groups[m.group] or CoreState.groups[m.group].enabled
            if group_active then
                
                -- A. Determine the maximum allowed delay for this specific shortcut
                local specific_delay = CoreState.BASE_DELAY_SEC
                
                if m.trigger:sub(-#CoreState.magic_key) == CoreState.magic_key then
                    specific_delay = CoreState.DELAYS.STAR_TRIGGER
                elseif m.group and CoreState.DELAYS[m.group] then
                    specific_delay = CoreState.DELAYS[m.group]
                end
                
                local allowed_delay = specific_delay * complex_mult

                -- B. Check if the time gap (dt) with the previous key is valid
                if dt <= allowed_delay then
                    if m.auto and Expander.try_auto_expand(m, char_len, is_ignored) then return true end
                    if not m.auto and Expander.try_terminator_expand(m, chars, char_len, is_ignored) then return true end
                end
            end
        end
        
        if dt <= (CoreState.DELAYS.STAR_TRIGGER * complex_mult) then
            if Expander.try_repeat_feature(chars, is_ignored) then return true end
        end
        
        return false
    end

    if is_ignored then
        hs.timer.doAfter(0, run_trigger_checks)
    else
        if run_trigger_checks() then return true end
    end

    if keyCode == 36 or keyCode == 48 then
        LLMBridge.check_nav_reset()
    end

    return false
end

--- Wrapper for raw key intercept catching arbitrary native OS errors cleanly.
--- @param e table Event parameters.
--- @return boolean Return flag logic passed from raw.
local function onKeyDown(e)
    local ok, result = pcall(onKeyDownRaw, e)
    if not ok then
        Logger.error(LOG, "Interception clavier: %s", tostring(result))
        return false
    end
    return result
end





-- ====================================
-- ====================================
-- ======= 5/ Module Lifecycle ========
-- ====================================
-- ====================================

tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)

shift_tap = eventtap.new(
    { eventtap.event.types.flagsChanged },
    function(e)
        local ok, result = pcall(function()
            local kc = e:getKeyCode()
            local f  = e:getFlags()
            if not f.shift then
                CoreState.shift_side = nil
            elseif kc == 56 then
                CoreState.shift_side = "left"
            elseif kc == 60 then
                CoreState.shift_side = "right"
            end
            return false
        end)
        if not ok then Logger.error(LOG, "Gestion majuscule: %s", tostring(result)) return false end
        return result
    end
)

mouse_tap = eventtap.new(
    { 
        eventtap.event.types.leftMouseDown, 
        eventtap.event.types.rightMouseDown, 
        eventtap.event.types.middleMouseDown,
        eventtap.event.types.scrollWheel 
    },
    function()
        local ok, result = pcall(function()
            LLMBridge.check_nav_reset()
            LLMBridge.reset_predictions()
            return false
        end)
        if not ok then Logger.error(LOG, "Gestion souris: %s", tostring(result)) return false end
        return result
    end
)

--- Safely registers and mounts the daemon listeners to the OS framework.
function M.start()
    if tap then tap:start() end
    if shift_tap then shift_tap:start() end
    if mouse_tap then mouse_tap:start() end
end

--- Unhooks daemons gracefully preventing memory leaks.
function M.stop()
    if tap then tap:stop() end
    if shift_tap then shift_tap:stop() end
    if mouse_tap then mouse_tap:stop() end
    LLMBridge.reset_predictions()
end

M.start()
return M
