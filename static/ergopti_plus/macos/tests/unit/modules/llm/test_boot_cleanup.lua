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

	helpers.it("cannot select its own shell as an MLX process", function()
		local BootCleanup = require("modules.llm.boot_cleanup")
		local prev_exec = hs.execute
		local command
		hs.execute = function(cmd, _shell)
			command = cmd
			return "[BOOT] no MLX Python processes — clean slate.\n"
				.. "[BOOT-DIAG] port 3460 state:\n  (port 3460 is FREE)\n", true
		end

		local ok, err = pcall(BootCleanup.run_selective_cleanup)
		hs.execute = prev_exec

		helpers.assert_true(ok, "run_selective_cleanup must not throw: " .. tostring(err))
		helpers.assert_true(type(command) == "string", "cleanup must dispatch one shell command")
		helpers.assert_contains(command, "ps -axo pid=,comm=,args=",
			"cleanup must enumerate executable identity instead of matching the shell argv")
		helpers.assert_contains(command, "'$2 ~ /^[Pp]ython/ && /mlx_lm/ {print $1}'",
			"only real Python executables whose argv names mlx_lm may be selected")
		helpers.assert_true(command:find("pgrep -f", 1, true) == nil,
			"pgrep -f sees the whole shell script and can select its own interpreter")

		local clean_at = command:find("clean slate", 1, true)
		local diagnostics_at = command:find("[BOOT-DIAG]", 1, true)
		helpers.assert_true(clean_at ~= nil and diagnostics_at ~= nil and clean_at < diagnostics_at,
			"a clean boot must still reach the final port diagnostics")
	end)
end)
