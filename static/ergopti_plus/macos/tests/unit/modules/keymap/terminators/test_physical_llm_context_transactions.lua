--- tests/unit/modules/keymap/terminators/test_physical_llm_context_transactions.lua

--- ==============================================================================
--- REGRESSION: physical edits preserve and protect independent LLM context
--- ==============================================================================

local helpers = require("tests.helpers")

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
		has_pending_work    = function() return false end,
		is_visible = function() return false end,
	}, {
		__index = function() return function() end end,
	})
	package.loaded["modules.keystats"] = {
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



helpers.describe("physical AI context retention", function()
	local function run(body)
		local keymap, hs_stub, state, effects, cleanup = load_fixture()
		local ok, err = xpcall(function()
			local tap = assert(find_tap(hs_stub, hs_stub.eventtap.event.types.keyDown))
			body(keymap, hs_stub, state, effects, tap)
		end, debug.traceback)
		cleanup()
		if not ok then error(err, 0) end
	end

	helpers.it("retains 2500 typed characters across backspace and navigation", function()
		run(function(keymap, _, state, _, tap)
			keymap.set_llm_context_length(4000)
			for _ = 1, 2500 do tap.fn(physical_key("x")) end
			helpers.assert_eq(state.llm_buffer, string.rep("x", 2500))
			helpers.assert_true(#state.buffer < 2500, "hotstring context remains bounded independently")
			tap.fn(physical_key("", 51))
			helpers.assert_eq(state.llm_buffer, string.rep("x", 2499))
			tap.fn(physical_key("", 123))
			helpers.assert_eq(state.buffer, "")
			helpers.assert_eq(state.llm_buffer, string.rep("x", 2499))
			tap.fn(physical_key("z"))
			helpers.assert_eq(state.llm_buffer, string.rep("x", 2499) .. "z")
		end)
	end)

	helpers.it("withholds a private expansion after long physical input and later edits", function()
		run(function(keymap, _, state, _, tap)
			for _ = 1, 900 do tap.fn(physical_key("x")) end
			for c in ("12345"):gmatch(".") do tap.fn(physical_key(c)) end
			local secret = "PRIVATE-4729"
			local accepted = keymap.inject_dynamic(5, secret, function() return #secret, secret, secret end, "dynamic", true)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(state.llm_buffer, "", "private text and preceding context must be withheld")
			for c in ("safety"):gmatch(".") do tap.fn(physical_key(c)) end
			tap.fn(physical_key("", 51))
			tap.fn(physical_key("", 123))
			tap.fn(physical_key("z"))
			helpers.assert_eq(state.llm_buffer, "safetz")
			helpers.assert_eq(state.llm_buffer:find(secret, 1, true), nil)
		end)
	end)

	helpers.it("keeps private boundaries and visible text across a hotstring idle timeout", function()
		run(function(keymap, _, state, _, tap)
			for c in ("12345"):gmatch(".") do tap.fn(physical_key(c)) end
			local secret = "PRIVATE-4729"
			helpers.assert_eq(keymap.inject_dynamic(5, secret, function() return #secret, secret, secret end,
				"dynamic", true), true)
			for c in ("safe"):gmatch(".") do tap.fn(physical_key(c)) end
			local scheduler = require("core.events.timer_scheduler")
			local original_time = scheduler.hotstring_time
			scheduler.hotstring_time = function() return 10000 end
			state.last_key_time = 10000 - state.WORD_TIMEOUT_SEC - 1
			tap.fn(physical_key("z"))
			local after_typing = state.llm_buffer
			state.last_key_time = 10000 - state.WORD_TIMEOUT_SEC - 1
			tap.fn(physical_key("", 51))
			scheduler.hotstring_time = original_time
			helpers.assert_eq(after_typing, "safez")
			helpers.assert_nil(after_typing:find(secret, 1, true))
			helpers.assert_eq(state.llm_buffer, "safe")
		end)
	end)

	helpers.it("does not resurrect context after a refused dynamic splice", function()
		run(function(keymap, _, state, _, tap)
			for c in ("private prefix"):gmatch(".") do tap.fn(physical_key(c)) end
			helpers.assert_eq(state.llm_buffer, "private prefix")
			local accepted = keymap.inject_dynamic(1000, "replacement", function() error("must not run") end)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(state.llm_buffer, "")
			tap.fn(physical_key("z"))
			helpers.assert_eq(state.llm_buffer, "z", "refused context must not reappear on the next physical key")
		end)
	end)

	helpers.it("keeps physical context when a replacement transaction is refused", function()
		run(function(keymap, _, state, _, tap)
			for c in ("abc"):gmatch(".") do tap.fn(physical_key(c)) end
			local before = state.llm_buffer
			local accepted = keymap.inject_dynamic(1, "replacement", function() error("injected failure") end)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(state.llm_buffer, before)
			tap.fn(physical_key("d"))
			helpers.assert_eq(state.llm_buffer, "abcd")
		end)
	end)
end)

return true
