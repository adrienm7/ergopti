--- tests/support/adapters/network/http_client_timeout_transaction_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_http_client_timeout_transaction
--- DESCRIPTION:
--- Prelude shared by the test_http_client_timeout_transaction_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================================
-- =====================================================
-- ======= 1/ Transactional Test Harness ===============
-- =====================================================
-- =====================================================

--- Loads HttpClient and the real TimerScheduler against one native timer stub.
--- @param timer_stub table Native timer API double.
--- @param http_stub table Native HTTP API double.
--- @param options table|nil Optional constructor configuration.
--- @return table client A fresh HttpClient instance.
--- @return table scheduler The freshly loaded TimerScheduler adapter.
local function load_client(timer_stub, http_stub, options)
	package.loaded["adapters.http_client"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	local HttpClient = helpers.load_with_stubs("adapters.http_client", {
		timer = timer_stub,
		http = http_stub,
	})
	return HttpClient.new(options), package.loaded["adapters.timer_scheduler"]
end

--- Builds a native timer whose start behavior is selected by the test.
--- @param start_mode string One of success, nil, false, or throw.
--- @return table timer_stub Native timer API double.
--- @return table state Observable constructor and stop state.
local function make_single_timer(start_mode)
	local state = {
		construct_calls = 0,
		delays = {},
		stop_calls = 0,
		native_callback = nil,
	}
	local timer_stub = {
		doAfter = function()
			error("HttpClient must not bypass TimerScheduler with a raw timeout")
		end,
		secondsSinceEpoch = function() return 0 end,
	}
	function timer_stub.new(delay, callback)
		state.construct_calls = state.construct_calls + 1
		state.delays[#state.delays + 1] = delay
		state.native_callback = callback
		local native = {}
		function native:start()
			if start_mode == "throw" then error("synthetic start failure") end
			if start_mode == "false" then return false end
			if start_mode == "nil" then return nil end
			return self
		end
		function native:stop()
			state.stop_calls = state.stop_calls + 1
			return self
		end
		state.native = native
		return native
	end
	return timer_stub, state
end

--- Builds an HTTP double that records dispatch without completing it.
--- @return table http_stub Native HTTP API double.
--- @return table state Observable request state.
local function make_http_stub()
	local state = { post_calls = 0, get_calls = 0, callbacks = {} }
	local http_stub = {}
	function http_stub.asyncPost(_url, _body, _headers, callback)
		state.post_calls = state.post_calls + 1
		state.callbacks[#state.callbacks + 1] = callback
		return nil
	end
	function http_stub.asyncGet(_url, _headers, callback)
		state.get_calls = state.get_calls + 1
		state.callbacks[#state.callbacks + 1] = callback
		return nil
	end
	return http_stub, state
end

--- Builds a faithful native timer whose stop refusal leaves it running.
--- @param initial_stop_mode string One of success, false, nil, or throw.
--- @return table timer_stub Native timer API double.
--- @return table state Observable timer identities and lifecycle calls.
local function make_exact_stop_timer(initial_stop_mode)
	local state = {
		construct_calls = 0,
		stop_calls = 0,
		callbacks = {},
		natives = {},
		stop_handles = {},
		stop_mode = initial_stop_mode,
	}
	local timer_stub = {
		doAfter = function()
			error("HttpClient must not bypass TimerScheduler with a raw timeout")
		end,
		secondsSinceEpoch = function() return 0 end,
	}
	function timer_stub.new(_, callback)
		state.construct_calls = state.construct_calls + 1
		state.callbacks[#state.callbacks + 1] = callback
		local running = false
		local native = {}
		function native:start()
			running = true
			return self
		end
		function native:running()
			return running
		end
		function native:stop()
			state.stop_calls = state.stop_calls + 1
			state.stop_handles[#state.stop_handles + 1] = self
			if state.stop_mode == "throw" then error("synthetic stop failure") end
			if state.stop_mode == "false" then return false end
			if state.stop_mode == "nil" then return nil end
			running = false
			return self
		end
		state.natives[#state.natives + 1] = native
		return native
	end
	return timer_stub, state
end

--- Builds an HTTP double whose first task exposes exact cancellation outcomes.
--- @param initial_cancel_mode string One of success, false, nil, or throw.
--- @return table http_stub Native HTTP API double.
--- @return table state Observable dispatch, callback, and task identity state.
local function make_exact_task_http(initial_cancel_mode)
	local state = {
		post_calls = 0,
		callbacks = {},
		cancel_handles = {},
		cancel_mode = initial_cancel_mode,
	}
	local first_task = {}
	function first_task:cancel()
		state.cancel_handles[#state.cancel_handles + 1] = self
		if state.cancel_mode == "throw" then error("synthetic task cancel failure") end
		if state.cancel_mode == "false" then return false end
		if state.cancel_mode == "nil" then return nil end
		return true
	end
	state.first_task = first_task

	local http_stub = {}
	function http_stub.asyncPost(_url, _body, _headers, callback)
		state.post_calls = state.post_calls + 1
		state.callbacks[#state.callbacks + 1] = callback
		if state.post_calls == 1 then return first_task end
		return { cancel = function() return true end }
	end
	return http_stub, state
end

return {
	load_client = load_client,
	make_exact_stop_timer = make_exact_stop_timer,
	make_exact_task_http = make_exact_task_http,
	make_http_stub = make_http_stub,
	make_single_timer = make_single_timer,
}
