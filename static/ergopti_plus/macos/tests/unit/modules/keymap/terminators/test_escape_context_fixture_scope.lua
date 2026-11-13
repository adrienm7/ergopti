--- tests/unit/modules/keymap/terminators/test_escape_context_fixture_scope.lua

--- ==============================================================================
--- MODULE: Escape Context Fixture Isolation Tests
--- DESCRIPTION:
--- Restores the exact replaced eventtap field and module identities even when
--- construction, assertions or cleanup fail, or the callback changes global hs.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.escape_context_fixture")

local OWNERS = {
	"core.logger.engine.logger", "adapters.event_provenance", "platform.input.synthetic_input",
	"core.events.timer_scheduler", "modules.keymap.utils", "core.text.engine.utils",
	"ai.engine", "platform.input.keycodes", "modules.keystats", "core.ui.ui.tooltip",
	"ai.engine.prediction.engine", "settings.engine.registry",
	"modules.hotstrings.hotstrings_config", "modules.keymap.expander",
	"menu.engine.manifest_reader", "ai.engine.bridge",
	"modules.diagnostics.hid_diagnostic_mailbox",
}

helpers.describe("Escape context fixture isolation", function()
	for _, failure in ipairs({ "none", "construction", "callback", "stop", "stop_refusal", "global_replacement" }) do
		helpers.it("(escape-fixture-scope) restores owners after " .. failure, function()
			helpers.with_stub_scope(OWNERS, function()
				helpers.load_with_stubs("hs")
				local prior_hs = _G.hs
				local prior_utils = {}
				package.loaded["modules.keymap.utils"] = prior_utils
				package.loaded["core.logger.engine.logger"] = false
				package.loaded["settings.engine.registry"] = nil
				local native_eventtap, original_new
				local foreign_new = function() end
				local foreign_hs = { eventtap = { new = foreign_new } }
				local reached, stops = 0, 0
				local ok, result = pcall(Fixture.with_fixture, {
					visible = true,
					on_trap_install = function(eventtap, previous)
						native_eventtap, original_new = eventtap, previous
						if failure == "construction" then error("escape construction marker") end
					end,
				}, function(Bridge)
					reached = reached + 1
					local original_stop = Bridge.stop
					Bridge.stop = function()
						stops = stops + 1
						local stopped = original_stop()
						if failure == "stop" then error("escape stop marker") end
						if failure == "stop_refusal" then return false end
						return stopped
					end
					if failure == "callback" then error("escape callback marker") end
					if failure == "global_replacement" then _G.hs = foreign_hs end
					return "escape fixture result"
				end)
				if failure == "none" or failure == "global_replacement" then
					helpers.assert_eq(ok, true, tostring(result))
					helpers.assert_eq(result, "escape fixture result")
				else
					helpers.assert_eq(ok, false)
					local expected = failure == "stop_refusal"
						and "Escape fixture cleanup refused" or "escape " .. failure .. " marker"
					helpers.assert_contains(tostring(result), expected)
				end
				helpers.assert_eq(reached, failure == "construction" and 0 or 1)
				helpers.assert_eq(stops, failure == "construction" and 0 or 1)
				helpers.assert_not_nil(native_eventtap, "the test must reach the native replacement boundary")
				helpers.assert_true(native_eventtap.new == original_new, "restore the captured native eventtap field")
				helpers.assert_true(foreign_hs.eventtap.new == foreign_new, "never mutate a successor native host")
				helpers.assert_nil(package.loaded["settings.engine.registry"])
				helpers.assert_eq(package.loaded["core.logger.engine.logger"], false)
				helpers.assert_true(package.loaded["modules.keymap.utils"] == prior_utils)
				helpers.assert_true(_G.hs == prior_hs)
			end)
		end)
	end
end)
