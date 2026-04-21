--- modules/keymap/expander.lua

--- ==============================================================================
--- MODULE: Keymap Expander
--- DESCRIPTION:
--- Executes text expansions: auto-expanding hotstrings, terminator-triggered
--- hotstrings, and the magic-key "repeat last character" feature.
---
--- FEATURES & RATIONALE:
--- 1. Fail Fast: A require_state guard prevents silent failures when a function
---    is called before the module is initialized.
--- 2. Intelligent Conflict Resolution: Common prefixes between the trigger and
---    the replacement are kept to minimize the number of backspaces issued.
--- 3. Synchronous Terminator Execution: Expansions run directly inside the HID
---    callback without deferral. CGEventPost() is non-blocking, so keyStroke()
---    calls return immediately — identical to how auto-expand already behaves.
--- ==============================================================================

local M = {}

local hs         = hs
local keyStroke  = hs.eventtap.keyStroke
local keyStrokes = hs.eventtap.keyStrokes

local text_utils = require("lib.text_utils")
local km_utils   = require("modules.keymap.utils")
local Logger     = require("lib.logger")
local LOG        = "keymap.expander"

-- Optional modules — loaded with pcall because they are not required for core expansion.
local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local ok_tt, tooltip = pcall(require, "ui.tooltip")
if not ok_tt then tooltip = { hide = function() end } end

local _state    = nil  -- Shared CoreState injected via M.init().
local _registry = nil  -- Registry module injected via M.init().
local _llm      = nil  -- LLMBridge module injected via M.init().


--- Guard: verifies that M.init() was called before any public function that
--- depends on the injected dependencies. Logs an error and returns false on failure.
--- @param func_name string Name of the calling function (for error messages).
--- @return boolean True when all dependencies are ready.
local function require_state(func_name)
	if not _state or not _registry or not _llm then
		Logger.error(LOG, "'%s' called before M.init() — dependencies not initialized.", func_name)
		return false
	end
	return true
end




-- ====================================
-- ====================================
-- ======= 1/ Core Replacements =======
-- ====================================
-- ====================================

--- Issues backspaces, fires the emit callback, updates the buffer, and
--- re-arms the LLM timer. This is the single choke-point through which
--- every expansion passes, ensuring consistent logging and side-effects.
---
--- @param deletes number Number of backspaces to issue.
--- @param emit_action function Called to type or paste the replacement text.
---   Must return (emitted_count: number, emitted_str: string).
--- @param buffer_action function Called to sync _state.buffer after emission.
--- @param is_final boolean When true, suppresses re-scanning after completion.
--- @param is_ignored boolean When true, skips tooltip and LLM side-effects.
--- @param source_type string Telemetry label passed to the keylogger.
--- @param source_variant string|nil Optional sub-type for the keylogger.
function M.perform_text_replacement(deletes, emit_action, buffer_action, is_final, is_ignored, source_type, source_variant)
	Logger.trace(LOG, "Performing replacement (%d deletion(s))…", deletes)

	_state.expected_synthetic_deletes = _state.expected_synthetic_deletes + deletes
	if not is_ignored and tooltip.hide then tooltip.hide() end

	for _ = 1, deletes do keyStroke({}, "delete", 0) end

	local ok, emit_count, emitted_str = pcall(emit_action)
	if not ok then
		-- The emit failed — emitted_str contains the error message from pcall.
		Logger.error(LOG, "emit_action failed: %s.", tostring(emit_count))
		emitted_str = ""
	end
	emitted_str = emitted_str or ""

	-- Track the emitted characters so the main event loop knows to skip them.
	_state.expected_synthetic_chars = _state.expected_synthetic_chars .. emitted_str

	if keylogger and type(keylogger.notify_synthetic) == "function" then
		keylogger.notify_synthetic(emitted_str, source_type or "hotstring", deletes, source_variant)
	end

	if type(buffer_action) == "function" then pcall(buffer_action) end

	if keylogger and type(keylogger.set_buffer) == "function" then
		keylogger.set_buffer(_state.buffer)
	end

	-- Re-evaluate preview on the updated buffer to support chained autocorrections.
	if not is_ignored then _llm.update_preview(_state.buffer) end

	if is_final then _state.suppress_rescan(1.0) end

	if not is_ignored and _llm.get_llm_enabled() then
		_llm.start_timer()
	end

	Logger.done(LOG, "Replacement complete.")
