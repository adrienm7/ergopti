--- tests/unit/lib/test_ui_restore_fixture_scope.lua

--- ==============================================================================
--- MODULE: UI Restore Fixture Scope Tests
--- DESCRIPTION:
--- Checks exact predecessor restoration and independence from foreign open windows.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui_restore_fixture")
local OWNERS = {
	"adapters.storage", "adapters.timer_scheduler", "infra.logger", "infra.timings",
	"infra.ui_restore", "ui.hotstring_editor", "ui.metrics_typing", "ui.metrics_typing.init",
	"ui.metrics_apps", "ui.metrics_apps.init",
}

helpers.describe("UI restore fixture lifetime (ui-restore-fixture-scope)", function()
	for _, kind in ipairs({ "absent", "false", "open window" }) do
		for _, outcome in ipairs({ "success", "callback failure", "construction failure", "cleanup throw", "cleanup refusal" }) do
			helpers.it("restores " .. kind .. " predecessors after " .. outcome, function()
				helpers.with_fresh_modules(OWNERS, function()
					local predecessor
					if kind == "false" then predecessor = false end
					if kind == "open window" then predecessor = { _wv = {} } end
					for _, name in ipairs(OWNERS) do package.loaded[name] = predecessor end
					local host = hs
					local original_require = require
					local constructed, reached = false, false
					if outcome == "construction failure" then
						_G.require = function(name)
							local module = original_require(name)
							if name == "infra.ui_restore" then
								constructed = true
								error("UI restore construction marker")
							end
							return module
						end
					end
					local ok, detail, middle, last = pcall(Fixture.with_fixture, {}, function(subject, _, window)
						reached = true
						window.open = false
						local reloads = 0
						subject.defer_reload(function() reloads = reloads + 1 end)
						helpers.assert_eq(reloads, 1, "foreign cached windows must not defer this scenario")
						if outcome == "callback failure" then error("UI restore callback marker") end
						if outcome == "cleanup throw" then
							subject.stop = function() error("UI restore cleanup marker") end
						elseif outcome == "cleanup refusal" then
							subject.stop = function() return false end
						end
						return "result", nil, false
					end)
					_G.require = original_require
					local restored = hs == host
					_G.hs = host
					helpers.assert_eq(ok, outcome == "success")
					helpers.assert_eq(reached, outcome ~= "construction failure")
					if outcome == "construction failure" then
						helpers.assert_true(constructed)
						helpers.assert_contains(detail, "UI restore construction marker")
					elseif outcome == "callback failure" then
						helpers.assert_contains(detail, "UI restore callback marker")
					elseif outcome == "cleanup throw" then
						helpers.assert_contains(detail, "UI restore cleanup marker")
					elseif outcome == "cleanup refusal" then
						helpers.assert_contains(detail, "UI restore fixture cleanup did not settle")
					else
						helpers.assert_eq(detail, "result")
						helpers.assert_nil(middle)
						helpers.assert_eq(last, false)
					end
					helpers.assert_true(restored, "every fixture exit must restore the native environment")
					for _, name in ipairs(OWNERS) do
						helpers.assert_eq(package.loaded[name], predecessor, name)
					end
				end)
			end)
		end
	end
end)
