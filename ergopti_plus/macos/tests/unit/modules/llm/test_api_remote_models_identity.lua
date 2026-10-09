--- tests/unit/modules/llm/test_api_remote_models_identity.lua

--- ==============================================================================
--- MODULE: Remote models-endpoint identity regression tests
--- DESCRIPTION:
--- Proves that an HTTP success is not enough to establish remote readiness.
--- Warmup and availability must both require a provider-shaped models payload.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Returns one named closure upvalue.
--- @param fn function Closure to inspect.
--- @param target string Upvalue name.
--- @return any value Captured value.
local function get_upvalue(fn, target)
	for index = 1, 128 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end


--- Configures one provider and active entry.
--- @param api table Remote backend.
--- @param format string Provider response format.
local function configure(api, format)
	local provider_id = "fixture-" .. format
	api.PROVIDERS[provider_id] = {
		label = "Fixture " .. format,
		base_url = "https://fixture.invalid/v1",
		default_model = "fixture-model",
		format = format,
	}
	api.set_entries({ {
		id = "entry-" .. format,
		provider = provider_id,
		base_url = "https://fixture.invalid/v1",
		token = "plain-token",
		model = "fixture-model",
	} })
	api.set_active_entry_id("entry-" .. format)
end


--- Exercises both public health paths with the same response.
--- @param api table Remote backend.
--- @param format string Provider response format.
--- @param response table HTTP response.
--- @return table result Observed readiness and availability callbacks.
local function exercise(api, format, response)
	configure(api, format)

	local warmup_client = get_upvalue(api.warmup, "_warmup_client")
	local check_client = get_upvalue(api.check_availability, "_check_client")
	helpers.assert_true(warmup_client ~= nil and check_client ~= nil,
		"both health paths must retain their production HTTP owners")
	local original_warmup_get = warmup_client.get
	local original_check_get = check_client.get
	local warmup_callback
	local check_callback
	warmup_client.get = function(_, _, callback)
		warmup_callback = callback
		return true
	end
	check_client.get = function(_, _, callback)
		check_callback = callback
		return true
	end

	local result = { available = 0, missing = 0, unreachable = nil }
	local ok, err = xpcall(function()
		helpers.assert_true(api.warmup())
		helpers.assert_eq(type(warmup_callback), "function")
		warmup_callback(response)
		result.ready = api.is_ready()

		helpers.assert_true(api.check_availability("fixture-model",
			function() result.available = result.available + 1 end,
			function(unreachable)
				result.missing = result.missing + 1
				result.unreachable = unreachable
			end))
		helpers.assert_eq(type(check_callback), "function")
		check_callback(response)
	end, debug.traceback)
	warmup_client.get = original_warmup_get
	check_client.get = original_check_get
	if not ok then error(err, 0) end
	return result
end


helpers.describe("HS-097 remote models endpoint identity", function()
	helpers.it("rejects captive HTML and unshaped JSON on both health paths", function()
		package.loaded["modules.llm.api_remote"] = nil
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local logger = get_upvalue(api.warmup, "Logger")
		helpers.assert_true(logger ~= nil)
		local original_warn = logger.warn
		local warnings = {}
		logger.warn = function(_, message, ...)
			warnings[#warnings + 1] = string.format(message, ...)
		end
		local ok, err = xpcall(function()
			for _, body in ipairs({
				"<html><title>CAPTIVE_RESPONSE_SECRET</title></html>",
				"{}",
			}) do
				local result = exercise(api, "openai", {
					ok = true,
					status = 200,
					body = body,
				})
				helpers.assert_eq(result.ready, false,
					"a generic 2xx response must not publish remote readiness")
				helpers.assert_eq(result.available, 0,
					"a generic 2xx response must not publish endpoint availability")
				helpers.assert_eq(result.missing, 1)
				helpers.assert_eq(result.unreachable, false,
					"a reachable but incompatible endpoint is not a transport outage")
			end
			helpers.assert_eq(#warnings, 4,
				"warmup and availability must each report both invalid responses")
			local rendered = table.concat(warnings, "\n")
			helpers.assert_true(rendered:find("invalid models response", 1, true) ~= nil)
			helpers.assert_true(rendered:find("CAPTIVE_RESPONSE_SECRET", 1, true) == nil,
				"health diagnostics must never expose response bytes")
			helpers.assert_true(rendered:find("plain-token", 1, true) == nil,
				"health diagnostics must never expose credentials")
		end, debug.traceback)
		logger.warn = original_warn
		if not ok then error(err, 0) end
	end)

	for _, case in ipairs({
		{ format = "openai", body = [[{"data":[]}]] },
		{ format = "anthropic", body = [[{"data":[]}]] },
		{ format = "gemini", body = [[{"models":[]}]] },
	}) do
		helpers.it("accepts an empty " .. case.format .. " models catalogue", function()
			package.loaded["modules.llm.api_remote"] = nil
			local api = helpers.load_with_stubs("modules.llm.api_remote")
			local result = exercise(api, case.format, {
				ok = true,
				status = 200,
				body = case.body,
			})
			helpers.assert_eq(result.ready, true)
			helpers.assert_eq(result.available, 1)
			helpers.assert_eq(result.missing, 0)
		end)
	end
end)