end




-- ======================================
-- ======================================
-- ======= 2/ Expansion Scenarios =======
-- ======================================
-- ======================================

--- Attempts to auto-expand a hotstring when the buffer ends with its trigger.
--- "Auto" hotstrings fire immediately on the last character, without a terminator.
--- @param m table The mapping entry from the registry.
--- @param char_len number UTF-8 length of the latest typed character.
--- @param is_ignored boolean True when the current window suppresses LLM/tooltip.
--- @return boolean True when the expansion fired.
function M.try_auto_expand(m, char_len, is_ignored)
	if not require_state("try_auto_expand") then return false end

	local trigger = m.trigger
	-- Byte-direct suffix match: two strings equal byte-for-byte are necessarily
	-- UTF-8 equivalent, so utf8_ends_with's extra utf8.len/utf8.offset hops are
	-- pure overhead on the hot path. m.trigger_bytes is precomputed at load time.
	local tb = m.trigger_bytes
	if #_state.buffer < tb or _state.buffer:sub(-tb) ~= trigger then return false end

	-- Word-boundary check: reject the match when the trigger is preceded by a
	-- letter or "@" (which is used as a personal-info trigger prefix).
	if m.is_word
		and text_utils.utf8_len(_state.buffer) > text_utils.utf8_len(trigger)
		and not trigger:match("^[ \194\160\226\128\175]")
	then
		local tstart    = utf8.offset(_state.buffer, -text_utils.utf8_len(trigger))
		local before    = tstart and _state.buffer:sub(1, tstart - 1) or ""
		local prev_off  = utf8.offset(before, -1)
		local prev_char = prev_off and before:sub(prev_off) or ""
		if text_utils.is_letter_char(prev_char) or prev_char == "@" then
			return false
		end
	end

	-- Use the precomputed plain_repl; tokens_from_repl() is only called below
	-- when we actually need to emit tokens (replacements with {Token} directives)
	local repl_text = m.plain_repl

	-- No-op guard: skip when the plain-text expansion equals the trigger.
	if repl_text == trigger then
		if m.final_result then _state.suppress_rescan() end
		if not is_ignored and tooltip.hide then tooltip.hide() end
		return true
	end

	-- Compute how many backspaces and what to type, keeping common prefix chars.
	-- In an ignored window (char_len == 0) there is no "last char" to keep, so
	-- we must erase the full trigger length.
	local char_offset = is_ignored and 0 or char_len
	local deletes, to_type = text_utils.utf8_len(trigger) - char_offset, repl_text

	if repl_text == m.repl then
		-- Simple text replacement: find the longest shared prefix to minimise backspaces.
		local screen = text_utils.utf8_sub(trigger, 1, text_utils.utf8_len(trigger) - char_offset)
		local common = text_utils.get_common_prefix_utf8(screen, repl_text)
		deletes = text_utils.utf8_len(screen) - common
		to_type = text_utils.utf8_sub(repl_text, common + 1)
	end

	M.perform_text_replacement(
		deletes,
		function()
			if repl_text == m.repl then
				return km_utils.emit_text(to_type)
			else
				-- Lazy: tokens_from_repl() only reached for {Token}-bearing replacements
				return km_utils.emit_tokens(km_utils.tokens_from_repl(m.repl))
			end
		end,
		function()
			local tstart = utf8.offset(_state.buffer, -text_utils.utf8_len(trigger))
			_state.buffer = (tstart and _state.buffer:sub(1, tstart - 1) or "") .. repl_text
		end,
		m.final_result,
		is_ignored,
		"hotstring",
		(m.group == "autocorrection") and "autocorrection" or nil
	)

	if keylogger and type(keylogger.log_hotstring) == "function" then
		pcall(keylogger.log_hotstring, trigger, repl_text)
	end
	Logger.debug(LOG, "Auto-expand: '%s' → '%s'.", trigger, repl_text)
	return true
