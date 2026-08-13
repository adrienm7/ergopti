--- tests/unit/lib/test_teardown_transaction.lua

--- ==============================================================================
--- MODULE: Retryable Local Teardown Transaction Tests
--- DESCRIPTION:
--- Proves that a throwing or false cleanup cannot be certified as complete,
--- cannot hide healthy sibling cleanup, and retains its retry capability.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_transaction()
	local errors = {}
	local noop = function() end
	package.loaded["infra.logger"] = {
		start = noop, debug = noop, info = noop, warn = noop,
		success = noop, done = noop, trace = noop,
		error = function(_, message, ...)
			local ok, formatted = pcall(string.format, tostring(message), ...)
			errors[#errors + 1] = ok and formatted or tostring(message)
		end,
	}
	package.loaded["infra.teardown_transaction"] = nil
	return require("infra.teardown_transaction"), errors
end

helpers.describe("retryable local teardown transaction", function()
	helpers.it("continues healthy siblings and retries only unproven steps", function()
		local transaction, errors = load_transaction()
		local state = transaction.new_state()
		local attempts = { throwing = 0, refusing = 0, healthy = 0 }
		local fail = true
		local steps = {
			{
				name = "throwing",
				run = function()
					attempts.throwing = attempts.throwing + 1
					if fail then error("synthetic teardown throw") end
				end,
			},
			{
				name = "refusing",
				run = function()
					attempts.refusing = attempts.refusing + 1
					return not fail
				end,
			},
			{
				name = "healthy",
				run = function() attempts.healthy = attempts.healthy + 1 end,
			},
		}

		helpers.assert_true(transaction.run(state, steps) == false)
		helpers.assert_eq(attempts.throwing, 1)
		helpers.assert_eq(attempts.refusing, 1)
		helpers.assert_eq(attempts.healthy, 1,
			"a failed sibling must not prevent independent cleanup")
		helpers.assert_true(state.completed.healthy == true)
		helpers.assert_true(state.completed.throwing ~= true)
		helpers.assert_true(state.completed.refusing ~= true)
		helpers.assert_eq(#errors, 2)

		fail = false
		helpers.assert_true(transaction.run(state, steps))
		helpers.assert_eq(attempts.throwing, 2)
		helpers.assert_eq(attempts.refusing, 2)
		helpers.assert_eq(attempts.healthy, 1,
			"a proven cleanup must not run twice during a retry")
	end)

	helpers.it("runs a quit-only step added after a completed reload teardown", function()
		local transaction = load_transaction()
		local state = transaction.new_state()
		local calls = { common = 0, quit_only = 0 }
		local common = {
			name = "common",
			run = function() calls.common = calls.common + 1 end,
		}

		helpers.assert_true(transaction.run(state, { common }))
		helpers.assert_true(transaction.run(state, {
			common,
			{
				name = "quit-only",
				run = function() calls.quit_only = calls.quit_only + 1 end,
			},
		}))
		helpers.assert_eq(calls.common, 1)
		helpers.assert_eq(calls.quit_only, 1)
	end)

	helpers.it("defers a global finalizer until every resource owner settles", function()
		local transaction = load_transaction()
		local state = transaction.new_state()
		local attempts = { refusing = 0, healthy = 0, finalizer = 0 }
		local owner_refuses = true
		local finalizer_refuses = true
		local owner_steps = {
			{
				name = "refusing-owner",
				run = function()
					attempts.refusing = attempts.refusing + 1
					return not owner_refuses
				end,
			},
			{
				name = "healthy-owner",
				run = function()
					attempts.healthy = attempts.healthy + 1
					return true
				end,
			},
		}
		local global_finalizer = {
			name = "global-finalizer",
			run = function()
				attempts.finalizer = attempts.finalizer + 1
				return not finalizer_refuses
			end,
		}

		helpers.assert_eq(false,
			transaction.run_with_finalizer(state, owner_steps, global_finalizer))
		helpers.assert_eq(1, attempts.refusing)
		helpers.assert_eq(1, attempts.healthy,
			"independent owners must still make teardown progress")
		helpers.assert_eq(0, attempts.finalizer,
			"a global drain must not invalidate resources retained by a failed owner")

		owner_refuses = false
		helpers.assert_eq(false,
			transaction.run_with_finalizer(state, owner_steps, global_finalizer))
		helpers.assert_eq(2, attempts.refusing)
		helpers.assert_eq(1, attempts.healthy,
			"a settled owner must not be repeated")
		helpers.assert_eq(1, attempts.finalizer,
			"the global drain may run once every owner has settled")

		finalizer_refuses = false
		helpers.assert_eq(true,
			transaction.run_with_finalizer(state, owner_steps, global_finalizer))
		helpers.assert_eq(2, attempts.refusing)
		helpers.assert_eq(1, attempts.healthy)
		helpers.assert_eq(2, attempts.finalizer,
			"a failed finalizer must remain retryable without repeating owners")
	end)

	helpers.it("rejects malformed, duplicate, and re-entrant transactions", function()
		local transaction, errors = load_transaction()
		local state = transaction.new_state()
		local calls = 0
		local step = { name = "same", run = function() calls = calls + 1 end }

		helpers.assert_true(transaction.run_with_finalizer(state, { step }, nil) == false)
		helpers.assert_eq(calls, 0)
		helpers.assert_true(transaction.run(state, { step, step }) == false)
		helpers.assert_eq(calls, 0)
		state.running = true
		helpers.assert_true(transaction.run(state, { step }) == false)
		helpers.assert_eq(calls, 0)
		helpers.assert_true(#errors >= 2)
	end)
end)
