--- tests/hardware/desktop/run_release_notes.lua

--- ==============================================================================
--- MODULE: The Update-Check Window's Release Notes Pane (PAR-52), Live
--- DESCRIPTION:
--- Opens the tray's update-check window (ui/update_check/bridge.lua open())
--- over the real updater (modules/updater/manager.lua) in real WebKit2GTK.
--- Only the release list comes from a local fixture instead of GitHub, and
--- `xdg-open` is a recorder first on PATH; the check, the classification,
--- the session's link policy and the shared page are the shipped ones.
--- 1. An offered release shows its changelog in the notes pane, without the
---    download table of the release body.
--- 2. Only the repository's link is a link: clicking it opens exactly that URL.
--- 3. An outside URL posted through the page's own bridge opens nothing.
---
--- Exit 0 = every check held. 1 = a failure. 2 = no environment.
--- ==============================================================================

local WAIT_ATTEMPTS = 100
local WAIT_SECONDS  = 0.05
local BUNDLE        = "ergopti-plus-linux.tar.gz"
local REPO_LINK     = "https://github.com/adrienm7/ergopti/pull/101"
local OUTSIDE_LINK  = "https://example.com/not-the-repository"

local _failures, _checks = 0, 0

--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print(string.format("  %s %s", condition and "ok  " or "FAIL", what))
end

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

if not os.getenv("DISPLAY") and not os.getenv("WAYLAND_DISPLAY") then abort("no display server.") end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed.") end
local Gtk = lgi.require("Gtk", "3.0")
require("core.lifecycle.engine.compat.utf8").install()
local Json = require("core.text.engine.json")
local recorder = assert(arg[1], "usage: run_release_notes.lua <xdg-open record file>")

--- The release body the publisher writes: a marked changelog, then downloads.
local BODY = table.concat({
	"<!-- ergopti:section=changelog -->",
	"## Changelog",
	"",
	"- Release notes proof line, see [the pull request](" .. REPO_LINK .. ").",
	"- An outside page: [elsewhere](" .. OUTSIDE_LINK .. ").",
	"<!-- /ergopti:section -->",
	"<!-- ergopti:section=downloads -->",
	"## Downloads",
	"",
	"| Linux | download-table-proof-row |",
	"|---|---|",
	"<!-- /ergopti:section -->",
}, "\n")

--- One release object of the GitHub list, with the Linux bundle.
--- @param tag string
--- @return table
local function release(tag)
	local base = "https://github.com/adrienm7/ergopti/releases/download/" .. tag .. "/" .. BUNDLE
	return { tag_name = tag, prerelease = true, published_at = "2026-11-09T00:00:00Z", body = BODY,
		assets = { { name = BUNDLE, browser_download_url = base },
			{ name = BUNDLE .. ".sha256", browser_download_url = base .. ".sha256" } } }
end

--- Pumps the GTK loop until `predicate` holds or the wait runs out.
--- @param predicate function
--- @return boolean
local function pump_until(predicate)
	for _ = 1, WAIT_ATTEMPTS do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		if predicate() then return true end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return predicate()
end

local Manager = require("ui.webview_manager")

--- Evaluates JavaScript in the window and returns its string value.
--- @param source string
--- @return string|nil
local function eval_sync(source)
	local webview = Manager.webview_for("update_check")
	if not webview then return nil end
	local answer, done = nil, false
	webview:run_javascript(source, nil, function(_, result)
		local ok, value = pcall(function() return webview:run_javascript_finish(result):get_js_value():to_string() end)
		answer, done = ok and value or nil, true
	end, nil)
	for _ = 1, WAIT_ATTEMPTS do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		if done then return answer end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return answer
end

--- The URLs the recorder xdg-open received.
--- @return table
local function opened()
	local urls = {}
	local file = io.open(recorder, "r")
	if not file then return urls end
	for line in file:lines() do urls[#urls + 1] = line end
	file:close()
	return urls
end

local function run()
	Manager.init()
	if not Manager.native_available() then abort("WebKit2GTK is not available to lgi.") end
	local Updater = require("modules.updater.manager")
	local list = Json.encode({ release("v0.0.0-dev.150"), release("v0.0.0-dev.140") })
	-- The network and the installed build are the only seams.
	Updater._fetch_feed = function(callback) callback(nil, "no feed in this proof"); return true end
	Updater._fetch_releases = function(_, callback) callback(list, 200, nil); return true end
	Updater.current_version = function() return "0.0.0-dev.140" end
	Updater.get_channel = function() return "dev" end
	print("=== update-check window: release notes pane, session " .. (os.getenv("ERGOPTI_PROOF_SESSION") or "?") .. " ===")
	check(require("ui.update_check.bridge").open({ updater = Updater }) == true, "the update-check window opens")
	local shown = pump_until(function()
		return eval_sync("String(!document.getElementById('notes').hidden)") == "true"
	end)
	check(shown, "the offered release shows the notes pane")
	local text = eval_sync("document.getElementById('release-notes').textContent") or ""
	check(text:find("Release notes proof line", 1, true) ~= nil, "the pane shows the release's changelog")
	check(text:find("download-table-proof-row", 1, true) == nil, "the pane leaves the download table out")
	local links = eval_sync("Array.prototype.map.call(document.querySelectorAll('#release-notes a'),"
		.. " function (a) { return a.getAttribute('data-url'); }).join(' ')") or ""
	check(links == REPO_LINK, "only the repository link is a link: " .. links)

	eval_sync("document.querySelector('#release-notes a').click(); 'clicked'")
	local clicked = pump_until(function() return #opened() == 1 end)
	check(clicked and opened()[1] == REPO_LINK, "a click opens exactly the repository URL")

	eval_sync("makeHostBridge('update_check_bridge')({ action: 'open_url', url: '" .. OUTSIDE_LINK .. "' }); 'posted'")
	pump_until(function() return #opened() > 1 end)
	check(#opened() == 1, "an outside URL posted through the page's bridge opens nothing")
	print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
	return _failures == 0 and 0 or 1
end

local ran, result = pcall(run)
pcall(Manager.shutdown)
if not ran then error(result, 0) end
os.exit(result)