end

--- Attempts to expand a hotstring when the buffer ends with the trigger followed
--- by an enabled terminator character (e.g., space, comma, ★).
--- @param m table The mapping entry from the registry.
--- @param chars string The latest typed character(s) (potential terminator).
--- @param char_len number UTF-8 length of `chars`.
--- @param is_ignored boolean True when the current window suppresses LLM/tooltip.
--- @return boolean True when the expansion fired.
function M.try_terminator_expand(m, chars, char_len, is_ignored)
	if not require_state("try_terminator_expand") then return false end

	if not _registry.is_terminator(chars) then return false end

	-- Byte-direct segment match: byte equality implies UTF-8 equality, so we skip
	-- the utf8.offset pair entirely. trigger_bytes is precomputed; #chars is the
	-- byte length of the terminator character(s) that were just typed.
	local trigger     = m.trigger
	local tb          = m.trigger_bytes
	local chars_bytes = #chars
	local buf         = _state.buffer
	if #buf < tb + chars_bytes then return false end
	local buf_start   = #buf - chars_bytes - tb + 1
	if buf:sub(buf_start, buf_start + tb - 1) ~= trigger then return false end
	local trig_len    = text_utils.utf8_len(trigger)

	-- Word-boundary check: same logic as in try_auto_expand.
	if m.is_word and not trigger:match("^[ \194\160\226\128\175]") then
		local before    = buf:sub(1, buf_start - 1)
		local prev_off  = utf8.offset(before, -1)
		local prev_char = prev_off and before:sub(prev_off) or ""
		if text_utils.is_letter_char(prev_char) or prev_char == "@" then
			return false
		end
	end

	local consume_term = _registry.terminator_is_consumed(chars)

	-- No-op guard: skip when the plain-text expansion equals the trigger.
	if m.repl == trigger then
		if m.final_result then _state.suppress_rescan() end
		if not is_ignored and tooltip.hide then tooltip.hide() end
		return true
	end

	-- Record a "suggestion shown" telemetry event for terminators that indicate
	-- explicit user acceptance (e.g., ★ consumed as a deliberate trigger).
	if keylogger and type(keylogger.log_hotstring_suggested) == "function" then
		pcall(keylogger.log_hotstring_suggested)
	end

	local function do_expansion()
		-- Use the precomputed plain_repl; tokens_from_repl() is only called below
		-- when we actually need to emit tokens (replacements with {Token} directives)
		local repl_text        = m.plain_repl
		local deletes, to_type = trig_len, repl_text

		if repl_text == m.repl then
			-- Simple text: keep common prefix to reduce backspaces.
			local common = text_utils.get_common_prefix_utf8(trigger, repl_text)
			deletes = trig_len - common
			to_type = text_utils.utf8_sub(repl_text, common + 1)
		end

		-- In an ignored window there is no "char" kept on screen — erase it too.
		if is_ignored then deletes = deletes + char_len end

		M.perform_text_replacement(
			deletes,
			function()
				local c, s = 0, ""
				if repl_text == m.repl then
					c, s = km_utils.emit_text(to_type)
				else
					-- Lazy: tokens_from_repl() only reached for {Token}-bearing replacements
					c, s = km_utils.emit_tokens(km_utils.tokens_from_repl(m.repl))
				end

				-- Re-type the terminator unless it should be consumed.
				if not consume_term then
					if chars == "\r" or chars == "\n" then
						keyStroke({}, "return", 0)
					elseif chars == "\t" then
						keyStroke({}, "tab", 0)
					else
						keyStrokes(chars)
						s = s .. chars
					end
					c = c + text_utils.utf8_len(chars)
				end
				return c, s
			end,
			function()
				-- buf_start is a valid byte index into _state.buffer: the buffer
				-- is only mutated by this very closure, which runs after emit.
				_state.buffer = _state.buffer:sub(1, buf_start - 1)
					.. repl_text
					.. (consume_term and "" or chars)
			end,
			m.final_result,
			is_ignored,
			"hotstring",
			(m.group == "autocorrection") and "autocorrection" or nil
		)

		if keylogger and type(keylogger.log_hotstring) == "function" then
			pcall(keylogger.log_hotstring, trigger, m.plain_repl)
		end
		Logger.debug(LOG, "Terminator-expand: '%s' → '%s'.", trigger, m.repl)
	end

	-- Run synchronously: CGEventPost() is non-blocking so calling keyStroke()
	-- inside the HID callback is safe. expected_synthetic_chars is already
	-- armed before events fire, preventing re-entrancy into the trigger loop.
	do_expansion()
	return true
