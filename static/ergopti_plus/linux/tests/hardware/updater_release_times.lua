--- tests/hardware/updater_release_times.lua

-- Owned HTTPS, cache routing and installed-version metadata are controlled.
-- Public updater checks, JSON parsing, curl, files and handle settlement are native.
local uv = require("luv")
local root = assert(os.getenv("UPDATER_TIME_ROOT"))
local origin = assert(os.getenv("UPDATER_TIME_ORIGIN"))
local Paths = require("infra.config_paths")
Paths.home = function() return root end
local M = require("modules.updater.manager")
-- A checkout's "local" version deliberately skips canonical asset admission.
local current = "1.0.0"
M.current_version = function() return current end
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
for index = 1, 12 do
	local metadata_file = assert(io.open(root .. "/expected-" .. index .. ".json", "rb"))
	local metadata = assert(require("json").decode(metadata_file:read("*a")))
	assert(metadata_file:close())
	current = metadata.current
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
	local got, others = answer.result.others, metadata.others
	local good = answer.available == metadata.available and answer.result.state == metadata.state
		and answer.result.latest == "v1.2.0" and answer.error == nil and #got == #others
	if metadata.available then
		good = good and answer.release and answer.release.tag == "v1.2.0"
			and answer.release.published_at == metadata.published_at
			and answer.release.download_url == origin .. "/never-requested-bundle"
			and answer.release.checksum_url == origin .. "/never-requested-checksum"
			and M.get_cached_release() == answer.release
	else
		good = good and answer.release == nil and M.get_cached_release() == nil
	end
	for n, other in ipairs(others) do
		good = good and got[n] and got[n].channel == other.channel and got[n].tag == other.tag
	end
	if not good then failures = failures + 1 end
	print((good and "PASS " or "FAIL ") .. "public updater release-time case=" .. index
		.. " others=" .. #got .. " published_at=" .. tostring(answer.release and answer.release.published_at) .. " state=" .. tostring(answer.result.state) .. " reason=" .. tostring(answer.result.reason_key))
end
print("Native public updater release times: 12 checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
