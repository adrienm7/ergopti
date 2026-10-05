--- tests/hardware/http_empty_headers.lua

-- The companion Python fixture records actual wire headers independently.
local uv = require("luv")
local Http = require("adapters.http_client")
local Json = require("json")
local origin = assert(os.getenv("HTTP_EMPTY_HEADER_ORIGIN"))
local owner = "empty-header-native-fixture"
local checks, failures, spawns = 0, 0, 0
local native_spawn = uv.spawn
local native_write, config_pipe, observed_config = uv.write, nil, ""
uv.spawn = function(command, options, callback)
	spawns = spawns + 1
	assert(command == "curl" and options.args[1] == "--disable")
	config_pipe, observed_config = options.stdio[1], ""
	return native_spawn(command, options, callback)
end
uv.write = function(stream, data, callback)
	if stream == config_pipe then observed_config = observed_config .. data end
	return native_write(stream, data, callback)
end
local function check(name, good)
	checks = checks + 1
	if not good then failures = failures + 1 end
	print((good and "PASS " or "FAIL ") .. name)
end
local methods = { "get", "get_owned", "post", "postStream" }
local function dispatch(method, path, headers)
	local result, calls, chunks = nil, 0, ""
	local function done(value) result, calls = value, calls + 1 end
	local options = { timeout_ms = 3000, owner = owner, follow_redirects = true }
	local url = origin .. "/" .. method .. "/" .. path
	local operation
	if method == "get" or method == "get_owned" then
		operation = Http[method](url, headers, options, done)
	elseif method == "post" then
		operation = Http.post(url, headers, "literal-fixture-body", done, options)
	else
		operation = Http.postStream(url, headers, "literal-fixture-body", options,
			function(chunk) chunks = chunks .. chunk end, done)
	end
	uv.run()
	assert(not uv.loop_alive() and not Http.isActive(owner), "native resources retire after each receipt")
	if method == "get_owned" then assert(operation:is_settled()) end
	return result, calls, chunks, operation
end
for _, method in ipairs(methods) do
	for _, mode in ipairs({ "ordinary", "empty-custom", "empty-defaults", "absent", "empty-sensitive",
		"ows-space", "ows-tab", "ows-mixed" }) do
		local headers = {}
		if mode == "ordinary" then
			headers = { ["X-Ordinary-Fixture"] = "literal-value", Accept = "application/json",
				["User-Agent"] = "Fixture/1", ["Content-Type"] = "application/json" }
		elseif mode == "empty-custom" then
			headers = { ["X-Empty-Fixture"] = "", ["X-Ordinary-Fixture"] = "literal-value" }
		elseif mode == "empty-defaults" then
			headers = { ["X-Empty-Fixture"] = "", Accept = "", ["User-Agent"] = "", ["Content-Type"] = "" }
		elseif mode == "empty-sensitive" then
			-- Empty synthetic authorization still selects the existing no-follow fence.
			headers = { Authorization = "", ["X-Empty-Fixture"] = "" }
		elseif mode:match("^ows%-") then
			local value = ({ ["ows-space"] = " ", ["ows-tab"] = "\t", ["ows-mixed"] = " \t " })[mode]
			headers = { ["X-Empty-Fixture"] = value, Accept = value, ["User-Agent"] = value,
				["Content-Type"] = value, ["X-Ordinary-Fixture"] = " \tliteral \t value \t" }
		end
		local result, calls, chunks, operation = dispatch(method, mode, headers)
		assert((method == "get_owned" and operation.started == true) or operation == true)
		assert(result and calls == 1, "one terminal callback")
		local sensitive = mode == "empty-sensitive"
		assert(result.status == (sensitive and 302 or 200) and result.ok == not sensitive)
		local body = method == "postStream" and chunks or (sensitive and result.error_body or result.body)
		local wire = assert(Json.decode(body))
		if mode:match("^ows%-") then
			assert(observed_config:find('header = "X-Ordinary-Fixture:  \\tliteral \\t value \\t"', 1, true),
				"genuinely nonempty caller bytes stay serialized exactly, including surrounding and internal OWS")
		end
		check(method .. " " .. mode .. " preserves literal field presence and native defaults", wire.valid == true)
	end
	for _, byte in ipairs({ "\0", "\r", "\n" }) do
		for _, field in ipairs({ "name", "value" }) do
			local headers = field == "name" and { ["X-Bad" .. byte] = "" } or { ["X-Empty-Fixture"] = byte }
			local before = spawns
			local result, calls, _, operation = dispatch(method, "malformed", headers)
			if method == "get_owned" then
				assert(operation.started == false and result and result.ok == false and calls == 1)
			else
				assert(operation == false and result and result.ok == false and result.status == 0 and calls == 1,
					"ordinary metadata refusal publishes its existing preflight failure receipt")
			end
			check(method .. " forbidden byte " .. byte:byte() .. " in " .. field .. " never spawns curl", spawns == before)
		end
	end
end
assert(checks == 56, "all original 44 controls and 12 OWS wire controls must execute")
print("Native empty-header receipts: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
