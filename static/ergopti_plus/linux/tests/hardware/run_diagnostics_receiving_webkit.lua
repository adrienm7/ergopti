--- tests/hardware/run_diagnostics_receiving_webkit.lua

--- ==============================================================================
--- MODULE: The Diagnostics Window Received In Real WebKit
--- DESCRIPTION:
--- Opens the diagnostics (healthcheck) window through its own bridge, in the
--- daemon's WebView manager, under a real X server and WebKit2GTK, with the
--- probes on the real libuv loop. The configuration check is the one probe that
--- runs without the extensive opt-in: it starts on a libuv timer after the first
--- snapshot. Every verdict is read from the page's rendered text, the libuv
--- handles that exist and the GTK toplevels that remain.
---
--- WHAT IT ASSERTS (native UI audit, scope linux-diagnostics, LDG-003):
--- 1. Native timer admission, healthy: the page first shows the check pending,
---    and once the loop runs the real timer the pending label is gone and the
---    configuration answer reached the page.
--- 2. Native timer admission, refused: with luv.new_timer refusing (nil,
---    ENOMEM, the fallible return the scheduler must classify), the page's own
---    Refresh button ends with the check failed, never pending, and no timer.
--- 3. Stale epochs: reopening the window replaces the page; a refresh stamped
---    with the retired epoch starts nothing, and only the new page receives the
---    new answer.
--- 4. Physical cleanup: Refresh redraws the page (an empty cleanup history once
---    reached it as {} and froze it on the previous run); closing the window
---    through GTK's own delete-event while
---    its check is still armed leaves no diagnostics toplevel, no armed scheduler
---    timer and no active libuv timer, and the late answer reaches no page.
---
--- Run from the Linux driver with its normal LUA_PATH under xvfb-run. Exit 0 =
--- every check held, 1 = a regression, 2 = the machine cannot host the test.
--- ==============================================================================

local EXPECTED_CHECKS = 13
local WAIT_ATTEMPTS = 80
local WAIT_SECONDS = 0.1

local _checks, _failures = 0, 0

--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if condition then
		print("  ok   " .. what)
	else
		_failures = _failures + 1
		print("  FAIL " .. what)
	end
end

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

print("=== the diagnostics window, received in real WebKit ===")
if not os.getenv("DISPLAY") and not os.getenv("WAYLAND_DISPLAY") then abort("no display server; run under xvfb-run.") end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed.") end
if not pcall(lgi.require, "WebKit2", "4.1") then abort("WebKit2GTK 4.1 is unavailable to lgi.") end
local ok_luv, uv = pcall(require, "luv")
if not ok_luv then abort("lua-luv is not installed.") end
local Gtk = lgi.require("Gtk", "3.0")

