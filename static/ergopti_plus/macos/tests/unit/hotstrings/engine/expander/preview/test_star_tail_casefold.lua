--- tests/unit/hotstrings/engine/expander/preview/test_star_tail_casefold.lua

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
	package.loaded["ai.engine"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		check_modifiers = function() return false end,
	}
	package.loaded["ai.engine.prediction.engine"] = {
		init = function() return true end,
		set_runtime_guard = function() end,
		get_llm_enabled = function() return false end,
		reset = function() return true end,
	}
	package.loaded["metrics.engine"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		log_llm_accepted = function() end,
		notify_synthetic = function() end,
		set_buffer = function() end,
		log_hotstring = function() end,
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
	package.loaded["hotstrings.engine.catalogue.config"] = {
		resolve = function() return nil end,
	}
	package.loaded["core.ui.adapters.tooltip_renderer"] = {
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
			name:match("^hotstrings%.engine%.expander") or name:match("^adapters%.")
		) then
			package.loaded[name] = nil
		end
	end
	install_collaborators(effects)
	local Bridge = helpers.load_with_stubs("ai.engine.bridge")
	local State = require("hotstrings.engine.expander.state")
	local Registry = assert(package.loaded["settings.engine.registry"])
	local Expander = assert(package.loaded["hotstrings.engine.expander.expander"])
	local state = State.new({ trigger_char = magic_key or STAR, expansion_delay = 0.4 }, {})
	state.preview_providers = {}
	state.is_repeat_feature_enabled = function() return false end
	Registry.init(state)
	require("ai.engine.api.context").seed(state, state.buffer or "", "")
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

	helpers.it("(hse-004-magic-key-case) a letter magic key follows the word's case, as on Windows", function()
		local effects = {}
		local state, Registry, Bridge, Expander = fresh_runtime(effects, "a")
		Registry.add("btw" .. STAR, "expanded", { auto_expand = true })
		Registry.sort_mappings()

		local upper, mixed
		for _, candidate in ipairs(Registry.mappings_for_tail("A")) do
			if candidate.trigger == "BTWA" then upper = candidate end
		end
		for _, candidate in ipairs(Registry.mappings_for_tail("a")) do
			if candidate.trigger == "BTWa" then mixed = candidate end
		end
		helpers.assert_not_nil(upper, "the UPPER variant carries the uppercased magic key")
		helpers.assert_nil(mixed, "BTWa is no trigger: Windows conforms against BTWA")
		helpers.assert_true(upper.has_magic, "the variant keeps its canonical-magic provenance")

		state.buffer = "BTWA"
		helpers.assert_eq(Expander.would_fire(upper, state.buffer), "EXPANDED")
		local resolution = Expander.resolve_magic_action("BTW", nil, "A")
		helpers.assert_not_nil(resolution, "the Shift+magic press reaches the uppercase mapping")
		helpers.assert_eq(resolution.winner.mapping, upper)
		helpers.assert_nil(Expander.resolve_magic_action("BTW", nil, "a"), "a lowercase magic press after BTW fires nothing")
		helpers.assert_eq(Expander.cased_magic("a"), "A")
		helpers.assert_nil(Expander.cased_magic(STAR), "a magic key with no case has no cased form")
		local _ = Bridge
	end)

	-- The literal-tail path took `buffer .. magic` when no star mapping shared
	-- the tail, so the uppercase press missed OLDA there and only there.
	helpers.it("(hse-004-literal-tail-case) a literal tail mapping sees the magic key as typed", function()
		local effects = {}
		local _, Registry, _, Expander = fresh_runtime(effects, "a")
		Registry.add("olda", "promised", { auto_expand = true })
		Registry.sort_mappings()
		local mapping = (Registry.mappings_for_literal_magic_tail("d") or {})[1]
		helpers.assert_not_nil(mapping, "olda ends on the literal magic key")
		local resolution = Expander.resolve_magic_action("OLD", nil, "A")
		helpers.assert_not_nil(resolution, "Shift+magic after OLD reaches the literal mapping")
		helpers.assert_eq(resolution.winner.mapping, mapping)
		-- The ordinary path reads OLDA, typed: the uppercase word's expansion.
		helpers.assert_eq(resolution.winner.eff_repl, "PROMISED")
	end)
end)
