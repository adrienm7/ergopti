--- tests/hardware/run_model_pull_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Model-Pull Retry Receipts
--- DESCRIPTION:
--- Uses the real model-download controller, progress bridge, GTK/WebKit window,
--- libuv and curl against an owned loopback Ollama response fixture. A failed
--- pull remains retryable; successful settlement retires that authorization.
--- Requires a real or virtual X11 session. No keyboard or Ollama model is used.
--- ==============================================================================

local uv = require("luv")
local Gtk = require("lgi").require("Gtk", "3.0")
local Download = require("modules.llm.model_download")
local Window = require("ui.download_window.bridge")
local Manager = require("ui.webview_manager")
local Http = require("adapters.http_client")
local Json = require("json")
local ScriptActions = require("modules.shortcuts.script_actions")
local sockets, requests, checks = {}, 0, 0
local status, body = 500, '{"error":"fixture failure"}\n'
local results = {}
-- Use the same actual pause controller as the daemon. Lifecycle actions are
-- restricted to the model/window resources this native fixture owns.
local script_actions = ScriptActions.new({
	reset = function() Download.shutdown() end,
	reload = function()
		Download.shutdown()
		Manager.hide("download_window")
	end,
	quit = function()
		Download.shutdown()
		Manager.hide("download_window")
	end,
})
Manager.set_daemon_state({ is_paused = script_actions.is_paused })
local server = uv.new_tcp()
assert(server:bind("127.0.0.1", 0))
local base = "http://127.0.0.1:" .. tostring(server:getsockname().port)

--- Closes only a handle owned by this fixture.
--- @param handle userdata
local function close(handle)
	if handle and not uv.is_closing(handle) then uv.close(handle) end
end

