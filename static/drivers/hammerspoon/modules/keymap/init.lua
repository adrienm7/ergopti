--- modules/keymap/init.lua

--- ==============================================================================
--- MODULE: Keymap Core
--- DESCRIPTION:
--- Core engine for Ergopti+. Initializes the central eventtap loop, manages
--- the typing buffer, and routes interactions to the Registry, LLM Bridge, and
--- Expander. This module is the single source of truth for all keymap defaults.
---
--- FEATURES & RATIONALE:
--- 1. Single Source of Truth: All keymap-wide defaults live in M.DEFAULT_STATE
---    and M.DELAYS_DEFAULT. Menu modules read from here — never re-declare them.
--- 2. Shared State: Centralizes runtime state via CoreState without globals.
--- 3. Zero-Latency Execution: Uses an ultra-fast event loop directly connected
---    to the OS, with a pcall safety wrapper to prevent keyboard lockups.
--- 4. Modularity: Defers specific responsibilities to specialized submodules.
--- ==============================================================================

local hs         = hs
local eventtap   = hs.eventtap
local text_utils = require("lib.text_utils")
local km_utils   = require("modules.keymap.utils")
local Logger     = require("lib.logger")

local Registry  = require("modules.keymap.registry")
local Expander  = require("modules.keymap.expander")
local LLMBridge = require("modules.keymap.llm_bridge")

local M   = {}
local LOG = "keymap"




-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

-- Per-group expansion delay thresholds (in seconds).
-- A value of 0 means the expansion fires regardless of typing speed.
M.DELAYS_DEFAULT = {
	STAR_TRIGGER       = 2.0,  -- Manual expansions with ★ (magic key)
	dynamichotstrings  = 2.0,  -- Phone numbers, SSN, dates…
	autocorrection     = 0.5,  -- Spell checking
	rolls              = 0.25, -- Rolls (e.g. sx → sk)
	sfbsreduction      = 0.25, -- Comma combos (e.g. ,t → pt)
	distancesreduction = 0.25, -- Dead keys and suffixes
	llm_prediction     = 20.0, -- AI prediction tooltip timeout
}

--- Canonical defaults exposed to menu modules (single source of truth).
--- Menu modules MUST read from here instead of re-declaring their own values.
M.DEFAULT_STATE = {
	keymap                      = true,
	expansion_delay             = 0.75,   -- Baseline inter-key delay threshold (seconds)
	delays                      = {},     -- Per-group overrides; empty = use DELAYS_DEFAULT
	trigger_char                = "★",
	preview_star_enabled        = true,
	preview_autocorrect_enabled = true,
	preview_ai_enabled          = true,
	preview_colored_tooltips    = true,
}




-- ======================================
-- ======================================
-- ======= 2/ Constants And State =======
-- ======================================
-- ======================================

-- Central memory struct passed via reference to all sub-modules.
local CoreState = {
	buffer                     = "",
	magic_key                  = M.DEFAULT_STATE.trigger_char,
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
	BASE_DELAY_SEC             = M.DEFAULT_STATE.expansion_delay,
	DELAYS                     = {},
	DELAYS_DEFAULT             = M.DELAYS_DEFAULT,
	current_group              = nil,
	group_post_load_hooks      = {},
	ignored_window_titles      = {},
	ignored_window_patterns    = {},
}

-- Methods bound onto CoreState for submodules to call.
CoreState.suppress_rescan = function(duration)
	CoreState.no_rescan_until = hs.timer.secondsSinceEpoch() + (tonumber(duration) or 0.5)
	CoreState.buffer = ""
end

CoreState.suppress_rescan_keep_buffer = function(duration)
	CoreState.no_rescan_until = hs.timer.secondsSinceEpoch() + (tonumber(duration) or 0.3)
end

CoreState.is_repeat_feature_enabled = Registry.is_repeat_feature_enabled

-- Seed the initial per-group delays from defaults and compute the word-timeout.
local has_infinite = false
local max_delay    = 0
for k, v in pairs(M.DELAYS_DEFAULT) do
	CoreState.DELAYS[k] = v
	if v == 0 then has_infinite = true end
	if v > max_delay then max_delay = v end
