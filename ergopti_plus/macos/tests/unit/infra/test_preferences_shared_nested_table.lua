--- tests/unit/infra/test_preferences_shared_nested_table.lua

--- ==============================================================================
--- MODULE: A scalar sharing a nested preference table (script-control-enabled)
--- DESCRIPTION:
--- [shortcuts.script_control] holds both the `chords_enabled` scalar and the
--- four key-slot actions. Saving stored the live key-slot table in the section and
--- then wrote `enabled` into it; loading read `enabled` back as a key slot.
--- The menu then called set_shortcut_action("enabled", true), which logged
--- "both keyname and action must be strings" in shortcuts.script_control, and
--- the saved enable flag was never restored.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec")

--- Runs body against a preferences module backed by an in-memory config.toml.
--- @param source string Initial file content.
--- @param body function Receives (prefs, read_source).
local function with_prefs(source, body)
	helpers.with_fresh_modules({ "infra.preferences", "adapters.file_system" }, function()
		package.loaded["adapters.file_system"] = {
			read_with_status = function() return source, "ok" end,
			write = function() error("unguarded publication") end,
			write_if_unchanged = function(_, content)
				source = content
				return true
			end,
		}
		body(helpers.load_with_stubs("infra.preferences"), function() return source end)
	end)
end

helpers.describe("preferences keep a shared nested table apart from its scalar (script-control-enabled)", function()
	helpers.it("loads the enable flag as its own setting, never as a key slot", function()
		local source = '[shortcuts.script_control]\nchords_enabled = false\nscript_altgr_enter = "script_reload"\n'
		with_prefs(source, function(prefs)
			local state, status = prefs.load("/shared/config.toml")
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.script_control_enabled, false)
			helpers.assert_eq(state.script_control_shortcuts.script_altgr_enter, "script_reload")
			helpers.assert_nil(state.script_control_shortcuts.chords_enabled)
		end)
	end)

	helpers.it("saves both without writing the flag into the live key-slot table", function()
		with_prefs("", function(prefs, read_source)
			prefs.load("/shared/config.toml")
			local slots = { script_altgr_enter = "script_reload", script_altgr_backspace = "none",
				script_altgr_escape = "none" }
			local ok = prefs.save("/shared/config.toml",
				{ script_control_enabled = false, script_control_shortcuts = slots }, {}, {})
			helpers.assert_eq(ok, true)
			helpers.assert_nil(slots.chords_enabled, "the saved state table must stay key slots only")
			local decoded = codec.decode(read_source())
			helpers.assert_eq(decoded.shortcuts.script_control.chords_enabled, false)
			helpers.assert_eq(decoded.shortcuts.script_control.script_altgr_enter, "script_reload")
		end)
	end)
end)
