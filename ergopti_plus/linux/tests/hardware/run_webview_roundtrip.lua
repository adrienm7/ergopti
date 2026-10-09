--- tests/hardware/run_webview_roundtrip.lua

--- ==============================================================================
--- MODULE: A Page Asks, The Daemon Answers, In Real WebKit
--- DESCRIPTION:
--- Opens the typing metrics window under a real display server with real
--- WebKit2GTK and waits for the page's OWN request — the {action: 'ready'}
--- object it posts on load — to be answered with the daemon's data.
---
--- WHY THIS EXISTS:
--- run_webview_push.lua routes a Lua string into the bridge and checks the
--- push; it never crosses the conversion of a JavaScript object into Lua, nor a
--- reply going back through window.__hostBridgeResponse. Both went through
--- dkjson, which is neither shipped nor installed: every object a page posted
--- arrived as nil and no reply was ever sent, so the metrics windows stayed
--- empty, while every test stayed green.
---
--- Exit 0 = the reply reached the page. 1 = it did not. 2 = the environment
--- cannot host the test (no display, no WebKit, no lgi).
--- ==============================================================================

local WAIT_ATTEMPTS = 100
local WAIT_SECONDS  = 0.1

local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

print("=== a page's own request, answered in a real WebKit page ===")

if not os.getenv("DISPLAY") and not os.getenv("WAYLAND_DISPLAY") then
	abort("no display server — run under xvfb-run.")
end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed.") end
local ok_webkit = pcall(function() return lgi.require("WebKit2", "4.1") end)
	or pcall(function() return lgi.require("WebKit2", "4.0") end)
if not ok_webkit then abort("WebKit2GTK is not available to lgi.") end
local Gtk = lgi.require("Gtk", "3.0")

local Manager = require("ui.webview_manager")

-- The day and app the page must end up holding: only the daemon knows them.
local DAY, APP, CHARS = "2026-09-24", "Firefox", 4242
Manager.set_daemon_state({ keylogger = {
	get_dashboard_payload = function()
		return {
			metrics_manifest = { [DAY] = { [APP] = { chars = CHARS, time = 60000 } } },
			app_icons = {},
			_prefetch_data = { historical = {}, today = {} },
			driver_meta = { os = "linux", heatmap_id = "kc" },
		}
	end,
} })

local function pump(seconds)
	for _ = 1, math.floor(seconds / WAIT_SECONDS) do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
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
	for _ = 1, WAIT_ATTEMPTS do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		if done then return answer end
		os.execute("sleep " .. tostring(WAIT_SECONDS))
	end
	return answer
end

local opened = Manager.show("metrics_typing")
if not opened then
	print("  FAIL the typing metrics window did not open")
	os.exit(1)
end
local webview = Manager.webview_for("metrics_typing")
local probe = string.format(
	"String(((window.metrics_manifest || {})['%s'] || {})['%s'] ? window.metrics_manifest['%s']['%s'].chars : 'none')",
	DAY, APP, DAY, APP)
local got = "none"
for _ = 1, WAIT_ATTEMPTS do
	pump(WAIT_SECONDS)
	got = eval_sync(webview, probe) or "none"
	if got ~= "none" then break end
end
print(string.format("  the page holds %s characters for %s on %s", got, APP, DAY))
if got == tostring(CHARS) then
	print("  ok   the page's own request reached the bridge and the reply reached the page")
	os.exit(0)
end
print("  FAIL the page never received the daemon's metrics")
os.exit(1)
