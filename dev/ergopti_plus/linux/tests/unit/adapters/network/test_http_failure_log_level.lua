--- tests/unit/adapters/network/test_http_failure_log_level.lua

--- ==============================================================================
--- MODULE: Request-Specific HTTP Failure Diagnostics
--- DESCRIPTION:
--- Exercises the actual public adapter, managed coordinator and Curl engine.
--- Controlled native ports separate terminal transport from infrastructure faults.
--- ==============================================================================

local helpers = require("tests.helpers")
local Ports = require("tests.support.managed_http_native_ports")
local Logger = require("logger.shim")
local Json = require("json")

--- Retires every controlled native owner even when a regression assertion fails.
--- @param config table Native refusal controls.
--- @param body function Actual managed client scenario.
local function with_client(config, body)
	local client, state = Ports.fresh_client(config)
	local before = Logger.session_issues()
	local ok, err = xpcall(function() body(client, state, before) end, debug.traceback)
	state.allow_kills, state.allow_closes, state.refuse_deadline_close = true, true, false
	client.shutdown()
	for index in ipairs(state.requests) do state.complete_request(index, "late\nERGOPTI_HTTP_STATUS:200\n") end
	state.ack_closes()
	for _, deadline in ipairs(state.deadlines) do deadline.ack() end
	assert(client.shutdown(), "all controlled HTTP owners must physically retire")
	if not ok then error(err, 0) end
end

--- Measures actual logger delivery without changing its level or error observer.
--- @param before table Session issue counters before the request.
--- @param errors number Expected ERROR delta.
--- @param warnings number Expected WARNING delta.
local function issues(before, errors, warnings)
	local after = Logger.session_issues()
	helpers.assert_eq(after.err_count - before.err_count, errors)
	helpers.assert_eq(after.warn_count - before.warn_count, warnings)
end

