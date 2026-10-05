--- tests/hardware/updater_conditional_receipts.lua

-- Run through run_updater_conditional_receipts.py with a private trusted TLS server.
-- URL and cache routing are controlled; HTTP, curl, ETags, JSON and files are native.
local uv = require("luv")
local root = assert(os.getenv("HTTP_CONDITIONAL_ROOT"))
local mode = assert(os.getenv("HTTP_CONDITIONAL_MODE"))
local Paths = require("infra.config_paths")
Paths.home = function() return root end
local M = require("modules.updater.manager")
M.release_api_url = function()
	return assert(os.getenv("HTTP_CONDITIONAL_ORIGIN")) .. "/releases?per_page=20"
end
local native_get, receipts = M._http_client.get, {}
M._http_client.get = function(url, headers, options, callback)
	return native_get(url, headers, options, function(result)
		receipts[#receipts + 1] = result
		callback(result)
	end)
end
local native_spawn, exits = uv.spawn, {}
uv.spawn = function(command, options, callback)
	assert(command == "curl", "only the native HTTP transport may start a process")
	for _, argument in ipairs(options.args) do
		assert(argument ~= "--insecure" and argument ~= "-k", "TLS verification stays enabled")
	end
	return native_spawn(command, options, function(code, signal)
		exits[#exits + 1] = { code = code, signal = signal }
		callback(code, signal)
	end)
end
local old = '[{"tag_name":"v0.1.1","draft":false,"prerelease":false,"assets":[]}]'
local fresh = old:gsub("v0%.1%.1", "v0.1.2")
local function read(path)
	local file = assert(io.open(root .. "/" .. path, "rb"))
	local value = file:read("*a")
	assert(file:close())
	return value
end
local function fetch(index)
	local result, calls
	assert(M._fetch_releases("main", function(body, status, err, reason)
		result = { body = body, status = status, error = err, reason = reason }
		calls = (calls or 0) + 1
	end))
	uv.run()
	assert(result and calls == 1 and not uv.loop_alive(), "one callback after native handle settlement")
	assert(exits[index].signal == 0)
	if result.status == 304 then
		assert(receipts[index].status == 304 and receipts[index].ok == false and receipts[index].body == "",
			"the adapter retains the real status and empty body")
	end
	print("request=" .. index .. " status=" .. result.status .. " curl=" .. exits[index].code
		.. " error=" .. tostring(result.error) .. " reason=" .. tostring(result.reason))
	return result
end
local checks, failures = 0, 0
local function check(name, good)
	checks = checks + 1
	if not good then failures = failures + 1 end
	print((good and "PASS " or "FAIL ") .. name)
end
if mode == "reset" then
	local first = fetch(1)
	check("initial 200 is cached without a conditional header", first.body == old and first.status == 200
		and first.error == nil and exits[1].code == 0 and read("wire-1-validator") == "")
	local failed = fetch(2)
	assert(exits[2].code == 56, "the server performs a real reset after curl receives the 304 header")
	assert(receipts[2].error_body == nil, "a failed 304 has no completed error-body receipt")
	assert(read(".cache/ergopti_updater_etag_main-page-1-size-20.txt") == '"fixture-v2"\n',
		"the real failed transfer advanced its native ETag file")
	check("incomplete 304 rejects its stale page and validator association", failed.body == nil
		and failed.status == 304 and type(failed.error) == "string" and failed.reason == "no_connection"
		and read("wire-2-validator") == '"fixture-v1"')
	local replacement = fetch(3)
	local unchanged = fetch(4)
	assert(receipts[4].error_body == "", "a completed 304 carries an empty error-body receipt")
	check("next wire GET is full and fresh 200 restores conditional caching", replacement.body == fresh
		and replacement.status == 200 and replacement.error == nil and read("wire-3-validator") == ""
		and unchanged.body == fresh and unchanged.status == 304 and unchanged.error == nil
		and read("wire-4-validator") == '"fixture-v2"' and exits[3].code == 0 and exits[4].code == 0)
elseif mode == "completed" then
	local first, unchanged = fetch(1), fetch(2)
	assert(receipts[2].error_body == "")
	check("completed empty-body 304 preserves its accepted page", first.body == old and first.status == 200
		and unchanged.body == old and unchanged.status == 304 and unchanged.error == nil
		and read("wire-2-validator") == '"fixture-v1"' and exits[2].code == 0)
else
	assert(mode == "uncached")
	local result = fetch(1)
	assert(receipts[1].error_body == "")
	check("completed 304 without a cached page remains unexpected", result.body == nil and result.status == 304
		and type(result.error) == "string" and result.reason == "unexpected" and exits[1].code == 0)
end
assert(checks == (mode == "reset" and 3 or 1), "native conditional receipt floor changed")
print("Native TLS updater conditional receipts: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
