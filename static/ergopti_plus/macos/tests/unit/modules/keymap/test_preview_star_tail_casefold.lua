--- tests/unit/modules/keymap/test_preview_star_tail_casefold.lua

--- ==============================================================================
--- MODULE: Regression — star-tail preview uses registry case-fold semantics
--- DESCRIPTION:
--- Builds a real fold-mode star mapping, asks the real expander what the typed
--- uppercase buffer would emit, then renders the real bridge preview for that
--- same buffer. The preview tail index must use the registry match mode instead
--- of requiring the raw trigger casing.
--- ==============================================================================

local helpers = require("tests.helpers")

local STAR = utf8.char(0x2605)
local REPLACEMENT = "EXP"


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
--- @param magic_key string|nil Runtime magic key.
--- @return table state, table registry, table bridge, table expander, table hs_stub
local function fresh_runtime(effects, magic_key)
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
	local state = State.new({ trigger_char = magic_key or STAR, expansion_delay = 0.4 }, {})
	state.preview_providers = {}
	state.is_repeat_feature_enabled = function() return false end
	Registry.init(state)
	Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
	Expander.init(state, Registry, Bridge)
	Bridge.set_preview_star_enabled(true)
	Bridge.set_preview_autocorrect_enabled(true)
	return state, Registry, Bridge, Expander, _G.hs
end





-- ========================================
-- ========================================
-- ======= 1/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("case-folded star-tail preview", function()
	helpers.it("G5 case-folded star preview reaches the engine mapping", function()
		local effects = {}
		local state, Registry, Bridge, Expander, hs_stub = fresh_runtime(effects)
		Registry.add("abc" .. STAR, REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
		})
		Registry.sort_mappings()

		local bucket = Registry.mappings_for_tail(STAR)
		helpers.assert_eq(#bucket, 1, "the real star-tail index must contain the fixture mapping")
		local mapping = bucket[1]
		helpers.assert_eq(mapping.match_mode, "fold",
			"omitting strict case sensitivity must create the reachable fold-mode mapping")

		state.buffer = "ABC" .. STAR
		local engine_output = Expander.would_fire(mapping, state.buffer)
		helpers.assert_eq(engine_output, REPLACEMENT,
			"the real expander must accept the uppercase spelling under fold semantics")

		effects.rows = nil
		Bridge.update_preview("ABC")
		hs_stub.timer.__fire_all()
		helpers.assert_true(type(effects.rows) == "table" and #effects.rows > 0,
			"the preview tail lookup must find the same fold-mode mapping as the engine")
		helpers.assert_eq(effects.rows[1].text, engine_output,
			"the preview replacement must equal the real engine output")
	end)

	helpers.it("preserves an alphabetic magic suffix while casing only the trigger body", function()
		local effects = {}
		local state, Registry, Bridge, Expander, hs_stub = fresh_runtime(effects, "a")
		Registry.add("btw" .. STAR, "expanded", { auto_expand = true })
		Registry.sort_mappings()

		local mapping
		for _, candidate in ipairs(Registry.mappings_for_tail("a")) do
			if candidate.trigger == "BTWa" then mapping = candidate; break end
		end
		helpers.assert_not_nil(mapping,
			"uppercase registration must keep the configured lowercase magic action")
		helpers.assert_true(mapping.has_magic,
			"the reachable variant must retain canonical-magic provenance")

		state.buffer = "BTWa"
		local engine_output = Expander.would_fire(mapping, state.buffer)
		helpers.assert_eq(engine_output, "EXPANDED")
		local resolution = Expander.resolve_magic_action("BTW")
		helpers.assert_not_nil(resolution,
			"the prospective resolver must reach the same body-cased mapping")
		helpers.assert_eq(resolution.winner.mapping, mapping)

		effects.rows = nil
		Bridge.update_preview("BTW")
		hs_stub.timer.__fire_all()
		helpers.assert_true(type(effects.rows) == "table" and #effects.rows > 0,
			"the preview must find the same body-cased mapping before the magic press")
		helpers.assert_eq(effects.rows[1].text, engine_output)
		helpers.assert_eq(effects.rows[1].trigger_label, "a")
	end)
end)
