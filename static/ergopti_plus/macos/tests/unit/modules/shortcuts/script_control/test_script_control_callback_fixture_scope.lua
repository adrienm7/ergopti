--- tests/unit/modules/shortcuts/script_control/test_script_control_callback_fixture_scope.lua

--- ==============================================================================
--- MODULE: Script Control Callback Fixture Isolation Tests
--- DESCRIPTION:
--- Preserves absent, false and loaded module identities across fixture success
--- and failures, including the exact native host replaced by the test loader.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.script_control_callback_fixture")

local OWNERS = {
	"core.logger.engine.logger", "core.ui.engine.notifications", "platform.input.keycodes", "core.i18n.engine.i18n", "core.fs.engine.paths",
	"gestures.engine.engine", "gestures.engine.actions", "metrics.engine",
	"diagnostics.adapters.event_provenance", "platform.input.synthetic_input", "core.events.timer_scheduler",
	"platform.input.key_state", "modules.shortcuts.script_control", "core.fs.adapters.file_system",
	"platform.input.hotkey_registrar", "core.fs.adapters.storage", "modules.shortcuts.keyboard_shortcuts", "keyboard.engine.chord",
	"settings.engine.paths", "settings.engine.preferences.preferences",
}

helpers.describe("Script control callback fixture isolation", function()
	for _, kind in ipairs({ "sentinel", "configurable" }) do
		for _, failure in ipairs({ "none", "construction", "callback" }) do
			helpers.it("(shortcut-fixture-scope) restores " .. kind .. " after " .. failure, function()
				helpers.with_stub_scope(OWNERS, function()
					helpers.load_with_stubs("hs")
					local prior_hs = _G.hs
					local identity_name = kind == "sentinel" and "platform.input.keycodes" or "core.fs.adapters.storage"
					local prior_identity = {}
					package.loaded[identity_name] = prior_identity
					package.loaded["core.logger.engine.logger"] = false
					package.loaded["gestures.engine.actions"] = nil
					local subject_name = kind == "sentinel"
						and "modules.shortcuts.script_control" or "modules.shortcuts.keyboard_shortcuts"
					local original_loader = helpers.load_with_stubs
					if failure == "construction" then
						helpers.load_with_stubs = function(name, ...)
							local result = original_loader(name, ...)
							if name == subject_name then error("shortcut construction marker") end
							return result
						end
					end
					local reached = 0
					local ok, result = pcall(Fixture["with_" .. kind], function(fixture)
						reached = reached + 1
						helpers.assert_type(fixture.subject.start, "function")
						if failure == "callback" then error("shortcut callback marker") end
						return "fixture result"
					end)
					helpers.load_with_stubs = original_loader
					if failure == "none" then
						helpers.assert_eq(ok, true, tostring(result))
						helpers.assert_eq(result, "fixture result")
					else
						helpers.assert_eq(ok, false)
						helpers.assert_contains(tostring(result), "shortcut " .. failure .. " marker")
					end
					helpers.assert_eq(reached, failure == "construction" and 0 or 1)
					helpers.assert_nil(package.loaded["gestures.engine.actions"])
					helpers.assert_eq(package.loaded["core.logger.engine.logger"], false)
					helpers.assert_true(package.loaded[identity_name] == prior_identity)
					helpers.assert_true(_G.hs == prior_hs)
				end)
			end)
		end
	end
end)
