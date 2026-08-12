--- tests/unit/modules/keymap/test_preview_respects_terminator_state.lua

--- ==============================================================================
--- MODULE: Regression — end-character preview respects enabled terminators
--- DESCRIPTION:
--- Uses the real terminator catalogue, registry, bridge, and expander. It toggles
--- Enter and the magic terminator in opposite directions so a preview resolver
--- that accidentally consults Enter cannot agree by coincidence. The row must
--- describe and execute the same magic-key action in both runtime states.
--- ==============================================================================

local helpers = require("tests.helpers")

local STAR = utf8.char(0x2605)
local ENTER_CHAR = string.char(13)
local REPLACEMENT = "EXP"
local ONE_CODEPOINT = 1


--- Installs narrow collaborators and captures committed tooltip rows.
--- @param effects table Mutable capture table.
local function install_collaborators(effects)
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		check_modifiers = function() return false end,
	}
	package.loaded["modules.llm.prediction_engine"] = {
		init = function() end,
		set_runtime_guard = function() end,
		get_llm_enabled = function() return false end,
		reset = function() return true end,
	}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		log_llm_accepted = function() end,
		notify_synthetic = function() end,
		set_buffer = function() end,
		log_hotstring = function() end,
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


--- Loads and initializes the real registry, bridge, and expander.
--- @param effects table Mutable capture table.
--- @return table state, table registry, table bridge, table expander, table hs_stub
local function fresh_runtime(effects)
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap") or name:match("^adapters%.")
		) then
			package.loaded[name] = nil
		end
	end
	install_collaborators(effects)
	local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
	local State = require("modules.keymap.state")
	local Registry = assert(package.loaded["modules.keymap.registry"])
	local Expander = assert(package.loaded["modules.keymap.expander"])
	local state = State.new({ trigger_char = STAR, expansion_delay = 0.4 }, {})
	state.preview_providers = {}
	state.is_repeat_feature_enabled = function() return false end
	Registry.init(state)
	Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
	Expander.init(state, Registry, Bridge)
	Bridge.set_preview_star_enabled(true)
	Bridge.set_preview_autocorrect_enabled(true)
	return state, Registry, Bridge, Expander, _G.hs
end


--- Renders one preview buffer through the bridge timer boundary.
--- @param effects table Mutable capture table.
--- @param bridge table Real LLM bridge.
--- @param hs_stub table Active Hammerspoon stub.
--- @param buffer string Buffer to preview.
--- @return table rows
local function render_preview(effects, bridge, hs_stub, buffer)
	effects.rows = nil
	bridge.update_preview(buffer)
	hs_stub.timer.__fire_all()
	return effects.rows or {}
end





-- ========================================
-- ========================================
-- ======= 1/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("preview terminator runtime state", function()
	helpers.it("G5 preview and engine consult and label the same magic action", function()
		local effects = {}
		local state, Registry, Bridge, Expander, hs_stub = fresh_runtime(effects)
		Registry.add("abc", REPLACEMENT, {
			auto_expand = false,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Registry.sort_mappings()
		local mapping = state.mappings[1]
		helpers.assert_not_nil(mapping, "the real registry must retain the end-character fixture")

		local enabled_rows = render_preview(effects, Bridge, hs_stub, "abc")
		helpers.assert_true(#enabled_rows > 0 and enabled_rows[1].text == REPLACEMENT,
			"the control state must prove that the real preview path rendered the fixture")

		local original_star = Registry.is_terminator_enabled("star")
		local original_enter = Registry.is_terminator_enabled("enter")
		local disabled_fired, disabled_rows, enabled_fired, enabled_rows_inverse
		local ok, err = xpcall(function()
			Registry.set_terminator_enabled("enter", true)
			Registry.set_terminator_enabled("star", false)
			helpers.assert_eq(Registry.is_terminator(ENTER_CHAR), true,
				"Enter must stay enabled so an Enter-based mutant cannot pass by coincidence")
			helpers.assert_eq(Registry.is_terminator(STAR), false,
				"the exact action being previewed must be disabled")

			state.buffer = "abc" .. STAR
			disabled_fired = Expander.try_terminator_expand(mapping, STAR, ONE_CODEPOINT, false)
			disabled_rows = render_preview(effects, Bridge, hs_stub, "abc")

			Registry.set_terminator_enabled("enter", false)
			Registry.set_terminator_enabled("star", true)
			helpers.assert_eq(Registry.is_terminator(ENTER_CHAR), false,
				"the row label must not rely on an unavailable Enter action")
			helpers.assert_eq(Registry.is_terminator(STAR), true,
				"the exact magic action must be reachable in the inverse state")
			enabled_rows_inverse = render_preview(effects, Bridge, hs_stub, "abc")
			state.buffer = "abc" .. STAR
			enabled_fired = Expander.try_terminator_expand(mapping, STAR, ONE_CODEPOINT, false)
		end, debug.traceback)

		-- The shared terminator catalogue is process-global. Restore it even when a
		-- regression assertion raises, or every later test observes this fixture's
		-- disabled state and the suite becomes order-dependent.
		Registry.set_terminator_enabled("star", original_star)
		Registry.set_terminator_enabled("enter", original_enter)
		helpers.assert_eq(Registry.is_terminator_enabled("star"), original_star,
			"the fixture must restore the shared star state")
		helpers.assert_eq(Registry.is_terminator_enabled("enter"), original_enter,
			"the fixture must restore the shared Enter state")
		if not ok then error(err, 0) end

		helpers.assert_eq(disabled_fired, false,
			"the real engine must reject the disabled magic action")
		helpers.assert_eq(#disabled_rows, 0,
			"the tooltip must not promise a magic action merely because Enter remains enabled")
		helpers.assert_eq(enabled_fired, true,
			"the same magic action must fire when only the magic terminator is enabled")
		helpers.assert_true(#enabled_rows_inverse > 0,
			"the tooltip must render the action that the engine accepts")
		helpers.assert_eq(enabled_rows_inverse[1].trigger_label, STAR,
			"the tooltip must name the enabled magic key, not disabled Enter")
	end)
end)
