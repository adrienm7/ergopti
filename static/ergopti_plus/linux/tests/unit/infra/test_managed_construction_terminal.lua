--- tests/unit/infra/test_managed_construction_terminal.lua

--- ==============================================================================
--- MODULE: Managed Native Construction Terminal Ordering Controls
--- DESCRIPTION:
--- Distinguishes a pre-start failure with physical close debt from a started
--- child's ordinary early logical terminal. Native acknowledgements are explicit.
--- ==============================================================================

local helpers = require("tests.helpers")
local Managed = require("infra.managed_http")
local function fresh(started, hold_deadline)
	local state = { now = 0, callbacks = {}, logs = {}, starts = 0 }
	local terminal = { ok = false, status = 0, body = "", error = "curl body pipe retirement failed" }
	local native = { started = started, settled = false, listeners = {} }
	function native:is_settled() return self.settled end
	function native:on_settled(listener)
		if self.settled then listener() else self.listeners[#self.listeners + 1] = listener end
		return true
	end
	function native:request_cancel() self.cancelled = true; return true end
	local function deadline(_, expired)
		state.deadline_expired = expired
		local token = { started = true, settled = false, listeners = {} }
		function token:is_settled() return self.settled end
		function token:on_settled(listener)
			if self.settled then listener() else self.listeners[#self.listeners + 1] = listener end
			return true
		end
		function token:ack()
			self.settled = true
			for _, listener in ipairs(self.listeners) do listener() end
		end
		function token:cancel()
			self.cancelled = true
			if not hold_deadline then self:ack() end
			return true
		end
		state.timer = token
		return token
	end
	local coordinator = assert(Managed.new({
		policy = {
			route = function() return { mode = "direct" } end,
			selection = function() return { { kind = "direct" } } end,
			can_retry = function() return false end,
		},
		proxy = { lookup_owned = function() error("direct requests must not acquire GIO") end },
		curl = function(_, _, _, options, _, complete)
			state.starts = state.starts + 1
			state.complete = complete
			options.on_native_terminal(terminal)
			return native
		end,
		deadline = deadline, clock = function() return state.now end,
		environment = function() return {} end,
		report = function(value) state.logs[#state.logs + 1] = value end,
	}))
	function state.ack()
		native.settled = true
		state.complete(terminal)
		for _, listener in ipairs(native.listeners) do listener() end
	end
	local operation = coordinator.start("http://127.0.0.1:9000/fixed", {}, nil,
		{ owner = "constructing", timeout_ms = 1000, method = "GET", buffered = true, owned_api = false }, nil,
		function(result) state.callbacks[#state.callbacks + 1] = result end)
	return coordinator, operation, state
end

helpers.describe("construction logical and physical boundaries", function()
	helpers.it("pre-start body refusal publishes no callback while its exact close debt remains", function()
		local _, operation, state = fresh(false)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.callbacks, 0)
		state.ack()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#state.callbacks, 1)
		helpers.assert_eq(state.callbacks[1].error, "curl body pipe retirement failed")
	end)
	helpers.it("caller cancellation suppresses the physically completed pre-start failure", function()
		local coordinator, operation, state = fresh(false)
		helpers.assert_eq(#state.callbacks, 0)
		helpers.assert_true(coordinator.cancel("constructing"))
		helpers.assert_eq(operation:is_settled(), false)
		state.ack()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#state.callbacks, 0)
	end)
	helpers.it("a started child retains early logical failure and later exact physical retirement", function()
		local _, operation, state = fresh(true)
		helpers.assert_true(operation.started)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.callbacks, 1)
		helpers.assert_eq(state.callbacks[1].error, "curl body pipe retirement failed")
		state.ack()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#state.callbacks, 1)
	end)
	helpers.it("a delayed original deadline cannot publish over a pre-start terminal failure", function()
		local _, operation, state = fresh(false)
		helpers.assert_true(state.timer.cancelled)
		state.now = 1001
		state.deadline_expired()
		helpers.assert_eq(#state.callbacks, 0)
		helpers.assert_eq(operation:is_settled(), false)
		state.ack()
		helpers.assert_eq(#state.callbacks, 1)
		helpers.assert_eq(state.callbacks[1].error, "curl body pipe retirement failed")
	end)
	helpers.it("pre-start completion retains its own deadline close debt too", function()
		local _, operation, state = fresh(false, true)
		helpers.assert_true(state.timer.cancelled)
		state.ack()
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.callbacks, 0)
		state.timer:ack()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#state.callbacks, 1)
		helpers.assert_eq(state.callbacks[1].error, "curl body pipe retirement failed")
	end)

	for _, started in ipairs({ false, true }) do
		local native_started = started
		helpers.it("terminal regular cleanup debt refuses owned metadata before evaluation (started=" .. tostring(started) .. ")", function()
			local coordinator, incumbent, state = fresh(native_started)
			local metadata, result = 0, nil
			local refused = coordinator.start("http://127.0.0.1:9000/next", {}, nil,
				{ owner = "constructing", timeout_ms = 1000, method = "GET", buffered = true, owned_api = true }, nil,
				function(value) result = value end,
				{ prepare = function() metadata = metadata + 1; error("must not prepare terminal debt") end })
			helpers.assert_eq(refused.started, false)
			helpers.assert_true(refused:is_settled())
			helpers.assert_eq(result.error, "previous request cleanup pending")
			helpers.assert_eq(metadata, 0)
			helpers.assert_eq(state.starts, 1)
			helpers.assert_eq(incumbent:is_settled(), false)
			state.ack()
			helpers.assert_true(incumbent:is_settled())
		end)
	end

end)