helpers.describe("request-specific HTTP transport failure diagnostics", function()
	for _, vector in ipairs({
		{ status = 401, code = 22 }, { status = 403, code = 22 }, { status = 404, code = 22 }, { status = 407, code = 22 },
		{ status = 0, code = 2 }, { status = 0, code = 5 }, { status = 0, code = 6 },
		{ status = 0, code = 28 }, { status = 0, code = 35 }, { status = 0, code = 60 },
	}) do
		local refused = vector
		helpers.it("keeps HTTP " .. vector.status .. "/curl " .. vector.code .. " at ERROR without parsing diagnostic text", function()
			with_client({}, function(client, state, before)
				local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {},
					{ failure_log_level = "warn" }, function() end)
				state.stderr("HTTP 503: deliberately misleading public diagnostic text")
				state.complete_request(1, '{}\nERGOPTI_HTTP_STATUS:' .. string.format("%03d", refused.status) .. '\n', refused.code)
				helpers.assert_true(operation:is_settled())
				issues(before, 1, 0)
			end)
		end)
	end
	for _, status in ipairs({ 500, 599 }) do
		local server_status = status
		helpers.it("accepts a verified direct HTTP " .. status .. " as optional service unavailability", function()
			with_client({}, function(client, state, before)
				local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {},
					{ failure_log_level = "warn" }, function() end)
				state.complete_request(1, '{}\nERGOPTI_HTTP_STATUS:' .. server_status .. '\n', 22)
				helpers.assert_true(operation:is_settled())
				issues(before, 0, 1)
			end)
		end)
	end
	for _, route in ipairs({ "selected", "unavailable" }) do
		local native_route = route
		helpers.it("preserves the admitted " .. route .. " route despite a caller-injected direct route", function()
			with_client({ defer_close = true }, function(client, state, before)
				local response
				local operation = client.get_owned("https://corporate.invalid/api/tags", {},
					{ failure_log_level = "warn", proxy_selection = { mode = "direct" } }, function(result) response = result end)
				local receipt = native_route == "selected" and {
					ok = true, proxies = { "http://proxy.invalid:81" }, backend = "GProxyResolverGnome",
					acknowledgement = "native-selection", failure_provenance = "unavailable",
				} or { ok = false, error = "proxy-native-unavailable" }
				state.complete_request(1, Json.encode(receipt))
				helpers.assert_eq(#state.requests, 1)
				state.ack_closes()
				helpers.assert_eq(#state.requests, 2)
				state.complete_request(2, '{}\nERGOPTI_HTTP_STATUS:503\n', 22)
				state.ack_closes()
				helpers.assert_true(operation:is_settled())
				helpers.assert_eq(response.ok, false)
				helpers.assert_eq(response.failure_receipt.proxy_mode, native_route)
				issues(before, 1, 0)
			end)
		end)
	end
	helpers.it("keeps a direct native request without an admitted route receipt at ERROR", function()
		local native, state = require("tests.support.adapters.network.http_client_curl_fixture").fresh_client()
		local before = Logger.session_issues()
		local ok, err = xpcall(function()
			local operation = native.get_owned("http://127.0.0.1:11434/api/tags", {},
				{ owner = "unadmitted-diagnostic", failure_log_level = "warn" }, function() end)
			state.complete_request(1, '{}\nERGOPTI_HTTP_STATUS:503\n', 22)
			helpers.assert_true(operation:is_settled())
			issues(before, 1, 0)
		end, debug.traceback)
		native.cancel("unadmitted-diagnostic")
		for index in ipairs(state.requests) do state.complete_request(index, "late\nERGOPTI_HTTP_STATUS:200\n") end
		state.ack_closes()
		if not ok then error(err, 0) end
	end)
	for _, level in ipairs({ "default", "error", "warn" }) do
		local selected = level
		for _, status in ipairs({ 0, 503 }) do
			local response_status = status
			helpers.it(selected .. " diagnostics retain failed HTTP " .. status .. " through physical settlement", function()
				with_client({ defer_close = true }, function(client, state, before)
					local options, responses = { owner = "optional-query", timeout_ms = 5000 }, {}
					if selected ~= "default" then options.failure_log_level = selected end
					local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {}, options,
						function(result) responses[#responses + 1] = result end)
					helpers.assert_true(operation.started)
					state.complete_request(1, '{}\nERGOPTI_HTTP_STATUS:' .. string.format("%03d", response_status) .. '\n',
						response_status == 0 and 7 or 22)
					helpers.assert_eq(#responses, 0)
					helpers.assert_eq(operation:is_settled(), false)
					state.ack_closes()
					helpers.assert_true(operation:is_settled())
					helpers.assert_eq(#responses, 1)
					helpers.assert_eq(responses[1].ok, false)
					helpers.assert_eq(responses[1].status, response_status)
					issues(before, selected == "warn" and 0 or 1, selected == "warn" and 1 or 0)
				end)
			end)
		end
	end
	for _, initial in ipairs({ "warn", "error" }) do
		local captured = initial
		helpers.it("captures " .. initial .. " before authorization reentry and later caller mutation", function()
			with_client({}, function(client, state, before)
				local options = { owner = "captured-query", failure_log_level = captured }
				options.authorized = function()
					options.failure_log_level = captured == "warn" and "error" or "warn"
					return true
				end
				local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {}, options, function() end)
				state.complete_request(1, '{}\nERGOPTI_HTTP_STATUS:503\n', 22)
				helpers.assert_true(operation:is_settled())
				issues(before, captured == "warn" and 0 or 1, captured == "warn" and 1 or 0)
			end)
		end)
		helpers.it("captures " .. initial .. " before the first timeout collaborator mutates caller metadata", function()
			local native, state = require("tests.support.adapters.network.http_client_curl_fixture").fresh_client()
			local options = { owner = "early-query", failure_log_level = captured }
			local default_timeout = native.default_timeout_ms
			native.default_timeout_ms = function()
				options.failure_log_level = captured == "warn" and "error" or "warn"
				return default_timeout()
			end
			with_client({ native_curl = native }, function(client, _, before)
				local ok, err = xpcall(function()
					local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {}, options, function() end)
					state.complete_request(1, '{}\nERGOPTI_HTTP_STATUS:503\n', 22)
					helpers.assert_true(operation:is_settled())
					issues(before, captured == "warn" and 0 or 1, captured == "warn" and 1 or 0)
				end, debug.traceback)
				native.default_timeout_ms = default_timeout
				native.cancel("early-query")
				for index in ipairs(state.requests) do state.complete_request(index, "late\nERGOPTI_HTTP_STATUS:200\n") end
				state.ack_closes()
				if not ok then error(err, 0) end
			end)
		end)
	end
	for _, value in ipairs({ false, true, 42, {}, function() end, "WARN", "debug" }) do
		local invalid = value
		helpers.it("refuses invalid diagnostic metadata before native acquisition or caller authorization", function()
			with_client({}, function(client, state, before)
				local calls = 0
				local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {}, {
					failure_log_level = invalid, authorized = function() calls = calls + 1; return true end,
				}, function() calls = calls + 1 end)
				helpers.assert_eq(operation.started, false)
				helpers.assert_true(operation:is_settled())
				helpers.assert_eq(operation:settled_result().error, "HTTP failure log level is invalid")
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(#state.requests, 0)
				helpers.assert_eq(#state.handles, 0)
				helpers.assert_eq(#state.deadlines, 0)
				issues(before, 0, 0)
				local native, native_state = require("tests.support.adapters.network.http_client_curl_fixture").fresh_client()
				local admitted, refusal = native.preflight("http://127.0.0.1:11434/api/tags", {}, nil,
					{ failure_log_level = invalid, method = "GET", buffered = true })
				helpers.assert_eq(admitted, false)
				helpers.assert_eq(refusal, "HTTP failure log level is invalid")
				helpers.assert_eq(#native_state.handles, 0)
			end)
		end)
	end
	for _, level in ipairs({ "default", "warn" }) do
		local selected = level
		helpers.it("retains " .. level .. " diagnostics through the existing boolean HTTP API", function()
			with_client({}, function(client, state, before)
				local options, response = {}, nil
				if selected == "warn" then options.failure_log_level = selected end
				helpers.assert_true(client.get("http://127.0.0.1:11434/api/tags", {}, options, function(result) response = result end))
				state.complete_request(1, '{}\nERGOPTI_HTTP_STATUS:503\n', 22)
				helpers.assert_eq(response.ok, false)
				issues(before, selected == "warn" and 0 or 1, selected == "warn" and 1 or 0)
			end)
		end)
	end
	helpers.it("keeps abnormal process termination at ERROR for a warning-level query", function()
		with_client({}, function(client, state, before)
			local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {},
				{ failure_log_level = "warn" }, function() end)
			state.stdout(nil); state.stderr(nil); state.ack_group_absent(1); state.exit(0, 15)
			helpers.assert_true(operation:is_settled())
			issues(before, 1, 0)
		end)
	end)
	for _, fault in ipairs({ "allocation_failure_at", "timer_failure", "spawn_failure" }) do
		local native_fault = fault
		helpers.it("keeps native " .. fault .. " at ERROR for a warning-level query", function()
			local config = { defer_close = true }
			config[native_fault] = native_fault == "allocation_failure_at" and 2 or true
			with_client(config, function(client, state, before)
				local response
				local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {},
					{ failure_log_level = "warn" }, function(result) response = result end)
				state.ack_closes()
				helpers.assert_true(operation:is_settled())
				helpers.assert_eq(response.ok, false)
				issues(before, 1, 0)
			end)
		end)
	end
	for _, malformed in ipairs({ "missing status", "excess body" }) do
		local scenario = malformed
		helpers.it("keeps " .. malformed .. " at ERROR after native EOF and exit", function()
			with_client({}, function(client, state, before)
				local response
				local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {},
					{ failure_log_level = "warn", max_body_bytes = 2 }, function(result) response = result end)
				state.complete_request(1, scenario == "missing status" and "{}" or 'large\nERGOPTI_HTTP_STATUS:503\n',
					scenario == "missing status" and 0 or 22)
				helpers.assert_true(operation:is_settled())
				helpers.assert_eq(response.error, scenario == "missing status" and "missing HTTP status" or "response body exceeds limit")
				issues(before, 1, 0)
			end)
		end)
	end
	for _, callback in ipairs({ "completion", "settlement" }) do
		local failing = callback
		helpers.it("keeps a raised " .. callback .. " callback at ERROR after a warning transport failure", function()
			with_client({}, function(client, state, before)
				local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {},
					{ failure_log_level = "warn" }, function() if failing == "completion" then error("controlled callback failure") end end)
				if failing == "settlement" then operation:on_settled(function() error("controlled settlement failure") end) end
				state.complete_request(1, '{}\nERGOPTI_HTTP_STATUS:503\n', 22)
				helpers.assert_true(operation:is_settled())
				issues(before, 1, 1)
			end)
		end)
	end
	helpers.it("keeps refused deadline cleanup at ERROR and retains exact settlement debt", function()
		with_client({}, function(client, state, before)
			local completed = false
			local operation = client.get_owned("http://127.0.0.1:11434/api/tags", {},
				{ failure_log_level = "warn" }, function() completed = true end)
			state.refuse_deadline_close = true
			state.complete_request(1, '{}\nERGOPTI_HTTP_STATUS:503\n', 22)
			helpers.assert_eq(operation:is_settled(), false)
			helpers.assert_eq(completed, false)
			issues(before, 1, 1)
			state.refuse_deadline_close = false
			for _, deadline in ipairs(state.deadlines) do deadline.ack() end
			helpers.assert_true(operation:is_settled())
			helpers.assert_true(completed)
		end)
	end)
end)
