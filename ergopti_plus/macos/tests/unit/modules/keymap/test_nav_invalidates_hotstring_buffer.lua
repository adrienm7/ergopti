--- tests/unit/modules/keymap/test_nav_invalidates_hotstring_buffer.lua

--- ==============================================================================
--- REGRESSION: navigation retains optional LLM context, never hotstring eligibility
--- ==============================================================================

local helpers = require("tests.helpers")

local MAGIC = utf8.char(0x2605)

local function physical_key(character, keycode)
	return {
		getProperty = function() return 0 end,
		getFlags = function() return { cmd = false, ctrl = false, alt = false, shift = false } end,
		getKeyCode = function() return keycode or 0 end,
		getCharacters = function() return character end,
	}
end


local function find_tap(hs_stub, event_type)
	for _, tap in ipairs(hs_stub.eventtap.__taps) do
		for _, registered_type in ipairs(tap.types or {}) do
			if registered_type == event_type then return tap end
		end
	end
	return nil
end


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


local function load_fixture()
	local prior_loaded = {}
	for name, value in pairs(package.loaded) do prior_loaded[name] = value end
	local prior_hs = rawget(_G, "hs")

	for name in pairs(package.loaded) do
		if type(name) == "string"
			and (name:match("^modules%.keymap") or name:match("^adapters%.")) then
			package.loaded[name] = nil
		end
	end

	local effects = { emitted = {}, rows = nil, visible = false }
	local core_state
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = false },
		check_modifiers = function() return false end,
	}
	package.loaded["modules.llm.prediction_engine"] = setmetatable({
		init = function(state) core_state = state; return true end,
		set_runtime_guard = function() end,
		get_llm_enabled = function() return false end,
		reset = function() effects.visible = false; return true end,
		handle_chain_signal = function() return false end,
		is_visible = function() return false end,
	}, {
		__index = function() return function() end end,
	})
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		log_llm_accepted = function() end,
		log_hotstring = function() end,
		notify_synthetic = function(text, source)
			if source == "hotstring" then effects.emitted[#effects.emitted + 1] = text end
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
		is_visible = function() return effects.visible end,
		is_hotstring_visible = function() return effects.visible end,
		has_visible_hotstring_lease = function(token)
			if not effects.visible then return false end
			for _, row in ipairs(effects.rows or {}) do
				if row.lease_token == token then return true end
			end
			return false
		end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		resolve = function() return nil end,
	}
	package.loaded["adapters.tooltip_renderer"] = { hide = function() return true end }

	local Keymap = helpers.load_with_stubs("modules.keymap")
	local hs_stub = _G.hs
	local Utils = package.loaded["modules.keymap.utils"]
	local original_is_ignored = Utils.is_ignored_window
	local original_is_secure = Utils.is_secure_field
	Utils.is_ignored_window = function() return false, 0 end
	Utils.is_secure_field = function() return false, 0 end

	Keymap.add("agé", "âgé", {
		auto_expand = false,
		is_case_sensitive = true,
		is_case_sensitive_strict = true,
	})
	Keymap.sort_mappings()
	Keymap.set_preview_star_enabled(true)
	Keymap.set_preview_autocorrect_enabled(true)
	Keymap.set_llm_reset_on_nav(false)

	local function cleanup()
		pcall(Keymap.stop)
		Utils.is_ignored_window = original_is_ignored
		Utils.is_secure_field = original_is_secure
		for name in pairs(package.loaded) do
			if prior_loaded[name] == nil then package.loaded[name] = nil end
		end
		for name, value in pairs(prior_loaded) do package.loaded[name] = value end
		_G.hs = prior_hs
	end

	return Keymap, hs_stub, core_state, effects, cleanup
end


local function type_trigger(key_tap, hs_stub)
	for _, character in ipairs({ "a", "g", "é" }) do
		key_tap.fn(physical_key(character))
	end
	drain_immediate_timers(hs_stub)
end


helpers.describe("navigation invalidates hotstring buffer", function()
	helpers.it("navigation invalidates hotstring buffer while retaining optional LLM context", function()
		for _, action in ipairs({ "left-arrow", "left-click" }) do
			local _, hs_stub, state, effects, cleanup = load_fixture()
			local ok, err = xpcall(function()
				local key_tap = find_tap(hs_stub, hs_stub.eventtap.event.types.keyDown)
				helpers.assert_not_nil(key_tap)
				type_trigger(key_tap, hs_stub)
				helpers.assert_true(effects.visible,
					"the control must first expose the fireable hotstring row")
				helpers.assert_eq(state.buffer, "agé")
				helpers.assert_eq(state.llm_buffer, "agé")

				if action == "left-arrow" then
					key_tap.fn(physical_key("", 123))
				else
					local mouse_tap = find_tap(hs_stub, hs_stub.eventtap.event.types.leftMouseDown)
					helpers.assert_not_nil(mouse_tap)
					mouse_tap.fn({ getProperty = function() return 0 end })
				end

				helpers.assert_eq(state.buffer, "",
					"cursor movement must revoke the authoritative magic-action buffer immediately")
				helpers.assert_eq(state.start_is_word_boundary, false)
				helpers.assert_eq(state.llm_buffer, "agé",
					"llm_reset_on_nav=false retains only the independent prompt context")
				drain_immediate_timers(hs_stub)
				helpers.assert_eq(effects.visible, false)

				local consumed = key_tap.fn(physical_key(MAGIC))
				helpers.assert_eq(consumed, false,
					"the next magic key must pass through after navigation")
				helpers.assert_eq(#effects.emitted, 0,
					"no stale hotstring may delete text at the moved cursor")
			end, debug.traceback)
			cleanup()
			if not ok then error(err, 0) end
		end
	end)
end)

return true
