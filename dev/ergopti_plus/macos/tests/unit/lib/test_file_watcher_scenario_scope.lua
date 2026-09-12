--- tests/unit/lib/test_file_watcher_scenario_scope.lua

--- ==============================================================================
--- MODULE: File Watcher Scenario Scope Tests
--- DESCRIPTION:
--- Forces assertion failures in real scenarios and checks their native ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local OWNERS = {
	"infra.file_watchers", "infra.ui_restore", "infra.git_status", "infra.fs_dir",
	"infra.logger", "infra.i18n", "infra.notifications", "reload_gate",
}

--- Collects real scenario callbacks without adding nested results to the runner.
--- @param name string Scenario module basename.
--- @return table Registered callbacks.
local function collect(name)
	local describe, it = helpers.describe, helpers.it
	local callbacks = {}
	helpers.describe = function(_, body) body() end
	helpers.it = function(_, body)
		local registered_modules = {}
		for _, name in ipairs(OWNERS) do registered_modules[name] = package.loaded[name] end
		callbacks[#callbacks + 1] = function()
			return helpers.with_fresh_modules(OWNERS, function()
				-- Preserve registration-time dependencies even if the module has a cleanup footer.
				for _, name in ipairs(OWNERS) do package.loaded[name] = registered_modules[name] end
				return body()
			end)
		end
	end
	local ok, detail = xpcall(function()
		assert(loadfile("tests/unit/lib/" .. name .. ".lua"))()
	end, debug.traceback)
	helpers.describe, helpers.it = describe, it
	if not ok then error(detail, 0) end
	return callbacks
end

helpers.describe("File-watcher scenario failure isolation", function()
	for _, case in ipairs({
		{ "test_file_watchers_git_defer", 2 },
		{ "test_file_watchers_adaptive_settle", 1 },
		{ "test_file_watchers_reload_gate_coverage", 5 },
	}) do
		helpers.it("restores native state after every assertion failure in " .. case[1], function()
			helpers.with_fresh_modules(OWNERS, function()
				local callbacks = collect(case[1])
				helpers.assert_eq(#callbacks, case[2], "every original scenario must be exercised")
				for _, callback in ipairs(callbacks) do
					local host = hs
					local pathwatcher, timer = host.pathwatcher, host.timer
					local attributes, reload = host.fs.attributes, host.reload
					local roots = rawget(_G, "script_watchers")
					local sentinel_roots = {}
					_G.script_watchers = sentinel_roots
					local originals = {}
					local injected = false
					for _, name in ipairs({ "assert_true", "assert_nil", "assert_eq" }) do
						originals[name] = helpers[name]
						helpers[name] = function()
							injected = true
							error("watcher scenario assertion marker", 0)
						end
					end
					local ok, detail = pcall(callback)
					for name, original in pairs(originals) do helpers[name] = original end
					local restored = hs == host and host.pathwatcher == pathwatcher
						and host.timer == timer and host.fs.attributes == attributes and host.reload == reload
					local restored_roots = rawget(_G, "script_watchers") == sentinel_roots
					-- Keep a deliberately broken fixture from contaminating later test results.
					host.pathwatcher, host.timer = pathwatcher, timer
					host.fs.attributes, host.reload = attributes, reload
					_G.hs, _G.script_watchers = host, roots
					helpers.assert_true(injected, "failure must reach a real scenario assertion: " .. tostring(detail))
					helpers.assert_eq(ok, false)
					helpers.assert_contains(detail, "watcher scenario assertion marker")
					helpers.assert_true(restored, "scenario failure must restore native doubles")
					helpers.assert_true(restored_roots, "scenario failure must restore watcher roots")
				end
			end)
		end)
	end
end)
