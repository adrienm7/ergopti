--- tests/unit/adapters/test_shell_runner_stream_input.lua

--- ==============================================================================
--- MODULE: ShellRunner Streaming Input Contract Tests
--- DESCRIPTION:
--- Proves that long-lived streaming helpers can receive framed commands and EOF
--- without exposing their native task object, while the adapter keeps the task
--- strongly referenced until completion.
---
--- FEATURES & RATIONALE:
--- 1. Input forwarding: set_input and close_input report native refusal/throws.
--- 2. Lifetime: the task remains in ShellRunner's GC root until completion.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Streaming Input Lifetime =======
-- ===========================================
-- ===========================================

helpers.describe("ShellRunner: streaming input lifetime", function()
	helpers.it("pins the task and forwards one command followed by EOF", function()
		local completion = nil
		local native_task = {
			inputs = {},
			closed = false,
			close_calls = 0,
		}
		function native_task:start() return self end
		function native_task:setInput(data)
			self.inputs[#self.inputs + 1] = data
			return self
		end
		function native_task:closeInput()
			self.close_calls = self.close_calls + 1
			self.closed = true
			return self
		end
		function native_task:terminate() return self end

		local runner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_path, on_done, _on_chunk, _args)
					completion = on_done
					return native_task
				end,
			},
		})

		local handle = runner.spawn("/bin/sh", {}, function() end, function() return true end)
		helpers.assert_true(runner._active_tasks[native_task] == true,
			"streaming task must be strongly pinned before start")
		helpers.assert_true(handle.start(), "native task must start")
		helpers.assert_true(handle.set_input("PAUSE\n"), "set_input must report accepted input")
		helpers.assert_true(handle.close_input(), "close_input must report accepted EOF")
		helpers.assert_true(handle.close_input(), "close_input must be idempotent after accepted EOF")
		helpers.assert_true(not handle.set_input("RESUME\n"),
			"set_input must reject bytes after EOF without touching the native task")
		helpers.assert_eq(native_task.inputs[1], "PAUSE\n", "input bytes must be forwarded unchanged")
		helpers.assert_eq(#native_task.inputs, 1, "no bytes may reach the task after EOF")
		helpers.assert_eq(native_task.close_calls, 1, "EOF must reach the native task exactly once")
		helpers.assert_true(native_task.closed, "close_input must call the native closeInput method")
		helpers.assert_true(runner._active_tasks[native_task] == true,
			"closing stdin must not release the task before process completion")

		completion(0, "", "")
		helpers.assert_nil(runner._active_tasks[native_task],
			"completion must release the GC pin")
	end)

	helpers.it("keeps repeat start pinned and fences input before completion callbacks", function()
		local completion = nil
		local callback_count = 0
		local callback_saw_fenced_input = false
		local native_task = {
			start_calls = 0,
			input_calls = 0,
			inputs = {},
		}
		function native_task:start()
			self.start_calls = self.start_calls + 1
			return self
		end
		function native_task:setInput(data)
			self.input_calls = self.input_calls + 1
			self.inputs[#self.inputs + 1] = data
			return self
		end
		function native_task:closeInput() return self end
		function native_task:terminate() return self end

		local runner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_path, on_done)
					completion = on_done
					return native_task
				end,
			},
		})
		local handle
		handle = runner.spawn("/bin/sh", {}, function()
			callback_count = callback_count + 1
			callback_saw_fenced_input = not handle.set_input("STALE\n")
		end, function() return true end)

		helpers.assert_true(handle.set_input("PREPARED\n"),
			"hs.task permits prepared input before the one allowed start")
		helpers.assert_true(handle.start(), "first start must launch the native task")
		helpers.assert_true(handle.start(), "repeat start while running must be idempotent")
		helpers.assert_eq(native_task.start_calls, 1,
			"an hs.task object can be started only once")
		helpers.assert_true(runner._active_tasks[native_task] == true,
			"repeat start must not release the live task's GC pin")

		completion(0, "", "")
		helpers.assert_true(callback_saw_fenced_input,
			"completion must fence stdin before invoking re-entrant user code")
		helpers.assert_eq(native_task.input_calls, 1,
			"no optimistic hs.task return may claim bytes were sent after completion")
		helpers.assert_nil(runner._active_tasks[native_task],
			"completion must release the exact native task pin")
		helpers.assert_true(not handle.start(),
			"a completed one-shot hs.task must never be started again")
		helpers.assert_eq(native_task.start_calls, 1)

		completion(0, "duplicate", "")
		helpers.assert_eq(callback_count, 1,
			"a duplicate native completion must not replay user-visible teardown")
	end)

	helpers.it("returns false for every native input refusal shape", function()
		for _, outcome in ipairs({ "false", "nil", "throw" }) do
			local native_task = {}
			function native_task:start() return self end
			function native_task:setInput(_data)
				if outcome == "throw" then error("input closed") end
				if outcome == "false" then return false end
				return nil
			end
			function native_task:closeInput()
				if outcome == "throw" then error("input closed") end
				if outcome == "false" then return false end
				return nil
			end
			function native_task:terminate() return self end

			local runner = helpers.load_with_stubs("adapters.shell_runner", {
				task = {
					new = function() return native_task end,
				},
			})
			local handle = runner.spawn("/bin/sh", {}, nil, function() return true end)
			helpers.assert_true(handle.start(), "native task must start for " .. outcome)
			helpers.assert_true(not handle.set_input("STOP\n"),
				"set_input must expose native " .. outcome .. " as false")
			helpers.assert_true(not handle.close_input(),
				"close_input must expose native " .. outcome .. " as false")
		end
	end)
end)
