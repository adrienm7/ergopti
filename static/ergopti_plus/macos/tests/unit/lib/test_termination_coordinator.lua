--- tests/unit/lib/test_termination_coordinator.lua

--- ==============================================================================
--- MODULE: Controlled Termination Transaction Tests
--- DESCRIPTION:
--- Drives reload and exit requests through an exact asynchronous lease double.
--- Proves local consumers are never torn down before the fence, failures retain
--- the live environment, and a concurrent quit supersedes a pending reload.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_coordinator(options)
	options = options or {}
	local calls = {
		order = {},
		lease_requests = 0,
		teardowns = 0,
		reloads = 0,
		exits = 0,
		marks = 0,
		clears = 0,
	}
	local function append(value) calls.order[#calls.order + 1] = value end
	local noop = function() end
	package.loaded["infra.logger"] = {
		start = noop, debug = noop, info = noop, warn = noop,
		error = noop, success = noop, done = noop,
	}
	package.loaded["infra.termination_coordinator"] = nil
	local coordinator = require("infra.termination_coordinator")
	helpers.assert_true(coordinator.is_initialized() == false)
	local initialized = coordinator.init({
		request_lease = function(reason, callback)
			calls.lease_requests = calls.lease_requests + 1
			calls.reason = reason
			calls.lease_callback = callback
			append("request-lease")
			if options.request_raises then error("synthetic lease request failure") end
			if options.synchronous_result ~= nil then
				callback(options.synchronous_result, "synchronous")
			end
			return options.request_accepted ~= false
		end,
		teardown = function(kind)
			calls.teardowns = calls.teardowns + 1
			calls.teardown_kind = kind
			append("teardown-" .. kind)
			if options.teardown_raises then error("synthetic teardown failure") end
			return options.teardown_result ~= false
		end,
		reload = function(...)
			calls.reloads = calls.reloads + 1
			calls.reload_arguments = table.pack(...)
			append("reload")
			if options.reload_raises then error("synthetic reload failure") end
			return true
		end,
		exit = function(code)
			calls.exits = calls.exits + 1
			calls.exit_code = code
			append("exit")
			if options.exit_raises then error("synthetic exit failure") end
			return true
		end,
		mark_reload = function()
			calls.marks = calls.marks + 1
			append("mark-reload")
			return options.mark_result ~= false
		end,
		clear_reload = function()
			calls.clears = calls.clears + 1
			append("clear-reload")
			return true
		end,
	})
	helpers.assert_true(initialized)
	helpers.assert_true(coordinator.is_initialized())
	return coordinator, calls
end

helpers.describe("controlled termination coordinator", function()
	helpers.it("keeps every local consumer live until the exact reload fence", function()
		local coordinator, calls = load_coordinator()
		helpers.assert_true(coordinator.request_reload("menu_reload", "arg-a", 7))
		helpers.assert_eq(calls.teardowns, 0)
		helpers.assert_eq(calls.reloads, 0)
		helpers.assert_true(coordinator.is_pending())

		calls.lease_callback(true, "stopped")
		helpers.assert_true(helpers.deep_equal(calls.order, {
			"request-lease", "mark-reload", "teardown-reload", "reload",
		}))
		helpers.assert_eq(calls.reload_arguments.n, 2)
		helpers.assert_eq(calls.reload_arguments[1], "arg-a")
		helpers.assert_eq(calls.reload_arguments[2], 7)
	end)

	helpers.it("aborts without teardown when exact revocation is not proven", function()
		local coordinator, calls = load_coordinator()
		helpers.assert_true(coordinator.request_exit("menu_quit", 0))
		calls.lease_callback(false, "fallback-failed")

		helpers.assert_eq(calls.teardowns, 0)
		helpers.assert_eq(calls.exits, 0)
		helpers.assert_true(not coordinator.is_pending())
	end)

	helpers.it("invokes only an explicit emergency abort callback after a failed fence", function()
		local coordinator, calls = load_coordinator()
		local aborts = 0
		helpers.assert_true(coordinator.request_exit("launcher_loss", 0, function(detail)
			aborts = aborts + 1
			helpers.assert_eq(detail, "fallback-failed")
		end))
		calls.lease_callback(false, "fallback-failed")

		helpers.assert_eq(aborts, 1)
		helpers.assert_eq(calls.teardowns, 0)
		helpers.assert_eq(calls.exits, 0)
	end)

	helpers.it("upgrades a pending reload to one fenced exit transaction", function()
		local coordinator, calls = load_coordinator()
		helpers.assert_true(coordinator.request_reload("first_reload"))
		helpers.assert_true(coordinator.request_exit("script_quit", 23))
		helpers.assert_eq(calls.lease_requests, 1)

		calls.lease_callback(true, "stopped")
		helpers.assert_eq(calls.teardown_kind, "exit")
		helpers.assert_eq(calls.exits, 1)
		helpers.assert_eq(calls.exit_code, 23)
		helpers.assert_eq(calls.reloads, 0)
		helpers.assert_eq(calls.marks, 0)
	end)

	helpers.it("preserves an emergency abort callback when exit supersedes reload", function()
		local coordinator, calls = load_coordinator()
		local aborts = 0
		helpers.assert_true(coordinator.request_reload("first_reload"))
		helpers.assert_true(coordinator.request_exit("launcher_loss", 0, function()
			aborts = aborts + 1
		end))
		calls.lease_callback(false, "fallback-failed")

		helpers.assert_eq(aborts, 1)
		helpers.assert_eq(calls.teardowns, 0)
		helpers.assert_eq(calls.reloads, 0)
		helpers.assert_eq(calls.exits, 0)
	end)

	helpers.it("returns the synchronous fence result instead of mere request acceptance", function()
		local failed, failed_calls = load_coordinator({ synchronous_result = false })
		helpers.assert_true(failed.request_exit("sync_failure") == false)
		helpers.assert_eq(failed_calls.exits, 0)

		local succeeded, success_calls = load_coordinator({ synchronous_result = true })
		helpers.assert_true(succeeded.request_exit("sync_success"))
		helpers.assert_eq(success_calls.exits, 1)
	end)

	helpers.it("contains request and teardown exceptions without executing the terminal action", function()
		local request_failure, request_calls = load_coordinator({ request_raises = true })
		helpers.assert_true(request_failure.request_reload("raising_request") == false)
		helpers.assert_eq(request_calls.teardowns, 0)
		helpers.assert_eq(request_calls.reloads, 0)

		local teardown_failure, teardown_calls = load_coordinator({ teardown_raises = true })
		helpers.assert_true(teardown_failure.request_reload("raising_teardown"))
		teardown_calls.lease_callback(true, "stopped")
		helpers.assert_eq(teardown_calls.reloads, 0)
		helpers.assert_eq(teardown_calls.clears, 1,
			"a failed teardown must not leave the next real quit marked as reload")

		local false_teardown, false_calls = load_coordinator({ teardown_result = false })
		helpers.assert_true(false_teardown.request_reload("false_teardown"))
		false_calls.lease_callback(true, "stopped")
		helpers.assert_eq(false_calls.reloads, 0,
			"an explicit false teardown result must not execute the terminal action")
		helpers.assert_eq(false_calls.clears, 1)
	end)

	helpers.it("clears the reload sentinel when the native reload action raises", function()
		local coordinator, calls = load_coordinator({ reload_raises = true })
		helpers.assert_true(coordinator.request_reload("raising_reload"))
		calls.lease_callback(true, "stopped")
		helpers.assert_eq(calls.teardowns, 1)
		helpers.assert_eq(calls.reloads, 1)
		helpers.assert_eq(calls.clears, 1)
	end)

	helpers.it("rejects invalid exit status before requesting a fence", function()
		local coordinator, calls = load_coordinator()
		helpers.assert_true(coordinator.request_exit("invalid", 256) == false)
		helpers.assert_eq(calls.lease_requests, 0)
	end)
end)
