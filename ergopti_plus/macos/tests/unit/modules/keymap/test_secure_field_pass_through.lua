--- tests/unit/modules/keymap/test_secure_field_pass_through.lua

--- ==============================================================================
--- MODULE: Secure-field total pass-through regression
--- DESCRIPTION:
--- Drives the real keymap eventtap across a cached normal-to-secure focus change.
--- Password fields must never run preview, acceptance, expansion, or repeat logic;
--- returning to a known-normal field must restore the ordinary hotstring path.
--- ==============================================================================

local helpers = require("tests.helpers")

local STAR = utf8.char(0x2605)
local KEYCODE_LETTER = 0
local REPLACEMENT = "SECURE_FIELD_GUARD"


--- Installs the external collaborators needed by the real keymap graph.
--- @param effects table Mutable behavior capture.
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
		reset = function()
			effects.llm_resets = effects.llm_resets + 1
			local tooltip = package.loaded["ui.tooltip"]
			return tooltip and tooltip.hide_forced_silent()
		end,
		handle_chain_signal = function() return false end,
		is_visible = function()
			effects.llm_visibility_reads = effects.llm_visibility_reads + 1
			return false
		end,
	}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		log_llm_accepted = function() end,
		log_hotstring = function() end,
		notify_synthetic = function(text, source, _deletes, variant)
			if source == "hotstring" then effects.emitted[#effects.emitted + 1] = text end
			if variant == "repeat_key" then effects.repeated = text end
		end,
		set_buffer = function() end,
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
			effects.visible = true
			return true
		end,
		hide = function() effects.visible = false; return true end,
		hide_forced = function() effects.visible = false; return true end,
		hide_forced_silent = function() effects.visible = false; return true end,
		is_visible = function() return effects.visible == true end,
		is_hotstring_visible = function() return effects.visible == true end,
		has_visible_hotstring_lease = function(token)
			if effects.visible ~= true then return false end
			for _, row in ipairs(effects.rows or {}) do
				if row.lease_token == token then return true end
			end
			return false
		end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		resolve = function() return nil end,
	}
	package.loaded["adapters.tooltip_renderer"] = {
		hide = function() effects.visible = false; return true end,
	}
end


--- Finds the real key-down tap installed by modules.keymap.
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


--- Builds one physical character event.
--- @param character string Event text.
--- @return table event
local function physical_key(character)
	return {
		getProperty = function() return 0 end,
		getFlags = function() return { cmd = false, ctrl = false, alt = false, shift = false } end,
		getKeyCode = function() return KEYCODE_LETTER end,
		getCharacters = function() return character end,
	}
end


--- Drains zero-delay work without firing the tracker's future TTL timer.
--- @param hs_stub table Active Hammerspoon test stub.
local function drain_immediate_timers(hs_stub)
	for _ = 1, 32 do
		local pending = {}
		for _, timer in ipairs(hs_stub.timer.__timers) do
			if timer.running and timer.delay == 0 then pending[#pending + 1] = timer end
		end
		if #pending == 0 then return end
		for _, timer in ipairs(pending) do
			if timer.running then timer:fire() end
		end
	end
	error("immediate timer queue did not settle", 0)
end


helpers.describe("secure fields are a total keymap pass-through boundary", function()
	helpers.it("revokes prior UI and resumes only after a known-normal focus generation", function()
		local effects = {
			emitted = {},
			llm_resets = 0,
			llm_visibility_reads = 0,
			visible = false,
		}
		install_collaborators(effects)
		local Keymap = helpers.load_with_stubs("modules.keymap")
		local hs_stub = _G.hs
		local Utils = package.loaded["modules.keymap.utils"]
		helpers.assert_not_nil(Utils, "the real keymap must load its context cache")

		local original_ignored = Utils.is_ignored_window
		local original_secure = Utils.is_secure_field
		local secure = false
		local generation = 0
		local secure_reads = 0
		Utils.is_ignored_window = function() return false, generation end
		Utils.is_secure_field = function()
			secure_reads = secure_reads + 1
			return secure, generation
		end

		Keymap.add("ab" .. STAR, REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.sort_mappings()
		Keymap.set_preview_star_enabled(true)
		Keymap.set_preview_autocorrect_enabled(true)
		Keymap.set_repeat_feature_enabled(true)

		local tap = find_keydown_tap(hs_stub)
		helpers.assert_not_nil(tap, "the real keymap must install one key-down eventtap")
		local now = 100
		hs_stub.timer.secondsSinceEpoch = function() return now end
		local function press(character)
			now = now + 0.01
			return tap.fn(physical_key(character))
		end

		local ok, err = xpcall(function()
			helpers.assert_eq(press("a"), false)
			helpers.assert_eq(press("b"), false)
			drain_immediate_timers(hs_stub)
			helpers.assert_true(effects.visible == true and type(effects.rows) == "table",
				"the control must establish a real preview before focus becomes secure")

			secure = nil
			generation = 1
			local visibility_before = effects.llm_visibility_reads
			local consumed = press(STAR)
			drain_immediate_timers(hs_stub)

			helpers.assert_eq(consumed, false,
				"an unclassified field must receive the user's physical magic key unchanged")
			helpers.assert_eq(#effects.emitted, 0,
				"a previous field's preview must not expand before the new field is classified")
			helpers.assert_nil(effects.repeated,
				"the repeat fallback must remain inert while field ownership is unknown")
			helpers.assert_eq(effects.visible, false,
				"entering an unclassified field must revoke the previous field's tooltip")
			helpers.assert_eq(effects.llm_visibility_reads, visibility_before,
				"unclassified input must return before prediction acceptance or visibility logic")

			secure = true
			helpers.assert_eq(press("x"), false)
			helpers.assert_eq(press(STAR), false)
			helpers.assert_nil(effects.repeated,
				"ordinary secure-field typing must not arm repeat state")

			secure = false
			generation = 2
			effects.rows = nil
			effects.emitted = {}
			helpers.assert_eq(press("a"), false)
			helpers.assert_eq(press("b"), false)
			drain_immediate_timers(hs_stub)
			helpers.assert_true(type(effects.rows) == "table" and effects.rows[1].text == REPLACEMENT,
				"a new known-normal generation must restore preview behavior")
			helpers.assert_eq(press(STAR), true,
				"the ordinary field must retain the configured magic expansion")
			helpers.assert_eq(effects.emitted[1], REPLACEMENT)
			helpers.assert_true(secure_reads >= 7,
				"every physical key must consult the cached secure-field verdict")
		end, debug.traceback)

		Keymap.set_repeat_feature_enabled(false)
		Utils.is_ignored_window = original_ignored
		Utils.is_secure_field = original_secure
		if not ok then error(err, 0) end
	end)
end)
