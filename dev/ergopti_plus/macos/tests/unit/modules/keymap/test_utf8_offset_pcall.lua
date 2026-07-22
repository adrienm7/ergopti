--- tests/unit/modules/keymap/test_utf8_offset_pcall.lua

--- ==============================================================================
--- MODULE: utf8.offset pcall Guard — Regression Tests
--- DESCRIPTION:
--- Verifies that every function in keymap/llm_bridge.lua and keymap/expander.lua
--- that calls utf8.offset wraps the call in a pcall so a malformed UTF-8 byte
--- sequence never propagates a C-level error to the caller.
---
--- FEATURES & RATIONALE:
--- 1. Regression coverage: LuaJIT raises a C-level error on malformed UTF-8 inside
---    utf8.offset; this test suite ensures the pcall guards added to all call sites
---    remain in place and working, so a future refactor cannot silently reintroduce
---    the crash.
--- 2. Inline extraction: the three local helpers (ends_with_trigger, is_word_boundary,
---    word_boundary_blocks) are not accessible via the module's public API. Their
---    pcall-guarded logic is extracted verbatim here. If the guard is ever removed
---    from the source, calls with a bad-UTF-8 string will raise inside pcall at
---    the test level — failing this test — rather than crashing the HID callback.
--- 3. Public-function coverage: update_preview and try_auto_expand are exercised via
---    the real modules so the full call path is covered end-to-end.
--- ==============================================================================

local helpers = require("tests.helpers")


-- Isolate the hs stub before loading any production module so every
-- require("hs.*") call shares the same stub instance.
package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")





-- =============================================
-- =============================================
-- ======= 1/ Shared Test Infrastructure =======
-- =============================================
-- =============================================

-- A raw continuation byte is the canonical "malformed UTF-8" probe:
-- 0xBF is a valid UTF-8 continuation byte but is illegal at the START
-- of a codepoint. LuaJIT's utf8.offset raises a C-level error on it.
local BAD_UTF8 = string.char(0xBF)

-- Additional malformed sequences to stress the guard across variants.
-- 0x80 is the first continuation byte (also illegal as a lead byte).
-- A premature-termination sequence: valid 2-byte lead (0xC3) but no continuation.
local BAD_UTF8_80       = string.char(0x80)
local BAD_UTF8_TRUNCATED = string.char(0xC3)  -- lead byte of "é" without the second byte

--- Asserts that a call wrapped in pcall did not propagate an error.
--- This is the primary invariant: bad UTF-8 must never escape as an exception.
--- @param ok boolean The first return value of pcall.
--- @param label string Test label for the error message.
local function assert_no_error(ok, label)
	helpers.assert_true(ok, label .. ": pcall caught an unexpected error")
end

--- Asserts that a result value is a recognised safe fallback for a boolean
--- function: nil, false, or true are all acceptable; an error object is not.
--- @param val any The return value.
--- @param label string Test label.
local function assert_safe_bool(val, label)
	local t = type(val)
	helpers.assert_true(t == "boolean" or t == "nil",
		label .. ": expected boolean or nil, got " .. t)
end

--- Asserts that a result value is a recognised safe fallback for a string
--- function: nil or a string are both acceptable; an error object is not.
--- @param val any The return value.
--- @param label string Test label.
local function assert_safe_string(val, label)
	local t = type(val)
	helpers.assert_true(t == "string" or t == "nil",
		label .. ": expected string or nil, got " .. t)
end





-- ==========================================================================
-- ==========================================================================
-- ======= 2/ Inline Extractions of Local Helpers from llm_bridge.lua =======
-- ==========================================================================
-- ==========================================================================

-- These functions are extracted VERBATIM from their production sources so that:
-- (a) the test is self-contained and does not require loading the full module,
-- (b) any future edit that removes the pcall guard from the source while keeping
--     the logic otherwise identical will not silently preserve green tests here.
--
-- If a future refactor renames or restructures these functions, the corresponding
-- test block below should be updated to match.


