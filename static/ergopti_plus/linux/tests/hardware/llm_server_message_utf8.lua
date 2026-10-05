--- tests/hardware/llm_server_message_utf8.lua

--- ==============================================================================
--- MODULE: Native Provider Error Message Unicode Receipts
--- DESCRIPTION:
--- Public Remote.chat receives genuine complete HTTP refusals over verified owned
--- TLS and native curl/libuv, preserving Unicode in bounded terminal diagnostics.
--- Expected strings are independent; no graphical or physical keyboard is used.
--- ==============================================================================

local uv = require("luv")
local Utf8 = require("compat.utf8")
local Remote = require("modules.llm.api_remote")
local Http = require("adapters.http_client")
local origin = assert(os.getenv("LLM_RESPONSE_ORIGIN"))
local root = assert(os.getenv("LLM_RESPONSE_ROOT"))
local vectors = require("tests.fixtures.llm_server_message_contract").vectors
assert(#vectors == 45)
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
local failures = 0
for index, vector in ipairs(vectors) do
	local provider = vector.format == "openai" and "openai_compat" or vector.format
	local done, calls, chunks = nil, 0, 0
	assert(Remote.chat({ provider = provider, token = "owned-fixture-token", model = "fixture-model",
		base_url = origin .. "/case/" .. index }, nil, { { role = "user", content = "fixture prompt" } },
		{ temperature = 0.25, max_tokens = 40 }, function() chunks = chunks + 1 end, function(text, err)
			calls = calls + 1; done = { text = text, error = err }
		end))
	uv.run()
	assert(done and calls == 1 and chunks == 0 and not Remote.is_active() and not uv.loop_alive())
	local handles = 0
	uv.walk(function() handles = handles + 1 end)
	assert(handles == 0)
	local wire = assert(io.open(root .. "/response-" .. index .. ".json","rb"))
	local expected_body = wire:read("*a"); assert(wire:close())
	assert(receipt.ok == false and receipt.status == 401 and receipt.body == ""
		and receipt.error_body == expected_body, "complete genuine HTTP error response")
	assert(exits[index].code == 22 and exits[index].signal == 0, "curl fail-with-body completed rejection")
	local valid_utf8 = Utf8.len(done.error) ~= nil
	local good = done.text == "" and done.error == vector.expected and valid_utf8
	if not good then failures = failures + 1 end
	local hex = done.error:gsub(".", function(byte) return string.format("%02x", byte:byte()) end)
	print((good and "PASS " or "FAIL ") .. vector.name .. " valid_utf8=" .. tostring(valid_utf8)
		.. " error_bytes=" .. #done.error .. " callback_hex=" .. hex)
end
print("Native provider error UTF-8 boundary: 45 checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
