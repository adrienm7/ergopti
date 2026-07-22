--- tests/unit/modules/llm/test_boot_cleanup.lua

--- ==============================================================================
--- MODULE: Regression — llm.boot_cleanup contract
--- DESCRIPTION:
--- The selective MLX boot cleanup was extracted from init.lua into
--- modules/llm/boot_cleanup.lua. init.lua requires it at boot and calls
--- run_selective_cleanup(); a wrong require path or a renamed function would only
--- surface as a boot-time crash on the maintainer's Mac (the unit suite never
--- loads init.lua). This test pins the require path + public API and asserts the
--- cleanup runs without throwing under a stubbed hs.execute.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("llm.boot_cleanup — module contract", function()
	helpers.it("loads and exposes run_selective_cleanup", function()
		package.loaded["modules.llm.boot_cleanup"] = nil
		local BootCleanup = require("modules.llm.boot_cleanup")
		helpers.assert_true(type(BootCleanup) == "table", "module must return a table")
		helpers.assert_true(type(BootCleanup.run_selective_cleanup) == "function",
			"must expose run_selective_cleanup (init.lua boot calls it)")
	end)

	helpers.it("run_selective_cleanup runs without throwing", function()
		local BootCleanup = require("modules.llm.boot_cleanup")
		-- Stub hs.execute so the test never spawns lsof/curl/kill on the host.
		local prev_exec = hs.execute
		hs.execute = function(_cmd, _shell) return "", true end
		local ok, err = pcall(BootCleanup.run_selective_cleanup)
		hs.execute = prev_exec
		helpers.assert_true(ok, "run_selective_cleanup must not throw: " .. tostring(err))
	end)
end)
