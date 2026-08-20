--- tests/unit/lib/test_termination_coordinator.lua

--- ==============================================================================
--- MODULE: Controlled Termination Transaction Tests
--- DESCRIPTION:
--- Drives reload and exit requests through an exact asynchronous lease double.
--- Proves local consumers are never torn down before the fence, pre-fence failures
--- retain the live environment, post-fence failures exit, and quit supersedes reload.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_coordinator(options)
	options = options or {}
	local calls = {
		order = {},
		lease_requests = 0,
		teardowns = 0,
		drains = 0,
		finalizers = 0,
		reloads = 0,
		exits = 0,
		fatal_exits = 0,
		marks = 0,
		clears = 0,
		logger_calls = 0,
	}
	local function append(value) calls.order[#calls.order + 1] = value end
	local function observe_log() calls.logger_calls = calls.logger_calls + 1 end
	local function observe_info(...)
		observe_log(...)
		if options.logger_info_raises then error("synthetic post-fence logger failure") end
	end
	package.loaded["infra.logger"] = {
		start = observe_log, debug = observe_log, info = observe_info, warn = observe_log,
		error = observe_log, success = observe_log, done = observe_log,
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
			if options.request_raises_after_callback then
				error("synthetic lease request failure after callback")
			end
			return options.request_accepted ~= false
		end,
		teardown = function(kind)
			calls.teardowns = calls.teardowns + 1
			calls.teardown_kind = kind
			append("teardown-" .. kind)
			if options.partial_teardown then
				calls.first_owner_stopped = true
				append("first-owner-stopped")
			end
			if options.teardown_raises then error("synthetic teardown failure") end
			return options.teardown_result ~= false
		end,
		begin_drain = function(callback)
			calls.drains = calls.drains + 1
			calls.drain_callback = callback
			append("begin-drain")
			if options.drain_raises then error("synthetic drain begin failure") end
			if options.drain_deferred ~= true then
				callback(options.drain_result ~= false, options.drain_detail or "drained")
			end
			return options.drain_accepted ~= false
		end,
		finalize_teardown = function()
			calls.finalizers = calls.finalizers + 1
			append("finalize-teardown")
			if options.finalize_raises then error("synthetic finalizer failure") end
			return options.finalize_result ~= false
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
		fatal_exit = function(code)
			calls.fatal_exits = calls.fatal_exits + 1
			calls.fatal_exit_code = code
			append("fatal-exit")
			if options.fatal_exit_raises then error("synthetic fatal exit failure") end
			return true
		end,
		fatal_exit_code = 70,
		mark_reload = function()
			calls.marks = calls.marks + 1
			append("mark-reload")
			if options.mark_raises then error("synthetic mark failure") end
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
	helpers.it("accepts a returning hs.reload after the exact fence and drained teardown", function()
		local coordinator, calls = load_coordinator()
		helpers.assert_true(coordinator.request_reload("menu_reload", "arg-a", 7))
		helpers.assert_eq(calls.teardowns, 0)
		helpers.assert_eq(calls.reloads, 0)
		helpers.assert_true(coordinator.is_pending())

		calls.lease_callback(true, "stopped")
		helpers.assert_true(helpers.deep_equal(calls.order, {
			"request-lease", "mark-reload", "teardown-reload", "begin-drain",
			"finalize-teardown", "reload",
		}))
		helpers.assert_eq(calls.reload_arguments.n, 2)
		helpers.assert_eq(calls.reload_arguments[1], "arg-a")
		helpers.assert_eq(calls.reload_arguments[2], 7)
		helpers.assert_eq(calls.clears, 0,
			"a scheduled reload must retain its sentinel for the shutdown callback")
		helpers.assert_eq(calls.fatal_exits, 0,
			"hs.reload is allowed to return after scheduling the native reload")
		helpers.assert_true(not coordinator.is_pending())
		local logs_after_reload = calls.logger_calls
		calls.lease_callback(true, "duplicate stopped")
		helpers.assert_eq(calls.logger_calls, logs_after_reload,
			"a late duplicate lease callback must not reopen the stopped logger")
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
		helpers.assert_eq(calls.fatal_exits, 1)
		helpers.assert_eq(calls.fatal_exit_code, 70)
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
		helpers.assert_true(succeeded.request_exit("sync_success") == false,
			"a returning terminal double must report the fatal fallback in synchronous tests")
		helpers.assert_eq(success_calls.exits, 1)
		helpers.assert_eq(success_calls.fatal_exits, 1)
	end)

	helpers.it("keeps termination pending until the native logger ACK drain completes", function()
		local coordinator, calls = load_coordinator({ drain_deferred = true })
		helpers.assert_true(coordinator.request_reload("drained_reload"))
		calls.lease_callback(true, "stopped")
		helpers.assert_eq(calls.teardowns, 1)
		helpers.assert_eq(calls.drains, 1)
		helpers.assert_eq(calls.finalizers, 0)
		helpers.assert_eq(calls.reloads, 0,
			"reload must not run while any teardown diagnostic lacks its native ACK")
		helpers.assert_true(coordinator.is_pending())

		calls.drain_callback(true, "all ACKed")
		helpers.assert_eq(calls.finalizers, 1)
		helpers.assert_eq(calls.reloads, 1)
		helpers.assert_true(not coordinator.is_pending())
		helpers.assert_true(helpers.deep_equal(calls.order, {
			"request-lease", "mark-reload", "teardown-reload", "begin-drain",
			"finalize-teardown", "reload",
		}))
	end)

	helpers.it("exits non-zero without post-drain logging when native drain times out", function()
		local coordinator, calls = load_coordinator({ drain_deferred = true })
		helpers.assert_true(coordinator.request_reload("drain_timeout"))
		calls.lease_callback(true, "stopped")
		local logs_before_timeout = calls.logger_calls
		calls.drain_callback(false, "ACK deadline expired")

		helpers.assert_eq(calls.finalizers, 0,
			"timeout must not pretend the logger finalized")
		helpers.assert_eq(calls.reloads, 0)
		helpers.assert_eq(calls.clears, 1,
			"a failed drained reload must clear its reload sentinel")
		helpers.assert_eq(calls.fatal_exits, 1,
			"post-teardown drain failure must not leave an inert process alive")
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_eq(calls.logger_calls, logs_before_timeout,
			"post-teardown failure must not append after the drained boundary")
		helpers.assert_true(not coordinator.is_pending(),
			"the failed transaction must not remain published as live")
	end)

	helpers.it("exits non-zero when native drain acquisition returns false", function()
		local coordinator, calls = load_coordinator({ drain_accepted = false, drain_deferred = true })
		helpers.assert_true(coordinator.request_exit("drain_rejected"))
		calls.lease_callback(true, "stopped")

		helpers.assert_eq(calls.exits, 0)
		helpers.assert_eq(calls.finalizers, 0)
		helpers.assert_eq(calls.fatal_exits, 1)
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_true(not coordinator.is_pending())
	end)

	helpers.it("exits non-zero when native drain acquisition raises", function()
		local coordinator, calls = load_coordinator({ drain_raises = true })
		helpers.assert_true(coordinator.request_exit("drain_throw"))
		calls.lease_callback(true, "stopped")

		helpers.assert_eq(calls.exits, 0)
		helpers.assert_eq(calls.finalizers, 0)
		helpers.assert_eq(calls.fatal_exits, 1)
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_true(not coordinator.is_pending())
	end)

	helpers.it("exits non-zero without post-stop logging when finalizer returns false", function()
		local coordinator, calls = load_coordinator({
			drain_deferred = true,
			finalize_result = false,
		})
		helpers.assert_true(coordinator.request_exit("finalize_false"))
		calls.lease_callback(true, "stopped")
		local logs_before_finalizer = calls.logger_calls
		calls.drain_callback(true, "all ACKed")

		helpers.assert_eq(calls.finalizers, 1)
		helpers.assert_eq(calls.exits, 0)
		helpers.assert_eq(calls.fatal_exits, 1)
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_eq(calls.logger_calls, logs_before_finalizer,
			"a false post-drain finalizer must not reopen a synchronous logger")
		helpers.assert_true(not coordinator.is_pending())
	end)

	helpers.it("exits non-zero without post-stop logging when finalizer raises", function()
		local coordinator, calls = load_coordinator({
			drain_deferred = true,
			finalize_raises = true,
		})
		helpers.assert_true(coordinator.request_exit("finalize_throw"))
		calls.lease_callback(true, "stopped")
		local logs_before_finalizer = calls.logger_calls
		calls.drain_callback(true, "all ACKed")

		helpers.assert_eq(calls.finalizers, 1)
		helpers.assert_eq(calls.exits, 0)
		helpers.assert_eq(calls.fatal_exits, 1)
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_eq(calls.logger_calls, logs_before_finalizer,
			"a throwing post-drain finalizer must not reopen a synchronous logger")
		helpers.assert_true(not coordinator.is_pending())
	end)

	helpers.it("contains a lease request exception before any teardown", function()
		local request_failure, request_calls = load_coordinator({ request_raises = true })
		helpers.assert_true(request_failure.request_reload("raising_request") == false)
		helpers.assert_eq(request_calls.teardowns, 0)
		helpers.assert_eq(request_calls.reloads, 0)
		helpers.assert_eq(request_calls.fatal_exits, 0,
			"a pre-fence failure leaves the intact driver live")
	end)

	helpers.it("exits non-zero when a synchronous exact fence is followed by a request throw", function()
		local coordinator, calls = load_coordinator({
			synchronous_result = true,
			request_raises_after_callback = true,
			drain_deferred = true,
		})
		helpers.assert_true(coordinator.request_reload("callback_then_throw") == false)
		helpers.assert_eq(calls.teardowns, 1,
			"the causal fixture must cross the exact fence and begin local teardown")
		helpers.assert_eq(calls.drains, 1,
			"the native drain must be pending when request_lease raises")
		helpers.assert_eq(calls.reloads, 0)
		helpers.assert_eq(calls.clears, 1)
		helpers.assert_eq(calls.fatal_exits, 1,
			"a fenced transaction must never be orphaned by its request owner throwing")
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_true(not coordinator.is_pending())
		calls.drain_callback(true, "late ACK")
		helpers.assert_eq(calls.reloads, 0,
			"the orphaned drain callback must not revive the failed transaction")
	end)

	helpers.it("exits non-zero when reload sentinel commit fails after the exact fence", function()
		for _, options in ipairs({
			{ mark_result = false },
			{ mark_raises = true },
		}) do
			local coordinator, calls = load_coordinator(options)
			helpers.assert_true(coordinator.request_reload("sentinel_failure"))
			calls.lease_callback(true, "stopped")

			helpers.assert_eq(calls.marks, 1)
			helpers.assert_eq(calls.teardowns, 0,
				"the sentinel fixture must fail before local teardown")
			helpers.assert_eq(calls.reloads, 0)
			helpers.assert_eq(calls.fatal_exits, 1,
				"exact STOPPED makes sentinel failure an irreversible split state")
			helpers.assert_eq(calls.fatal_exit_code, 70)
			helpers.assert_true(not coordinator.is_pending())
		end
	end)

	helpers.it("exits non-zero after a throwing post-fence teardown", function()
		local teardown_failure, teardown_calls = load_coordinator({ teardown_raises = true })
		helpers.assert_true(teardown_failure.request_reload("raising_teardown"))
		teardown_calls.lease_callback(true, "stopped")
		helpers.assert_eq(teardown_calls.reloads, 0)
		helpers.assert_eq(teardown_calls.clears, 1,
			"a failed teardown must not leave the next real quit marked as reload")
		helpers.assert_eq(teardown_calls.fatal_exits, 1,
			"post-fence teardown failure cannot return as a live driver")
		helpers.assert_eq(teardown_calls.fatal_exit_code, 70)
		helpers.assert_true(not teardown_failure.is_pending())
	end)

	helpers.it("exits non-zero when an earlier owner stopped before teardown returned false", function()
		local false_teardown, false_calls = load_coordinator({
			teardown_result = false,
			partial_teardown = true,
		})
		helpers.assert_true(false_teardown.request_reload("false_teardown"))
		false_calls.lease_callback(true, "stopped")
		helpers.assert_true(false_calls.first_owner_stopped,
			"the causal fixture must prove local teardown already mutated live state")
		helpers.assert_eq(false_calls.reloads, 0,
			"an explicit false teardown result must not execute the terminal action")
		helpers.assert_eq(false_calls.clears, 1)
		helpers.assert_eq(false_calls.fatal_exits, 1,
			"an irreversibly partial teardown must invoke the native EOF backstop once")
		helpers.assert_eq(false_calls.fatal_exit_code, 70)
		helpers.assert_true(not false_teardown.is_pending(),
			"the broken environment must never be republished as live")
	end)

	helpers.it("exits non-zero when the fenced callback raises before local teardown", function()
		local coordinator, calls = load_coordinator({ logger_info_raises = true })
		helpers.assert_true(coordinator.request_exit("post_fence_callback_failure", 0))

		calls.lease_callback(true, "stopped")

		helpers.assert_eq(calls.teardowns, 0,
			"the fixture must fail before local teardown to isolate the committed fence")
		helpers.assert_eq(calls.exits, 0)
		helpers.assert_eq(calls.fatal_exits, 1,
			"an already-fenced half-disabled driver must never return as live")
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_true(not coordinator.is_pending())
	end)

	helpers.it("forces one non-zero fallback when hs.reload raises after finalization", function()
		local coordinator, calls = load_coordinator({ reload_raises = true })
		helpers.assert_true(coordinator.request_reload("reload-throw"))
		calls.lease_callback(true, "stopped")

		helpers.assert_eq(calls.reloads, 1)
		helpers.assert_eq(calls.teardowns, 1,
			"local consumers must already be stopped")
		helpers.assert_eq(calls.drains, 1,
			"logger drain must not be restarted after finalization")
		helpers.assert_eq(calls.finalizers, 1,
			"finalized capabilities must not be retried")
		helpers.assert_eq(calls.clears, 1,
			"a failed reload must clear the sentinel before fatal exit")
		helpers.assert_eq(calls.fatal_exits, 1,
			"reload failure must invoke the fatal native fallback exactly once")
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_true(not coordinator.is_pending())
	end)

	helpers.it("forces one non-zero fallback when os.exit returns after finalization", function()
		local coordinator, calls = load_coordinator()
		helpers.assert_true(coordinator.request_exit("exit-return", 0))
		calls.lease_callback(true, "stopped")

		helpers.assert_eq(calls.exits, 1)
		helpers.assert_eq(calls.teardowns, 1)
		helpers.assert_eq(calls.drains, 1)
		helpers.assert_eq(calls.finalizers, 1)
		helpers.assert_eq(calls.fatal_exits, 1,
			"a returning os.exit double must invoke the fallback exactly once")
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_true(not coordinator.is_pending())
	end)

	helpers.it("forces one non-zero fallback when os.exit raises after finalization", function()
		local coordinator, calls = load_coordinator({ exit_raises = true })
		helpers.assert_true(coordinator.request_exit("exit-throw", 0))
		calls.lease_callback(true, "stopped")

		helpers.assert_eq(calls.exits, 1)
		helpers.assert_eq(calls.teardowns, 1)
		helpers.assert_eq(calls.drains, 1)
		helpers.assert_eq(calls.finalizers, 1)
		helpers.assert_eq(calls.fatal_exits, 1,
			"an os.exit exception must invoke the fallback exactly once")
		helpers.assert_eq(calls.fatal_exit_code, 70)
		helpers.assert_true(not coordinator.is_pending())
	end)

	helpers.it("rejects invalid exit status before requesting a fence", function()
		local coordinator, calls = load_coordinator()
		helpers.assert_true(coordinator.request_exit("invalid", 256) == false)
		helpers.assert_eq(calls.lease_requests, 0)
	end)
end)
