--- tests/unit/infra/test_managed_http_cancelled_admission.lua

--- tests/unit/infra/test_cancelled_managed_admission.lua

--- ==============================================================================
--- MODULE: Synchronous Managed Admission Cancellation Control
--- DESCRIPTION:
--- A predecessor settlement listener cancels its queued successor during native
--- cancellation. The exact coordinator must not acquire GIO or arm a new timer
--- after that synchronous cancellation, regardless of the successor's route.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")
local driver_root = helpers.driver_root()
local module = dofile(driver_root .. "/infra/managed_http.lua")
local policy_module = dofile(assert(Paths.shared("lua/network/proxy_policy.lua")))
local file = assert(io.open(assert(Paths.shared("modules/network/proxy_policy.json")), "rb"))
local data = Json.decode(file:read("*a")); file:close()

helpers.describe("managed_http: synchronous cancelled successor admission", function()
	helpers.it("never acquires system resolution after predecessor listener cancels an adopted queued successor", function()
		local state = { curls = {}, proxies = {}, timers = {}, reports = {} }
		local function child(kind)
			local item = { settled = false, listeners = {} }
			local operation = { started = true }
			local function cancel()
				if item.settled then return true end
				item.settled = true
				for _, listener in ipairs(item.listeners) do listener() end
				return true
			end
			if kind == "proxy" then
				function operation.is_settled() return item.settled end
				operation.cancel = cancel
				function operation.on_settled(listener) item.listeners[#item.listeners + 1] = listener; return true end
			else
				function operation:is_settled() return item.settled end
				operation.request_cancel, operation.cancel = cancel, cancel
				function operation:on_settled(listener)
					if item.settled then listener() else item.listeners[#item.listeners + 1] = listener end
					return true
				end
			end
			return operation, item
		end
		local coordinator = assert(module.new({
			policy = assert(policy_module.new(data)), clock = function() return 0 end,
			environment = function() return {} end,
			report = function(message) state.reports[#state.reports + 1] = message end,
			deadline = function()
				local operation, item = child("timer")
				state.timers[#state.timers + 1] = item
				return operation
			end,
			curl = function()
				local operation, item = child("curl")
				state.curls[#state.curls + 1] = item
				return operation
			end,
			proxy = { lookup_owned = function()
				local operation, item = child("proxy")
				state.proxies[#state.proxies + 1] = item
				return operation
			end },
		}))
		local options = { owner = "synchronous-owner", timeout_ms = 1000, owned_api = false }
		local callbacks = 0
		local first = coordinator.start("http://127.0.0.1/models", {}, nil, options, nil, function() callbacks = callbacks + 1 end)
		local cancel_receipt
		first:on_settled(function() cancel_receipt = coordinator.cancel("synchronous-owner") end)
		local successor = coordinator.start("https://corporate.invalid/private", {}, nil, options, nil, function() callbacks = callbacks + 1 end)
		helpers.assert_eq(cancel_receipt, true)
		helpers.assert_eq(#state.proxies, 0, "cancelled successor cannot acquire GIO")
		helpers.assert_eq(#state.timers, 1, "cancelled successor cannot arm a new deadline owner")
		helpers.assert_true(first:is_settled() and successor:is_settled())
		helpers.assert_eq(callbacks, 0)
		helpers.assert_true(not coordinator.is_active("synchronous-owner"))
		for _, item in ipairs(state.timers) do helpers.assert_true(item.settled) end
		for _, item in ipairs(state.curls) do helpers.assert_true(item.settled) end
	end)
end)
return helpers
