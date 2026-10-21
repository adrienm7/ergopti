--- tests/hardware/llm_response_errors.lua

--- ==============================================================================
--- MODULE: Native Remote Provider Error Envelope Receipts
--- DESCRIPTION:
--- Public provider chat calls use actual curl, verified owned TLS and libuv.
--- Only endpoint, inert fixture tokens and independently supplied responses are
--- controlled. No inference service, graphical session or keyboard is required.
--- ==============================================================================

local uv = require("luv")
-- Every failure a protected boundary swallows must reach the runner output:
-- a raised recorder or callback otherwise only leaves "done" unset.
require("logger").set_sink(function(line, variant)
	if variant == "warn" or variant == "error" then io.stderr:write("LOG ", line, "\n") end
end)
local recorder_failures = 0
local unpack_args = table.unpack or unpack -- LuaJIT keeps the Lua 5.1 global.
--- Runs one recorder, printing its traceback before the native boundary hides it.
local function recorded(where, fn, ...)
	local args, count = { ... }, select("#", ...)
	local ok, failure = xpcall(function() fn(unpack_args(args, 1, count)) end, debug.traceback)
	if not ok then
		recorder_failures = recorder_failures + 1
		io.stderr:write("RECORDER FAILURE ", where, ": ", tostring(failure), "\n")
		error(failure, 0)
	end
end
local Remote = require("modules.llm.api_remote")
local Http = require("adapters.http_client")
local origin = assert(os.getenv("LLM_RESPONSE_ORIGIN"))
local root = assert(os.getenv("LLM_RESPONSE_ROOT"))
local corpus = require("test.response_error_contract")
assert(#corpus.vectors == 23, "every independent response vector executes")
local native_post, receipt = Http.post
Http.post = function(url, headers, body, callback, options)
	return native_post(url, headers, body, function(result)
		receipt = result
		recorded("HTTP completion relay", callback, result)
	end, options)
end
local native_spawn, exits = uv.spawn, {}
uv.spawn = function(command, options, callback)
	recorded("spawn admission", function()
		assert(command == "curl", "only the production HTTP transport starts a child, not " .. tostring(command))
		for _, argument in ipairs(options.args) do
			assert(argument ~= "--insecure" and argument ~= "-k", "TLS verification remains enabled")
		end
	end)
	return native_spawn(command, options, function(code, signal)
		exits[#exits + 1] = { code = code, signal = signal }
		recorded("child exit relay", callback, code, signal)
	end)
end
local failures = 0
for index, vector in ipairs(corpus.vectors) do
	local provider = vector.format == "openai" and "openai_compat" or vector.format
	local done, chunks, calls = nil, {}, 0
	assert(Remote.chat({ provider = provider, token = "owned-fixture-token", model = "fixture-model",
		base_url = origin .. "/case/" .. index }, nil, { { role = "user", content = "fixture prompt" } }, {},
		function(text) recorded("chunk recorder", function() chunks[#chunks + 1] = text end) end,
		function(text, err)
			recorded("terminal recorder", function()
				calls = calls + 1
				done = { text = text, error = err }
			end)
		end), "public request dispatch")
	uv.run()
	assert(done and calls == 1 and not uv.loop_alive(), string.format(
		"one terminal callback after native settlement (vector %d, calls %d, recorder failures %d)",
		index, calls, recorder_failures))
	local handles = 0
	uv.walk(function() handles = handles + 1 end)
	assert(handles == 0, "no retained native handle")
	local expected_file = assert(io.open(root .. "/response-" .. index .. ".json", "rb"))
	local expected_body = expected_file:read("*a")
	assert(expected_file:close())
	assert(receipt.ok and receipt.status == 200 and receipt.body == expected_body, "exact owned response bytes")
	assert(exits[index].code == 0 and exits[index].signal == 0, "healthy native curl child")
	local expected = type(vector.expected) == "string" and vector.expected or nil
	local good = expected and done.text == expected and done.error == nil and #chunks == 1 and chunks[1] == expected
		or not expected and done.text == "" and done.error == "empty reply" and #chunks == 0
	if not good then failures = failures + 1 end
	print((good and "PASS " or "FAIL ") .. vector.name .. " text=" .. string.format("%q", done.text)
		.. " error=" .. tostring(done.error))
end
print("Native remote provider response text: 23 checks, " .. failures .. " failures, "
	.. recorder_failures .. " recorder failures")
os.exit((failures == 0 and recorder_failures == 0) and 0 or 1)
