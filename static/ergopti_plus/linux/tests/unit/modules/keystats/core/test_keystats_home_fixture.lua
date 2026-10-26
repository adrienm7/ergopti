--- tests/unit/modules/keystats/core/test_keystats_home_fixture.lua

--- ==============================================================================
--- MODULE: Keystats Own-Home Fixture Guard
--- DESCRIPTION:
--- The keystats tests run in a home of their own and fail when a case writes
--- outside it. Without this proof the guard could silently stop guarding.
---
--- ROOT CAUSE ENCODED:
--- test_keystats.lua and test_keystats_system_events.lua leaned on the
--- runner's HOME redirect: their default paths wrote logs/keystrokes_*.json and
--- the metrics flag into the shared scratch config, where the next test read
--- them.
--- ==============================================================================

local helpers = require("tests.helpers")
local Home = require("tests.support.keystats_home_fixture")

helpers.describe("keystats own-home fixture", function()
	helpers.it("points every default path of the collector inside its directory", function()
		local outer = os.getenv("HOME")
		Home.run(function()
			local inside = os.getenv("HOME")
			helpers.assert_true(inside ~= outer, "the case must not share the runner's home")
			helpers.assert_eq(inside, Home.path(), "HOME is the fixture directory")
			local paths = require("infra.config_paths")
			helpers.assert_eq(paths.config("logs"):sub(1, #inside), inside, "the log directory follows HOME")
			helpers.assert_eq(paths.metrics_path():sub(1, #inside), inside, "the database follows HOME")
		end)
		helpers.assert_eq(os.getenv("HOME"), outer, "the runner's HOME is restored")
	end)

	helpers.it("fails a case that writes outside its directory, and names the file", function()
		local stray = os.getenv("HOME") .. "/keystats_stray_probe.json"
		local ok, err = pcall(Home.run, function()
			local handle = assert(io.open(stray, "w"))
			handle:write("{}")
			handle:close()
		end)
		os.remove(stray)
		helpers.assert_eq(ok, false, "a write into the runner's home must fail the case")
		helpers.assert_true(tostring(err):find("keystats_stray_probe.json", 1, true) ~= nil,
			"the failure names the stray file: " .. tostring(err))
	end)

	helpers.it("lets a case write inside its directory", function()
		Home.run(function()
			local handle = assert(io.open(Home.path("logs_probe.json"), "w"))
			handle:write("{}")
			handle:close()
		end)
	end)
end)
