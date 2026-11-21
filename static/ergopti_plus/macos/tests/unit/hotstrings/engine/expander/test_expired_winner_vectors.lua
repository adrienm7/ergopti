--- tests/unit/hotstrings/engine/expander/test_expired_winner_vectors.lua

--- ==============================================================================
--- MODULE: Expired Winner Corpus (hcd-1-expired-winner)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/expired_winner_vectors.json through
--- the real keymap key-down tap. The matcher picks its winner first and asks
--- only that winner's expansion delay: an expired winner fires nothing, and a
--- shorter or lower rule whose delay still allows it no longer fires in its
--- place (maintainer decision HCD-1, 2026-11-21, as on Windows, Linux and the
--- shared engine). Each mapping carries its own delay, so the shared delay
--- policy is replaced by the vector's per-trigger delays on the live CoreState.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYCODE_LETTER = 0

--- Reads the shared vectors.
--- @return table
local function read_vectors()
	local fh = assert(io.open(helpers.shared("tests/corpus/hotstrings/expired_winner_vectors.json"), "r"))
	local raw = fh:read("*a")
	fh:close()
	local ok, corpus = pcall(require("hs").json.decode, raw)
	assert(ok, "expired-winner corpus is not valid JSON")
	return corpus.vectors
end

--- Installs the external collaborators needed to drive the real keymap tap.
--- @param effects table Mutable output/tooltip capture.
local function install_collaborators(effects)
	-- This module drives the real keymap graph. Other test files initialise the
	-- registry/bridge against their own state objects, so reusing those cached
	-- singletons makes this behavioral repro depend on discovery order.
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			helpers.in_module_family(name, "hotstrings.engine.expander")
			or helpers.is_driver_module(name)
		) then
			package.loaded[name] = nil
		end
	end
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["ai.engine"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		check_modifiers = function() return false end,
	}
	package.loaded["ai.engine.prediction.engine"] = {
		init = function() return true end,
		set_runtime_guard = function() end,
		get_llm_enabled = function() return false end,
		reset = function() return true end,
		handle_chain_signal = function() return false end,
		has_pending_work    = function() return false end,
		is_visible = function() return false end,
	}
	package.loaded["modules.keystats"] = {
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
	package.loaded["core.ui.ui.tooltip"] = {
		set_runtime_guard = function() end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_on_show_callback = function() end,
		set_timeout = function() end,
		set_colorization_enabled = function() end,
		set_accent_color = function() end,
		tint = function() return {} end,
		glyph = function() return nil, nil end,
		show_stacked = function(rows) effects.rows = rows; effects.visible = true; return true end,
		hide = function() effects.visible = false; return true end,
		hide_forced = function() effects.visible = false; return true end,
		hide_forced_silent = function() effects.visible = false; return true end,
		is_visible = function() return effects.visible == true end,
		is_hotstring_visible = function() return effects.visible == true end,
		has_visible_hotstring_lease = function(token)
			if not effects.visible then return false end
			for _, row in ipairs(effects.rows or {}) do
				if row.lease_token == token then return true end
			end
			return false
		end,
	}
	package.loaded["hotstrings.engine.catalogue.config"] = { resolve = function() return nil end }
	package.loaded["core.ui.adapters.tooltip_renderer"] = { hide = function() return true end }
end

--- Finds the real key-down tap installed by modules.keymap.
--- @param hs_stub table Hammerspoon stub.
--- @return table|nil
local function find_keydown_tap(hs_stub)
	for _, tap in ipairs(hs_stub.eventtap.__taps) do
		if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then return tap end
	end
	return nil
end

--- Builds one physical character event.
--- @param character string Event text.
--- @param flags table|nil Modifier state.
--- @param keycode number|nil Quartz keycode.
--- @return table
local function physical_key(character, flags, keycode)
	return {
		getProperty = function() return 0 end,
		getFlags = function()
			return flags or { cmd = false, ctrl = false, alt = false, shift = false }
		end,
		getKeyCode = function() return keycode or KEYCODE_LETTER end,
		getCharacters = function() return character end,
	}
end

--- Holds the unrelated AX boundary in its already-classified normal state.
--- @return function restore
local function force_normal_window()
	local Utils = package.loaded["hotstrings.engine.expander.utils"]
	helpers.assert_not_nil(Utils, "the real keymap must load its window-classification module")
	local original_ignored = Utils.is_ignored_window
	local original_secure = Utils.is_secure_field
	Utils.is_ignored_window = function() return false, 0 end
	Utils.is_secure_field = function() return false, 0 end
	return function()
		Utils.is_ignored_window = original_ignored
		Utils.is_secure_field = original_secure
	end
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





-- ==================================
-- ==================================
-- ======= 1/ The corpus ============
-- ==================================
-- ==================================

helpers.describe("expired winner: the shared corpus (hcd-1-expired-winner)", function()
	for _, vector in ipairs(read_vectors()) do
		helpers.it(vector.id .. " (hcd-1-expired-winner)", function()
			local effects = { emitted = {}, visible = false }
			install_collaborators(effects)
			local StateM = require("hotstrings.engine.expander.state")
			local original_new = StateM.new
			local core_state
			StateM.new = function(...)
				core_state = original_new(...)
				return core_state
			end
			local Keymap = helpers.load_with_stubs("hotstrings.engine.expander")
			StateM.new = original_new
			helpers.assert_not_nil(core_state, "the keymap must build its CoreState")
			local hs_stub = _G.hs
			local restore_normal_window = force_normal_window()
			local now = 100
			hs_stub.timer.secondsSinceEpoch = function() return now end
			hs_stub.timer.absoluteTime = function() return math.floor(now * 1e9) end

			local delays = {}
			for _, m in ipairs(vector.mappings) do
				delays[m.trigger] = m.delay_s
				Keymap.add(m.trigger, m.replacement, {
					auto_expand = m.auto_expand == true,
					is_case_sensitive = true,
					is_case_sensitive_strict = true,
				})
			end
			Keymap.sort_mappings()
			Keymap.set_repeat_feature_enabled(false)
			-- The vector's own gap before each key decides the verdict: the shared
			-- delay policy has its own corpus (time_gate_vectors.json); this one
			-- pins which mapping the keymap asks, and that nothing lower fires.
			local asked = {}
			local gap = 0
			core_state.mapping_delay_remaining = function(m)
				asked[#asked + 1] = m.trigger
				return gap <= (delays[m.trigger] or 0)
			end

			local tap = find_keydown_tap(hs_stub)
			helpers.assert_not_nil(tap, "the real keymap must install one key-down eventtap")
			local ok, err = xpcall(function()
				local previous = nil
				for _, key in ipairs(vector.typed) do
					gap = previous and (key.down_ms - previous) / 1000 or 0.01
					now = now + gap
					previous = key.down_ms
					tap.fn(physical_key(key.char, nil, KEYCODE_LETTER))
				end
				local fired = vector.expected.fires
				local want = nil
				for _, m in ipairs(vector.mappings) do
					if m.trigger == fired then want = m.replacement end
				end
				-- An end character is replayed after the replacement.
				helpers.assert_eq(want and 1 or 0, #effects.emitted, "how many expansions fire")
				if want then
					helpers.assert_eq(want, effects.emitted[1]:sub(1, #want), "what fires")
				end
				helpers.assert_eq(vector.expected.winner, asked[#asked],
					"the delay is asked of the winner")
			end, debug.traceback)
			Keymap.set_repeat_feature_enabled(false)
			restore_normal_window()
			if not ok then error(err, 0) end
		end)
	end
end)
