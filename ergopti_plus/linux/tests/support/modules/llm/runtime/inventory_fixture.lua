--- tests/support/modules/llm/runtime/inventory_fixture.lua

--- ==============================================================================
--- MODULE: Inventory Acquisition Fixture
--- DESCRIPTION:
--- Controls only the inventory's owned defer and HTTP boundaries. Actual Engine
--- runtime response admission stays in the surrounding managed service graph.
--- No native process or timer cleanup is proven by these controlled ACKs.
--- ==============================================================================

local M = {}

--- Installs exact inventory capabilities before the actual Engine constructor.
--- @param world table Managed runtime fixture state.
function M.install(world)
	world.inventory_defers, world.inventory_requests = {}, {}
	local function operation(kind, done)
		local op = { started = true, closed = false, listeners = {}, kind = kind }
		function op:is_settled() return self.closed end
		function op:settled_result() return self.closed and self.result or nil end
		function op:on_settled(listener)
			if world.inventory_notify_refused == kind then return false end
			if self.closed then listener() else self.listeners[#self.listeners + 1] = listener end
			return true
		end
		function op:close()
			if self.closed then return end
			self.closed = true
			local listeners = self.listeners; self.listeners = {}
			for _, listener in ipairs(listeners) do listener() end
		end
		function op:cancel()
			world.inventory_cancels = (world.inventory_cancels or 0) + 1
			self.cancelled = true
			if world.inventory_cancel_ok ~= false and world.inventory_hold_cancel ~= kind then self:close() end
			return self.closed
		end
		function op:answer(result)
			self.result = result
			if done then done(result) end
			if world.inventory_hold_settlement ~= kind then self:close() end
		end
		return op
	end
	package.loaded["modules.llm.model_inventory"] = nil
	package.loaded["infra.managed_http_deadline"] = { start = function(instant, done)
		local op = operation("defer", done)
		op.instant = instant
		world.inventory_defers[#world.inventory_defers + 1] = op
		if world.inventory_during_defer then world.inventory_during_defer(op) end
		return op
	end }
	local Http = package.loaded["adapters.http_client"]
	local original = Http.get_owned
	Http.get_owned = function(url, headers, options, done)
		if options.owner ~= "ollama_model_inventory" then return original(url, headers, options, done) end
		local op = operation("http", done)
		op.url, op.headers, op.options = url, headers, options
		world.inventory_requests[#world.inventory_requests + 1] = op
		if world.inventory_during_http then world.inventory_during_http(op) end
		return op
	end
	function world:inventory_defer()
		local op = assert(self.inventory_defers[#self.inventory_defers], "inventory defer was not reserved")
		op:answer()
		return op
	end
	function world:inventory_answer(models)
		local Json = require("json")
		local rows = {}
		for _, model in ipairs(models) do rows[#rows + 1] = { name = model } end
		local body = #rows == 0 and '{"models":[]}' or Json.encode({ models = rows })
		local op = assert(self.inventory_requests[#self.inventory_requests], "inventory HTTP was not dispatched")
		op:answer({ ok = true, status = 200, body = body })
		return op
	end
end

return M
