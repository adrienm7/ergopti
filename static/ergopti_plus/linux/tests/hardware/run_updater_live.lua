--- tests/hardware/run_updater_live.lua

--- ==============================================================================
--- MODULE: The Linux Updater, Live, Against GitHub
--- DESCRIPTION:
--- Driven by run_updater_live.sh on an installed old build. Uses the installed
--- updater exactly as the tray does: the channel it follows by default, a check,
--- a second check (an ETag answer must not forget the release), the download
--- and its SHA-256, the installation, and the restart on the new version.
---
--- Measured before this existed: an installed prerelease asked the "stable"
--- channel and never found an update (HTTP 404), a 304 forgot a found release,
--- and an installed update waited for the next login to run.
--- ==============================================================================

local luv = require("luv")

local DRIVER, HOME = arg[1], arg[2]
local failures = {}

local function run_until(predicate, seconds)
	local deadline = os.time() + seconds
	while not predicate() and os.time() < deadline do luv.run("once") end
end

local function read(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

local function expect(ok, label)
	print((ok and "  ok   " or "  FAIL ") .. label)
	if not ok then failures[#failures + 1] = label end
	return ok
end

local Updater = require("modules.updater.manager")
local Json = require("json")
local Redact = require("diagnostics.redact")
local rules = assert(Json.decode(read(DRIVER .. "/../_shared/modules/diagnostics/redaction.json")))
local http_evidence = { schema_version = 1, responses = {} }
local evidence_dir = os.getenv("ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR")
local transport_get = Updater._http_client.get

--- Bounds independently redacted response text without cutting a UTF-8 character.
--- Request headers and URLs are never collected by this observational probe.
local function safe_detail(value)
	local text = Redact.apply(tostring(value or ""), rules, { home = HOME })
	text = text:gsub("https?://[^%s\"'<>]+", "<url>")
	local limit = 2048
	if #text <= limit then return text end
	while limit > 0 and text:byte(limit + 1) >= 128 and text:byte(limit + 1) < 192 do
		limit = limit - 1
	end
	return text:sub(1, limit) .. " <truncated>"
end

--- Records only the same refused response that the actual updater consumes.
--- Missing header metadata is named rather than guessed to be a rate limit.
local function observe_response(result)
	if type(result) ~= "table" or result.ok == true then return end
	local decoded = type(result.error_body) == "string" and Json.decode(result.error_body) or nil
	local message = type(decoded) == "table" and type(decoded.message) == "string"
		and decoded.message or result.error_body
	local receipt = {
		status = result.status,
		error = safe_detail(result.error),
		message = safe_detail(message),
		body = safe_detail(result.error_body),
		headers_available = type(result.headers) == "table",
	}
	http_evidence.responses[#http_evidence.responses + 1] = receipt
	if evidence_dir and evidence_dir ~= "" then
		local file = assert(io.open(evidence_dir .. "/http.json", "wb"))
		assert(file:write(Json.encode(http_evidence) .. "\n"))
		assert(file:close())
	end
	if os.getenv("GITHUB_ACTIONS") == "true" then
		local detail = receipt.error .. "; " .. receipt.message
		if not receipt.headers_available then detail = detail .. "; response headers unavailable" end
		detail = detail:gsub("%%", "%%25"):gsub("\r", "%%0D"):gsub("\n", "%%0A")
		io.stderr:write("::error title=Linux updater live HTTP::" .. detail .. "\n")
	end
end

Updater._http_client.get = function(url, headers, options, callback)
	return transport_get(url, headers, options, function(result, ...)
		local captured = pcall(observe_response, result)
		if not captured then io.stderr:write("HTTP refusal evidence could not be captured.\n") end
		return callback(result, ...)
	end)
end

--- Releases the probe wrapper before the original process verdict is published.
local function finish(status)
	Updater._http_client.get = transport_get
	os.exit(status)
end

Updater.init({ interval_sec = 0 })
print("  installed " .. Updater.current_version() .. ", channel " .. Updater.get_channel())
expect(Updater.current_version() == "0.0.0-dev.1", "the installed build reports its old version")
expect(Updater.get_channel() == "dev", "a prerelease build follows the prerelease channel by default")

local function check()
	local done, result = false, nil
	Updater.check_for_updates(nil, function(available, release, err)
		done, result = true, { available = available, tag = release and release.tag, err = err }
	end)
	run_until(function() return done end, 60)
	return result or { available = false, err = "no answer" }
end

local first = check()
print("  check: " .. tostring(first.tag) .. " " .. tostring(first.err))
if not expect(first.available and first.tag ~= nil, "the newest release is found") then finish(1) end
local second = check()
expect(second.available and second.tag == first.tag, "a second check keeps it (" .. tostring(second.err) .. ")")

local done, archive, download_error = false, nil, nil
Updater.download_update(nil, function(path, err) done, archive, download_error = true, path, err end)
run_until(function() return done end, 300)
if not expect(archive ~= nil, "downloaded and SHA-256 verified (" .. tostring(download_error) .. ")") then finish(1) end
if not expect(Updater.install_update(archive) == true, "installed") then finish(1) end

local stamp = read(HOME .. "/.local/lib/ergopti/_shared/build_stamp.txt") or ""
local installed = stamp:match("version=([^\n]+)")
expect(installed and ("v" .. installed) == first.tag, "the installation now carries " .. tostring(first.tag))
expect(read(HOME .. "/.local/lib/ergopti.old/_shared/build_stamp.txt") ~= nil, "the previous version is kept as a backup")

-- The restart, from this checkout's restarter: the running daemon's own code.
package.path = DRIVER .. "/?.lua;" .. DRIVER .. "/?/init.lua;" .. package.path
package.loaded["modules.updater.restarter"] = nil
local how = dofile(DRIVER .. "/modules/updater/restarter.lua").restart({
	wrapper = Updater.installed_launcher(), args = { "--verbose" }, cgroup = "0::/test.scope\n",
})
expect(how == "relay", "the restart relay is armed")
print("  (this process exits; the relay starts the new daemon)")
local verdict = io.open(HOME .. "/verdict", "w")
verdict:write(#failures == 0 and "ok\n" or table.concat(failures, "\n"))
verdict:close()
finish(#failures == 0 and 0 or 1)
