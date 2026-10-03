--- tests/unit/adapters/test_keyboard_source_probe.lua

--- ==============================================================================
--- MODULE: Native Keyboard Source Proof Ownership Tests
--- DESCRIPTION:
--- Proves strict native receipt validation and acknowledged asynchronous task
--- and timer cleanup. Translation itself is qualified by the Swift native tests;
--- these doubles model refusal, pending SIGTERM, and synchronous re-entry.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local MODULES = {
	"adapters.keyboard_source_probe", "adapters.shell_runner", "adapters.timer_scheduler",
	"adapters.json_codec", "platform.remap.lease_helper", "infra.timings", "infra.logger",
}
local SOURCE = "com.apple.keylayout.US"

--- Builds owned task/timer doubles without assertions in production callbacks.
--- @param options table|nil Hostile native behavior.
--- @return table context Controls and observations.
local function fixture(options)
	options = options or {}
	local context = { source = SOURCE, calls = {}, results = {}, task_observers = {}, timer_observers = {} }
	local task_settled = false
	local task = {}
	local timer = { timer = {} }
	local completion
	local timeout
	local function notify(observers)
		local snapshot = {}
		for index, observer in ipairs(observers) do snapshot[index] = observer end
		for _, observer in ipairs(snapshot) do observer() end
	end
	function context.finish(value, exit_code)
		task_settled = true
		completion(exit_code or 0, type(value) == "string" and value or Json.encode(value))
		notify(context.task_observers)
	end
	function context.expire() timeout() end
	function context.settle_deadline()
		timer.timer = nil
		notify(context.timer_observers)
	end
	function task.isSettled() return task_settled end
	function task.onSettled(observer)
		if options.task_observer_refusal then return false end
		context.task_observers[#context.task_observers + 1] = observer
		if task_settled then observer() end
		return true
	end
	function task.start()
		context.calls.started = (context.calls.started or 0) + 1
		if options.start_throw then error("native start failed after mutation") end
		if options.start_refusal then return false end
		if options.complete_in_start then context.finish(context.receipt()) end
		return true
	end
	function task.terminate()
		context.calls.terminated = (context.calls.terminated or 0) + 1
		if context.terminate_refusal == "throw" then error("native termination refused") end
		if context.terminate_refusal == "false" then return false, "refused" end
		if context.terminate_refusal == "nil" then return nil end
		if context.terminate_pending then return true, "pending" end
		task_settled = true
		notify(context.task_observers)
		return true, "settled"
	end
	function context.receipt()
		return {
			version = 1, source_id = SOURCE, keyboard_type = 40,
			levels = { { code = 41, text = ";", dead = false, direct = true } },
		}
	end
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = { sec = function() return 10 end }
	package.loaded["platform.remap.lease_helper"] = {
		resolve = function()
			if options.helper_refusal then return nil, "exact helper unavailable" end
			return "/signed/ErgoptiPlus", nil, { ERGOPTI_LAUNCHER_EXECUTABLE = "/signed/ErgoptiPlus" }
		end,
	}
	package.loaded["adapters.json_codec"] = { decode = Json.decode }
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args, callback, chunks, environment)
			context.calls.spawned = (context.calls.spawned or 0) + 1
			context.executable, context.args, context.chunks, context.environment = executable, args, chunks, environment
			completion = callback
			if options.constructor_completion then completion(0, Json.encode(context.receipt())) end
			return task
		end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			context.delay, timeout = delay, callback
			if options.timer_in_constructor then callback() end
			return timer, not options.timer_start_refusal
		end,
		onSettled = function(handle, observer)
			if options.timer_observer_refusal then return false end
			context.timer_observers[#context.timer_observers + 1] = observer
			if handle.timer == nil then observer() end
			return true
		end,
		cancel = function(handle)
			context.calls.timer_cancelled = (context.calls.timer_cancelled or 0) + 1
			if context.timer_refusal == "throw" then error("native timer stop refused") end
			if context.timer_refusal == "false" then return false end
			if context.timer_refusal == "nil" then return nil end
			handle.timer = nil
			notify(context.timer_observers)
			return true
		end,
	}
	context.probe = helpers.load_with_stubs("adapters.keyboard_source_probe", {
		keycodes = {
			currentSourceID = function()
				if options.source_throw then error("selected source read refused") end
				return context.source
			end,
			currentLayout = function()
				context.calls.layout_fallback = true
				return "underlying US layout"
			end,
		},
	})
	function context.request(request)
		return context.probe.request(request or { source_id = SOURCE, codes = { 41 } }, function(receipt, reason)
			context.results[#context.results + 1] = { receipt = receipt, reason = reason }
		end)
	end
	return context
end

helpers.describe("native keyboard source proof ownership", function()
	helpers.it("uses numeric argv and exact helper identity for an acknowledged receipt", function()
		helpers.with_stub_scope(MODULES, function()
			local context = fixture()
			local operation = context.request()
			helpers.assert_eq(context.args, { "--keyboard-source-probe", SOURCE, "41" })
			helpers.assert_eq(context.environment.ERGOPTI_LAUNCHER_EXECUTABLE, context.executable)
			helpers.assert_eq(context.chunks, nil)
			helpers.assert_eq(false, operation.is_settled())
			context.finish(context.receipt())
			helpers.assert_true(operation.is_settled())
			helpers.assert_eq(#context.results, 1)
			helpers.assert_eq(context.results[1].receipt.levels[1].text, ";")
			helpers.assert_eq(context.results[1].reason, nil)
			helpers.assert_true(operation.cancel())
		end)
	end)

	helpers.it("retains explicit dead and empty levels instead of inventing direct output", function()
		for _, level in ipairs({
			{ code = 41, text = "^", dead = true, direct = false },
			{ code = 41, text = "", dead = false, direct = false },
		}) do
			helpers.with_stub_scope(MODULES, function()
				local context = fixture()
				context.request()
				local receipt = context.receipt()
				receipt.levels[1] = level
				context.finish(receipt)
				helpers.assert_eq(context.results[1].receipt.levels[1], level)
			end)
		end
	end)

	helpers.it("never falls back to an underlying layout when the selected source cannot be read", function()
		for _, options in ipairs({ {}, { source_throw = true } }) do
			helpers.with_stub_scope(MODULES, function()
				local context = fixture(options)
				context.source = nil
				local operation = context.request()
				helpers.assert_true(operation.is_settled())
				helpers.assert_eq(context.calls.layout_fallback, nil)
				helpers.assert_eq(context.calls.spawned, nil)
				helpers.assert_eq(context.results[1].receipt, nil)
			end)
		end
	end)

	helpers.it("rejects missing dead proof, wrong identities and contradictory receipts", function()
		local corruptions = {
			function(receipt) receipt.levels[1].dead = nil end,
			function(receipt) receipt.levels[1].dead = true end,
			function(receipt) receipt.levels[1].code = 42 end,
			function(receipt) receipt.source_id = "other.source" end,
			function(receipt) receipt.version = 2 end,
			function(receipt) receipt.keyboard_type = -1 end,
			function(receipt) receipt.levels[2] = receipt.levels[1] end,
			function(receipt) receipt.levels.extra = receipt.levels[1] end,
			function(receipt) receipt.alias = "source.json" end,
			function(receipt) receipt.levels[1].direct = "true" end,
		}
		for _, corrupt in ipairs(corruptions) do
			helpers.with_stub_scope(MODULES, function()
				local context = fixture()
				local operation = context.request()
				local receipt = context.receipt()
				corrupt(receipt)
				context.finish(receipt)
				helpers.assert_true(operation.is_settled())
				helpers.assert_eq(context.results[1].receipt, nil)
				helpers.assert_eq(context.results[1].reason, "invalid_receipt")
			end)
		end
	end)

	helpers.it("rejects malformed and oversized native JSON and nonzero exit", function()
		for _, response in ipairs({ "null", "{broken", string.rep("x", 65537) }) do
			helpers.with_stub_scope(MODULES, function()
				local context = fixture()
				context.request()
				context.finish(response)
				helpers.assert_eq(context.results[1].receipt, nil)
			end)
		end
		helpers.with_stub_scope(MODULES, function()
			local context = fixture()
			context.request()
			context.finish(context.receipt(), 70)
			helpers.assert_eq(context.results[1].receipt, nil)
		end)
	end)

	helpers.it("rejects invalid requests before any native acquisition", function()
		for _, request in ipairs({
			{ source_id = SOURCE, codes = {} },
			{ source_id = SOURCE, codes = { 41, 41 } },
			{ source_id = SOURCE, codes = { -1 } },
			{ source_id = SOURCE, codes = { 128 } },
			{ source_id = SOURCE, codes = { 1.5 } },
			{ source_id = SOURCE, codes = { [2] = 41 } },
			{ source_id = SOURCE, codes = { 41 }, alias = "dictionary" },
		}) do
			helpers.with_stub_scope(MODULES, function()
				local context = fixture()
				local operation = context.request(request)
				helpers.assert_true(operation.is_settled())
				helpers.assert_eq(context.calls.spawned, nil)
				helpers.assert_eq(context.results[1].reason, "invalid_request")
			end)
		end
	end)

	helpers.it("snapshots caller data and refuses a source change before delivery", function()
		helpers.with_stub_scope(MODULES, function()
			local context = fixture()
			local request = { source_id = SOURCE, codes = { 41 } }
			context.request(request)
			request.codes[1], request.source_id = 42, "mutated"
			context.source = "com.apple.keylayout.French"
			context.finish(context.receipt())
			helpers.assert_eq(context.args[3], "41")
			helpers.assert_eq(context.results[1].receipt, nil)
			helpers.assert_eq(context.results[1].reason, "source_changed")
		end)
	end)

	helpers.it("retains pending SIGTERM and fences a late successful result", function()
		helpers.with_stub_scope(MODULES, function()
			local context = fixture()
			local operation = context.request()
			context.terminate_pending = true
			local settled = 0
			operation.on_settled(function() settled = settled + 1 end)
			helpers.assert_eq(false, operation.cancel())
			helpers.assert_eq(false, operation.is_settled())
			helpers.assert_eq(#context.results, 0)
			context.finish(context.receipt())
			helpers.assert_eq(#context.results, 1)
			helpers.assert_eq(context.results[1].receipt, nil)
			helpers.assert_eq(context.results[1].reason, "cancelled")
			helpers.assert_eq(settled, 1)
			helpers.assert_true(operation.cancel())
		end)
	end)

	helpers.it("retries false, nil and throwing native termination without losing the handle", function()
		for _, refusal in ipairs({ "false", "nil", "throw" }) do
			helpers.with_stub_scope(MODULES, function()
				local context = fixture()
				local operation = context.request()
				context.terminate_refusal = refusal
				helpers.assert_eq(false, operation.cancel())
				helpers.assert_eq(#context.results, 0)
				context.terminate_refusal = nil
				helpers.assert_true(operation.cancel())
				helpers.assert_eq(context.calls.terminated, 2)
				helpers.assert_eq(context.results[1].reason, "cancelled")
			end)
		end
	end)

	helpers.it("joins deadline cleanup refusal before publishing or cancelling the receipt", function()
		for _, refusal in ipairs({ "false", "nil", "throw" }) do
			helpers.with_stub_scope(MODULES, function()
				local context = fixture()
				local operation = context.request()
				context.timer_refusal = refusal
				context.finish(context.receipt())
				helpers.assert_eq(false, operation.is_settled())
				helpers.assert_eq(#context.results, 0)
				helpers.assert_eq(false, operation.cancel())
				context.timer_refusal = nil
				helpers.assert_true(operation.cancel())
				helpers.assert_eq(context.results[1].receipt, nil)
				helpers.assert_eq(context.results[1].reason, "cancelled")
			end)
		end
	end)

	helpers.it("publishes retained native success after autonomous deadline settlement", function()
		helpers.with_stub_scope(MODULES, function()
			local context = fixture()
			local operation = context.request()
			context.timer_refusal = "false"
			context.finish(context.receipt())
			helpers.assert_eq(#context.results, 0)
			context.settle_deadline()
			helpers.assert_true(operation.is_settled())
			helpers.assert_eq(#context.results, 1)
			helpers.assert_eq(context.results[1].receipt.levels[1].text, ";")
			helpers.assert_eq(context.results[1].reason, nil)
		end)
	end)

	helpers.it("joins timeout termination and refuses callbacks delivered during acquisition", function()
		helpers.with_stub_scope(MODULES, function()
			local context = fixture()
			local operation = context.request()
			context.terminate_pending = true
			context.expire()
			helpers.assert_eq(false, operation.is_settled())
			context.finish(context.receipt())
			helpers.assert_eq(context.results[1].reason, "timeout")
		end)
		for _, options in ipairs({ { constructor_completion = true }, { timer_in_constructor = true } }) do
			helpers.with_stub_scope(MODULES, function()
				local context = fixture(options)
				local operation = context.request()
				helpers.assert_true(operation.is_settled())
				helpers.assert_eq(context.calls.started, nil)
				helpers.assert_eq(context.results[1].receipt, nil)
			end)
		end
	end)

	helpers.it("handles synchronous native completion after a committed start exactly once", function()
		helpers.with_stub_scope(MODULES, function()
			local context = fixture({ complete_in_start = true })
			local operation = context.request()
			helpers.assert_true(operation.is_settled())
			helpers.assert_eq(#context.results, 1)
			helpers.assert_eq(context.results[1].receipt.levels[1].text, ";")
			helpers.assert_eq(context.results[1].reason, nil)
		end)
	end)

	helpers.it("rejects unacknowledged acquisition without orphaning task or timer", function()
		for _, options in ipairs({
			{ helper_refusal = true }, { task_observer_refusal = true },
			{ timer_observer_refusal = true }, { timer_start_refusal = true },
			{ start_refusal = true }, { start_throw = true },
		}) do
			helpers.with_stub_scope(MODULES, function()
				local context = fixture(options)
				local operation = context.request()
				helpers.assert_true(operation.is_settled())
				helpers.assert_eq(#context.results, 1)
				helpers.assert_eq(context.results[1].receipt, nil)
			end)
		end
	end)

	helpers.it("contains consumer callback errors while settlement remains observable", function()
		helpers.with_stub_scope(MODULES, function()
			local context = fixture()
			local operation = context.probe.request({ source_id = SOURCE, codes = { 41 } }, function()
				error("consumer failed after result delivery")
			end)
			local observed = false
			operation.on_settled(function() observed = true end)
			context.finish(context.receipt())
			helpers.assert_true(operation.is_settled())
			helpers.assert_true(observed)
		end)
	end)
end)