end
-- WORD_TIMEOUT_SEC: how long the engine waits before wiping the buffer on inactivity.
-- 0 means infinite (never wipe), which is needed when any delay is 0 (always-active trigger).
CoreState.WORD_TIMEOUT_SEC = has_infinite and 0 or (max_delay + 0.5)

-- Mount dependencies (order matters: Registry before Expander/LLMBridge).
Registry.init(CoreState)
LLMBridge.init(CoreState, M.DEFAULT_STATE)
Expander.init(CoreState, Registry, LLMBridge)

local tap       = nil
local shift_tap = nil
local mouse_tap = nil




-- ==========================================
-- ==========================================
-- ======= 3/ Base API And Forwarding =======
-- ==========================================
-- ==========================================

--- Returns the current baseline inter-key delay threshold.
--- @return number The delay in seconds.
function M.get_base_delay()
	return CoreState.BASE_DELAY_SEC
end

--- Sets the baseline inter-key delay threshold used for all unmapped groups.
--- @param secs number The new threshold in seconds (clamped to ≥ 0).
function M.set_base_delay(secs)
	local v = math.max(0, tonumber(secs) or M.DEFAULT_STATE.expansion_delay)
	CoreState.BASE_DELAY_SEC = v
	Logger.debug(LOG, "Base delay: %.3fs.", v)
end

--- Returns the side of the last shift key pressed.
--- @return string|nil "left", "right", or nil if Shift is not held.
function M.get_shift_side()
	return CoreState.shift_side
end

--- Pauses eventtap processing — all keystrokes pass through unmodified.
function M.pause_processing()
	CoreState.processing_paused = true
	Logger.debug(LOG, "Processing paused.")
end

--- Resumes eventtap processing after a pause.
function M.resume_processing()
	CoreState.processing_paused = false
	Logger.debug(LOG, "Processing resumed.")
end

--- Returns true when the eventtap is currently paused.
--- @return boolean
function M.is_processing_paused()
	return CoreState.processing_paused
end

--- Sets the per-group delay threshold for the given key.
--- Only keys present in DELAYS_DEFAULT are accepted; unknown keys are silently ignored.
--- @param key string The group identifier (must be a key of DELAYS_DEFAULT).
--- @param val number The new threshold in seconds.
function M.set_delay(key, val)
	if M.DELAYS_DEFAULT[key] == nil then return end

	CoreState.DELAYS[key] = tonumber(val) or M.DELAYS_DEFAULT[key]
	Logger.debug(LOG, "Delay '%s': %.3fs.", key, CoreState.DELAYS[key])

	-- Recompute WORD_TIMEOUT_SEC whenever any delay changes.
	local has_inf = false
	local max_d   = 0
	for _, v in pairs(CoreState.DELAYS) do
		if type(v) == "number" then
			if v == 0     then has_inf = true end
			if v > max_d  then max_d = v      end
		end
	end
	CoreState.WORD_TIMEOUT_SEC = has_inf and 0 or (max_d + 0.5)
end

--- Globally reassigns the magic expansion key (the "★" character by default).
--- @param char string The new trigger character (must be a non-empty string).
function M.set_trigger_char(char)
	if type(char) ~= "string" or char == "" then
		Logger.warn(LOG, "set_trigger_char: received an invalid value ('%s') — ignored.", tostring(char))
		return
	end
	CoreState.magic_key = char
	Registry.update_trigger_char(char)
	Logger.debug(LOG, "Trigger char: '%s'.", char)
end

--- Ignores a specific window title from hotstring processing.
--- @param title string The exact window title to ignore.
function M.ignore_window_title(title)
	if type(title) == "string" then
		CoreState.ignored_window_titles[title] = true
	end
end

--- Ignores windows whose title matches a Lua pattern.
--- @param pattern string A Lua pattern matched against window titles.
function M.ignore_window_pattern(pattern)
	if type(pattern) == "string" then
		table.insert(CoreState.ignored_window_patterns, pattern)
	end
end

--- Registers a keystroke interceptor called before the expansion engine.
--- Return "consume" to swallow the event, "suppress" to skip triggers.
--- @param fn function The interceptor callback.
function M.register_interceptor(fn)
	if type(fn) == "function" then
		table.insert(CoreState.interceptors, fn)
	end
end