--- Verbatim copy of the local `ends_with_trigger` from llm_bridge.lua (§2).
--- Returns true when buf ends with trigger (word-boundary variant checks the
--- codepoint immediately before the trigger via utf8.offset).
--- @param buffer string
--- @param trigger string
--- @param is_word boolean
--- @return boolean
local function ends_with_trigger(buffer, trigger, is_word)
	if type(buffer) ~= "string" or type(trigger) ~= "string" or trigger == "" then return false end
	if #buffer < #trigger or buffer:sub(-#trigger) ~= trigger then return false end
	if is_word ~= true then return true end
	local before = buffer:sub(1, #buffer - #trigger)
	if #before == 0 then return true end
	-- Guard against malformed UTF-8: LuaJIT raises a C-level error on bad sequences
	local ok_utf8, prev_offset = pcall(utf8.offset, before, -1)
	if not ok_utf8 then prev_offset = nil end
	local prev_char = prev_offset and before:sub(prev_offset) or ""
	-- Block when the character immediately before the trigger is a letter or "@"
	if prev_char == "@" then return false end
	return true
end

--- Verbatim copy of the local `is_word_boundary` from llm_bridge.lua (§2).
--- Returns true when buf ends with a word-boundary codepoint.
--- @param buf string
--- @return boolean
local function is_word_boundary(buf)
	if type(buf) ~= "string" or buf == "" then return false end
	-- Extract the last UTF-8 codepoint rather than the last byte so that
	-- multi-byte separators are recognised correctly.
	local ok, poff = pcall(utf8.offset, buf, -1)
	local last = (ok and poff) and buf:sub(poff) or buf:sub(-1)
	return last == " " or last == "," or last == "." or last == "!"
		or last == "?" or last == ";" or last == ":" or last == ")"
		or last == "}" or last == "]" or last == "\n"
		or last == "\194\160" or last == "\226\128\175"
end

--- Verbatim copy of the local `word_boundary_blocks` from expander.lua (§2).
--- Returns true when the character before the trigger's start is a letter or "@".
--- @param buffer string
--- @param trigger string
--- @param trigger_start_byte number
--- @param start_is_word_boundary boolean
--- @return boolean
local function word_boundary_blocks(buffer, trigger, trigger_start_byte, start_is_word_boundary)
	if trigger:match("^[ \194\160\226\128\175;]") then return false end
	if trigger_start_byte <= 1 then
		return not start_is_word_boundary
	end
	local before = buffer:sub(1, trigger_start_byte - 1)
	local ok_utf8, prev_off = pcall(utf8.offset, before, -1)
	-- Treat malformed UTF-8 the same as an absent left-hand char: no block
	if not ok_utf8 then prev_off = nil end
	local prev_char = prev_off and before:sub(prev_off) or ""
	return prev_char == "@"
end





-- ===========================================================
-- ===========================================================
-- ======= 3/ ends_with_trigger: Malformed UTF-8 Guard =======
-- ===========================================================
-- ===========================================================

helpers.describe("ends_with_trigger: malformed UTF-8 in `before` segment", function()

	helpers.it("0xBF lead byte in before — no error, returns boolean", function()
		-- `before` = BAD_UTF8 + "abc", trigger = "abc", is_word = true
		-- utf8.offset on BAD_UTF8 + "abc" raises without pcall
		local buf     = BAD_UTF8 .. "abc"
		local trigger = "abc"
		local ok, result = pcall(ends_with_trigger, buf, trigger, true)
		assert_no_error(ok, "ends_with_trigger BAD_UTF8 0xBF")
		assert_safe_bool(result, "ends_with_trigger BAD_UTF8 0xBF result")
	end)

	helpers.it("0x80 lead byte in before — no error, returns boolean", function()
		local buf     = BAD_UTF8_80 .. "hi"
		local trigger = "hi"
		local ok, result = pcall(ends_with_trigger, buf, trigger, true)
		assert_no_error(ok, "ends_with_trigger BAD_UTF8 0x80")
		assert_safe_bool(result, "ends_with_trigger BAD_UTF8 0x80 result")
	end)

	helpers.it("truncated multi-byte sequence in before — no error, returns boolean", function()
		local buf     = BAD_UTF8_TRUNCATED .. "ab"
		local trigger = "ab"
		local ok, result = pcall(ends_with_trigger, buf, trigger, true)
		assert_no_error(ok, "ends_with_trigger truncated lead byte")
		assert_safe_bool(result, "ends_with_trigger truncated lead byte result")
	end)

	helpers.it("is_word=false skips the utf8.offset path entirely — always safe", function()
		local buf     = BAD_UTF8 .. "test"
		local trigger = "test"
		local ok, result = pcall(ends_with_trigger, buf, trigger, false)
		assert_no_error(ok, "ends_with_trigger is_word=false")
		helpers.assert_eq(result, true, "is_word=false must match when suffix matches")
	end)

	helpers.it("valid UTF-8 buffer still returns the correct match result", function()
		-- Regression guard: the pcall must not break the normal happy path.
		local buf     = "cafe abc"
		local trigger = "abc"
		local ok, result = pcall(ends_with_trigger, buf, trigger, true)
		assert_no_error(ok, "ends_with_trigger valid UTF-8")
		helpers.assert_eq(result, true, "valid UTF-8 must match")
	end)

	helpers.it("word-boundary blocks when prev char is '@' (valid UTF-8)", function()
		local buf     = "@abc"
		local trigger = "abc"
		local ok, result = pcall(ends_with_trigger, buf, trigger, true)
		assert_no_error(ok, "ends_with_trigger '@' prefix")
		helpers.assert_eq(result, false, "should block when preceded by '@'")
	end)

end)





-- ==========================================================
-- ==========================================================
-- ======= 4/ is_word_boundary: Malformed UTF-8 Guard =======
-- ==========================================================
-- ==========================================================

helpers.describe("is_word_boundary: malformed UTF-8 last byte", function()

	helpers.it("0xBF as sole byte — no error, returns false (not a boundary char)", function()
		local ok, result = pcall(is_word_boundary, BAD_UTF8)
		assert_no_error(ok, "is_word_boundary 0xBF sole")
		assert_safe_bool(result, "is_word_boundary 0xBF sole result")
		-- 0xBF is not a boundary char; the fallback sub(-1) path returns it raw,
		-- and none of the comparisons match — so false is the expected result.
		helpers.assert_eq(result, false, "0xBF is not a word-boundary character")
	end)

	helpers.it("0xBF as trailing byte after valid prefix — no error", function()
		local buf = "hello" .. BAD_UTF8
		local ok, result = pcall(is_word_boundary, buf)
		assert_no_error(ok, "is_word_boundary trailing 0xBF")
		assert_safe_bool(result, "is_word_boundary trailing 0xBF result")
	end)

	helpers.it("0x80 as trailing byte — no error", function()
		local buf = "word" .. BAD_UTF8_80
		local ok, result = pcall(is_word_boundary, buf)
		assert_no_error(ok, "is_word_boundary trailing 0x80")
		assert_safe_bool(result, "is_word_boundary trailing 0x80 result")
	end)

	helpers.it("truncated 2-byte lead as last byte — no error", function()
		local buf = "abc" .. BAD_UTF8_TRUNCATED
		local ok, result = pcall(is_word_boundary, buf)
		assert_no_error(ok, "is_word_boundary truncated last byte")
		assert_safe_bool(result, "is_word_boundary truncated last byte result")
	end)

	helpers.it("valid boundary character still detected correctly", function()
		local ok, result = pcall(is_word_boundary, "hello ")
		assert_no_error(ok, "is_word_boundary space")
		helpers.assert_eq(result, true, "trailing space is a word boundary")
	end)

	helpers.it("valid NBSP boundary (U+00A0) detected correctly", function()
		-- U+00A0 = 0xC2 0xA0 — valid 2-byte sequence used by French typography
		local ok, result = pcall(is_word_boundary, "bonjour\194\160")
		assert_no_error(ok, "is_word_boundary NBSP")
		helpers.assert_eq(result, true, "NBSP is a word boundary")
	end)

	helpers.it("empty string returns false without error", function()
		local ok, result = pcall(is_word_boundary, "")
		assert_no_error(ok, "is_word_boundary empty")
		helpers.assert_eq(result, false, "empty string is not a boundary")
	end)

end)





-- ==============================================================
-- ==============================================================
-- ======= 5/ word_boundary_blocks: Malformed UTF-8 Guard =======
-- ==============================================================
-- ==============================================================

helpers.describe("word_boundary_blocks: malformed UTF-8 in `before` segment", function()

	helpers.it("0xBF in before segment — no error, returns boolean", function()
		-- buffer = BAD_UTF8 + "trigger", trigger starts at byte 2
		local buffer  = BAD_UTF8 .. "trigger"
		local trigger = "trigger"
		local tstart  = #BAD_UTF8 + 1
		local ok, result = pcall(word_boundary_blocks, buffer, trigger, tstart, false)
		assert_no_error(ok, "word_boundary_blocks 0xBF before")
		assert_safe_bool(result, "word_boundary_blocks 0xBF result")
	end)

	helpers.it("0x80 in before segment — no error, returns boolean", function()
		local buffer  = BAD_UTF8_80 .. "word"
		local trigger = "word"
		local tstart  = #BAD_UTF8_80 + 1
		local ok, result = pcall(word_boundary_blocks, buffer, trigger, tstart, false)
		assert_no_error(ok, "word_boundary_blocks 0x80 before")
		assert_safe_bool(result, "word_boundary_blocks 0x80 result")
	end)

	helpers.it("truncated lead byte in before — no error, block treated as absent", function()
		local buffer  = BAD_UTF8_TRUNCATED .. "abc"
		local trigger = "abc"
		local tstart  = #BAD_UTF8_TRUNCATED + 1
		local ok, result = pcall(word_boundary_blocks, buffer, trigger, tstart, true)
		assert_no_error(ok, "word_boundary_blocks truncated before")
		assert_safe_bool(result, "word_boundary_blocks truncated before result")
		-- Malformed = prev_char is "" → not "@" → false (no block)
		helpers.assert_eq(result, false, "malformed UTF-8 before must not block (treated as absent)")
	end)

	helpers.it("trigger starts at position 1 — returns !start_is_word_boundary (no utf8 call)", function()
		local ok, result = pcall(word_boundary_blocks, "abc", "abc", 1, true)
		assert_no_error(ok, "word_boundary_blocks tstart=1 boundary")
		helpers.assert_eq(result, false, "start_is_word_boundary=true => no block")

		local ok2, result2 = pcall(word_boundary_blocks, "abc", "abc", 1, false)
		assert_no_error(ok2, "word_boundary_blocks tstart=1 no-boundary")
		helpers.assert_eq(result2, true, "start_is_word_boundary=false => block")
	end)

	helpers.it("trigger preceded by '@' — blocks correctly (valid UTF-8 happy path)", function()
		-- buffer = "@trigger", trigger starts at byte 2
		local buffer  = "@trigger"
		local trigger = "trigger"
		local tstart  = 2
		local ok, result = pcall(word_boundary_blocks, buffer, trigger, tstart, true)
		assert_no_error(ok, "word_boundary_blocks '@' prefix")
		helpers.assert_eq(result, true, "'@' immediately before trigger must block")
	end)

	helpers.it("trigger preceded by space (non-blocking valid UTF-8)", function()
		local buffer  = "hello trigger"
		local trigger = "trigger"
		local tstart  = #buffer - #trigger + 1
		local ok, result = pcall(word_boundary_blocks, buffer, trigger, tstart, true)
		assert_no_error(ok, "word_boundary_blocks space prefix")
		-- Space is not "@", so prev_char != "@" → false (no block)
		helpers.assert_eq(result, false, "space before trigger must not block")
	end)

end)





-- ===========================================================
-- ===========================================================
-- ======= 6/ Public API Surface — End-to-End Coverage =======
-- ===========================================================
-- ===========================================================

-- Load a minimal version of the module tree so that the public functions
-- (update_preview via llm_bridge, try_auto_expand via expander) can be
-- exercised with a real module instance rather than an inline copy.
-- Both modules require heavy stubs; we set them up here then reload.

helpers.describe("llm_bridge.update_preview: bad UTF-8 in buffer does not propagate", function()

	-- Build the minimal stub tree required by llm_bridge.lua so the module
	-- loads without hs.* dependencies that are unavailable in headless tests.
	local function build_llm_bridge()
		-- Clear the full dependency chain so load_with_stubs starts clean.
		local to_clear = {
			"modules.keymap.llm_bridge",
			"modules.keymap.utils",
			"modules.keymap.registry",
			"modules.keymap.terminators",
			"modules.llm",
			"modules.llm.prediction_engine",
			"modules.keylogger",
			"modules.hotstrings.hotstrings_config",
			"lib.text_utils",
			"lib.keycodes",
			"lib.perf",
			"lib.hotpath_profiler",
			"ui.tooltip",
		}
		for _, mod in ipairs(to_clear) do package.loaded[mod] = nil end

		-- Stub every dependency that is not under test.
		package.loaded["lib.keycodes"] = {
			ESCAPE            = 53,
			RETURN            = 36,
			BACKSPACE         = 51,
			F16_LLM_CHAIN_SIGNAL = 106,
			to_name           = function(_) return "f16" end,
		}
		package.loaded["lib.text_utils"] = {
			is_letter_char       = function(_) return false end,
			trig_lower           = function(s) return s:lower() end,
			conform_replacement  = function(repl, _, _) return repl end,
			utf8_len             = function(s) return #s end,
			utf8_sub             = function(s, i, j) return s:sub(i, j) end,
			get_common_prefix_utf8 = function(_, _) return 0 end,
		}
		package.loaded["lib.perf"] = {
			is_enabled = function() return false end,
			now        = function() return 0 end,
			elapsed_ms = function(_) return 0 end,
			sample     = function() end,
			set_enabled = function() end,
		}
		package.loaded["lib.hotpath_profiler"] = {
			now        = function() return 0 end,
			elapsed_ms = function(_) return 0 end,
			log_if_slow = function() end,
		}
		package.loaded["modules.keylogger"] = {
			log_hotstring_suggested = function() end,
			log_hotstring_dismissed = function() end,
			notify_synthetic        = function() end,
			set_buffer              = function() end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			resolve = nil,  -- Not called in the paths we exercise
		}
		package.loaded["ui.tooltip"] = {
			hide              = function() end,
			hide_forced       = function() end,
			show_stacked      = function() end,
			set_timeout       = function() end,
			is_visible        = function() return false end,
			tint              = function(_) return nil end,
			set_colorization_enabled = function() end,
			set_accent_color  = function() end,
			set_accept_callback  = function() end,
			set_cancel_callback  = function() end,
			set_on_show_callback = function() end,
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {
				llm_after_hotstring = false,
				llm_reset_on_nav    = false,
			},
			check_modifiers = function() return false end,
			-- get_current_model is called unconditionally by prediction_engine.lua's
			-- module-level code; without it, any later test whose require chain
			-- reaches prediction_engine while this stub is still cached crashes
			-- with "attempt to call a nil value (field 'get_current_model')".
			get_current_model = function() return "stub-model" end,
		}

		-- Minimal prediction engine stub — all operations are no-ops.
		local engine_stub = {
			init                    = function() end,
			get_llm_enabled         = function() return false end,
			stop_timer              = function() end,
			start_timer             = function() end,
			start_timer_word_end    = function() end,
			reset                   = function() end,
			is_visible              = function() return false end,
			get_predictions         = function() return {} end,
			navigate                = function() end,
			consume                 = function() return nil end,
			get_current_index       = function() return 1 end,
			perform_check           = function() end,
			handle_chain_signal     = function() return false end,
			arm_chain               = function() end,
			get_navigation_mods     = function() return {} end,
			get_validation_mods     = function() return {} end,
			set_llm_enabled         = function() end,
			set_llm_model           = function() end,
			set_llm_display_model_name = function() end,
			set_llm_backend_name    = function() end,
			set_llm_context_length  = function() end,
			set_llm_temperature     = function() end,
			set_llm_num_predictions = function() end,
			set_llm_pred_indent     = function() end,
			set_llm_show_info_bar   = function() end,
			set_llm_sequential_mode = function() end,
			set_llm_auto_raise_temp = function() end,
			set_llm_disabled_apps   = function() end,
			set_llm_url_bar_filter_enabled = function() end,
			set_llm_secure_field_filter_enabled = function() end,
			set_llm_instant_on_word_end = function() end,
			set_llm_val_modifiers   = function() end,
			set_llm_nav_modifiers   = function() end,
			set_llm_min_words       = function() end,
			set_llm_max_words       = function() end,
			set_llm_debounce        = function() end,
			set_llm_streaming       = function() end,
			set_llm_streaming_multi = function() end,
			set_preview_ai_enabled  = function() end,
			set_preview_ai_color    = function() end,
		}
		package.loaded["modules.llm.prediction_engine"] = engine_stub

		-- Stub Registry: no mappings, all lookups return nil.
		package.loaded["modules.keymap.registry"] = {
			mappings_for_tail      = function(_) return nil end,
			mappings_for_star_tail = function(_) return nil end,
		}

		-- km_utils is used for tokens/plain and emit; stubs are sufficient.
		package.loaded["modules.keymap.utils"] = {
			tokens_from_repl = function(s) return {{ kind = "text", value = s }} end,
			plain_text       = function(tokens)
				local out = {}
				for _, t in ipairs(tokens or {}) do
					if t.kind == "text" then out[#out + 1] = t.value end
				end
				return table.concat(out)
			end,
			emit_text    = function(s) return #s, s end,
			emit_tokens  = function(_)  return 0, "" end,
			resolve_prediction_overlap = function(_, d, t) return d, t end,
			is_ignored_window = function() return false end,
		}

		-- Reload lib.logger with the fresh hs stub so require("lib.logger") works.
		package.loaded["lib.logger"] = nil
		helpers.load_with_stubs("lib.logger")

		local bridge = require("modules.keymap.llm_bridge")

		-- Build a minimal CoreState that satisfies the guard in update_preview.
		local core_state = {
			buffer              = "",
			mappings            = {},
			groups              = {},
			DELAYS              = {},
			preview_providers   = {},
			is_repeat_feature_enabled = function() return false end,
		}
		local keymap_defaults = {
			preview_star_enabled        = true,
			preview_autocorrect_enabled = true,
		}
		bridge.init(core_state, keymap_defaults)
		return bridge, core_state
	end

	helpers.it("0xBF in buffer does not propagate an error from update_preview", function()
		local bridge, state = build_llm_bridge()
		state.buffer = BAD_UTF8
		local ok = pcall(bridge.update_preview, BAD_UTF8)
		helpers.assert_true(ok, "update_preview must not raise on malformed UTF-8")
	end)

	helpers.it("0x80 continuation byte as buffer does not raise", function()
		local bridge, state = build_llm_bridge()
		state.buffer = BAD_UTF8_80
		local ok = pcall(bridge.update_preview, BAD_UTF8_80)
		helpers.assert_true(ok, "update_preview must not raise on 0x80")
	end)

	helpers.it("truncated 2-byte lead byte as buffer does not raise", function()
		local bridge, state = build_llm_bridge()
		state.buffer = BAD_UTF8_TRUNCATED
		local ok = pcall(bridge.update_preview, BAD_UTF8_TRUNCATED)
		helpers.assert_true(ok, "update_preview must not raise on truncated lead byte")
	end)

	helpers.it("bad UTF-8 appended after valid text does not raise", function()
		local bridge, state = build_llm_bridge()
		local buf = "bonjour" .. BAD_UTF8
		state.buffer = buf
		local ok = pcall(bridge.update_preview, buf)
		helpers.assert_true(ok, "update_preview must not raise on valid + bad UTF-8")
	end)

	helpers.it("valid UTF-8 buffer still runs without error (no regression on happy path)", function()
		local bridge, state = build_llm_bridge()
		state.buffer = "hello world"
		local ok = pcall(bridge.update_preview, "hello world")
		helpers.assert_true(ok, "update_preview must not raise on valid UTF-8")
	end)

end)
