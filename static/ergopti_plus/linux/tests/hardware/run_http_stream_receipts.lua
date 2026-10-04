--- tests/hardware/run_http_stream_receipts.lua

--- ==============================================================================
--- MODULE: Native Curl Streaming Receipts
--- DESCRIPTION:
--- Runs the actual libuv/curl adapter against an owned loopback HTTP server.
--- A model present in /api/tags disappears at inference; genuine HTTP receipts
--- must reach the existing missing-model offer, while auth/server failures stay
--- ordinary. Status metadata never becomes an NDJSON response chunk.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
local native_cpath = os.getenv("ERGOPTI_NATIVE_LUA_CPATH")
if native_cpath and native_cpath ~= "" then package.cpath = native_cpath end
local ok_luv, uv = pcall(require, "luv")
if not ok_luv then
	io.stderr:write("ENVIRONMENT: native lua-luv for this Lua ABI is required\n")
	os.exit(2)
end
require("compat.utf8").install()

local Http = require("adapters.http_client")
local Ollama = require("modules.llm.api_ollama")
local Policy = require("llm.local_model_policy")
local Offer = require("modules.llm.local_model_offer")
local MODEL = "ergopti-stream-receipt:latest"
local failures, checks, sockets = {}, 0, {}
local requests = {}
local response = { status = 404,
	body = require("json").encode({ error = 'model "' .. MODEL .. '" not found' }) }