--- Registers a custom preview provider called by the LLM bridge on each keystroke.
--- Return a non-nil value to display a custom tooltip; return nil to fall through.
--- @param fn function The provider callback.
function M.register_preview_provider(fn)
	if type(fn) == "function" then
		table.insert(CoreState.preview_providers, fn)
	end
end


-- ── Registry proxies ─────────────────────────────────────────────────────────

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

M.set_terminator_enabled   = Registry.set_terminator_enabled
M.is_terminator_enabled    = Registry.is_terminator_enabled
M.get_terminator_defs      = Registry.get_terminator_defs
M.add_custom_terminator    = Registry.add_custom_terminator
M.remove_custom_terminator = Registry.remove_custom_terminator


-- ── LLM bridge proxies ───────────────────────────────────────────────────────

M.set_llm_model              = LLMBridge.set_llm_model
M.set_llm_display_model_name = LLMBridge.set_llm_display_model_name
M.set_llm_context_length     = LLMBridge.set_llm_context_length
M.set_llm_reset_on_nav       = LLMBridge.set_llm_reset_on_nav
M.set_llm_temperature        = LLMBridge.set_llm_temperature
M.set_llm_max_words          = LLMBridge.set_llm_max_words
M.set_llm_num_predictions    = LLMBridge.set_llm_num_predictions
M.set_llm_show_info_bar      = LLMBridge.set_llm_show_info_bar
M.set_llm_pred_indent        = LLMBridge.set_llm_pred_indent
M.set_llm_sequential_mode    = LLMBridge.set_llm_sequential_mode
M.set_llm_val_modifiers      = LLMBridge.set_llm_val_modifiers
M.set_llm_nav_modifiers      = LLMBridge.set_llm_nav_modifiers
M.get_llm_enabled            = LLMBridge.get_llm_enabled
M.set_llm_show_model_name    = LLMBridge.set_llm_show_model_name
M.set_llm_disabled_apps      = LLMBridge.set_llm_disabled_apps
M.set_llm_enabled            = LLMBridge.set_llm_enabled
M.set_llm_after_hotstring    = LLMBridge.set_llm_after_hotstring
M.set_llm_debounce           = LLMBridge.set_llm_debounce
M.set_llm_auto_raise_temp    = LLMBridge.set_llm_auto_raise_temp
M.set_llm_streaming          = LLMBridge.set_llm_streaming

M.set_preview_enabled             = LLMBridge.set_preview_enabled
M.set_preview_star_enabled        = LLMBridge.set_preview_star_enabled
M.set_preview_autocorrect_enabled = LLMBridge.set_preview_autocorrect_enabled
M.set_preview_ai_enabled          = LLMBridge.set_preview_ai_enabled
M.set_preview_colored_tooltips    = LLMBridge.set_preview_colored_tooltips

M.trigger_prediction = LLMBridge._perform_llm_check
M.reset_predictions  = LLMBridge.reset_predictions




-- =========================================
-- =========================================
-- ======= 4/ Keyboard Event Handler =======
-- =========================================
-- =========================================

