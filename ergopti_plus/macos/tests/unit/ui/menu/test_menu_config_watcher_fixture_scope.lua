--- tests/unit/ui/menu/test_menu_config_watcher_fixture_scope.lua

--- ==============================================================================
--- MODULE: Menu Config Watcher Fixture Scope Tests
--- DESCRIPTION:
--- Exercises exact predecessor restoration across construction and callback exits.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.menu_config_watcher_fixture")
local OWNERS = {
	"ui.menu.menu_watchers", "infra.logger", "infra.git_status", "reload_gate",
}

helpers.describe("Menu config watcher fixture lifetime", function()
	for _, kind in ipairs({ "absent", "false", "table" }) do
		for _, outcome in ipairs({ "success", "callback failure", "construction failure" }) do
			helpers.it("restores " .. kind .. " predecessors after " .. outcome, function()
				helpers.with_fresh_modules(OWNERS, function()
					local predecessor
					if kind == "false" then predecessor = false end
					if kind == "table" then predecessor = {} end
					for _, name in ipairs(OWNERS) do package.loaded[name] = predecessor end
					local host = hs
					local pathwatcher, timer = host.pathwatcher, host.timer
					local attributes, reload = host.fs.attributes, host.reload
					local roots = rawget(_G, "script_watchers")
					local sentinel_roots = {}
					_G.script_watchers = sentinel_roots
					local original_require = require
					local constructed, reached = false, false
					if outcome == "construction failure" then
						_G.require = function(name)
							local module = original_require(name)
							if name == "ui.menu.menu_watchers" then
								module.start_config_watcher = function()
									constructed = true
									error("menu watcher construction marker")
								end
							end
							return module
						end
					end
					local ok, detail, middle, last = pcall(Fixture.with_watcher, function(w)
						w.fire({ "/fake/base/source.lua" })
						local scheduled_count = w.armed_count()
						w.set_clock(1001)
						w.poll()
						helpers.assert_eq(w.reloads(), 1)
						helpers.assert_eq(w.armed_count(), scheduled_count,
							"an accepted reload must not leave retry debt")
						reached = true
						if outcome == "callback failure" then error("menu watcher callback marker") end
						return "result", nil, false
					end)
					_G.require = original_require
					local restored_native = hs == host and host.pathwatcher == pathwatcher
						and host.timer == timer and host.fs.attributes == attributes and host.reload == reload
					host.pathwatcher, host.timer = pathwatcher, timer
					host.fs.attributes, host.reload = attributes, reload
					_G.hs = host
					local restored_roots = rawget(_G, "script_watchers")
					_G.script_watchers = roots
					helpers.assert_eq(ok, outcome == "success")
					helpers.assert_eq(reached, outcome ~= "construction failure")
					if outcome == "construction failure" then
						helpers.assert_true(constructed)
						helpers.assert_contains(detail, "menu watcher construction marker")
					elseif outcome == "callback failure" then
						helpers.assert_contains(detail, "menu watcher callback marker")
					else
						helpers.assert_eq(detail, "result")
						helpers.assert_nil(middle)
						helpers.assert_eq(last, false)
					end
					helpers.assert_true(restored_roots == sentinel_roots)
					helpers.assert_true(restored_native)
					for _, name in ipairs(OWNERS) do
						helpers.assert_eq(package.loaded[name], predecessor, name)
					end
				end)
			end)
		end
	end
end)
