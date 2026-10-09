--- tests/unit/adapters/test_process_lifecycle_running_guard.lua

--- ==============================================================================
--- MODULE: Regression — transactional ProcessLifecycle ownership
--- DESCRIPTION:
--- Exercises the real adapter against watcher doubles whose start/stop methods
--- fail once. A constructed handle is not proof that the native watcher started,
--- and clearing an aggregate running flag after a failed stop loses the only
--- cleanup handle. The same harness drives a throwing subscriber followed by a
--- healthy one and requires the first failure to reach the central logger.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================================
-- ===========================================================
-- ======= 1/ Transactional Lifecycle Harness ================
-- ===========================================================
-- ===========================================================

--- Loads a fresh adapter with deterministic native watcher failures.
--- @param options table|nil Failure injection options.
--- @return table adapter, table context
local function load_adapter(options)
	options = options or {}
	local ctx = {
		errors             = {},
		new_calls          = 0,
		start_calls        = 0,
		stop_calls         = 0,
		callbacks           = {},
		filter_new_calls    = 0,
		subscribe_calls     = 0,
		unsubscribe_calls   = 0,
		filter_callbacks    = {},
	}

	package.loaded["infra.logger"] = nil
	local real_logger = require("infra.logger")
	local logger = setmetatable({}, { __index = real_logger })
	logger.error = function(_module, fmt, ...)
		local ok, rendered = pcall(string.format, fmt, ...)
		ctx.errors[#ctx.errors + 1] = ok and rendered or tostring(fmt)
	end
	package.loaded["infra.logger"] = logger

	local watcher_api = {
		launched   = 1,
		terminated = 2,
		activated  = 3,
		new = function(callback)
			ctx.new_calls = ctx.new_calls + 1
			ctx.callbacks[#ctx.callbacks + 1] = callback
			local candidate = {}
			function candidate:start()
				ctx.start_calls = ctx.start_calls + 1
				if options.start_throws_once and ctx.start_calls == 1 then
					error("native start failed")
				end
				return self
			end
			function candidate:stop()
				ctx.stop_calls = ctx.stop_calls + 1
				if options.stop_throws_once and ctx.stop_calls == 1 then
					error("native stop failed")
				end
				if options.stop_returns_nil_once and ctx.stop_calls == 1 then return nil end
				return self
			end
			return candidate
		end,
	}

	local adapter = helpers.load_with_stubs("adapters.process_lifecycle", {
		application = {
			watcher = watcher_api,
		},
		window = {
			focusedWindow = function() return nil end,
			filter = {
				windowFocused = 1,
				new = function()
					ctx.filter_new_calls = ctx.filter_new_calls + 1
					return {
						subscribe = function(self, _, callback)
							ctx.subscribe_calls = ctx.subscribe_calls + 1
							ctx.filter_callbacks[#ctx.filter_callbacks + 1] = callback
							if options.subscribe_throws_once and ctx.subscribe_calls == 1 then
								error("native subscribe failed")
							end
							if options.subscribe_returns_nil_once and ctx.subscribe_calls == 1 then return nil end
							return self
						end,
						unsubscribeAll = function(self)
							ctx.unsubscribe_calls = ctx.unsubscribe_calls + 1
							if options.unsubscribe_throws_once and ctx.unsubscribe_calls == 1 then
								error("native unsubscribe failed")
							end
							return self
						end,
					}
				end,
			},
		},
	})

	return adapter, ctx
end

helpers.describe("process_lifecycle: native ownership is transactional", function()
	helpers.it("retries after a watcher start throw (process-lifecycle-start-retry)", function()
		local adapter, ctx = load_adapter({ start_throws_once = true })

		adapter.start()
		adapter.start()

		helpers.assert_eq(2, ctx.new_calls,
			"a handle whose start threw must not poison the idempotence guard")
		helpers.assert_eq(2, ctx.start_calls,
			"the second start must activate a fresh native watcher")
		helpers.assert_true(#ctx.errors >= 1,
			"the first native start failure must be visible in the file logger")
		adapter.stop()
	end)

	helpers.it("retains and retries a watcher whose stop throws (process-lifecycle-stop-retry)", function()
		local adapter, ctx = load_adapter({ stop_throws_once = true })

		adapter.start()
		adapter.stop()
		adapter.stop()

		helpers.assert_eq(2, ctx.stop_calls,
			"a failed stop must retain the exact handle for a second cleanup attempt")
		helpers.assert_true(#ctx.errors >= 1,
			"the failed native teardown must be visible in the file logger")
	end)

	helpers.it("retains and retries a watcher whose stop returns nil", function()
		local adapter, ctx = load_adapter({ stop_returns_nil_once = true })

		adapter.start()
		helpers.assert_eq(false, adapter.stop(),
			"the documented watcher object is the only successful stop result")
		helpers.assert_eq(true, adapter.stop(),
			"the exact handle must remain available for a cleanup retry")
		helpers.assert_eq(2, ctx.stop_calls,
			"a nil stop result cannot silently discard native ownership")
	end)

	helpers.it("rejects a nil filter subscription result and rolls back siblings", function()
		local adapter, ctx = load_adapter({ subscribe_returns_nil_once = true })
		adapter.onFocusChange(function() end)

		helpers.assert_eq(false, adapter.start(),
			"the documented filter object is the only successful subscribe result")
		helpers.assert_eq(1, ctx.stop_calls,
			"a nil subscription result must roll back the sibling application watcher")
		helpers.assert_eq(1, ctx.unsubscribe_calls,
			"the partially subscribed filter candidate must still be released")
		helpers.assert_eq(true, adapter.start(),
			"a fresh transaction must be possible after strict nil rejection")
		adapter.stop()
	end)

	helpers.it("rolls back every new sibling and retains a failed filter cleanup after subscribe throws", function()
		local adapter, ctx = load_adapter({
			subscribe_throws_once = true,
			unsubscribe_throws_once = true,
		})
		local app_events = 0
		local focus_events = 0
		adapter.onAppActivate(function() app_events = app_events + 1 end)
		adapter.onFocusChange(function() focus_events = focus_events + 1 end)

		helpers.assert_eq(false, adapter.start(),
			"a required filter subscription throw must fail the whole start transaction")
		helpers.assert_eq(1, ctx.stop_calls,
			"the application watcher started by the failed transaction must be rolled back")
		helpers.assert_eq(1, ctx.unsubscribe_calls,
			"the exact partially subscribed filter must be cleaned up immediately")

		ctx.callbacks[1]("Safari", 3, {})
		ctx.filter_callbacks[1]({
			application = function() return { name = function() return "Safari" end } end,
			title = function() return "Private" end,
		})
		helpers.assert_eq(0, app_events,
			"the rolled-back application watcher callback must be generation-inert")
		helpers.assert_eq(0, focus_events,
			"the partially subscribed filter callback must be generation-inert")

		helpers.assert_eq(true, adapter.start(),
			"a later start must retry exact cleanup and then acquire a fresh pair")
		helpers.assert_eq(2, ctx.unsubscribe_calls,
			"the retained partially subscribed filter must be retried before replacement")
		helpers.assert_eq(2, ctx.new_calls,
			"recovery must construct a fresh application watcher")
		helpers.assert_eq(2, ctx.filter_new_calls,
			"recovery must construct a fresh window filter")
		adapter.stop()
	end)
end)





-- ===========================================================
-- ===========================================================
-- ======= 2/ Subscriber Failure Visibility ==================
-- ===========================================================
-- ===========================================================

helpers.describe("process_lifecycle: subscriber errors stay visible", function()
	helpers.it("logs one throwing subscriber and continues healthy siblings (process-lifecycle-callback-visible)", function()
		local adapter, ctx = load_adapter()
		local healthy_calls = 0
		adapter.onAppActivate(function() error("activation subscriber exploded") end)
		adapter.onAppActivate(function() healthy_calls = healthy_calls + 1 end)
		adapter.start()

		ctx.callbacks[1]("Safari", 3, {})

		helpers.assert_eq(1, healthy_calls,
			"one bad subscriber must not suppress later independent subscribers")
		helpers.assert_eq(1, #ctx.errors,
			"the swallowed callback throw must produce exactly one contextual ERROR")
		helpers.assert_true(ctx.errors[1]:find("activation", 1, true) ~= nil
			and ctx.errors[1]:find("subscriber exploded", 1, true) ~= nil,
			"the ERROR must identify the callback class and preserve the thrown cause")
		adapter.stop()
	end)
end)