end

--- Fires the magic-key "repeat last character" feature when the user types
--- the trigger char twice: the first occurrence of the trigger is replaced by
--- the character that immediately preceded it.
---
--- Example: the user types "a★" → "aa".
---
--- @param chars string The latest typed character(s) (potential magic key).
--- @param is_ignored boolean True when the current window suppresses LLM/tooltip.
--- @return boolean True when the repeat fired.
function M.try_repeat_feature(chars, is_ignored)
	if not require_state("try_repeat_feature") then return false end
	if not _state.is_repeat_feature_enabled() then return false end
	if chars ~= _state.magic_key then return false end

	local char_len = text_utils.utf8_len(chars)
	local buf_len  = text_utils.utf8_len(_state.buffer)
	if buf_len <= char_len then return false end

	-- Find the offset of the magic-key in the buffer and isolate the text before it.
	local magic_offset = utf8.offset(_state.buffer, -char_len)
	if not magic_offset then
		Logger.warn(LOG, "try_repeat_feature: utf8.offset returned nil — skipping.")
		return false
	end
	local before = _state.buffer:sub(1, magic_offset - 1)

	-- Read the last character before the magic key.
	local last_char_offset = utf8.offset(before, -1)
	if not last_char_offset then return false end
	local last_char = before:sub(last_char_offset)

	-- Refuse to repeat whitespace — repeating a space or newline is never useful.
	if last_char == "" or last_char:match("^%s$") then return false end

	if not is_ignored and tooltip.hide then tooltip.hide() end

	-- In ignored windows, the magic key is already on screen and must be deleted.
	if is_ignored then
		_state.expected_synthetic_deletes = _state.expected_synthetic_deletes + 1
		keyStroke({}, "delete", 0)
	end

	_state.expected_synthetic_chars = _state.expected_synthetic_chars .. last_char

	if keylogger and type(keylogger.notify_synthetic) == "function" then
		keylogger.notify_synthetic(last_char, "hotstring", is_ignored and 1 or 0)
	end
	keyStrokes(last_char)

	-- Update the buffer: strip the magic key and append the repeated character.
	local tstart      = utf8.offset(_state.buffer, -char_len)
	_state.buffer     = (tstart and _state.buffer:sub(1, tstart - 1) or "") .. last_char

	if not is_ignored and _llm.get_llm_enabled() then
		_llm.start_timer()
	end

	Logger.debug(LOG, "Repeat feature: repeated '%s'.", last_char)
	return true
end




-- =============================
-- =============================
-- ======= 3/ Module API =======
-- =============================
-- =============================

--- Injects the shared dependencies from keymap/init.lua.
--- Must be called exactly once before any expansion function.
--- @param core_state table The shared CoreState object.
--- @param registry_mod table The registry module.
--- @param llm_mod table The LLM bridge module.
function M.init(core_state, registry_mod, llm_mod)
	if type(core_state)  ~= "table" then Logger.error(LOG, "M.init(): core_state must be a table."); return end
	if type(registry_mod) ~= "table" then Logger.error(LOG, "M.init(): registry_mod must be a table."); return end
	if type(llm_mod)     ~= "table" then Logger.error(LOG, "M.init(): llm_mod must be a table."); return end

	Logger.start(LOG, "Initializing expander…")
	_state    = core_state
	_registry = registry_mod
	_llm      = llm_mod
	Logger.success(LOG, "Expander initialized.")
end

return M
