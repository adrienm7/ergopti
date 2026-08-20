--- tests/unit/modules/keymap/test_preview_cross_kind_winner.lua

--- ==============================================================================
--- MODULE: Regression — preview uses the engine winner across mapping kinds
--- DESCRIPTION:
--- Drives the real keymap eventtap with a shorter star mapping and a longer
--- end-character mapping that both match the same screen buffer. The engine
--- arbitrates across both kinds; every undimmed tooltip row must identify that
--- same winner before the user presses the magic key.
--- ==============================================================================

local helpers = require("tests.helpers")

local STAR = utf8.char(0x2605)
local KEYCODE_LETTER = 0
local STAR_REPLACEMENT = "STAR"
local END_REPLACEMENT = "END"
local SHADOW_REPLACEMENT = "SHADOW"
local EQUAL_STAR_REPLACEMENT = "STAR_EQUAL"
local EQUAL_END_REPLACEMENT = "END_EQUAL"
local WHITESPACE_REPLACEMENT = "WHITESPACE"


--- Installs only the external LLM/UI collaborators needed by the real keymap.
--- @param effects table Mutable capture table for tooltip rows and emitted text.
local function install_collaborators(effects)
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name:match("^adapters%.")
		) then
			package.loaded[name] = nil
		end
	end
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		check_modifiers = function() return false end,
	}
	package.loaded["modules.llm.prediction_engine"] = {
		init = function() return true end,
		set_runtime_guard = function() end,
		get_llm_enabled = function() return false end,
		reset = function() return true end,
		handle_chain_signal = function() return false end,
		is_visible = function() return false end,
	}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		log_llm_accepted = function() end,
		log_hotstring = function() end,
		notify_synthetic = function(text, source)
			if source == "hotstring" then
				effects.emitted[#effects.emitted + 1] = text
			end
		end,
		set_buffer = function(value) effects.post_buffer = value end,
	}
	package.loaded["ui.tooltip"] = {
		set_runtime_guard = function() end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_on_show_callback = function() end,
		set_timeout = function() end,
		set_colorization_enabled = function() end,
		set_accent_color = function() end,
		tint = function() return {} end,
		show_stacked = function(rows)
			effects.rows = rows
			return true
		end,
		hide = function() return true end,
		hide_forced = function() return true end,
		hide_forced_silent = function() return true end,
		is_visible = function() return false end,
		is_hotstring_visible = function() return false end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		resolve = function() return nil end,
	}
	package.loaded["adapters.tooltip_renderer"] = {
		hide = function() return true end,
	}
end


--- Returns the real key-down tap created by the keymap module.
--- @param hs_stub table Active Hammerspoon test stub.
--- @return table|nil tap
local function find_keydown_tap(hs_stub)
	for _, tap in ipairs(hs_stub.eventtap.__taps) do
		if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then
			return tap
		end
	end
	return nil
end


--- Builds a physical key-down event carrying one character.
--- @param character string Character observed by the keymap.
--- @return table event
local function physical_key(character)
	return {
		getProperty = function() return 0 end,
		getFlags = function() return { cmd = false, ctrl = false, alt = false, shift = false } end,
		getKeyCode = function() return KEYCODE_LETTER end,
		getCharacters = function() return character end,
	}
end

--- Holds the unrelated AX boundary in its already-classified normal state.
--- @return function restore
local function force_normal_window()
	local Utils = package.loaded["modules.keymap.utils"]
	helpers.assert_not_nil(Utils, "the real keymap must load its window-classification module")
	local original = Utils.is_ignored_window
	Utils.is_ignored_window = function() return false, 0 end
	return function() Utils.is_ignored_window = original end
end

