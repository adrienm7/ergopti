--- tests/hardware/run_local_api_auth.lua

--- ==============================================================================
--- MODULE: Native Local API Authentication Receipts
--- DESCRIPTION:
--- Exercises actual curl/libuv models and chat at a configurable loopback URL.
--- Credentials, HTTP refusal and cancelled or changed sources retain their owners.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
local native_cpath = os.getenv("ERGOPTI_NATIVE_LUA_CPATH")
if native_cpath and native_cpath ~= "" then package.cpath = native_cpath end
local available, uv = pcall(require, "luv")
if not available then io.stderr:write("ENVIRONMENT: native lua-luv is required\n"); os.exit(2) end
require("compat.utf8").install()
local Http = require("adapters.http_client")
local Remote = require("modules.llm.api_remote")
local Json = require("json")
local failures, checks, sockets, requests = {}, 0, {}, {}
local response = { status = 200, body = '{"data":[{"id":"fixture-model"}]}' }

local function check(value, message)
	checks = checks + 1
	print((value and "ok   " or "FAIL ") .. message)
	if not value then failures[#failures + 1] = message end
end
local function close(handle)
	if handle and not uv.is_closing(handle) then uv.close(handle) end
end
local function run_until(predicate)
	local deadline = uv.now() + 5000
	local timer = uv.new_timer()
	uv.timer_start(timer, 10, 10, function() if predicate() or uv.now() > deadline then uv.stop() end end)
	uv.run()
	uv.timer_stop(timer); close(timer); uv.run("nowait")
	return predicate() == true
end
local server = uv.new_tcp()
local bound = server:bind("127.0.0.1", 0)
if not bound then close(server); io.stderr:write("ENVIRONMENT: owned loopback bind failed\n"); os.exit(2) end
local base_url = "http://127.0.0.1:" .. server:getsockname().port .. "/v1"
server:listen(16, function(error)
	if error then failures[#failures + 1] = "owned server accept failed"; return end
	local socket = uv.new_tcp(); sockets[#sockets + 1] = socket; server:accept(socket)
	local input, handled = "", false
	socket:read_start(function(read_error, chunk)
		if read_error or not chunk then close(socket); return end
		if handled then return end
		input = input .. chunk
		local boundary = input:find("\r\n\r\n", 1, true)
		if not boundary then return end
		local length = tonumber(input:sub(1, boundary):lower():match("content%-length:%s*(%d+)")) or 0
		if #input < boundary + 3 + length then return end
		handled = true
		local method, route = input:match("^(%u+) ([^ ]+) ")
		requests[#requests + 1] = { method = method, route = route,
			authorization = input:sub(1, boundary):match("[Aa]uthorization: ([^\r\n]+)"),
			body = input:sub(boundary + 4) }
		if response.pending then return end
		local body = route == "/v1/chat/completions" and '{"choices":[{"message":{"content":"native reply"}}]}' or response.body
		local header = "HTTP/1.1 " .. response.status .. " Fixture\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " .. #body .. "\r\n\r\n"
		socket:write(header .. body, function() socket:shutdown(function() close(socket) end) end)
	end)
end)
local entry = { id = "local", provider = "lmstudio", token = "", model = "fixture-model", base_url = base_url }
local function models()
	local observed = { done = false, calls = 0 }
	local started = Remote.models(entry, function(ids, reason)
		observed.ids, observed.reason, observed.done = ids, reason, true
		observed.calls = observed.calls + 1
	end)
	check(started == true, "actual local models request is dispatched")
	check(run_until(function() return observed.done end), "actual native models receipt settles")
	check(observed.calls == 1 and not Remote.is_active() and not Http.isActive(), "native and API models owners settle exactly once")
	return observed
end
local first = models()
check(first.ids and first.ids[1] == "fixture-model" and first.reason == nil, "native models JSON supplies a selectable model")
check(requests[1].method == "GET" and requests[1].route == "/v1/models" and requests[1].authorization == nil, "keyless models uses the exact configured endpoint without Authorization")
local completed, text, reason = false, nil, nil
check(Remote.chat(entry, nil, { { role = "user", content = "inert fixture" } }, {}, nil,
	function(value, failure) text, reason, completed = value, failure, true end) == true, "models selection dispatches the actual chat consumer")
check(run_until(function() return completed end), "native local chat completes")
check(text == "native reply" and reason == nil and not Http.isActive() and not Remote.is_active(), "actual chat receipt releases both owners")
check(requests[2].method == "POST" and requests[2].route == "/v1/chat/completions" and requests[2].authorization == nil
	and Json.decode(requests[2].body).model == "fixture-model", "keyless chat retains selected model and omits blank Bearer")
entry.token = "inert-provided-token"
local supplied = models()
check(supplied.ids ~= nil and requests[#requests].authorization == "Bearer inert-provided-token", "provided local credentials reach the actual header unchanged")
entry.token = ""
response = { status = 401, body = '{"error":"authentication required"}' }
local rejected = models()
check(rejected.ids == nil and rejected.reason == "http_failure", "actual 401 cannot become a models list")
response = { status = 200, body = '{"data":{}}' }
local malformed = models()
check(malformed.ids == nil and malformed.reason == "invalid_models", "actual object in place of models array is refused")
response = { status = 200, body = '{"data":[]}' }
local stale = { done = false }
check(Remote.models(entry, function(ids, failure) stale.ids, stale.reason, stale.done = ids, failure, true end), "source-switch control begins an actual request")
entry.base_url = base_url .. "/changed"
check(run_until(function() return stale.done end) and stale.ids == nil and stale.reason == "identity_changed", "changed configured source cannot admit its old native answer")
entry.base_url = base_url
response = { pending = true }
local calls, before = 0, #requests
check(Remote.models(entry, function() calls = calls + 1 end), "cancel control owns a real pending curl process")
check(run_until(function() return #requests > before end), "pending request actually reached its configured server")
local cancelled = Remote.cancel()
check(cancelled == true, "cancellation requires the actual native transport acknowledgement")
check(run_until(function() return not Http.isActive() end) and not Remote.is_active() and calls == 0, "cancelled owner settles without a late models publication")
for _, socket in ipairs(sockets) do close(socket) end
close(server)
uv.run()
local live = 0
uv.walk(function(handle) if uv.is_active(handle) and not uv.is_closing(handle) then live = live + 1 end end)
check(live == 0, "all fixture/native event-loop handles have settled")
if #failures > 0 then io.stderr:write("FAIL native local API authentication: " .. #failures .. " failures\n"); os.exit(1) end
print("PASS native local API authentication: " .. checks .. " checks")
