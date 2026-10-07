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
local ci = os.getenv("GITHUB_ACTIONS") == "true"
local ci_token = ci and os.getenv("GITHUB_TOKEN") or nil
if ci then
	-- RFC 6750 b64token is opaque: transport safety does not imply a GitHub
	-- prefix or length. This excludes control/header injection before curl stdin.
	assert(type(ci_token) == "string" and ci_token:match("^[A-Za-z0-9._~+/%-]+=*$"),
		"CI updater authentication is unavailable or invalid")
end

--- Reads an exact GitHub release-list path without URL alias normalization.
--- @param url any
--- @return string|nil
local function release_request_path(url)
	if type(url) ~= "string" or url:find("[%c%s]") then return nil end
	local suffix = url:match("^https://api%.github%.com(/[^#]*)$")
	if not suffix then return nil end
	local path, query = suffix:match("^([^?]+)%?(.*)$")
	if not path then path = suffix end
	local owner, repo = path:match("^/repos/([A-Za-z0-9_.%-]+)/([A-Za-z0-9_.%-]+)/releases$")
	if not owner or owner:match("^%.+$") or repo:match("^%.+$")
		or (query ~= nil and not query:match("^[A-Za-z0-9_.~%%=&+%-]*$")) then return nil end
	return path
end

-- The installed old-version build is this checkout's packaged manager. Its
-- immutable release URL comes from the shared defaults, never a caller URL.
local ci_release_path = nil
if ci then
	assert(type(Updater.release_api_url) == "function", "CI updater release owner is unavailable")
	ci_release_path = release_request_path(Updater.release_api_url())
	assert(ci_release_path ~= nil, "CI updater release owner is invalid")
end

--- Bounds independently redacted response text without cutting a UTF-8 character.
--- Request headers and URLs are never collected by this observational probe.
local function safe_detail(value)
	local raw = tostring(value or "")
	-- A server may echo even a short opaque credential below the generic
	-- redactor's threshold. Match the known value literally before truncation.
	if ci_token then
		raw = raw:gsub(ci_token:gsub("(%W)", "%%%1"), function() return rules.secret_placeholder end)
	end
	local text = Redact.apply(raw, rules, { home = HOME })
	text = text:gsub("https?://[^%s\"'<>]+", "<url>")
	local limit = 2048
	if #text <= limit then return text end
	while limit > 0 and text:byte(limit + 1) >= 128 and text:byte(limit + 1) < 192 do
		limit = limit - 1
	end
	return text:sub(1, limit) .. " <truncated>"
end

--- Records the same non-success transport response that the updater consumes.
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
		-- A conditional 304 carries no body; only the manager can admit its
		-- cached page. The original check still determines the failed verdict.
		local level = receipt.status == 304 and "notice" or "error"
		io.stderr:write("::" .. level .. " title=Linux updater live HTTP::" .. detail .. "\n")
	end
end

Updater._http_client.get = function(url, headers, options, callback)
	local sent_headers = headers
	local sent_options = options
	if ci and release_request_path(url) == ci_release_path then
		sent_headers = {}
		for name, value in pairs(headers or {}) do sent_headers[name] = value end
		sent_headers.Authorization = "Bearer " .. ci_token
		sent_options = {}
		for name, value in pairs(options or {}) do sent_options[name] = value end
		-- Even a same-origin redirect can leave this repository's release list.
		-- A genuine 3xx is a refusal, never an authenticated retry or fallback.
		sent_options.follow_redirects = false
		-- This request has one fixed endpoint, so it needs no managed-hop permission.
		-- Keep the conditional files and expected endpoint for final ETag association.
		sent_options.etag_affinity = nil
	end
	return transport_get(url, sent_headers, sent_options, function(result, ...)
		local captured = pcall(observe_response, result)
		if not captured then io.stderr:write("HTTP refusal evidence could not be captured.\n") end
		return callback(result, ...)
	end)
end

-- The real daemon's controller owns pause; the probe owns this controller's
-- lifetime. Lifecycle requests revoke admission rather than fabricating a
-- forever-active source for the native transfer/installation.
local probe_active = true
local function retire_probe() probe_active = false end
local script_actions = require("modules.shortcuts.script_actions").new({
	reset = retire_probe, reload = retire_probe, quit = retire_probe,
})
local is_paused = script_actions.is_paused

--- Releases the probe wrapper before the original process verdict is published.
local function finish(status)
	retire_probe()
	Updater._http_client.get = transport_get
	os.exit(status)
end

Updater.init({ interval_sec = 0, is_paused = is_paused })
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
-- A displayed archive path is not install authority. The manager keeps its
-- authentic private artifact and calls back only after physical settlement.
local install = Updater.install_update_async
local get_release = Updater.get_cached_release
local get_state = Updater.get_state
local selected = get_release()
local selected_tag = selected and selected.tag
local install_done, installed = false, false
local accepted = install(archive, function(ok)
	install_done, installed = true, ok == true
end, function()
	return probe_active and not install_done
		and package.loaded["modules.updater.manager"] == Updater
		and Updater.install_update_async == install and Updater.get_cached_release == get_release
		and Updater.get_state == get_state
		and script_actions.is_paused == is_paused and is_paused() == false
		and get_release() == selected and selected_tag == first.tag and selected.tag == selected_tag
end)
-- Admission is not completion. The retained installer owns its canonical
-- deadline and cleanup; no successful verdict/restart precedes its callback.
if accepted == true or get_state() == "installing" then
	while not install_done do luv.run("once") end
end
if not expect(accepted == true and install_done and installed, "installed") then finish(1) end

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
