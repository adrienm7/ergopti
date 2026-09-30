--- tests/unit/modules/keymap/test_no_repeat_preview.lua

--- ==============================================================================
--- MODULE: Regression — the bubble never offers a key doubling (no-repeat-preview)
--- DESCRIPTION:
--- Maintainer report on Windows: the preview bubble kept proposing the magic
--- key's doubling ("ef" offered "ff"). The repeat fallback can double almost any
--- letter that is not the first of its word, so such a row would sit on nearly
--- every keystroke. The rule is the same on every driver: never preview a
--- doubling, keep firing it, keep every other row.
---
--- WHY THIS DRIVER ALREADY HOLDS, AND WHAT THIS GUARDS:
--- update_preview reads only the registry through Expander.resolve_magic_action,
--- while the doubling is try_repeat_feature, an engine fallback outside that
--- registry. Windows drifted precisely by folding its fallbacks into the preview
--- oracle. This drives the real eventtap so that design cannot arrive here
--- silently: a doubling-eligible buffer must paint no row while the magic key
--- still doubles, and a text_expansion_symbols mapping must still be offered.
--- ==============================================================================

local helpers = require("tests.helpers")

local STAR = utf8.char(0x2605)
local CHECK_MARK = utf8.char(0x2713)
local KEYCODE_LETTER = 0





-- ====================================
-- ====================================
-- ======= 1/ The Real Eventtap =======
-- ====================================
-- ====================================

--- Installs the external collaborators needed to drive the real keymap tap.
--- @param effects table Mutable output/tooltip capture.
local function install_collaborators(effects)
	-- Other test files initialise the registry/bridge against their own state
	-- objects, so reusing those cached singletons makes this repro depend on
	-- discovery order.
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
		notify_synthetic = function(text, _source, _deletes, variant)
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
		show_stacked = function(rows) effects.rows = rows; effects.visible = true; return true end,
		hide = function() effects.visible = false; return true end,
		hide_forced = function() effects.visible = false; return true end,
		hide_forced_silent = function() effects.visible = false; return true end,
		is_visible = function() return effects.visible == true end,
		is_hotstring_visible = function() return effects.visible == true end,
		has_visible_hotstring_lease = function() return false end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = { resolve = function() return nil end }
	package.loaded["adapters.tooltip_renderer"] = { hide = function() return true end }
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
--- @return table
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





-- ==============================================
-- ==============================================
-- ======= 2/ A Doubling Is Never Offered =======
-- ==============================================
-- ==============================================

helpers.describe("the bubble never proposes a key doubling (no-repeat-preview)", function()
	helpers.it("paints no doubling row, still doubles on the magic key, still offers a symbol", function()
		local effects = { visible = false }
		install_collaborators(effects)
		local Keymap = helpers.load_with_stubs("modules.keymap")
		local hs_stub = _G.hs
		local restore_normal_window = force_normal_window()
		local now = 100
		hs_stub.timer.secondsSinceEpoch = function() return now end

		-- magickey.toml [[text_expansion_symbols]]: "(v)★" = "✓", is_word,
		-- auto_expand and strict case, as the bundled loader registers it.
		Keymap.add("(v)" .. STAR, CHECK_MARK, {
			auto_expand = true,
			is_word = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.sort_mappings()
		Keymap.set_preview_star_enabled(true)
		Keymap.set_preview_autocorrect_enabled(true)
		Keymap.set_repeat_feature_enabled(true)

		local tap = find_keydown_tap(hs_stub)
		helpers.assert_not_nil(tap, "the real keymap must install one key-down eventtap")
		local function press(character)
			now = now + 0.01
			local consumed = tap.fn(physical_key(character))
			drain_immediate_timers(hs_stub)
			return consumed
		end

		local ok, err = xpcall(function()
			press("e")
			press("f")
			helpers.assert_true(effects.rows == nil or #effects.rows == 0,
				"the bubble must never propose a key doubling: one is available after almost "
					.. "every letter, so its row would sit on nearly every keystroke")

			press(STAR)
			helpers.assert_eq(effects.repeated, "f",
				"withholding the promise must not withdraw the expansion: the magic key must "
					.. "still double the letter")

			-- A space ends the word, so "(v)" starts a new one: "(v)★" is is_word.
			press(" ")
			effects.rows = nil
			for _, character in ipairs({ "(", "v", ")" }) do press(character) end
			helpers.assert_true(type(effects.rows) == "table" and #effects.rows == 1,
				"an ordinary magic-key expansion must still be offered: only doublings are withheld")
			helpers.assert_eq(effects.rows[1].text, CHECK_MARK,
				"the row must show the symbol the magic key will type")
		end, debug.traceback)
		restore_normal_window()
		if not ok then error(err, 0) end
	end)
end)
