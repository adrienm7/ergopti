--- tests/unit/modules/llm/test_boot_cleanup.lua

--- ==============================================================================
--- MODULE: Regression - asynchronous MLX boot cleanup
--- DESCRIPTION:
--- The cleanup shell pipeline may wait on curl and sleep. It must therefore run
--- through ShellRunner while publishing exactly one terminal result that init.lua
--- can use to order the LLM bootstrap after the port state has settled.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"modules.llm.boot_cleanup",
	"adapters.shell_runner",
	"modules.llm.api_mlx",
}

local function with_cleanup(start_result, callback)
	local saved_execute = hs.execute
	hs.execute = function()
		error("synchronous hs.execute is forbidden in MLX boot cleanup")
	end

	local ok, err = xpcall(function()
		helpers.with_fresh_modules(MODULES, function()
			local state = {
				spawn_calls = 0,
				start_calls = 0,
			}
			package.loaded["modules.llm.api_mlx"] = {
				DEFAULT_PORT = 3460,
				get_port = function() return 4567 end,
			}
			package.loaded["adapters.shell_runner"] = {
				spawn = function(executable, args, on_done)
					state.spawn_calls = state.spawn_calls + 1
					state.executable = executable
					state.args = args
					state.finish = on_done
					return {
						start = function()
							state.start_calls = state.start_calls + 1
							return start_result
						end,
					}
				end,
			}

			local BootCleanup = require("modules.llm.boot_cleanup")
			local callback_ok, callback_err = xpcall(function()
				callback(BootCleanup, state)
			end, debug.traceback)
			package.loaded["adapters.shell_runner"] = nil
			if not callback_ok then error(callback_err, 0) end
		end)
	end, debug.traceback)
	hs.execute = saved_execute
	if not ok then error(err, 0) end
end

helpers.describe("llm.boot_cleanup - asynchronous settlement", function()
	helpers.it("spawns the cleanup and settles only after the child exits", function()
		with_cleanup(true, function(BootCleanup, state)
			local completions = {}
			local started = BootCleanup.run_selective_cleanup(function(success)
				completions[#completions + 1] = success
			end)

			helpers.assert_eq(started, true)
			helpers.assert_eq(state.spawn_calls, 1)
			helpers.assert_eq(state.start_calls, 1)
			helpers.assert_eq(state.executable, "/bin/sh")
			helpers.assert_eq(state.args[1], "-c")
			helpers.assert_eq(#completions, 0,
				"cleanup must not settle before the asynchronous task terminates")

			local command = state.args[2]
			helpers.assert_true(type(command) == "string", "cleanup must dispatch one shell script")
			helpers.assert_contains(command, "-iTCP:4567",
				"cleanup must use the port resolved by api_mlx")
			helpers.assert_contains(command, "ps -axo pid=,comm=,args=",
				"cleanup must enumerate executable identity instead of matching its shell argv")
			helpers.assert_contains(command, "'$2 ~ /^[Pp]ython/ && /mlx_lm/ {print $1}'",
				"only Python executables whose argv names mlx_lm may be selected")
			helpers.assert_true(command:find("pgrep -f", 1, true) == nil,
				"pgrep -f can select the cleanup shell itself")

			state.finish(0, "cleanup complete\n", "")
			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], true)
			state.finish(0, "duplicate\n", "")
			helpers.assert_eq(#completions, 1,
				"a duplicate native terminal must not publish a second settlement")
		end)
	end)

	helpers.it("publishes an immediate failure when the task cannot start", function()
		with_cleanup(false, function(BootCleanup, state)
			local completions = {}
			local started = BootCleanup.run_selective_cleanup(function(success)
				completions[#completions + 1] = success
			end)

			helpers.assert_eq(started, false)
			helpers.assert_eq(state.start_calls, 1)
			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], false)
		end)
	end)

	helpers.it("publishes a failed terminal when the cleanup command exits nonzero", function()
		with_cleanup(true, function(BootCleanup, state)
			local completion
			helpers.assert_true(BootCleanup.run_selective_cleanup(function(success)
				completion = success
			end))
			state.finish(7, "", "cleanup failed")
			helpers.assert_eq(completion, false)
		end)
	end)
end)
