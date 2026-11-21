--- tests/unit/hotstrings/engine/test_magic_key_display.lua

--- ==============================================================================
--- MODULE: Magic Key Rules (macOS)
--- DESCRIPTION:
--- The magic key is a configured character (maintainer's decision of
--- 2026-11-21). Replays the shared layout-default and display vectors, then the
--- macOS adoption: the input source's base level decides the default, an
--- emulated layout falls back to ★, the display folds an already displayed
--- text instead of doubling it, the menu helper shows « ★ (ù) », and a saved
--- layout default stays implicit.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.hotstrings.magic_key_contract")(helpers, require("core.text.engine.json"), helpers.shared(""))

local MODULES = { "hotstrings.engine.magic_key_display", "modules.keymap.layout_emulation" }

--- Runs a case with an input source typing the given base levels by macOS keycode.
--- @param base table keycode -> text
--- @param emulating boolean Whether an emulated layout types.
--- @param callback function(Rules)
local function with_source(base, emulating, callback)
	helpers.with_stub_scope(MODULES, function()
		local saved = hs.keycodes.map
		hs.keycodes.map = base
		package.loaded["modules.keymap.layout_emulation"] = {
			status = function() return { active = emulating == true } end,
		}
		local Rules = require("hotstrings.engine.magic_key_display")
		Rules._reset_for_test()
		local ok, err = pcall(callback, Rules)
		hs.keycodes.map = saved
		if not ok then error(err, 0) end
	end)
end

-- macOS virtual keycodes of KeyQ, KeyW, KeyA, KeyY.
local AZERTY = { [12] = "a", [13] = "z", [0] = "q", [16] = "y" }
local QWERTY = { [12] = "q", [13] = "w", [0] = "a", [16] = "y" }
local QWERTZ = { [12] = "q", [13] = "w", [0] = "a", [16] = "z" }

helpers.describe("magic key rules on macOS (magic-key-2026-11-21)", function()
	helpers.it("defaults to ù on an AZERTY input source", function()
		with_source(AZERTY, false, function(Rules) helpers.assert_eq(Rules.layout_default(), "ù") end)
	end)

	helpers.it("defaults to ; on a QWERTY input source", function()
		with_source(QWERTY, false, function(Rules) helpers.assert_eq(Rules.layout_default(), ";") end)
	end)

	helpers.it("defaults to ★ on any other input source", function()
		with_source(QWERTZ, false, function(Rules) helpers.assert_eq(Rules.layout_default(), "★") end)
	end)

	helpers.it("defaults to ★ while an emulated layout types over the source", function()
		with_source(AZERTY, true, function(Rules) helpers.assert_eq(Rules.layout_default(), "★") end)
	end)

	helpers.it("shows the marker and the configured character, never doubled", function()
		with_source(AZERTY, false, function(Rules)
			helpers.assert_eq(Rules.display("ù"), "★ (ù)")
			helpers.assert_eq(Rules.display("★"), "★")
			local shown = Rules.display_text("Touche ★ et expansion", "ù")
			helpers.assert_eq(shown, "Touche ★ (ù) et expansion")
			helpers.assert_eq(Rules.display_text(shown, "ù"), shown, "a displayed text is folded, not doubled")
			helpers.assert_eq(Rules.display_text("⇪★ CapsWord", "ù", "sg_actions.caps_word"), "⇪★ CapsWord")
		end)
	end)
end)

helpers.describe("the layout default stays implicit in config.toml (magic-key-2026-11-21)", function()
	--- Saves a preference snapshot through the real preferences owner.
	--- @param trigger string|nil The trigger_char the state holds, nil for its initial value.
	--- @return table state The initial state.
	--- @return table decoded The saved document.
	local function save(trigger)
		local result_state, decoded
		with_source(AZERTY, false, function()
			helpers.with_fresh_modules({ "settings.engine.preferences.preferences", "core.fs.adapters.file_system" }, function()
				local codec = require("core.text.engine.toml_codec")
				local source = "[future]\nkeep = 99\n"
				package.loaded["core.fs.adapters.file_system"] = {
					read_with_status = function() return source, "ok" end,
					write = function() error("publication must retain its source precondition") end,
					write_if_unchanged = function(_, content) source = content; return true end,
				}
				local prefs = helpers.load_with_stubs("settings.engine.preferences.preferences")
				-- Loading installs a fresh hs stub: the input source is AZERTY again.
				hs.keycodes.map = AZERTY
				prefs.load("/magic/config.toml")
				local state = prefs.build_initial_state({}, {}, {})
				result_state = { trigger_char = state.trigger_char }
				if trigger ~= nil then state.trigger_char = trigger end
				helpers.assert_eq(prefs.save("/magic/config.toml", state, {}, {}), true)
				decoded = codec.decode(source)
			end)
		end)
		return result_state, decoded
	end

	helpers.it("starts an empty configuration on the layout's own default", function()
		local state = save(nil)
		helpers.assert_eq(state.trigger_char, "ù")
	end)

	helpers.it("writes no trigger_char while the layout default is in force", function()
		local _, decoded = save(nil)
		helpers.assert_eq(decoded.hotstrings and decoded.hotstrings.trigger_char, nil)
	end)

	helpers.it("writes a character that differs from the layout default, ★ included", function()
		local _, chosen = save(";")
		helpers.assert_eq(chosen.hotstrings.trigger_char, ";")
		local _, star = save("★")
		helpers.assert_eq(star.hotstrings.trigger_char, "★")
	end)
end)
