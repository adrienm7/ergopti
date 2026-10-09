--- tests/unit/lib/test_file_watcher_self_write_fixture_scope.lua

--- ==============================================================================
--- MODULE: File Watcher Self-Write Fixture Scope Tests
--- DESCRIPTION:
--- Exercises exact predecessor restoration across construction and callback exits.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.file_watcher_self_write_fixture")
local OWNERS = {
	"infra.file_watchers", "infra.ui_restore", "infra.git_status", "infra.fs_dir",
	"infra.logger", "infra.i18n", "infra.notifications", "reload_gate",
}

helpers.describe("File-watcher self-write fixture lifetime", function()
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
							if name == "infra.file_watchers" then
								module.start = function()
									constructed = true
									error("self-write construction marker")
								end
							end
							return module
						end
					end
					local ok, detail, middle, last = pcall(Fixture.with_watchers, function(w)
						w.fire(Fixture.HOTSTRING_TOML)
						local scheduled_count = w.scheduled_count()
						w.settle()
						helpers.assert_eq(w.reloads(), 1)
						helpers.assert_eq(w.scheduled_count(), scheduled_count,
							"an accepted reload must not leave retry debt")
						reached = true
						if outcome == "callback failure" then error("self-write callback marker") end
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
						helpers.assert_contains(detail, "self-write construction marker")
					elseif outcome == "callback failure" then
						helpers.assert_contains(detail, "self-write callback marker")
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