local function check(condition, message)
	checks = checks + 1
	print((condition and "ok   " or "FAIL ") .. message)
	if not condition then failures[#failures + 1] = message end
end

local function close(handle)
	if handle and not uv.is_closing(handle) then uv.close(handle) end
end

local function run_until(done)
	local deadline = uv.now() + 5000
	local timer = uv.new_timer()
	uv.timer_start(timer, 10, 10, function()
		if done() or uv.now() > deadline then uv.stop() end
	end)
	uv.run()
	uv.timer_stop(timer)
	close(timer)
	uv.run("nowait")
	return done() == true
end

local server = uv.new_tcp()
local bound, bind_error = server:bind("127.0.0.1", 0)
if not bound then
	io.stderr:write("ENVIRONMENT: loopback HTTP bind failed: " .. tostring(bind_error) .. "\n")
	close(server)
	os.exit(2)
end
local port = server:getsockname().port
local base_url = "http://127.0.0.1:" .. tostring(port)

local function respond(socket, status, body, incomplete)
	local length = #body + (incomplete and 100 or 0)
	local head = "HTTP/1.1 " .. tostring(status) .. " Fixture\r\nContent-Type: application/json\r\n"
		.. "Connection: close\r\nContent-Length: " .. tostring(length) .. "\r\n\r\n"
	socket:write(head .. body, function()
		socket:shutdown(function() close(socket) end)
	end)
end

server:listen(16, function(err)
	if err then failures[#failures + 1] = tostring(err); return end
	local socket = uv.new_tcp()
	sockets[#sockets + 1] = socket
	server:accept(socket)
	local input, handled = "", false
	socket:read_start(function(read_error, chunk)
		if read_error then failures[#failures + 1] = tostring(read_error); close(socket); return end
		if not chunk then close(socket); return end
		if handled then return end
		input = input .. chunk
		local boundary = input:find("\r\n\r\n", 1, true)
		if not boundary then return end
		local length = tonumber(input:sub(1, boundary):lower():match("content%-length:%s*(%d+)")) or 0
		if #input < boundary + 3 + length then return end
		handled = true
		local method, path = input:match("^(%u+) ([^ ]+) ")
		requests[#requests + 1] = { method = method, path = path }
		if path == "/api/tags" then
			respond(socket, 200, require("json").encode({ models = { { name = MODEL } } }))
		elseif path == "/api/chat" then
			respond(socket, response.status, response.body, response.incomplete)
		elseif path == "/slow" then
			-- The owned process stays pending until cancellation; cleanup owns the
			-- server socket rather than a timer that could publish a late response.
			socket:write("HTTP/1.1 200 Fixture\r\nContent-Length: 10000\r\n\r\npartial")
		else
			respond(socket, 404, '{"error":"route not found"}')
		end
	end)
end)

local function request_chat()
	local done, text, failure, terminals = false, nil, nil, 0
	local started = Ollama.chat(base_url, MODEL, { { role = "user", content = "private fixture" } },
		{ verify_local_model = true }, nil, function(value, reason)
			text, failure, done = value, reason, true
			terminals = terminals + 1
		end)
	check(started == true, "actual model preflight is dispatched")
	check(run_until(function() return done end), "native chat terminal receipt settles")
	check(terminals == 1, "native chat terminal is published exactly once")
	check(not Http.isActive() and not Ollama.is_active(), "native/API owners release after the receipt")
	return text, failure
end

local _, missing = request_chat()
check(requests[1] and requests[1].path == "/api/tags" and requests[2]
	and requests[2].path == "/api/chat", "a real tags 200 admits chat before the model disappears")
check(Policy.is_missing(missing) and missing.model == MODEL and missing.base_url == base_url,
	"real curl HTTP 404/error JSON reaches the exact structured missing-model failure")
local notices = {}
Offer._reset_for_test({ notify = function(text) notices[#notices + 1] = text; return true end })
check(Offer.handle(missing, { automatic = true }) == true and #notices == 1,
	"the actual automatic offer accepts the native missing-model receipt once")

local missing_json = require("json").encode({ error = 'model "' .. MODEL .. '" not found' })
response = { status = 404, body = missing_json .. string.rep(" ", 65536) .. "trailing invalid JSON" }
check(require("json").decode(response.body) == nil, "the entire oversized error body is independently invalid JSON")
local _, overflow_failure = request_chat()
check(not Policy.is_missing(overflow_failure) and overflow_failure == "HTTP 404",
	"a valid prefix with invalid discarded trailing bytes cannot become a model-missing receipt")
check(Offer.handle(overflow_failure, { automatic = true }) == false and #notices == 1,
	"an incomplete oversized receipt cannot offer a model download")

response = { status = 404, body = missing_json .. string.rep(" ", 65536 - #missing_json) }
check(#response.body == 65536, "the positive boundary contains exactly 64 KiB of valid JSON")
local _, boundary_failure = request_chat()
check(Policy.is_missing(boundary_failure) and boundary_failure.model == MODEL,
	"a complete error body at the exact budget boundary retains missing-model evidence")
check(Offer.handle(boundary_failure, { automatic = true }) == true and #notices == 1,
	"a complete boundary receipt is admitted without duplicating the automatic notice")

for _, case in ipairs({
	{ status = 404, body = '{"error":"route not found"}' },
	{ status = 401, body = require("json").encode({ error = 'model "' .. MODEL .. '" not found' }) },
	{ status = 503, body = require("json").encode({ error = 'model "' .. MODEL .. '" not found' }) },
}) do
	response = case
	local _, failure = request_chat()
	check(not Policy.is_missing(failure) and failure == "HTTP " .. tostring(case.status),
		"HTTP " .. tostring(case.status) .. " control stays an ordinary HTTP error")
	check(Offer.handle(failure, { automatic = true }) == false and #notices == 1,
		"ordinary HTTP failures cannot offer a model download")
end

response = { status = 200, body = '{"message":{"content":"ready 😀"},"done":false}\n{"done":true}\n' }
local recovered, recovered_error = request_chat()
check(recovered == "ready 😀" and recovered_error == nil, "a following genuine stream recovers and offers text")

-- Buffered GET, POST and file downloads share one receipt decoder. Curl reports
-- both HTTP 200 and exit 18 when the peer closes before Content-Length bytes.
local destination = assert(os.tmpname())
for _, method in ipairs({ "get", "post", "download" }) do
	for _, case in ipairs({
		{ status = 200, body = "partial", incomplete = true },
		{ status = 299, body = "complete" },
		{ status = 404, body = '{"error":"route not found"}' },
	}) do
		response = case
		local answer, terminals = nil, 0
		local owner = "native-buffered-" .. method
		local options = { owner = owner, timeout_ms = 2000 }
		local function done(value) answer = value; terminals = terminals + 1 end
		if method == "get" then
			Http.get(base_url .. "/api/chat", {}, options, done)
		elseif method == "post" then
			Http.post(base_url .. "/api/chat", {}, "{}", done, options)
		else
			Http.download(base_url .. "/api/chat", {}, destination, options, done)
		end
		check(run_until(function() return answer ~= nil end), method .. " native buffered receipt settles")
		local correct = answer and answer.status == case.status
		if case.incomplete then
			correct = correct and not answer.ok and answer.body == ""
				and type(answer.error) == "string" and answer.error:find("curl", 1, true) ~= nil
		elseif case.status == 299 then
			correct = correct and answer.ok and answer.error == nil
			if method == "download" then
				local file = assert(io.open(destination, "r"))
				correct = correct and file:read("*a") == case.body
				file:close()
			else
				correct = correct and answer.body == case.body
			end
		else
			correct = correct and not answer.ok and answer.error == "HTTP 404"
		end
		check(correct, method .. " validates buffered HTTP " .. tostring(case.status)
			.. (case.incomplete and " with native curl transfer failure" or " with completed native curl"))
		check(terminals == 1 and not Http.isActive(owner), method .. " buffered owner settles exactly once")
	end
end
assert(os.remove(destination))

local chunks, receipt, terminal_count = {}, nil, 0
response = { status = 299, body = "native body" }
Http.postStream(base_url .. "/api/chat", {}, "{}", { owner = "native-status", timeout_ms = 2000 },
	function(chunk) chunks[#chunks + 1] = chunk end,
	function(value) receipt = value; terminal_count = terminal_count + 1 end)
check(run_until(function() return receipt ~= nil end), "the actual non-200 success receipt settles")
check(receipt and receipt.ok and receipt.error == nil and receipt.status == 299 and terminal_count == 1,
	"the streaming adapter reports real 2xx status instead of manufacturing 200")
check(table.concat(chunks) == "native body", "write-out protocol metadata never enters response chunks")

response = { status = 200, body = "incomplete", incomplete = true }
receipt = nil
Http.postStream(base_url .. "/api/chat", {}, "{}", { owner = "native-partial", timeout_ms = 2000 },
	function() end, function(value) receipt = value end)
check(run_until(function() return receipt ~= nil end), "partial native transfer settles")
check(receipt and not receipt.ok and receipt.status == 200,
	"an incomplete 200 transfer retains its status without becoming a success")

response = { status = 404, body = string.rep("x", 70000) }
receipt = nil
Http.postStream(base_url .. "/api/chat", {}, "{}", { owner = "native-bounded", timeout_ms = 2000 },
	function() end, function(value) receipt = value end)
check(run_until(function() return receipt ~= nil end), "large native error response settles")
check(receipt and receipt.status == 404 and receipt.error == "HTTP 404" and receipt.error_body == nil,
	"oversized native error bodies are omitted rather than presented as complete JSON")

local cancel_terminals = 0
Http.postStream(base_url .. "/slow", {}, "{}", { owner = "native-cancel", timeout_ms = 2000 },
	function() end, function() cancel_terminals = cancel_terminals + 1 end)
check(run_until(function() return requests[#requests] and requests[#requests].path == "/slow" end),
	"the cancellation case reaches a real pending native request")
check(Http.cancel("native-cancel") == true and not Http.isActive("native-cancel"),
	"native streaming cancellation releases the exact request owner")
check(cancel_terminals == 0, "cancellation suppresses the terminal callback")


-- Discovery needs a stronger receipt than the historical signal-accepted bool.
-- This uses the same actual curl/native process and retains exact cleanup
-- ownership until its process exit and every libuv close callback acknowledge.
local owned_receipt, owned_callbacks, settled_callbacks = nil, 0, 0
response = { status = 200, body = '{"data":[{"id":"owned:first"},{"id":"owned:second"}]}' }
local owned = Http.get_owned(base_url .. "/api/chat", {},
	{ owner = "native-owned", timeout_ms = 2000, max_body_bytes = 65536 }, function(value)
		owned_receipt = value
		owned_callbacks = owned_callbacks + 1
	end)
check(owned.started == true and not owned:is_settled(), "owned native GET returns before actual response/cleanup")
owned:on_settled(function() settled_callbacks = settled_callbacks + 1 end)
check(run_until(function() return owned:is_settled() end), "owned native GET receives process-exit and handle-close ACKs")
check(owned_receipt and owned_receipt.ok and owned_receipt.status == 200
	and owned_receipt.body == response.body and owned_callbacks == 1 and settled_callbacks == 1,
	"the complete actual 200/body publishes exactly once after physical settlement")

owned_receipt = nil
response = { status = 401, body = '{"error":"authentication required"}' }
owned = Http.get_owned(base_url .. "/api/chat", {}, { owner = "native-owned", timeout_ms = 2000 },
	function(value) owned_receipt = value end)
check(run_until(function() return owned:is_settled() end), "owned native authentication refusal physically settles")
check(owned_receipt and not owned_receipt.ok and owned_receipt.status == 401
	and owned_receipt.error_body == response.body, "owned GET retains the real 401 receipt and complete error body")

owned_receipt = nil
response = { status = 200, body = '{"data":[]}', incomplete = true }
owned = Http.get_owned(base_url .. "/api/chat", {}, { owner = "native-owned", timeout_ms = 2000 },
	function(value) owned_receipt = value end)
check(run_until(function() return owned:is_settled() end), "owned native incomplete 200 physically settles")
check(owned_receipt and not owned_receipt.ok and owned_receipt.status == 200
	and owned_receipt.body == "", "an actual interrupted 200 cannot publish a complete models receipt")

local cancelled_callbacks = 0
owned = Http.get_owned(base_url .. "/slow", {}, { owner = "native-owned", timeout_ms = 2000 },
	function() cancelled_callbacks = cancelled_callbacks + 1 end)
check(run_until(function() return requests[#requests] and requests[#requests].path == "/slow" end),
	"owned cancellation reaches a real pending curl process")
check(owned:cancel() == false and not owned:is_settled(),
	"accepted native cancellation remains unsettled until the event loop observes actual exit/close")
local blocked_receipt
check(Http.get(base_url .. "/api/chat", {}, { owner = "native-owned" }, function(value) blocked_receipt = value end) == false
	and blocked_receipt and blocked_receipt.error == "previous request cleanup pending",
	"a logical legacy GET cannot acquire over a retained owned native cancellation")
local blocked = Http.get_owned(base_url .. "/api/chat", {}, { owner = "native-owned" }, function() end)
check(blocked.started == false and blocked:is_settled(), "a second owned GET acquires no process while cleanup is pending")
check(run_until(function() return owned:is_settled() end) and owned:cancel() == true,
	"cancelled native ownership retires only after physical process and handle settlement")
check(cancelled_callbacks == 0, "native late completion remains fenced after cancellation")

owned_receipt = nil
response = { status = 200, body = '{"data":[]}' }
local successor = Http.get_owned(base_url .. "/api/chat", {}, { owner = "native-owned", timeout_ms = 2000 },
	function(value) owned_receipt = value end)
check(successor.started == true and run_until(function() return successor:is_settled() end),
	"a fresh owned GET can acquire after the exact predecessor physically settles")
check(owned_receipt and owned_receipt.ok and owned_receipt.body == response.body,
	"post-cancellation retry receives its own real HTTP body")

Http.cancel()
for _, owner in ipairs({ "native-status", "native-partial", "native-bounded", "native-cancel" }) do Http.cancel(owner) end
Offer._reset_for_test()
for _, socket in ipairs(sockets) do close(socket) end
close(server)
-- The guard is unreferenced: successful cleanup returns when the curl process,
-- pipes and server sockets settle, rather than waiting for the deadline.
local drain_guard = uv.new_timer()
uv.timer_start(drain_guard, 2000, 0, function() uv.stop() end)
uv.unref(drain_guard)
uv.run()
uv.timer_stop(drain_guard)
close(drain_guard)
uv.run("nowait")
check(not uv.loop_alive(), "all native process, pipe and server owners settle after cancellation")
if #failures > 0 then
	io.stderr:write(string.format("FAIL native HTTP streaming receipts: %d/%d failed\n", #failures, checks))
	os.exit(1)
end
print(string.format("PASS native HTTP streaming receipts: %d checks", checks))