--- Inner keyboard handler — never called directly; always wrapped in a pcall.
--- @param e table The macOS keystroke event payload.
--- @return boolean True to consume the event, false to pass it through.
local function onKeyDownRaw(e)
	if CoreState.processing_paused then return false end

	local now = hs.timer.secondsSinceEpoch()
	local dt  = now - CoreState.last_key_time
	CoreState.last_key_time = now

	-- Auto-reset stuck synthetic counters when typing resumes after a pause.
	-- Without this, a missed synthetic event would permanently lock the engine.
	if dt > 0.5 then
		CoreState.expected_synthetic_deletes = 0
		CoreState.expected_synthetic_chars   = ""
	end

	-- Wipe the buffer after the user pauses long enough that the next keystroke
	-- cannot possibly belong to the same word.
	if CoreState.WORD_TIMEOUT_SEC > 0 and dt > CoreState.WORD_TIMEOUT_SEC then
		CoreState.buffer = ""
		LLMBridge.reset_predictions()
	end

	local keyCode = e:getKeyCode()
	local flags   = e:getFlags()

	-- Determine whether the current window should suppress hotstring expansion.
	-- The Hammerspoon console check is inside is_ignored_window() and covered
	-- by its 0.5s cache. Pass `now` so the cache comparison reuses the timestamp
	-- already computed above instead of making a second secondsSinceEpoch() call.
	local is_ignored = km_utils.is_ignored_window(CoreState.ignored_window_titles, CoreState.ignored_window_patterns, now)

	-- 1. Ignore our own synthetic "Delete" keystrokes to prevent double-deletion.
	if keyCode == 51 and CoreState.expected_synthetic_deletes > 0 then
		CoreState.expected_synthetic_deletes = CoreState.expected_synthetic_deletes - 1
		return false
	end

	-- 2. Route LLM prediction keys (Enter / digits / arrows) before buffer logic.
	if LLMBridge.handle_llm_keys(keyCode, flags, is_ignored) then return true end

	-- 3. Run custom interceptors registered by external modules.
	local suppress_triggers = false
	for _, interceptor in ipairs(CoreState.interceptors) do
		local ok, result = pcall(interceptor, e, CoreState.buffer)
		if ok then
			if result == "consume"   then return true end
			if result == "suppress"  then suppress_triggers = true; break end
		end
	end

	-- Ignore Karabiner synthetic layer keys and F13-F20 (used for signaling).
	if keyCode == 105 or keyCode == 107 or keyCode == 113 or keyCode == 106
		or keyCode == 64 or keyCode == 79 or keyCode == 80 or keyCode == 90 then
		return false
	end

	-- 4. Handle Escape — dismiss predictions or optionally clear the buffer.
	if keyCode == 53 then return LLMBridge.check_escape_reset() end

	-- 5. Modifier shortcuts (Cmd/Ctrl) break the current word context.
	if flags.cmd or flags.ctrl then
		CoreState.buffer = ""
		LLMBridge.check_nav_reset()
		return false
	end

	-- 6. Handle Backspace.
	if keyCode == 51 then
		-- Cmd+Backspace / Alt+Backspace delete whole words — wipe the buffer.
		if flags.cmd or flags.alt then
			CoreState.buffer = ""
			LLMBridge.check_nav_reset()
			return false
		end
		if #CoreState.buffer > 0 then
			-- Remove the last UTF-8 character from the buffer safely.
			local ok, offset = pcall(utf8.offset, CoreState.buffer, -1)
			CoreState.buffer = (ok and offset) and CoreState.buffer:sub(1, offset - 1) or ""
			if not is_ignored then LLMBridge.update_preview(CoreState.buffer) end
		end
		return false
	end

	-- 7. Arrow / navigation keys break word context; delegate to nav-reset handler.
	if keyCode == 117 or keyCode == 115 or keyCode == 116 or keyCode == 119 or keyCode == 121
		or (keyCode >= 123 and keyCode <= 126) then
		LLMBridge.check_nav_reset()
		return false
	end

	-- 8. Gather the character produced by this keystroke.
	local chars = e:getCharacters(false)
	if not chars or chars == "" then return false end

	-- CRUCIAL SYNTHETIC FILTER:
	-- When we typed a character programmatically, the OS sends it back to us as
	-- a real event. Skip it here so it does not get added twice to the buffer.
	if #CoreState.expected_synthetic_chars > 0 then
		if CoreState.expected_synthetic_chars:sub(1, #chars) == chars then
			CoreState.expected_synthetic_chars = CoreState.expected_synthetic_chars:sub(#chars + 1)
			return false
		elseif dt < 0.02 then
			-- Tolerance window for macOS UTF-8 multi-event decomposition
			return false
		end
	end

	-- Append to the rolling buffer (capped at 500 chars to bound memory usage).
	CoreState.buffer = CoreState.buffer .. chars
	if #CoreState.buffer > 500 then
		local ok, off = pcall(utf8.offset, CoreState.buffer, -500)
		CoreState.buffer = CoreState.buffer:sub((ok and off) or 1)
	end

	if not is_ignored then LLMBridge.update_preview(CoreState.buffer) end

	-- 9. Run expansion trigger checks.
	local function rescan_suppressed()
		return hs.timer.secondsSinceEpoch() < CoreState.no_rescan_until
	end

	if suppress_triggers or rescan_suppressed() then return false end

	-- Complex keystrokes (involving Shift or Alt) allow a wider timing window
	-- to accommodate the extra finger movement required by the modifier.
	local is_complex   = flags.shift or flags.alt
	local complex_mult = (is_complex or CoreState.last_key_was_complex) and 2 or 1
	CoreState.last_key_was_complex = is_complex

	local function run_trigger_checks()
		local char_len = text_utils.utf8_len(chars)
		-- Pre-evaluate once: avoids a 20-entry linear scan inside try_terminator_expand
		-- for every non-auto mapping — on a normal letter keystroke that saves ~300 calls
		local chars_is_terminator = Registry.is_terminator(chars)

		for _, m in ipairs(CoreState.mappings) do
			local group_active = not m.group
				or not CoreState.groups[m.group]
				or CoreState.groups[m.group].enabled
			if not group_active then goto continue end

			-- Determine the tightest applicable delay for this mapping.
			-- m.has_magic is precomputed at load time — no string ops needed here
			local specific_delay
			if m.has_magic then
				specific_delay = CoreState.DELAYS.STAR_TRIGGER
			elseif m.group and CoreState.DELAYS[m.group] then
				specific_delay = CoreState.DELAYS[m.group]
			else
				specific_delay = CoreState.BASE_DELAY_SEC
			end

			-- Autocorrections are never stretched for complex keystrokes (they
			-- fire on letter combos, not on modifier+letter sequences).
			local allow_complex_delay = (m.group ~= "autocorrection")
			local allowed_delay       = allow_complex_delay and (specific_delay * complex_mult) or specific_delay

			if allowed_delay == 0 or dt <= allowed_delay then
				if m.auto     and Expander.try_auto_expand(m, char_len, is_ignored)       then return true end
				if not m.auto and chars_is_terminator
					and Expander.try_terminator_expand(m, chars, char_len, is_ignored) then return true end
			end

			::continue::
		end

		local star_allowed = CoreState.DELAYS.STAR_TRIGGER * complex_mult
		if (star_allowed == 0 or dt <= star_allowed)
			and Expander.try_repeat_feature(chars, is_ignored) then
			return true
		end

		return false
	end

	-- In ignored windows we still want repeatable features to work,
	-- but must run them asynchronously to avoid blocking the event queue.
	if is_ignored then
		hs.timer.doAfter(0, run_trigger_checks)
	else
		if run_trigger_checks() then return true end
	end

	-- Enter / Tab after a plain keystroke clears prediction state.
	if keyCode == 36 or keyCode == 48 then
		LLMBridge.check_nav_reset()
	end

	return false
end

--- pcall wrapper around onKeyDownRaw to prevent keyboard lockups on uncaught errors.
--- @param e table Event parameters.
--- @return boolean Pass-through result from the inner handler.
local function onKeyDown(e)
	local ok, result = pcall(onKeyDownRaw, e)
	if not ok then
		Logger.error(LOG, "Keyboard interception failure: %s.", tostring(result))
		return false
	end
	return result
end




-- ===================================
-- ===================================
-- ======= 5/ Module Lifecycle =======
-- ===================================
-- ===================================

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
		if not ok then
			Logger.error(LOG, "Shift-side detection failure: %s.", tostring(result))
			return false
		end
		return result
	end
)

mouse_tap = eventtap.new(
	{
		eventtap.event.types.leftMouseDown,
		eventtap.event.types.rightMouseDown,
		eventtap.event.types.middleMouseDown,
		eventtap.event.types.scrollWheel,
	},
	function()
		local ok, result = pcall(function()
			LLMBridge.check_nav_reset()
			LLMBridge.reset_predictions()
			return false
		end)
		if not ok then
			Logger.error(LOG, "Mouse event handler failure: %s.", tostring(result))
			return false
		end
		return result
	end
)

--- Starts the eventtap listeners and attaches them to the OS event queue.
function M.start()
	Logger.start(LOG, "Starting keymap engine…")
	tap:start()
	shift_tap:start()
	mouse_tap:start()
	Logger.success(LOG, "Keymap engine started.")
end

--- Stops the eventtap listeners and cleans up prediction state.
function M.stop()
	Logger.start(LOG, "Stopping keymap engine…")
	tap:stop()
	shift_tap:stop()
	mouse_tap:stop()
	LLMBridge.reset_predictions()
	Logger.success(LOG, "Keymap engine stopped.")
end

M.start()
return M
