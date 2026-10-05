--- tests/hardware/updater_release_tags.lua

-- Owned HTTPS, cache routing and installed-version metadata are controlled.
-- Public updater checks, JSON parsing, curl, files and handle settlement are native.
local uv = require("luv")
local root = assert(os.getenv("UPDATER_TAG_ROOT"))
local origin = assert(os.getenv("UPDATER_TAG_ORIGIN"))
local Paths = require("infra.config_paths")
Paths.home = function() return root end
local M = require("modules.updater.manager")
-- A checkout's "local" version deliberately skips canonical asset admission.
M.current_version = function() return "1.0.0" end
M.release_api_url = function() return origin .. "/releases?per_page=100" end
local native_get, receipt = M._http_client.get
M._http_client.get = function(url, headers, options, callback)
	return native_get(url, headers, options, function(result)
		receipt = result
		callback(result)
	end)
end
local native_spawn, exits = uv.spawn, {}
uv.spawn = function(command, options, callback)
	assert(command == "curl", "only the HTTP transport may start a child")
	for _, argument in ipairs(options.args) do
		assert(argument ~= "--insecure" and argument ~= "-k", "TLS verification stays enabled")
	end
	return native_spawn(command, options, function(code, signal)
		exits[#exits + 1] = { code = code, signal = signal }
		callback(code, signal)
	end)
end
local failures = 0
for index = 1, 10 do
	local answer, calls
	assert(M.check_for_updates("main", function(available, release, err, result)
		answer = { available = available, release = release, error = err, result = result }
		calls = (calls or 0) + 1
	end))
	uv.run()
	assert(answer and calls == 1 and not uv.loop_alive(), "one callback after native handle settlement")
	local file = assert(io.open(root .. "/response-" .. index .. ".json", "rb"))
	local expected = file:read("*a")
	assert(file:close())
	assert(receipt.ok and receipt.status == 200 and receipt.body == expected, "complete independently written JSON bytes")
	assert(exits[index].code == 0 and exits[index].signal == 0, "a completed native curl response")
	local tag_file = assert(io.open(root .. "/expected-tag-" .. index, "rb"))
	local expected_tag = tag_file:read("*a")
	assert(tag_file:close())
	local good
	if expected_tag == "" then
		good = answer.available == false and answer.release == nil and answer.error == nil
			and answer.result.state == "no_release"
	else
		good = answer.available == true and answer.release and answer.release.tag == expected_tag
			and answer.result.state == "available" and answer.error == nil
			and answer.release.download_url == origin .. "/never-requested-bundle"
			and answer.release.checksum_url == origin .. "/never-requested-checksum"
	end
	if not good then failures = failures + 1 end
	print((good and "PASS " or "FAIL ") .. "public updater release-tag case=" .. index
		.. " state=" .. tostring(answer.result.state) .. " reason=" .. tostring(answer.result.reason_key))
end
print("Native public updater release tags: 10 checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
