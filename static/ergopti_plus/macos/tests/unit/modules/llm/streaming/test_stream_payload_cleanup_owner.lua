--- tests/unit/modules/llm/streaming/test_stream_payload_cleanup_owner.lua

--- Exercises cleanup receipts independently of provider and native task outcomes.
local helpers = require("tests.helpers")
local Cleanup = require("modules.llm.stream_payload_cleanup")

local function with_owner(callback)
	helpers.with_fresh_modules({ "adapters.file_system" }, function()
		local state = { attempts = 0, errors = {}, debug = {}, present = true, remove_args = {}, inspect_args = {} }
		package.loaded["adapters.file_system"] = {
			remove_exact = function(...)
				state.remove_args[#state.remove_args + 1] = table.pack(...)
				state.attempts = state.attempts + 1
				if state.remove then return state.remove() end
				state.present = false
				return true
			end,
			classify_no_follow = function(...)
				state.inspect_args[#state.inspect_args + 1] = table.pack(...)
				if state.classify then return state.classify() end
				if state.present then return { mode = "file" }, "ok" end
				return nil, "absent"
			end,
		}
		local logger = {
			error = function(_, message, ...)
				state.errors[#state.errors + 1] = string.format(message, ...)
				if state.on_error then state.on_error() end
			end,
			debug = function(_, message) state.debug[#state.debug + 1] = message end,
		}
		callback(Cleanup.new(logger, "fixture"), state)
		-- These oracles must stay outside the owner's native pcall boundaries.
		for _, calls in ipairs({ state.remove_args, state.inspect_args }) do
			for _, args in ipairs(calls) do
				helpers.assert_eq(args.n, 1)
				helpers.assert_eq(args[1], "/owned/payload")
			end
		end
	end)
end

helpers.describe("stream payload cleanup owner", function()
	helpers.it("(stream-payload-owner) consumes delete authority after success", function()
		with_owner(function(registry, state)
			local cleanup = registry.capture("/owned/payload", function() return state.task end)
			helpers.assert_eq(cleanup(), true)
			state.present = true
			helpers.assert_eq(cleanup(), true)
			helpers.assert_eq(registry.settle_pending(), true)
			helpers.assert_eq(state.present, true, "a later file at the retired pathname must survive")
			helpers.assert_eq(state.attempts, 1)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	for _, refusal in ipairs({ "nil", "false", "throw", "foreign" }) do
		helpers.it("(stream-payload-owner) retains and retries " .. refusal .. " unlink receipts", function()
			with_owner(function(registry, state)
				local cleanup = registry.capture("/owned/payload", function() return state.task end)
				state.remove = function()
					if refusal == "throw" then error("PRIVATE_NATIVE_DETAIL") end
					if refusal == "false" then return false, "PRIVATE_NATIVE_DETAIL" end
					if refusal == "foreign" then return {} end
					return nil, "PRIVATE_NATIVE_DETAIL"
				end
				helpers.assert_eq(cleanup(), false)
				helpers.assert_eq(registry.settle_pending(), false)
				helpers.assert_eq(#state.errors, 1, "the exact refusal episode is reported once")
				helpers.assert_nil(state.errors[1]:find("PRIVATE_NATIVE_DETAIL", 1, true))
				state.remove = nil
				helpers.assert_eq(registry.settle_pending(), true)
				helpers.assert_eq(state.present, false)
				helpers.assert_eq(#state.debug, 1)
				local attempts = state.attempts
				state.present = true
				helpers.assert_eq(cleanup(), true)
				helpers.assert_eq(state.attempts, attempts)
			end)
		end)
	end
	helpers.it("(stream-payload-owner) accepts classified absence without reviving deletion", function()
		with_owner(function(registry, state)
			state.remove = function() return false, "already absent" end
			state.present = false
			local cleanup = registry.capture("/owned/payload", function() return state.task end)
			helpers.assert_eq(cleanup(), true)
			state.present = true
			helpers.assert_eq(cleanup(), true)
			helpers.assert_eq(state.attempts, 1)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	for _, refusal in ipairs({ "error", "throw", "contradictory" }) do
		helpers.it("(stream-payload-owner) retains indeterminate absence " .. refusal, function()
			with_owner(function(registry, state)
				state.remove = function() return false end
				state.classify = function()
					if refusal == "throw" then error("inspection refused") end
					if refusal == "contradictory" then return { mode = "file" }, "absent" end
					return nil, "error", "inspection refused"
				end
				local cleanup = registry.capture("/owned/payload", function() return state.task end)
				helpers.assert_eq(cleanup(), false)
				helpers.assert_eq(registry.settle_pending(), false)
				helpers.assert_eq(state.present, true)
				helpers.assert_eq(#state.errors, 1)
			end)
		end)
	end
	helpers.it("(stream-payload-owner) pins debt before reentrant diagnostics", function()
		with_owner(function(registry, state)
			state.remove = function() return false end
			state.on_error = function()
				state.reentry_result = registry.settle_pending()
				state.reentry_attempts = state.attempts
			end
			local cleanup = registry.capture("/owned/payload", function() return state.task end)
			helpers.assert_eq(cleanup(), false)
			helpers.assert_eq(state.reentry_result, false)
			helpers.assert_eq(state.reentry_attempts, 1, "the in-progress unlink cannot be reentered")
			state.on_error, state.remove = nil, nil
			helpers.assert_eq(registry.settle_pending(), true)
			helpers.assert_eq(state.present, false)
		end)
	end)
	helpers.it("(stream-payload-owner) preserves exact debt when the diagnostic throws", function()
		with_owner(function(registry, state)
			state.remove = function() return false end
			state.on_error = function() error("diagnostic failure") end
			local cleanup = registry.capture("/owned/payload", function() return state.task end)
			local ok, detail = pcall(cleanup)
			helpers.assert_eq(ok, false)
			helpers.assert_contains(tostring(detail), "diagnostic failure")
			state.on_error, state.remove = nil, nil
			helpers.assert_eq(registry.settle_pending(), true)
			helpers.assert_eq(state.present, false)
		end)
	end)
end)

helpers.describe("stream payload cleanup exact task ownership", function()
	helpers.it("(stream-payload-owner) retains a still-running task without unlinking its input", function()
		with_owner(function(registry, state)
			local settled = false
			state.task = { isSettled = function() return settled end }
			local cleanup = registry.capture("/owned/payload", function() return state.task end)
			helpers.assert_eq(cleanup(), false)
			helpers.assert_eq(registry.settle_pending(), false)
			helpers.assert_eq(state.attempts, 0)
			helpers.assert_eq(#state.errors, 0, "a task still reading its input is ordinary pending ownership")
			settled = true
			helpers.assert_eq(registry.settle_pending(), true)
			helpers.assert_eq(state.attempts, 1)
			helpers.assert_eq(state.present, false)
		end)
	end)
	for _, receipt in ipairs({ "throw", "nil", "foreign" }) do
		helpers.it("(stream-payload-owner) refuses indeterminate original task " .. receipt, function()
			with_owner(function(registry, state)
				state.task = { isSettled = function()
					if receipt == "throw" then error("PRIVATE_TASK_DETAIL") end
					if receipt == "foreign" then return {} end
				end }
				local cleanup = registry.capture("/owned/payload", function() return state.task end)
				helpers.assert_eq(cleanup(), false)
				helpers.assert_eq(registry.settle_pending(), false)
				helpers.assert_eq(state.attempts, 0)
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_nil(state.errors[1]:find("PRIVATE_TASK_DETAIL", 1, true))
				state.task.isSettled = function() return true end
				helpers.assert_eq(registry.settle_pending(), true)
				helpers.assert_eq(state.attempts, 1)
			end)
		end)
	end
end)

helpers.describe("stream payload cleanup constructor admission", function()
	for _, missing in ipairs({ "remove_exact", "classify_no_follow" }) do
		helpers.it("(stream-payload-owner) refuses missing " .. missing .. " before native work", function()
			helpers.with_fresh_modules({ "adapters.file_system" }, function()
				local calls = 0
				local files = {
					remove_exact = function() calls = calls + 1; return true end,
					classify_no_follow = function() calls = calls + 1; return nil, "absent" end,
				}
				files[missing] = nil
				package.loaded["adapters.file_system"] = files
				local ok, detail = pcall(Cleanup.new, helpers.make_logger_stub(), "fixture")
				helpers.assert_eq(ok, false)
				helpers.assert_contains(tostring(detail), "exact file cleanup ports")
				helpers.assert_eq(calls, 0, "constructor validation must not allocate or inspect a file")
			end)
		end)
	end
end)
