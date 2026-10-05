--- tests/unit/infra/test_managed_http_deadline.lua

--- ==============================================================================
--- MODULE: Independent Managed HTTP Deadline Ownership Controls
--- DESCRIPTION:
--- Explicit native arming, stop and closure ACKs exercise the actual deadline
--- ledger. The incoming owner-authored relative timer helper stays byte exact.
--- Logical expiry and physical retirement remain independently observable.
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local driver_root = helpers.driver_root()

--- Loads the production deadline ledger with independent native receipts.
--- @param config table|nil
--- @return table module, table state
local function fresh(config)
	config = config or {}
	local state = { time = config.time or 0, handles = {}, closes = {}, logs = {}, refreshed = 0 }
	local uv = {}
	function uv.new_timer()
		if config.allocate_failure then return nil end
		local value = { closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end
	function uv.update_time() state.refreshed = state.refreshed + 1 end
	function uv.timer_start(timer, timeout, _, callback)
		state.timer, state.timeout, state.callback = timer, timeout, callback
		if config.arm_failure then return nil, "EINVAL" end
		if config.missing_ack then return nil end
		if config.throw_arm then error("private arming detail") end
		return 0
	end
	function uv.timer_stop()
		if state.refuse_stop then return nil, "EINVAL" end
		return 0
	end
	function uv.is_closing(timer) return timer.closing end
	function uv.close(timer, callback)
		if state.refuse_close then return nil, "EPERM" end
		timer.closing = true
		state.closes[#state.closes + 1] = { timer = timer, callback = callback }
	end
	function state.ack()
		for _, receipt in ipairs(state.closes) do
			if not receipt.acknowledged then receipt.acknowledged = true; receipt.callback() end
		end
	end
	local names = { "luv", "infra.monotonic", "logger.shim" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local ok, module = pcall(function()
	package.loaded.luv = uv
	package.loaded["infra.monotonic"] = { now_ms = function() return state.time end }
	package.loaded["logger.shim"] = { error = function(_, message) state.logs[#state.logs + 1] = message end }
	return dofile(driver_root .. "/infra/managed_http_deadline.lua")
	end)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(module, 0) end
	return module, state
end

helpers.describe("managed_http_deadline: independent native receipt ledger", function()
	helpers.it("uses original remaining budget and exact refreshed native timer arming", function()
		local module, state = fresh({ time = 175 })
		local token = module.start(1000, function() end)
		helpers.assert_true(token.started)
		helpers.assert_eq(state.timeout, 825)
		helpers.assert_eq(state.refreshed, 1)
		helpers.assert_true(token:cancel())
		helpers.assert_true(not token:is_settled())
		state.ack()
		helpers.assert_true(token:is_settled())
	end)
	helpers.it("notifies logical expiry before any native close acknowledgement", function()
		local module, state = fresh()
		local expired, settled = 0, 0
		local token = module.start(1000, function() expired = expired + 1 end)
		token:on_settled(function() settled = settled + 1 end)
		state.callback()
		helpers.assert_eq(expired, 1)
		helpers.assert_eq(settled, 0)
		helpers.assert_true(not token:is_settled())
		state.ack()
		helpers.assert_eq(settled, 1)
		state.callback(); state.ack()
		helpers.assert_eq(expired, 1)
		helpers.assert_eq(settled, 1)
	end)
	for _, config in ipairs({ { arm_failure = true }, { missing_ack = true }, { throw_arm = true } }) do
		local refusal = config
		helpers.it("retains precise failed arming debt " .. (config.arm_failure and "error" or (config.missing_ack and "absent ACK" or "exception")), function()
			local module, state = fresh(refusal)
			local callbacks = 0
			local token = module.start(1000, function() callbacks = callbacks + 1 end)
			helpers.assert_true(not token.started)
			helpers.assert_true(not token:is_settled())
			helpers.assert_eq(#state.handles, 1)
			helpers.assert_eq(#state.closes, 1)
			state.ack()
			helpers.assert_true(token:is_settled())
			helpers.assert_eq(callbacks, 0)
		end)
	end
	helpers.it("retries refused closure on exactly the same owned timer", function()
		local module, state = fresh()
		local token = module.start(1000, function() end)
		state.refuse_close = true
		helpers.assert_true(not token:cancel())
		helpers.assert_true(not token:is_settled())
		state.refuse_close = false
		helpers.assert_true(token:cancel())
		helpers.assert_eq(#state.handles, 1)
		helpers.assert_eq(#state.closes, 1)
		state.ack()
		helpers.assert_true(token:is_settled())
	end)
	helpers.it("retains failed stop ACK and fences a stale timer callback", function()
		local module, state = fresh()
		local callbacks = 0
		local token = module.start(1000, function() callbacks = callbacks + 1 end)
		state.refuse_stop = true
		helpers.assert_true(not token:cancel())
		helpers.assert_eq(#state.closes, 0)
		state.callback()
		helpers.assert_eq(callbacks, 0)
		state.refuse_stop = false
		helpers.assert_true(token:cancel())
		state.ack()
		helpers.assert_true(token:is_settled())
	end)
	for _, timing in ipairs({ "before", "after" }) do
		local registered = timing
		helpers.it("reports a throwing listener registered " .. timing .. " retirement without private exception", function()
			local module, state = fresh()
			local token = module.start(1000, function() end)
			local function listener() error("private callback metadata") end
			if registered == "before" then token:on_settled(listener) end
			token:cancel(); state.ack()
			if registered == "after" then token:on_settled(listener) end
			helpers.assert_eq(state.logs, { "Deadline settlement callback raised." })
		end)
	end
	helpers.it("refuses unavailable allocation without inventing physical debt", function()
		local module, state = fresh({ allocate_failure = true })
		local token = module.start(1000, function() end)
		helpers.assert_true(not token.started and token:is_settled())
		helpers.assert_eq(#state.handles, 0)
		helpers.assert_eq(#state.closes, 0)
	end)
end)
return helpers