-- A private profile: the configuration probe reads the user's files from it.
local profile = assert(uv.fs_mkdtemp("/tmp/ergopti-diagnostics-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	local directory = profile .. "/" .. name:lower()
	assert(uv.fs_mkdir(directory, 448))
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", directory))
end
print("OWNED_PROFILE " .. profile)

local Timers = require("core.events.timer_scheduler")
local Manager = require("core.ui.ui.webview_manager")
local Bridge = require("ui.healthcheck.bridge")
local APP = "healthcheck"
Manager.set_daemon_state({})
local PENDING = require("core.i18n.engine.i18n").get("healthcheck.probe.pending")
assert(type(PENDING) == "string" and PENDING ~= "" and PENDING ~= "healthcheck.probe.pending",
	"the pending label must be translated")





-- ===================================
-- ===================================
-- ======= 1/ Driving the page =======
-- ===================================
-- ===================================

local function pump_gtk()
	while Gtk.events_pending() do Gtk.main_iteration_do(false) end
end

--- Pumps GTK and, when asked, the libuv loop the probes run on.
--- @param with_loop boolean
local function pump(with_loop)
	pump_gtk()
	if with_loop then uv.run("nowait") end
	pump_gtk()
end

--- Evaluates JavaScript in the live diagnostics page; never runs the libuv loop.
--- @param source string
--- @return string|nil
local function eval(source)
	local view = Manager.webview_for(APP)
	if not view then return nil end
	local answer, done = nil, false
	view:run_javascript(source, nil, function(_, result)
		local ok, value = pcall(function() return view:run_javascript_finish(result):get_js_value():to_string() end)
		answer, done = ok and value or nil, true
	end, nil)
	for _ = 1, WAIT_ATTEMPTS do
		pump_gtk()
		if done then return answer end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return answer
end

--- Waits for a JavaScript predicate, optionally letting the probes run.
--- @param source string
--- @param with_loop boolean
--- @return boolean
local function wait_js(source, with_loop)
	for _ = 1, WAIT_ATTEMPTS do
		if eval(source) == "true" then return true end
		pump(with_loop)
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return false
end

--- Active libuv timers in the default loop.
--- @return integer
local function active_uv_timers()
	local count = 0
	uv.walk(function(handle)
		if handle:get_type() == "timer" and handle:is_active() then count = count + 1 end
	end)
	return count
end

--- Visible diagnostics toplevels GTK still holds.
--- @return table windows
local function diagnostics_toplevels()
	local caption, windows = Manager.app_caption(APP), {}
	for _, window in ipairs(Gtk.Window.list_toplevels()) do
		if window.title == caption and window.visible then windows[#windows + 1] = window end
	end
	return windows
end

local PENDING_JS = string.format("String(document.getElementById('content').innerText.indexOf(%q) >= 0)", PENDING)

--- Opens the window and waits for its first snapshot without running the probes.
--- @return number|nil epoch
local function open_page()
	if not Bridge.open() then return nil end
	-- The pending label is drawn only from the host's snapshot: the init arrived.
	if not wait_js(PENDING_JS, false) then return nil end
	-- Records every settled configuration answer the page receives from now on.
	eval([[
		window.__probes = [];
		(function () {
			var original = window.receiveDiagnostics;
			window.receiveDiagnostics = function (message) {
				var result = null;
				if (message && message.type === 'probe' && message.id === 'configuration') result = message.result;
				else if (message && message.snapshot && message.snapshot.probes) result = message.snapshot.probes.configuration;
				if (result && result.state !== 'pending') window.__probes.push('configuration:' + result.state);
				return original.apply(this, arguments);
			};
		})(); 'spied'
	]])
	return Manager.current_epoch(APP)
end




-- ======================================
-- ======================================
-- ======= 2/ The four flows ============
-- ======================================
-- ======================================

local function run()
	local baseline = active_uv_timers()

	print("--- native timer admission, healthy ---")
	local first = open_page()
	check(type(first) == "number", "the diagnostics window opens and draws its first snapshot")
	if not first then return end
	check(eval(PENDING_JS) == "true" and Timers.activeCount() >= 1,
		"before the loop runs, the page shows the configuration check pending on an armed timer")
	check(wait_js("String(window.__probes.indexOf('configuration:ok') >= 0)", true),
		"the real timer delivers the configuration answer to the page")
	check(wait_js("String(" .. PENDING_JS .. " === 'false')", true), "no check stays pending on the page")

	print("--- native timer admission, refused ---")
	local new_timer = uv.new_timer
	uv.new_timer = function() return nil, "ENOMEM: not enough memory" end
	eval("window.__probes = []; document.getElementById('btn-refresh').click(); 'refresh'")
	local failed = wait_js("String(window.__probes.indexOf('configuration:error') >= 0)", false)
	uv.new_timer = new_timer
	check(failed, "a refused native timer ends the configuration check failed on the page")
	pump(true)
	check(wait_js(string.format("String(document.getElementById('content').innerText.indexOf(%q) >= 0)",
		"Timer could not be started"), true) and eval(PENDING_JS) == "false" and Timers.activeCount() == 0,
		"the refreshed page shows the failure, no check stays pending and no timer is armed")

	print("--- stale epochs ---")
	local second = open_page()
	check(type(second) == "number" and second ~= first and #diagnostics_toplevels() == 1,
		"reopening replaces the page with a new epoch and one window")
	if not second then return end
	local stale = Manager.route_message(APP, APP, { action = "refresh", detailed = false, extensive = false }, first)
	check(stale == nil, "a refresh stamped with the retired epoch is refused")
	check(wait_js("String(window.__probes.indexOf('configuration:ok') >= 0)", true)
		and eval("String(window.__probes.length)") == "1",
		"only the new page's own check answers, once")

	print("--- physical cleanup ---")
	eval("document.getElementById('btn-refresh').click(); 'refresh'")
	local shown = wait_js(PENDING_JS, false)
	local armed = Timers.activeCount()
	check(shown and armed >= 1, string.format("Refresh redraws the page with its check pending on an armed timer"
		.. " (pending shown=%s, armed=%d)", tostring(shown), armed))
	local windows = diagnostics_toplevels()
	if windows[1] then windows[1]:close() end
	for _ = 1, 10 do pump(false); os.execute("sleep " .. WAIT_SECONDS) end
	check(Manager.current_epoch(APP) == nil and #diagnostics_toplevels() == 0,
		"GTK's delete-event retires the page and its window")
	check(Timers.activeCount() == 0, "no scheduler timer stays armed after the window closed")
	for _ = 1, 5 do uv.run("nowait") end
	check(active_uv_timers() <= baseline, "no libuv timer stays active after the window closed")
end

local ran, err = xpcall(run, debug.traceback)
if not ran then
	_failures = _failures + 1
	print("  FAIL the flow raised: " .. tostring(err))
end
pcall(Manager.shutdown)
os.execute("rm -rf '" .. profile .. "'")
check(_checks == EXPECTED_CHECKS, string.format("every check ran (%d of %d)", _checks, EXPECTED_CHECKS))
print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
