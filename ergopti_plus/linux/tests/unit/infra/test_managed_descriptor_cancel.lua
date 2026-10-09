--- tests/unit/infra/test_managed_descriptor_cancel.lua

--- ==============================================================================
--- MODULE: Managed Native Construction Terminal Ordering Controls
--- DESCRIPTION:
--- Distinguishes a pre-start failure with physical close debt from a started
--- child's ordinary early logical terminal. Native acknowledgements are explicit.
--- ==============================================================================

local helpers = require("tests.helpers")
local Managed = require("infra.managed_http")
local function fresh(started, cause)
	local state = { now = 0, callbacks = {}, logs = {}, starts = 0 }
	local terminal = { ok = false, status = 0, body = "", error = "curl body pipe retirement failed" }
	local native = { started = started, settled = false, listeners = {} }
	function native:is_settled() return self.settled end
	function native:on_settled(listener)
		if self.settled then listener() else self.listeners[#self.listeners + 1] = listener end
		return true
	end
	function native:request_cancel() self.cancelled = true; return false, cause end
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
			self:ack()
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

helpers.describe("managed typed construction descriptor cancellation",function()
 helpers.it("typed pre-start descriptor refusal returns false and retains revocation through physical completion",function()
  local coordinator,op,state=fresh(false,"body-descriptor-retirement-pending")
  helpers.assert_eq(coordinator.cancel("constructing"),false)
  helpers.assert_true(op._cancelled);helpers.assert_eq(op:is_settled(),false)
  helpers.assert_eq(#state.callbacks,0);state.ack()
  helpers.assert_true(op:is_settled());helpers.assert_eq(#state.callbacks,0)
 end)
 helpers.it("untyped boolean cancellation refusal preserves original delivery eligibility",function()
  local coordinator,op,state=fresh(false,"fixed-process-signal-refused")
  helpers.assert_eq(coordinator.cancel("constructing"),false)
  helpers.assert_eq(op._cancelled,false);state.ack()
  helpers.assert_true(op:is_settled());helpers.assert_eq(#state.callbacks,1)
  helpers.assert_eq(state.callbacks[1].error,"curl body pipe retirement failed")
 end)
 helpers.it("a started child cannot promote the descriptor marker into pre-start authority",function()
  local coordinator,op,state=fresh(true,"body-descriptor-retirement-pending")
  helpers.assert_eq(#state.callbacks,1);helpers.assert_eq(coordinator.cancel("constructing"),false)
  helpers.assert_eq(op._cancelled,false);state.ack()
  helpers.assert_true(op:is_settled());helpers.assert_eq(#state.callbacks,1)
 end)
end)
