--- tests/unit/modules/dynamic_hotstrings/test_personal_preview_static_ownership.lua

--- ==============================================================================
--- MODULE: Regression — personal preview providers obey static mapping ownership
--- DESCRIPTION:
--- Drives the real keymap eventtap, registry, expander, bridge, and personal-info
--- provider through the reachable `@e★` collision. The tooltip and committed
--- output must describe the same winner. A provider cannot bypass the registry
--- ownership decision merely because providers are scanned before static rows.
--- ==============================================================================

local helpers = require("tests.helpers")

local STAR = utf8.char(0x2605)
local KEYCODE_LETTER = 0
local STATIC_REPLACEMENT = "STATIC"
local END_REPLACEMENT = "END_STATIC"
local PROVIDER_REPLACEMENT = "exemple.pro@example.com"


--- Installs only the external LLM/UI collaborators needed by the real keymap.
--- @param effects table Mutable capture table for tooltip rows and emitted text.
local function install_collaborators(effects)
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name:match("^modules%.dynamic_hotstrings")
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
		init = function() end,
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


--- Holds the unrelated AX boundary in its already-classified normal state.
--- @return function restore
local function force_normal_window()
	local Utils = package.loaded["modules.keymap.utils"]
	helpers.assert_not_nil(Utils, "the real keymap must load its window-classification module")
	local original = Utils.is_ignored_window
	Utils.is_ignored_window = function() return false, 0 end
	return function() Utils.is_ignored_window = original end
end


--- Drains only zero-delay work; production deliberately keeps future TTL timers.
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





-- ========================================
-- ========================================
-- ======= 1/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("personal preview and static engine ownership", function()
	helpers.it("G5 personal preview obeys the static mapping selected by the engine", function()
		local effects = { emitted = {} }
		install_collaborators(effects)

		local Keymap = helpers.load_with_stubs("modules.keymap")
		local PersonalInfo = require("modules.dynamic_hotstrings.personal_info")
		local hs_stub = _G.hs
		local restore_normal_window = force_normal_window()
		local now = 100
		hs_stub.timer.secondsSinceEpoch = function() return now end

		Keymap.add("@e" .. STAR, STATIC_REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		-- The personal interceptor runs before the static terminator engine. A
		-- non-auto `@w` mapping therefore cannot claim the complete `@w★` action:
		-- the provider is the real winner in this collision direction.
		Keymap.add("@w", END_REPLACEMENT, {
			auto_expand = false,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.sort_mappings()
		Keymap.set_preview_star_enabled(true)
		Keymap.set_preview_autocorrect_enabled(true)

		PersonalInfo.start("", Keymap,
			helpers.shared("core/config_schema/examples/personal_info.example.toml"))
		PersonalInfo.enable()

		local tap = find_keydown_tap(hs_stub)
		helpers.assert_not_nil(tap, "the real keymap must install one key-down eventtap")
		local function press(character, elapsed)
			now = now + (elapsed or 0.01)
			return tap.fn(physical_key(character))
		end

		-- At buffer start, the static `@e★` mapping claims `@` as a prefix, so the
		-- personal interceptor deliberately remains IDLE. A provider that merely
		-- re-matches the visible `@p` suffix would advertise a first name that the
		-- live state machine cannot emit on the next magic key.
		press("@")
		press("p")
		drain_immediate_timers(hs_stub)
		helpers.assert_true(effects.rows == nil or #effects.rows == 0,
			"the provider must stay silent when its interceptor never entered collection")
		local blocked_consumed = press(STAR)
		helpers.assert_eq(blocked_consumed, false,
			"the uncollected personal combo must pass through instead of claiming an output")
		helpers.assert_eq(#effects.emitted, 0,
			"the blocked interceptor state must emit no personal replacement")

		-- Move away from the buffer-start prefix collision before exercising the
		-- complete static trigger below.
		press(" ")
		effects.rows = nil
		press("@")
		press("e")
		drain_immediate_timers(hs_stub)

		helpers.assert_true(type(effects.rows) == "table" and #effects.rows > 0,
			"the reachable @e state must render a concrete preview row")
		local consumed = press(STAR)
		helpers.assert_eq(consumed, true, "the real engine must consume the magic-key expansion")
		helpers.assert_eq(#effects.emitted, 1, "the real engine must commit exactly one replacement")
		helpers.assert_eq(effects.emitted[1], STATIC_REPLACEMENT,
			"the registry-owned static mapping is the engine winner")

		helpers.assert_eq(effects.rows[1].text, effects.emitted[1],
			"the personal provider must not preview a different winner than the real engine")

		-- Start a fresh word without reloading the engine, then exercise the inverse
		-- ownership case through the same physical eventtap. This catches a bridge
		-- that always lets static rows outrank interceptors merely because both are
		-- prospective at preview time.
		effects.rows = nil
		effects.emitted = {}
		press(" ")
		press("@")
		press("w")
		drain_immediate_timers(hs_stub)

		helpers.assert_true(type(effects.rows) == "table" and #effects.rows > 0,
			"the reachable @w state must render the interceptor-backed provider row")
		helpers.assert_eq(effects.rows[1].text, PROVIDER_REPLACEMENT,
			"the provider must outrank a static end mapping its interceptor bypasses")

		local provider_consumed = press(STAR)
		helpers.assert_eq(provider_consumed, true,
			"the personal interceptor must consume the complete provider action")
		helpers.assert_eq(#effects.emitted, 1,
			"the provider collision must commit exactly one replacement")
		helpers.assert_eq(effects.emitted[1], PROVIDER_REPLACEMENT,
			"the interceptor must produce the provider value, not the static end mapping")
		helpers.assert_eq(effects.rows[1].text, effects.emitted[1],
			"provider-first preview order must match the real interceptor-first engine order")
		restore_normal_window()
	end)
end)
