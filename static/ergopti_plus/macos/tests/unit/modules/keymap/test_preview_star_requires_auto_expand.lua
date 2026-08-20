--- tests/unit/modules/keymap/test_preview_star_requires_auto_expand.lua

--- ==============================================================================
--- MODULE: Regression — star preview requires an auto-expand engine action
--- DESCRIPTION:
--- Uses the real registry, bridge, and expander with one valid auto-expand
--- control mapping and one non-auto star mapping. The latter is present in the
--- star index but cannot fire when the magic key is pressed, so it must never be
--- presented as an actionable star preview.
--- ==============================================================================

local helpers = require("tests.helpers")

local STAR = utf8.char(0x2605)
local AUTO_REPLACEMENT = "AUTO"
local NONAUTO_REPLACEMENT = "NONAUTO"
local NOOP_TRIGGER = "same"
local END_NOOP_TRIGGER = "finish"
local BARE_REPLACEMENT = "BARE"
local ONE_CODEPOINT = 1


--- Installs narrow collaborators and captures committed tooltip rows.
--- @param effects table Mutable capture table.
local function install_collaborators(effects)
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		check_modifiers = function() return false end,
	}
	package.loaded["modules.llm.prediction_engine"] = {
		init = function() return true end,
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

helpers.describe("star preview auto-expand gate", function()
	helpers.it("G5 star preview requires an auto-expand action", function()
		local effects = {}
		local state, Registry, Bridge, Expander, hs_stub = fresh_runtime(effects)
		Registry.add("ok" .. STAR, AUTO_REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Registry.add("pub" .. STAR, NONAUTO_REPLACEMENT, {
			auto_expand = false,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Registry.add(NOOP_TRIGGER .. STAR, NOOP_TRIGGER .. STAR, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
			final_result = true,
		})
		Registry.add(END_NOOP_TRIGGER, END_NOOP_TRIGGER, {
			auto_expand = false,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
			final_result = true,
		})
		Registry.sort_mappings()

		local control_rows = render_preview(effects, Bridge, hs_stub, "ok")
		helpers.assert_true(#control_rows > 0 and control_rows[1].text == AUTO_REPLACEMENT,
			"the control mapping must prove that the real star preview path rendered")

		local nonauto_mapping = nil
		for _, mapping in ipairs(state.mappings) do
			if mapping.trigger == "pub" .. STAR then
				nonauto_mapping = mapping
				break
			end
		end
		helpers.assert_not_nil(nonauto_mapping,
			"the real registry must retain the non-auto star fixture")
		helpers.assert_eq(nonauto_mapping.auto, false,
			"the repro requires a star mapping explicitly gated out of auto expansion")

		state.buffer = "pub" .. STAR
		local fired = Expander.try_auto_expand(nonauto_mapping, ONE_CODEPOINT, false)
		helpers.assert_eq(fired, false,
			"the real engine must reject a non-auto star mapping on magic-key input")

		local rows = render_preview(effects, Bridge, hs_stub, "pub")
		helpers.assert_eq(#rows, 0,
			"the tooltip must not advertise a star mapping that the engine cannot fire")

		state.no_rescan_until = hs_stub.timer.secondsSinceEpoch() + 10
		local blocked_rows = render_preview(effects, Bridge, hs_stub, "ok")
		helpers.assert_eq(#blocked_rows, 0,
			"the preview must offer no static action while the engine is rescan-suppressed")
		state.no_rescan_until = 0

		-- A no-op action is also not displayable, but the engine must still attempt
		-- it: try_auto_expand owns suppress-rescan and tooltip cleanup side effects
		-- before returning false. Omitting it from `attempts` silently changes the
		-- live engine even though the preview correctly has no row.
		local resolution = Expander.resolve_magic_action(NOOP_TRIGGER)
		helpers.assert_not_nil(resolution,
			"the shared resolver must retain a reachable no-op action")
		helpers.assert_eq(#resolution.candidates, 0,
			"a no-op action must never become a tooltip candidate")
		helpers.assert_eq(resolution.winner, nil,
			"a no-op action must never become the advertised winner")
		helpers.assert_eq(#resolution.attempts, 1,
			"the engine attempt ledger must retain the no-op cleanup action")
		helpers.assert_eq(resolution.attempts[1].is_noop, true,
			"the retained attempt must carry the no-op decision from would_fire")

		local end_resolution = Expander.resolve_magic_action(END_NOOP_TRIGGER)
		helpers.assert_not_nil(end_resolution,
			"the shared resolver must retain a reachable terminator no-op action")
		helpers.assert_eq(#end_resolution.candidates, 0,
			"a terminator no-op must never become a tooltip candidate")
		helpers.assert_eq(end_resolution.winner, nil,
			"a terminator no-op must never become the advertised winner")
		helpers.assert_eq(#end_resolution.attempts, 1,
			"the engine attempt ledger must retain terminator no-op cleanup")
		helpers.assert_eq(end_resolution.attempts[1].kind, "autocorrect",
			"the retained no-op must preserve its terminator dispatch path")
		helpers.assert_eq(end_resolution.attempts[1].is_noop, true,
			"the terminator attempt must carry the no-op decision from would_fire")

		Registry.add(STAR, BARE_REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Registry.sort_mappings()
		local bare_resolution = Expander.resolve_magic_action("")
		helpers.assert_not_nil(bare_resolution and bare_resolution.winner,
			"a bare magic-key mapping must remain a reachable engine action")
		helpers.assert_eq(bare_resolution.winner.eff_plain, BARE_REPLACEMENT,
			"the bare mapping must preserve its replacement through arbitration")
		local bare_rows = render_preview(effects, Bridge, hs_stub, "")
		helpers.assert_eq(#bare_rows, 1,
			"the empty-buffer preview must expose the bare action the engine will fire")
		helpers.assert_eq(bare_rows[1].text, BARE_REPLACEMENT,
			"the bare preview row must equal the resolver-owned engine output")
	end)
end)