--- Drains only zero-delay work; production deliberately keeps a future TTL timer.
--- @param hs_stub table Hammerspoon stub.
local function drain_immediate_timers(hs_stub)
	for _ = 1, 32 do
		local snapshot = {}
		for _, timer in ipairs(hs_stub.timer.__timers) do
			if timer.running and timer.delay == 0 then snapshot[#snapshot + 1] = timer end
		end
		if #snapshot == 0 then return end
		for _, timer in ipairs(snapshot) do
			if timer.running then timer:fire() end
		end
	end
	error("immediate timer queue did not settle", 0)
end





-- ========================================
-- ========================================
-- ======= 1/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("preview arbitration across mapping kinds", function()
	helpers.it("G5 every active preview row names the cross-kind engine winner", function()
		local effects = { emitted = {} }
		install_collaborators(effects)

		local Keymap = helpers.load_with_stubs("modules.keymap")
		local hs_stub = _G.hs
		local restore_normal_window = force_normal_window()
		Keymap.add("b" .. STAR, STAR_REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.add("aab", END_REPLACEMENT, {
			auto_expand = false,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.add("xy" .. STAR, EQUAL_STAR_REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.add("zxy", EQUAL_END_REPLACEMENT, {
			auto_expand = false,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.add(" " .. STAR, WHITESPACE_REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.add("abc" .. STAR, "abc" .. STAR, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
			final_result = true,
		})
		Keymap.add("bc" .. STAR, SHADOW_REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.sort_mappings()
		Keymap.set_preview_star_enabled(true)
		Keymap.set_preview_autocorrect_enabled(true)

		local tap = find_keydown_tap(hs_stub)
		helpers.assert_not_nil(tap, "the real keymap must install one key-down eventtap")
		local now = 100
		hs_stub.timer.secondsSinceEpoch = function() return now end
		local function press(character, elapsed)
			now = now + (elapsed or 0.01)
			return tap.fn(physical_key(character))
		end
		local ok, err = xpcall(function()
		for _, character in ipairs({ "a", "a", "b" }) do
			press(character)
		end
		drain_immediate_timers(hs_stub)

		helpers.assert_true(type(effects.rows) == "table" and #effects.rows >= 2,
			"both matching mapping kinds must reach the preview arbitration state")
		local active_rows = {}
		local dimmed_star_row = nil
		for _, row in ipairs(effects.rows) do
			if row.dimmed == false then
				active_rows[#active_rows + 1] = row
			elseif row.trigger_label == STAR and row.text == STAR_REPLACEMENT then
				dimmed_star_row = row
			end
		end
		helpers.assert_eq(#active_rows, 1,
			"cross-kind arbitration must expose exactly one active engine promise")
		helpers.assert_eq(active_rows[1].text, END_REPLACEMENT,
			"the prospective resolver must mark the longer end-character winner active")
		helpers.assert_not_nil(dimmed_star_row,
			"the shorter star alternative may remain visible only as a dimmed row")

		local consumed = press(STAR)
		helpers.assert_eq(consumed, true, "the real engine must consume the magic key")
		helpers.assert_eq(#effects.emitted, 1, "the real engine must commit exactly one replacement")
		helpers.assert_eq(effects.emitted[1], END_REPLACEMENT,
			"the longer end-character mapping is the real cross-kind winner")

		helpers.assert_eq(active_rows[1].text, effects.emitted[1],
			"an undimmed tooltip row must never disagree with the engine winner")

		-- Equal length is not covered by the longer-end control above. The shared
		-- cross-driver rule is strict `>`: a tie stays with the auto/star action.
		now = now + 1
		effects.rows = nil
		effects.emitted = {}
		for _, character in ipairs({ "z", "x", "y" }) do press(character) end
		drain_immediate_timers(hs_stub)
		local equal_active = nil
		for _, row in ipairs(effects.rows or {}) do
			if row.dimmed == false then equal_active = row; break end
		end
		helpers.assert_not_nil(equal_active,
			"an equal-length collision must expose one active engine promise")
		helpers.assert_eq(equal_active.text, EQUAL_STAR_REPLACEMENT,
			"equal length must stay with the star action, not the end-character action")
		local equal_consumed = press(STAR)
		helpers.assert_eq(equal_consumed, true,
			"the real eventtap must commit the equal-length winner")
		helpers.assert_eq(effects.emitted[1], EQUAL_STAR_REPLACEMENT,
			"the equal-length preview winner must equal the emitted replacement")

		-- Whitespace is a valid custom star base. The bridge must ask the resolver
		-- before treating a trailing space as an LLM-only word boundary.
		now = now + 1
		effects.rows = nil
		effects.emitted = {}
		press(" ")
		drain_immediate_timers(hs_stub)
		helpers.assert_true(type(effects.rows) == "table" and #effects.rows > 0,
			"a whitespace-base mapping reachable by the engine must be previewed")
		helpers.assert_eq(effects.rows[1].text, WHITESPACE_REPLACEMENT,
			"the whitespace preview must carry the engine replacement")
		helpers.assert_eq(press(STAR), true,
			"the real eventtap must consume the whitespace-base magic action")
		helpers.assert_eq(effects.emitted[1], WHITESPACE_REPLACEMENT,
			"the whitespace preview and engine output must agree")

		-- A longer final no-op is an observable terminal action: it suppresses
		-- rescans and clears the engine buffer before returning false. The shorter
		-- mapping is therefore not a fallback the same keypress can reach.
		now = now + 1
		effects.rows = nil
		effects.emitted = {}
		for _, character in ipairs({ "a", "b", "c" }) do
			press(character)
		end
		drain_immediate_timers(hs_stub)
		helpers.assert_true(effects.rows == nil or #effects.rows == 0,
			"a terminal no-op must suppress every shorter candidate it makes unreachable")

		local noop_consumed = press(STAR)
		helpers.assert_eq(noop_consumed, false,
			"the terminal no-op must preserve the user's physical magic key")
		helpers.assert_eq(#effects.emitted, 0,
			"the shorter shadowed mapping must not fire after the terminal no-op clears state")
		end, debug.traceback)
		restore_normal_window()
		if not ok then error(err, 0) end
	end)
end)
