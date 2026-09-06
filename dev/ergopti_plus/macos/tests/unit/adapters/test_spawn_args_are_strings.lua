--- tests/unit/adapters/test_spawn_args_are_strings.lua

--- ==============================================================================
--- MODULE: Spawn argument typing (keylogger-worker-timings-must-be-strings)
--- DESCRIPTION:
--- An argument vector becomes an execve(2) argv: every element is a C string and
--- nothing else. hs.task.new() does not convert a number and does not say which
--- slot offended -- it returns nil -- so the adapter used to log the generic
--- "returned no task" and the caller lost its whole subprocess with no way to
--- find out why.
---
--- The Windows driver shipped exactly that defect for sixteen days: the metrics
--- worker spliced six Integer timing constants straight into its vector, the
--- spawn boundary refused it, and the only diagnostic anywhere was the argument
--- index in "Argument 9 must be a string". macOS could not produce even that.
---
--- ROOT CAUSE ENCODED: refuse by index, before any native task exists, and prove
--- the check cannot be bypassed by a future code path -- the validation must run
--- ahead of hs.task.new, not beside it.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"infra.logger",
	"adapters.shell_runner",
}

--- Loads the adapter against a native double that records every constructed task,
--- so "no task was created" is an observable fact rather than an inference.
local function with_runner(callback)
	local saved_hs = _G.hs
	local outcome = table.pack(xpcall(function()
		helpers.with_fresh_modules(OWNED_MODULES, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local native = { tasks = {} }
			_G.hs = {
				execute = function() return "" end,
				timer = { doAfter = function(_, fn) fn() return true end },
				task = {},
			}
			_G.hs.task.new = function(_, on_done, _on_chunk_or_args)
				local task = { on_done = on_done, running = false }
				function task:environment() return {} end
				function task:setEnvironment() return self end
				function task:start() self.running = true return self end
				function task:terminate() self.running = false return self end
				function task:isRunning() return self.running end
				native.tasks[#native.tasks + 1] = task
				return task
			end

			local ShellRunner = require("adapters.shell_runner")
			callback(ShellRunner, native)
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	if not outcome[1] then error(outcome[2], 0) end
end




-- ================================================================
-- ================================================================
-- ======= 1/ The validator names the offending slot ==============
-- ================================================================
-- ================================================================

helpers.describe("ShellRunner spawn argument typing", function()

	helpers.it("refuses a non-string argument by its index", function()
		with_runner(function(ShellRunner)
			local refusal = ShellRunner.validate_spawn_args("/bin/worker",
				{ "--flag", 1500 })
			helpers.assert_true(refusal:find("argument 2", 1, true) ~= nil,
				"the refusal must name the offending slot -- that index was the only "
				.. "diagnostic that located the identical Windows defect; got: " .. refusal)

			helpers.assert_eq(
				ShellRunner.validate_spawn_args("/bin/worker", { "--flag", "1500" }), "",
				"the same value as decimal text must be admissible, otherwise the fix "
				.. "would be unreachable and this guard vacuous")
		end)
	end)

	helpers.it("refuses every non-string element type, not only numbers", function()
		with_runner(function(ShellRunner)
			local cases = {
				{ value = 1500, label = "number" },
				{ value = true, label = "boolean" },
				{ value = {}, label = "table" },
				{ value = print, label = "function" },
			}
			for _, case in ipairs(cases) do
				local refusal = ShellRunner.validate_spawn_args("/bin/worker",
					{ "--flag", case.value })
				helpers.assert_true(refusal ~= "",
					"a " .. case.label .. " argument must be refused")
				helpers.assert_true(refusal:find("argument 2", 1, true) ~= nil,
					"the " .. case.label .. " refusal must still name the index")
			end
			helpers.assert_eq(#cases, 4, "every non-string type must be covered")
		end)
	end)

	helpers.it("refuses an empty or non-string executable", function()
		with_runner(function(ShellRunner)
			helpers.assert_true(ShellRunner.validate_spawn_args("", { "--flag" }) ~= "",
				"an empty executable must be refused")
			helpers.assert_true(ShellRunner.validate_spawn_args(nil, { "--flag" }) ~= "",
				"a nil executable must be refused")
		end)
	end)

	helpers.it("accepts a nil argument vector as 'no arguments'", function()
		with_runner(function(ShellRunner)
			helpers.assert_eq(ShellRunner.validate_spawn_args("/bin/worker", nil), "",
				"callers that pass no arguments at all must stay admissible")
		end)
	end)

	helpers.it("refuses a keyed table posing as an argument vector", function()
		with_runner(function(ShellRunner)
			helpers.assert_true(
				ShellRunner.validate_spawn_args("/bin/worker", { flag = "--x" }) ~= "",
				"a keyed table has no argv order and must be refused rather than "
				.. "silently spawning with zero arguments")
		end)
	end)




	-- ================================================================
	-- ================================================================
	-- ======= 2/ No native task is created for a refusal =============
	-- ================================================================
	-- ================================================================

	-- The point of validating early is that nothing observable happens: no
	-- process, no PID, no GC pin. A check that ran after hs.task.new would still
	-- leak a native object on every refusal.
	helpers.it("creates no native task when the vector is refused", function()
		with_runner(function(ShellRunner, native)
			local handle = ShellRunner.spawn("/fixture/worker", { "--flag", 1500 },
				function() end)
			helpers.assert_eq(#native.tasks, 0,
				"a refused vector must never reach hs.task.new")
			helpers.assert_eq(handle.start(), false,
				"the refused handle must answer start() with false, like a launch failure")
			helpers.assert_true(handle.isSettled(),
				"no process was created, so the handle is settled on arrival")
			local accepted, state = handle.terminate()
			helpers.assert_true(accepted, "terminating a refused handle must succeed")
			helpers.assert_eq(state, "settled",
				"a refusal leaves nothing to signal")
		end)
	end)

	helpers.it("still spawns normally once every element is a string", function()
		with_runner(function(ShellRunner, native)
			local handle = ShellRunner.spawn("/fixture/worker", { "--flag", "1500" },
				function() end)
			helpers.assert_eq(#native.tasks, 1,
				"an admissible vector must reach hs.task.new -- otherwise the guard "
				.. "above would pass by breaking spawn() outright")
			helpers.assert_eq(handle.start(), true)
		end)
	end)

	helpers.it("notifies an onSettled observer on a refused handle", function()
		with_runner(function(ShellRunner)
			local handle = ShellRunner.spawn("/fixture/worker", { 1500 }, function() end)
			local notified = 0
			helpers.assert_true(handle.onSettled(function() notified = notified + 1 end),
				"the refused handle must honour the settlement contract")
			helpers.assert_eq(notified, 1,
				"an already-settled handle notifies synchronously, so a caller waiting "
				.. "on settlement cannot hang on a refusal")
		end)
	end)




	-- ================================================================
	-- ================================================================
	-- ======= 3/ The check cannot be bypassed later ==================
	-- ================================================================
	-- ================================================================

	-- Behavioural tests prove today's path. This one pins the ORDER, so a future
	-- edit cannot move the validation after task construction and keep the suite
	-- green while reintroducing the leak the section above rules out.
	helpers.it("validates before hs.task.new is ever reached", function()
		local src = helpers.read_driver_source("function M.spawn(executable, args")
		helpers.assert_true(src ~= nil and src ~= "",
			"adapters/shell_runner.lua must be readable -- an unresolved selector "
			.. "would make this guard pass vacuously")
		-- Anchor on M.spawn's own body. Searching the whole file would match the
		-- validator's definition and the doc comments that name hs.task.new, and
		-- the comparison would then say nothing about the call order.
		local body_at = src:find("function M.spawn(executable, args", 1, true)
		helpers.assert_true(body_at ~= nil, "M.spawn must exist under that signature")
		-- The CALL, not the definition: the two are textually similar and only the
		-- call site's position carries the invariant.
		local validate_at = src:find("local refusal = M.validate_spawn_args(", body_at, true)
		local task_at = src:find("pcall(hs.task.new,", body_at, true)
		helpers.assert_true(validate_at ~= nil,
			"M.spawn must call M.validate_spawn_args on entry")
		helpers.assert_true(task_at ~= nil,
			"M.spawn must still construct a task through pcall(hs.task.new, …) -- "
			.. "otherwise the assertion below is vacuous")
		helpers.assert_true(validate_at < task_at,
			"the argument check must run BEFORE hs.task.new, so a refusal costs no "
			.. "native object (keylogger-worker-timings-must-be-strings)")
	end)
end)
