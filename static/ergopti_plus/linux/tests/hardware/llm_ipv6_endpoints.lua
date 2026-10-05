--- tests/hardware/llm_ipv6_endpoints.lua

--- ==============================================================================
--- MODULE: Native IPv6 Provider Endpoint Receipts
--- DESCRIPTION:
--- Public provider calls use actual IPv4/IPv6 sockets, verified owned TLS, curl
--- and libuv. Independent server oracles check exact request identity and fields.
--- These network receipts do not require a graphical or physical keyboard host.
--- ==============================================================================

local uv = require("luv")
local Json = require("json")
local Remote = require("modules.llm.api_remote")
local Http = require("adapters.http_client")
local vectors = assert(Json.decode(assert(os.getenv("AUDIT_VECTORS"))))
assert(#vectors == 8)
local native_post, receipt = Http.post
Http.post = function(url, headers, body, callback, options)
	return native_post(url, headers, body, function(result)
		receipt = result
		callback(result)
	end, options)
end
local native_spawn, exits = uv.spawn, {}
uv.spawn = function(command, options, callback)
	assert(command == "curl")
	for _, argument in ipairs(options.args) do assert(argument ~= "--insecure" and argument ~= "-k") end
	return native_spawn(command, options, function(code, signal)
		exits[#exits + 1] = { code = code, signal = signal }
		callback(code, signal)
	end)
end
local failures, accepted_count = 0, 0
for _, v in ipairs(vectors) do
	receipt = nil
	local done, calls, chunks = nil, 0, {}
	local accepted = Remote.chat({ provider = v.provider, model = v.model,
		token = v.token, base_url = v.base }, nil,
		{ { role = "system", content = 'system "owned"\n' }, { role = "user", content = "fixture prompt é 😀" } },
		{ temperature = 0.25, max_tokens = 40 }, function(text) chunks[#chunks + 1] = text end,
		function(text, err) calls = calls + 1; done = { text = text, error = err } end)
	uv.run()
	assert(done and calls == 1 and not Remote.is_active() and not uv.loop_alive())
	local handles = 0
	uv.walk(function() handles = handles + 1 end)
	assert(handles == 0)
	if accepted then
		accepted_count = accepted_count + 1
		assert(receipt and receipt.ok and receipt.status == 200 and receipt.body == v.response)
		assert(exits[#exits].code == 0 and exits[#exits].signal == 0)
	else
		assert(receipt == nil and #chunks == 0)
	end
	local good = accepted == true and done.text == "valid reply" and done.error == nil
		and #chunks == 1 and chunks[1] == "valid reply"
	if not good then failures = failures + 1 end
	print((good and "PASS " or "FAIL ") .. v.name .. " dispatch=" .. tostring(accepted)
		.. " text=" .. string.format("%q", done.text) .. " error=" .. tostring(done.error))
end
assert(#exits == accepted_count, "every accepted public request owns one actual native curl child")
print("Native curl children: " .. #exits)
print("Native public provider IPv6 identity: 8 checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
