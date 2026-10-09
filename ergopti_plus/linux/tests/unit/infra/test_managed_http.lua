--- tests/unit/infra/test_managed_http.lua

--- ==============================================================================
--- MODULE: Managed HTTP Public Ownership Regression Controls
--- DESCRIPTION:
--- Uses independent native child acknowledgements to prove composite ownership,
--- ordered relay, shrinking deadlines and unchanged logical/physical meanings.
--- Current curl engine assertions remain in their actual production module.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")
local driver_root = helpers.driver_root()
local module = dofile(driver_root .. "/infra/managed_http.lua")
local policy_module = dofile(assert(Paths.shared("lua/network/proxy_policy.lua")))
local file = assert(io.open(assert(Paths.shared("modules/network/proxy_policy.json")), "rb"))
local data = Json.decode(file:read("*a")); file:close()

--- Creates independent native-child controls with separate settlement receipts.
--- @return table coordinator, table state
local function fresh()
	local state = { time = 0, proxy = {}, curls = {}, reports = {}, environment = {} }
	local function child(kind, callback, options)
		local item = { settled = false, cancelled = false, listeners = {}, callback = callback, options = options }
		local operation = { started = true }
		if kind == "proxy" then
			function operation.is_settled() return item.settled end
			function operation.cancel()
				if state.refuse_cancel and options.logical_cancel then return false end
				item.cancelled = true
				return not state.refuse_cancel
			end
			function operation.on_settled(listener) item.listeners[#item.listeners + 1] = listener; return true end
		else
			function operation:is_settled() return item.settled end
			function operation:request_cancel()
				if state.refuse_cancel and options.owned_api == false then return false end
				item.cancelled = true
				return not state.refuse_cancel
			end
			function operation:on_settled(listener) item.listeners[#item.listeners + 1] = listener; return true end
		end
		item.operation = operation
		function item.ack(result)
			item.settled = true
			if not item.cancelled then item.callback(result) end
			for _, listener in ipairs(item.listeners) do listener() end
		end
		return item
	end
	local coordinator = assert(module.new({
		policy = assert(policy_module.new(data)),
		proxy = { lookup_owned = function(url, options, callback)
			local item = child("proxy", callback, options)
			item.url = url
			state.proxy[#state.proxy + 1] = item
			return item.operation
		end },
		curl = function(url, headers, body, options, on_chunk, on_done)
			local item = child("curl", on_done, options)
			item.url, item.chunk = url, on_chunk
			function item.logical(result) options.on_native_terminal(result) end
			state.curls[#state.curls + 1] = item
			return item.operation
		end,
		deadline = function(_, _)
			local token = { started = true, settled = false, listeners = {} }
			function token:is_settled() return self.settled end
			function token:on_settled(listener)
				if self.settled then listener() else self.listeners[#self.listeners + 1] = listener end
				return true
			end
			function token:cancel()
				if self.settled then return true end
				self.settled = true
				for _, listener in ipairs(self.listeners) do listener() end
				return true
			end
			return token
		end,
		clock = function() return state.time end,
		environment = function() return state.environment end,
		report = function(message) state.reports[#state.reports + 1] = message end,
	}))
	return coordinator, state
end

--- Captures actual coordinator delivery for one original public owner.
--- @param coordinator table
--- @param options table|nil
--- @param callback function|nil
--- @return table operation, table results
local function start(coordinator, options, callback)
	local results = {}
	local request = { owner = "public-owner", timeout_ms = 1000, owned_api = true, buffered = true }
	for key, value in pairs(options or {}) do request[key] = value end
	local operation = coordinator.start("https://corporate.invalid/private?token=private-token", {}, nil, request,
		function() end, callback or function(result) results[#results + 1] = result end)
	return operation, results
end

--- Supplies an independently authored actual-selection-shaped receipt.
--- @return table
local function selection()
	return {
		ok = true, proxies = { "http://first.invalid:81", "http://second.invalid:82", "direct://" },
		acknowledgement = "native-selection", failure_provenance = "unavailable", backend = "GLibproxyResolver",
		curl_capabilities = { proxy_used = true },
	}
end

--- Supplies a fixed typed native proxy-connect failure receipt.
--- @return table
local function refused_proxy()
	return {
		ok = false, status = 0, body = "", proxy_used = true,
		failure_receipt = { backend = "curl", stage = "proxy_connect", failure_provenance = "verified",
			curl_exit = 7, http_status = 0, proxy_connect_status = 0 },
	}
end

helpers.describe("managed_http: actual public ownership sequencing", function()
	for _, source in ipairs({ "proxy", "curl" }) do
		local native_source = source
		helpers.it("retains boolean activity and refuses replacement after " .. source .. " signal refusal", function()
			local coordinator, state = fresh()
			if native_source == "curl" then state.environment.HTTPS_PROXY = "http://environment.invalid:81" end
			local original, original_results = start(coordinator, { owned_api = false })
			state.refuse_cancel = true
			helpers.assert_true(not coordinator.cancel("public-owner"))
			helpers.assert_true(coordinator.is_active("public-owner"))
			local successor, refused = start(coordinator, { owned_api = false })
			helpers.assert_true(not successor.started)
			helpers.assert_true(successor:is_settled())
			helpers.assert_eq(refused[1].error, "previous request cancellation failed")
			helpers.assert_true(coordinator.is_active("public-owner"))
			if native_source == "proxy" then state.proxy[1].ack(selection()) end
			helpers.assert_eq(#state.curls, 1)
			state.curls[1].logical({ ok = true, status = 200, body = "original" })
			state.curls[1].ack({ ok = true, status = 200, body = "original" })
			helpers.assert_true(original:is_settled())
			helpers.assert_eq(#original_results, 1)
		end)
	end

	helpers.it("defers destination lease retry admission until the exact failed curl retires", function()
		local coordinator, state = fresh()
		local lease_calls = 0
		local operation, results = start(coordinator, { owned_api = false, output_path = "/private/owned.part",
			proxy_retry_admit = function() lease_calls = lease_calls + 1; return true end })
		state.proxy[1].ack(selection())
		state.curls[1].logical(refused_proxy())
		helpers.assert_eq(lease_calls, 0)
		helpers.assert_eq(#results, 0)
		state.curls[1].ack(refused_proxy())
		helpers.assert_eq(lease_calls, 1)
		helpers.assert_eq(#state.curls, 2)
		state.curls[2].logical({ ok = true, status = 200, body = "" })
		state.curls[2].ack({ ok = true, status = 200, body = "" })
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#results, 1)
	end)
	helpers.it("preserves complete PAC order and consumes one shrinking total budget", function()
		local coordinator, state = fresh()
		local operation, results = start(coordinator)
		helpers.assert_eq(#state.curls, 0)
		helpers.assert_eq(state.proxy[1].options.timeout_ms, 1000)
		helpers.assert_eq(state.proxy[1].url, "https://corporate.invalid/private?token=private-token",
			"actual native lookup must receive the original private destination on its stdin seam")
		state.time = 125
		state.proxy[1].ack(selection())
		helpers.assert_eq(state.curls[1].options.timeout_ms, 875)
		helpers.assert_eq(state.curls[1].options.proxy_selection.proxy, "http://first.invalid:81")
		state.curls[1].logical(refused_proxy())
		helpers.assert_eq(#state.curls, 1, "logical terminal is not physical retirement")
		helpers.assert_eq(#results, 0)
		state.time = 250
		state.curls[1].ack(refused_proxy())
		helpers.assert_eq(#state.curls, 2)
		helpers.assert_eq(state.curls[2].options.proxy_selection.proxy, "http://second.invalid:82")
		helpers.assert_eq(state.curls[2].options.timeout_ms, 750)
		state.time = 500
		state.curls[2].ack(refused_proxy())
		helpers.assert_eq(state.curls[3].options.proxy_selection.mode, "direct")
		helpers.assert_eq(state.curls[3].options.timeout_ms, 500)
		state.curls[3].ack({ ok = true, status = 200, body = "accepted" })
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].body, "accepted")
	end)

	helpers.it("queues a boolean successor without starting it before exact predecessor retirement", function()
		local coordinator, state = fresh()
		state.environment.HTTPS_PROXY = "http://environment.invalid:81"
		local original = start(coordinator, { owned_api = false })
		local successor, results = start(coordinator, { owned_api = false })
		helpers.assert_true(successor.started)
		helpers.assert_eq(#state.curls, 1)
		helpers.assert_true(state.curls[1].cancelled)
		helpers.assert_true(not original:is_settled())
		helpers.assert_true(coordinator.is_active("public-owner"))
		state.curls[1].ack({ ok = false, status = 0 })
		helpers.assert_true(original:is_settled())
		helpers.assert_eq(#state.curls, 2)
		state.curls[2].ack({ ok = true, status = 200, body = "newest" })
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(results[1].body, "newest")
	end)

	helpers.it("retains get_owned duplicate refusal and preserves its physical completion meaning", function()
		local coordinator, state = fresh()
		state.environment.HTTPS_PROXY = "http://environment.invalid:81"
		local original, results = start(coordinator)
		local duplicate, refused = start(coordinator)
		helpers.assert_true(not duplicate.started)
		helpers.assert_true(duplicate:is_settled())
		helpers.assert_eq(refused[1].error, "previous request cleanup pending")
		state.curls[1].logical({ ok = true, status = 200, body = "physical" })
		helpers.assert_eq(#results, 0)
		helpers.assert_true(not original:is_settled())
		state.curls[1].ack({ ok = true, status = 200, body = "physical" })
		helpers.assert_true(original:is_settled())
		helpers.assert_eq(#results, 1)
	end)

	for _, reason in ipairs({ "timeout", "response body exceeds limit" }) do
		local terminal_reason = reason
		helpers.it("preserves early boolean " .. terminal_reason .. " delivery while retaining native debt", function()
			local coordinator, state = fresh()
			state.environment.HTTPS_PROXY = "http://environment.invalid:81"
			local operation, results = start(coordinator, { owned_api = false })
			local result = { ok = false, status = 0, body = "", error = terminal_reason }
			state.curls[1].logical(result)
			helpers.assert_eq(#results, 1)
			helpers.assert_true(not coordinator.is_active("public-owner"))
			helpers.assert_true(not operation:is_settled())
			state.curls[1].ack(result)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(#results, 1)
		end)
	end

	helpers.it("synchronous logical callback reentry queues behind the same exact native close debt", function()
		local coordinator, state = fresh()
		state.environment.HTTPS_PROXY = "http://environment.invalid:81"
		local successor
		local original = start(coordinator, { owned_api = false }, function()
			successor = start(coordinator, { owned_api = false })
		end)
		state.curls[1].logical({ ok = true, status = 200, body = "first" })
		helpers.assert_true(successor.started)
		helpers.assert_eq(#state.curls, 1)
		state.curls[1].ack({ ok = true, status = 200, body = "first" })
		helpers.assert_true(original:is_settled())
		helpers.assert_eq(#state.curls, 2)
		state.curls[2].ack({ ok = true, status = 200, body = "second" })
		helpers.assert_true(successor:is_settled())
	end)

	helpers.it("cancellation fences stale GIO delivery and retains its public owner until retirement", function()
		local coordinator, state = fresh()
		local operation, results = start(coordinator)
		helpers.assert_true(not operation:cancel())
		helpers.assert_true(not operation:is_settled())
		state.proxy[1].callback(selection())
		helpers.assert_eq(#state.curls, 0)
		state.proxy[1].ack(selection())
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#results, 0)
	end)

	helpers.it("stale predecessor events cannot affect a successor's curl or completion", function()
		local coordinator, state = fresh()
		state.environment.HTTPS_PROXY = "http://environment.invalid:81"
		start(coordinator, { owned_api = false })
		local successor, results = start(coordinator, { owned_api = false })
		state.curls[1].ack({ ok = false, status = 0 })
		state.curls[1].callback({ ok = true, status = 200, body = "stale" })
		state.curls[1].logical({ ok = true, status = 200, body = "stale" })
		helpers.assert_eq(#results, 0)
		helpers.assert_true(not successor:is_settled())
		state.curls[2].ack({ ok = true, status = 200, body = "current" })
		helpers.assert_eq(results[1].body, "current")
	end)

	helpers.it("never launches relay after the original deadline expires", function()
		local coordinator, state = fresh()
		local operation, results = start(coordinator)
		state.proxy[1].ack(selection())
		state.time = 1001
		state.curls[1].ack(refused_proxy())
		helpers.assert_eq(#state.curls, 1)
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(results[1].error, "timeout")
	end)

	helpers.it("retains ordinary networking when actual desktop capability is unavailable", function()
		local coordinator, state = fresh()
		local operation, results = start(coordinator)
		state.proxy[1].ack({ ok = false, error = "proxy-backend-unavailable", backend = "GDummyProxyResolver" })
		helpers.assert_eq(state.curls[1].options.proxy_selection, { mode = "environment", capability = "unavailable" })
		state.curls[1].ack({ ok = true, status = 200, body = "ordinary" })
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(results[1].proxy_selection_receipt.failure_provenance, "unavailable")
	end)

	for _, mutation in ipairs({ "origin403", "connect407", "connect403", "certificate", "unknown", "no_proxy", "streamed", "file" }) do
		local reason = mutation
		helpers.it("refuses relay after " .. reason .. " rather than guessing proxy transport failure", function()
			local coordinator, state = fresh()
			local operation, results = start(coordinator, reason == "file" and { output_path = "/private/download" } or nil)
			state.proxy[1].ack(selection())
			local result = refused_proxy()
			if reason == "origin403" then result.failure_receipt.http_status = 403
			elseif reason == "connect407" then result.failure_receipt.proxy_connect_status = 407
			elseif reason == "connect403" then result.failure_receipt.proxy_connect_status = 403
			elseif reason == "certificate" then result.failure_receipt.stage, result.failure_receipt.curl_exit = "tls", 60
			elseif reason == "unknown" then result.failure_receipt.failure_provenance = "unavailable"
			elseif reason == "no_proxy" then result.proxy_used = false
			elseif reason == "streamed" then state.curls[1].chunk("one delivered chunk") end
			state.curls[1].ack(result)
			helpers.assert_eq(#state.curls, 1)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(#results, 1)
		end)
	end

	for _, timing in ipairs({ "before", "after" }) do
		local callback_timing = timing
		helpers.it("reports a throwing settlement listener registered " .. timing .. " exact retirement", function()
			local coordinator, state = fresh()
			state.environment.HTTPS_PROXY = "http://environment.invalid:81"
			local operation, results = start(coordinator)
			local function listener() error("private callback metadata") end
			if callback_timing == "before" then helpers.assert_true(operation:on_settled(listener)) end
			state.curls[1].ack({ ok = true, status = 200, body = "done" })
			helpers.assert_true(operation:is_settled())
			if callback_timing == "after" then helpers.assert_true(operation:on_settled(listener)) end
			helpers.assert_eq(state.reports, { "Managed HTTP settlement callback raised." })
			helpers.assert_eq(#results, 1)
			helpers.assert_true(not coordinator.is_active("public-owner"))
		end)
	end
end)

return helpers