server:listen(8, function(err)
	assert(not err, err)
	local socket = uv.new_tcp()
	sockets[#sockets + 1] = socket
	assert(server:accept(socket))
	local input, answered = "", false
	socket:read_start(function(read_error, chunk)
		assert(not read_error, read_error)
		if not chunk then close(socket); return end
		if answered then return end
		input = input .. chunk
		local boundary = input:find("\r\n\r\n", 1, true)
		if not boundary then return end
		local length = tonumber(input:lower():match("content%-length:%s*(%d+)")) or 0
		if #input < boundary + 3 + length then return end
		assert(input:match("^POST /api/pull "), "production controller used the wrong endpoint")
		answered = true
		requests = requests + 1
		local head = "HTTP/1.1 " .. tostring(status) .. " Fixture\r\nConnection: close\r\nContent-Length: "
			.. tostring(#body) .. "\r\n\r\n"
		socket:write(head .. body, function() socket:shutdown(function() close(socket) end) end)
	end)
end)

--- Pumps the actual libuv and GTK loops with a bounded deadline.
--- @param predicate function
--- @return boolean
local function await(predicate)
	local deadline = uv.hrtime() + 5000000000
	repeat
		uv.run("nowait")
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		if predicate() then return true end
		uv.sleep(10)
	until uv.hrtime() > deadline
	return false
end

--- Reads an observation back from actual WebKit after its evaluation settles.
--- @param view userdata
--- @param source string
--- @return string
local function evaluate(view, source)
	local complete, value = false, nil
	view:run_javascript(source, nil, function(_, result)
		value = view:run_javascript_finish(result):get_js_value():to_string()
		complete = true
	end, nil)
	assert(await(function() return complete end), "native WebKit evaluation did not settle")
	return value
end

--- Posts from the real page and observes its decoded native response.
--- The page factory supplies its genuine document binding; no native context,
--- nonce, token or lease is manufactured by this fixture.
--- @param view userdata
--- @param payload any
--- @return table
local function bridge_response(view, payload)
	assert(evaluate(view, "window.__nativePullResponses = []; String(makeHostBridge('dl_bridge')("
		.. assert(Json.encode(payload)) .. "))") == "true", "actual page bridge must admit the post")
	local response, pending, failure = nil, false, nil
	local settled = await(function()
		if response or failure then return true end
		if not pending then
			pending = true
			view:run_javascript("JSON.stringify(window.__nativePullResponses)", nil, function(_, result)
				local decoded, values = pcall(function()
					return Json.decode(view:run_javascript_finish(result):get_js_value():to_string())
				end)
				if not decoded or type(values) ~= "table" then
					failure = "actual page response observation failed"
				else
					for _, value in ipairs(values) do
						if type(value) == "table" and ((payload == "ready" and type(value.pushed) == "boolean")
							or (type(payload) == "table" and type(value.retried) == "boolean")) then
							response = value
							break
						end
					end
				end
				pending = false
			end, nil)
		end
		return response ~= nil or failure ~= nil
	end)
	assert(settled, "actual native progress response did not settle")
	assert(not failure, failure)
	return assert(response, "actual native progress response is absent")
end

--- Requires a meaningful native observation and counts it for CI evidence.
--- @param condition boolean
--- @param message string
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
	print("PASS " .. message)
end

local ok, err = xpcall(function()
	check(Download.start(base, "ergopti-fixture:latest", "Native fixture",
		function(success) results[#results + 1] = success end), "native model pull dispatches")
	check(await(function() return #results == 1 end), "failed native model pull settles")
	check(results[1] == false and requests == 1 and not Download.is_active(), "HTTP failure remains a failed pull")
	status, body = 200, '{"status":"success"}\n'
	local view = assert(Manager.webview_for("download_window"), "actual progress WebKit view is absent")
	check(type(view.is_loading) == "boolean", "actual progress native loading property is Boolean")
	check(await(function() return Manager.capture_document_owner("download_window") ~= nil end),
		"actual progress document acknowledges native initialization")
	check(evaluate(view, [[
		window.__nativePullResponses = [];
		var priorNativePullResponse = window.__hostBridgeResponse;
		window.__hostBridgeResponse = function(name, encoded, payload) {
			if (name === 'dl_bridge') {
				var response = decodeHostBridgeResponse(encoded, payload);
				if (response !== null) window.__nativePullResponses.push(response);
			}
			if (typeof priorNativePullResponse === 'function') {
				return priorNativePullResponse.apply(this, arguments);
			}
		};
		typeof makeHostBridge + ':' + typeof decodeHostBridgeResponse;
	]]) == "function:function", "actual progress page exposes its host post and response decoder")
	local failed_session = Window.session_id()
	local failed_epoch = bridge_response(view, "ready").failure_epoch
	local failed_retry = { action = "failure_action", id = "retry", session = failed_session, epoch = failed_epoch }
	local retry = bridge_response(view, failed_retry)
	check(retry and retry.retried == true, "failed pull admits retry through the actual progress bridge")
	check(await(function() return #results == 2 end), "retried native pull settles")
	check(results[2] == true and requests == 2 and not Download.is_active(), "successful native pull releases transport")
	check(await(function() return not view.is_loading end), "actual progress page finishes loading")
	check(evaluate(view, [[
		window.nativePullSucceeded = null;
		var originalDone = window.done;
		window.done = function(succeeded) {
			window.nativePullSucceeded = succeeded;
			return originalDone.apply(this, arguments);
		};
		typeof originalDone;
	]]) == "function", "actual progress page exposes its completion receiver")
	check(bridge_response(view, "ready").pushed == true
		and evaluate(view, "String(window.nativePullSucceeded)") == "true", "native page receives successful settlement")
	check(Download.retry() == false, "successful native pull refuses direct stale retry")
	retry = bridge_response(view, failed_retry)
	check(retry and retry.retried == false, "successful native pull refuses stale progress retry")
	check(requests == 2 and not Download.is_active() and not Http.isActive("ollama_model_pull"),
		"stale retries cannot reacquire native transport")
	check(bridge_response(view, "ready").pushed == true
		and evaluate(view, "String(window.nativePullSucceeded)") == "true", "stale retry preserves successful page settlement")
end, debug.traceback)

Download.shutdown()
Manager.hide("download_window")
for _, socket in ipairs(sockets) do close(socket) end
close(server)
local drained = await(function() return not uv.loop_alive() end)
if not ok then io.stderr:write(err .. "\n"); os.exit(1) end
check(drained, "all native socket and process handles settle")
print(string.format("Native model pulls: %d checks, 0 failures", checks))
