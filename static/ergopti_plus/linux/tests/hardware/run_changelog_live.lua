--- tests/hardware/run_changelog_live.lua

--- ==============================================================================
--- MODULE: The Release List Window, Live, In Real WebKit
--- DESCRIPTION:
--- Opens the tray's release-notes window under a real display server with
--- real WebKit2GTK and lets the Linux bridge fetch GitHub's releases through
--- its curl adapter, as the daemon does. The page must list the published
--- releases, newest first, on the channel the installation follows, show the
--- selected release's notes, and switch channels on a click.
---
--- Exit 0 = listed and switched. 1 = it did not. 2 = the environment cannot
--- host the test (no display, no WebKit, no lgi, no luv, no network).
--- ==============================================================================

local WAIT_SECONDS = 0.1

local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

print("=== the release list window, fetched from GitHub in a real WebKit page ===")

if not os.getenv("DISPLAY") and not os.getenv("WAYLAND_DISPLAY") then
	abort("no display server — run under xvfb-run.")
end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed.") end
local ok_webkit = pcall(function() return lgi.require("WebKit2", "4.1") end)
	or pcall(function() return lgi.require("WebKit2", "4.0") end)
if not ok_webkit then abort("WebKit2GTK is not available to lgi.") end
local ok_luv, luv = pcall(require, "luv")
if not ok_luv then abort("lua-luv is not installed (the curl adapter runs on it).") end
local Gtk = lgi.require("Gtk", "3.0")

-- The newest release, straight from GitHub, to compare the page with.
local pipe = io.popen("curl -fsS --max-time 20 'https://api.github.com/repos/adrienm7/ergopti/releases?per_page=1'")
local latest_json = pipe and pipe:read("*a") or ""
if pipe then pipe:close() end
local latest = latest_json:match('"tag_name"%s*:%s*"([^"]+)"')
if not latest then abort("GitHub's release API is unreachable.") end
local latest_is_prerelease = latest_json:match('"prerelease"%s*:%s*true') ~= nil
print("  newest published release: " .. latest .. (latest_is_prerelease and " (prerelease)" or ""))

local Manager = require("ui.webview_manager")
local Updater = require("modules.updater.manager")
Manager.set_daemon_state({ _version = "0.0.0-dev.1" })

local function pump(seconds)
	for _ = 1, math.max(1, math.floor(seconds / WAIT_SECONDS)) do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		luv.run("nowait")
		os.execute("sleep " .. tostring(WAIT_SECONDS))
	end
end

--- Evaluates JavaScript and returns its string result.
local function eval_sync(webview, source)
	local answer, done = nil, false
	webview:run_javascript(source, nil, function(_, result)
		local ok, value = pcall(function()
			return webview:run_javascript_finish(result):get_js_value():to_string()
		end)
		answer = ok and value or nil
		done = true
	end, nil)
	for _ = 1, 100 do
		pump(WAIT_SECONDS)
		if done then return answer end
	end
	return answer
end

--- Polls `probe` until `accept(value)` or the deadline.
local function wait_for(webview, probe, accept, seconds)
	local value = nil
	for _ = 1, math.floor(seconds / 0.5) do
		pump(0.5)
		value = eval_sync(webview, probe)
		if value and accept(value) then return value end
	end
	return value
end

local failures = {}
local function expect(ok, label)
	print((ok and "  ok   " or "  FAIL ") .. label)
	if not ok then failures[#failures + 1] = label end
end

if not Manager.show("changelog") then
	print("  FAIL the release list window did not open")
	os.exit(1)
end
local webview = Manager.webview_for("changelog")

local expected_channel = Updater.get_channel() == "dev" and "dev" or "main"
local STATE = "JSON.stringify({"
	.. "tags: Array.prototype.map.call(document.querySelectorAll('#release-list .release-item-tag'), function (e) { return e.textContent; }),"
	.. "dev: document.getElementById('btn-dev').classList.contains('active'),"
	.. "error: (document.getElementById('error-overlay') || {style: {}}).style.display === 'flex',"
	.. "content: (document.getElementById('release-content') || document.body).textContent.length"
	.. "})"

local state = wait_for(webview, STATE, function(value) return value:find('"tags":%["') ~= nil end, 45) or ""
print("  page: " .. state:sub(1, 300))
expect(not state:find('"error":true', 1, true), "no error is shown")
expect(state:find('"tags":["' .. latest .. '"', 1, true) ~= nil,
	"the newest release (" .. latest .. ") heads the list")
expect(state:find('"dev":' .. tostring(expected_channel == "dev"), 1, true) ~= nil,
	"the list opens on the channel the installation follows (" .. expected_channel .. ")")

-- The other channel, clicked as a user does.
local other = expected_channel == "dev" and "btn-stable" or "btn-dev"
eval_sync(webview, "document.getElementById('" .. other .. "').click(); 'clicked'")
-- Settled once the other channel's answer is drawn: its own list, or the
-- page's "no release" row for a channel with none (stable, while every
-- release is a prerelease).
local SETTLED = "JSON.stringify({ dev: document.getElementById('btn-dev').classList.contains('active'),"
	.. " loading: (document.getElementById('loading') || {style: {}}).style.display !== 'none',"
	.. " rows: document.querySelectorAll('#release-list > div').length })"
wait_for(webview, SETTLED, function(value)
	return value:find('"dev":' .. tostring(expected_channel ~= "dev"), 1, true) ~= nil
		and value:find('"rows":0', 1, true) == nil
end, 45)
local switched = eval_sync(webview, STATE) or ""
print("  after the click: " .. switched:sub(1, 300))
expect(switched:find('"dev":' .. tostring(expected_channel ~= "dev"), 1, true) ~= nil, "the channel switches on a click")
expect(not switched:find('"error":true', 1, true), "and loads without an error")

if #failures == 0 then os.exit(0) end
os.exit(1)
