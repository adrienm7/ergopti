--- tests/hardware/run_model_browser_runtime_webkit.lua

--- ==============================================================================
--- MODULE: The Model Page Reads The Managed Ollama Before And After Its Install
--- DESCRIPTION:
--- Run by run_model_browser_runtime_webkit.sh under Xvfb with a private
--- session bus, a private profile below HOME (the runtime resolver refuses
--- /tmp ancestors) and the native archive helper built from its C source. The
--- model selector page is the daemon's: the menu's own binding
--- (backend_rows.bind_page) with the real install state, the bridge and the
--- WebView manager drawing the shared page in WebKit2GTK. Its "Install Ollama"
--- button runs the AI enable, which downloads the pinned official archive over
--- HTTPS, checks its digest, publishes the runtime and starts it. Only the
--- download consent is scripted (the native question dialog), as in
--- run_ollama_runtime_acceptance.lua; every verdict is read from the page.
---
--- WHAT IT ASSERTS (native UI audit, LRT-001):
--- 1. Before: the page greys the Ollama group with the missing-runtime reason
---    and offers its install button.
--- 2. The click: one consent, one archive download from the pinned URL, the AI
---    enabled and the owned daemon running.
--- 3. After, on the same page and without a restart or a model: the group is
---    available, the install button says installed and is disabled, the model
---    entry field is offered, and the install state reads "installed" from the
---    managed inventory (the stale absence LRT-001 kept until a restart).
--- 4. Cleanup: switching the AI off retires the owned daemon; closing the
---    window leaves no model page.
--- Exit 0 = every check held; 1 = a regression; 2 = no environment.
--- ==============================================================================

local EXPECTED_CHECKS = 12
local INSTALL_SECONDS = 900
local WAIT_ATTEMPTS = 100
local WAIT_SECONDS = 0.1
local OFFICIAL_ARCHIVE = "https://github.com/ollama/ollama/releases/download/v0.40.6/ollama-linux-amd64.tar.zst"

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
	io.stdout:flush()
	return condition
end

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

print("=== the model page reads the managed Ollama before and after its install ===")
if not os.getenv("DISPLAY") then abort("no display server; run under xvfb-run.") end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed.") end
if not pcall(lgi.require, "WebKit2", "4.1") then abort("WebKit2GTK 4.1 is unavailable to lgi.") end
local ok_luv, uv = pcall(require, "luv")
if not ok_luv then abort("lua-luv is not installed.") end
local Gtk = lgi.require("Gtk", "3.0")
require("core.lifecycle.engine.compat.utf8").install()
if os.getenv("ERGOPTI_LIVE_DEBUG") then
	require("core.logger.engine").set_sink(function(line) io.stderr:write(line, "\n") end)
end

local I18n = require("core.i18n.engine.i18n")
local Json = require("core.text.engine.json")
local Http = require("core.network.adapters.http_client")
local Native = require("core.process.adapters.owned_process")

-- The port the owned daemon listens on, free when chosen.
local function free_port()
	local server = assert(uv.new_tcp())
	assert(server:bind("127.0.0.1", 0))
	local port = server:getsockname().port
	server:close()
	uv.run("nowait")
	return port
end

-- Timestamped steps name what a stalled install waits on: hosts and program
-- names only, and the warnings and errors the owners log.
local trace_origin = uv.hrtime()
local function trace(step)
	print(string.format("TRACE %6d ms %s", math.floor((uv.hrtime() - trace_origin) / 1e6), step))
	io.stdout:flush()
end
local function host_of(url) return tostring(type(url) == "string" and url:match("^%a+://([^/]+)") or "?") end
local Logger = require("core.logger.engine.shim")
for _, level in ipairs({ "error", "warn" }) do
	local original = Logger[level]
	Logger[level] = function(tag, format, ...)
		local ok, text = pcall(string.format, format, ...)
		trace(level .. " " .. tostring(tag) .. " " .. (ok and text or tostring(format)))
		return original(tag, format, ...)
	end
end

-- Observed, never replaced: the archive transport and the owned daemon.
local archive_urls, services = {}, {}
local original_download = Http.download_output_owned
Http.download_output_owned = function(url, headers, target, options, callback)
	archive_urls[#archive_urls + 1] = url
	trace("download-start " .. host_of(url))
	return original_download(url, headers, target, options, function(...)
		trace("download-end " .. host_of(url))
		return callback(...)
	end)
end
local original_get_owned = Http.get_owned
Http.get_owned = function(url, headers, options, callback)
	if options.output_path then archive_urls[#archive_urls + 1] = url end
	trace("http-start " .. host_of(url) .. (options.output_path and " archive" or ""))
	return original_get_owned(url, headers, options, function(result)
		trace("http-end " .. host_of(url) .. " status=" .. tostring(type(result) == "table" and result.status or "?"))
		return callback(result)
	end)
end
local original_start = Native.start
Native.start = function(executable, arguments, options, callback)
	local program = tostring(executable):match("[^/]+$") or "?"
	local verb = type(arguments) == "table" and tostring(arguments[1] or "") or ""
	trace("process-start " .. program .. " " .. verb)
	local inner = callback
	if type(callback) == "function" then
		callback = function(...)
			trace("process-end " .. program .. " " .. verb)
			return inner(...)
		end
	end
	local operation = original_start(executable, arguments, options, callback)
	if type(arguments) == "table" and arguments[1] == "serve" then services[#services + 1] = operation end
	return operation
end

-- The download consent: the one scripted input, answering the native question
-- the AI enable asks when Ergopti's own Ollama is missing.
local consents = 0
package.loaded["ai.ui.enable_refusal"] = { show = function(_, rows)
	consents = consents + 1
	local wanted = I18n.get("ollama.offer_download")
	trace(string.format("consent asked with %d choice(s)", type(rows) == "table" and #rows or 0))
	for _, row in ipairs(type(rows) == "table" and rows or {}) do
		if row.label == wanted then return true, false, row.value end
	end
	return true, false, nil
end }

local Engine = require("ai.engine.prediction.engine")
local Profiles = require("ai.engine.settings.profiles")
local InstallState = require("ai.engine.ollama.install_state")
Engine.init({ is_paused = function() return false end })
-- The daemon's own inventory listener (ergopti_hotstrings.lua on_models_changed)
-- reprojects the open model page; the profile moves to a free port.
Profiles.init({ port = free_port(), on_models_changed = function()
	require("ai.ui.model_browser.bridge").reproject_current()
end })
local Manager = require("core.ui.ui.webview_manager")
local config_changes = 0
Manager.set_daemon_state({ llm = Engine, on_config_changed = function() config_changes = config_changes + 1 end })
require("ai.ui.menu.backend_rows").bind_page(Engine, {
	dialogs = {}, on_changed = function() end, delete_model = function() return false end, context = {},
})
local APP = "model_browser"





-- ===================================
-- ===================================
-- ======= 1/ Driving the page =======
-- ===================================
-- ===================================

-- Bounds one libuv turn of the pump: GTK's events are not libuv's, so the turn
-- must come back for them even when no libuv descriptor is ready.
local PUMP_TURN_MS = 10
local pump_clock = assert(uv.new_timer())
assert(pump_clock:start(PUMP_TURN_MS, PUMP_TURN_MS, function() end))

--- Pumps GTK and the libuv loop the install runs on. The libuv turn waits for
--- a ready descriptor (at most PUMP_TURN_MS) and handles it at once, as the
--- daemon's loop does. One non-blocking turn then a fixed sleep served one
--- event per sleep: the archive, a 64 KiB read then its write acknowledgement
--- per chunk, came in at under 1 MB/s, and the 1.4 GB install outlived the
--- step's limit with curl blocked on its full pipe.
local function pump()
	while Gtk.events_pending() do Gtk.main_iteration_do(false) end
	uv.run("once")
	while Gtk.events_pending() do Gtk.main_iteration_do(false) end
end

--- Evaluates JavaScript in the live model page.
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
		pump()
		if done then return answer end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return answer
end

-- The Ollama group as the page holds it (payload) and draws it (DOM).
local OLLAMA_JS = [[
	(function () {
		var b = (typeof _backends !== 'undefined' ? _backends : []).filter(function (x) { return x.id === 'ollama'; })[0];
		var toggle = document.querySelector('span.group-toggle[data-group="ollama"]');
		if (!b || !toggle) return 'null';
		var head = toggle.closest('tr');
		var button = head.querySelector('button.act.install');
		var reason = head.querySelector('.reason');
		return JSON.stringify({
			available: b.available !== false, reason_key: b.reason_key || null,
			install: b.install ? b.install.state : null,
			greyed: head.classList.contains('unavailable'),
			button: button ? { text: button.textContent, disabled: button.disabled } : null,
			reason: reason ? reason.textContent : null,
			add: head.querySelector('.add-input') !== null
		});
	})()
]]

--- The Ollama group, decoded, or nil before the page drew it.
local function ollama_group()
	local body = eval(OLLAMA_JS)
	if not body or body == "null" then return nil end
	local ok, group = pcall(Json.decode, body)
	return ok and group or nil
end

--- Pumps until the predicate holds or the deadline passes.
--- @param predicate function
--- @param seconds number
--- @return boolean
local function wait_for(predicate, seconds)
	local deadline = uv.hrtime() + seconds * 1e9
	repeat
		-- The pump's own libuv turn is the wait: a sleep here would hold every
		-- ready descriptor behind it.
		pump()
		if predicate() then return true end
	until uv.hrtime() > deadline
	return predicate() and true or false
end

--- Visible model page toplevels GTK holds.
local function page_windows()
	local caption, count = Manager.app_caption(APP), 0
	for _, window in ipairs(Gtk.Window.list_toplevels()) do
		if window.title == caption and window.visible then count = count + 1 end
	end
	return count
end





-- ===================================
-- ===================================
-- ======= 2/ The install flow =======
-- ===================================
-- ===================================

local function run()
	local brand, missing = "Ollama", I18n.get("model_browser.reason_ollama_missing")
	local install_caption = I18n.get("model_browser.install_runtime"):gsub("%%s", brand)
	local installed_caption = I18n.get("model_browser.install_installed")

	print("--- before the install ---")
	check(Manager.show(APP) == true and wait_for(function() return ollama_group() ~= nil end, 30),
		"the model page opens and draws the Ollama group")
	local epoch = Manager.current_epoch(APP)
	-- The page's own model inventory probe holds the runtime pending while it
	-- runs; the install button is offered once it answered.
	local before
	wait_for(function()
		before = ollama_group()
		return before ~= nil and before.install ~= "running"
	end, 30)
	before = before or {}
	check(before.available == false and before.reason_key == "model_browser.reason_ollama_missing"
		and before.greyed == true and before.reason == missing,
		"the page greys the Ollama group with the missing-runtime reason")
	check(before.install == "available" and type(before.button) == "table" and before.button.disabled == false
		and before.button.text == install_caption and before.add == false,
		"the page offers the install button and no model entry: " .. Json.encode(before))

	print("--- the install button ---")
	eval([[(function () {
		var head = document.querySelector('span.group-toggle[data-group="ollama"]').closest('tr');
		head.querySelector('button.act.install').click(); return 'clicked';
	})()]])
	check(wait_for(function() return Engine.runtime_pending() or Engine.is_enabled() end, 30),
		"the click starts the AI enable, which installs the runtime")
	local next_beat = uv.hrtime()
	local enabled = wait_for(function()
		if uv.hrtime() >= next_beat then
			next_beat = uv.hrtime() + 30e9
			trace(string.format("install: enabled=%s pending=%s consents=%d", tostring(Engine.is_enabled()),
				tostring(Engine.runtime_pending()), consents))
		end
		return Engine.is_enabled() and not Engine.runtime_pending()
	end, INSTALL_SECONDS)
	check(enabled and consents == 1 and #archive_urls == 1 and archive_urls[1] == OFFICIAL_ARCHIVE,
		string.format("one consent and one download of the pinned archive enable the AI (consents=%d, downloads=%d)",
			consents, #archive_urls))
	check(#services == 1 and services[1]:is_running() == true, "the owned Ollama daemon runs")

	print("--- after the install, same page, no restart ---")
	local after
	check(wait_for(function()
		after = ollama_group()
		return after ~= nil and after.available == true and after.install == "installed"
	end, 30) and Manager.current_epoch(APP) == epoch,
		"the same page shows the Ollama group available and installed")
	after = after or {}
	check(after.greyed == false and after.reason == nil and type(after.button) == "table"
		and after.button.disabled == true and after.button.text == installed_caption and after.add == true,
		"the install button says installed and is disabled, and the model entry is offered: " .. Json.encode(after))
	local models = Engine.get_cached_models()
	local available, reason, cause = InstallState.capture(Engine)
	check(type(models) == "table" and #models == 0 and available == true and reason == nil and cause == "installed",
		string.format("with no model, the install state reads the managed runtime installed (cause=%s)", tostring(cause)))
	check(config_changes >= 1, "the install reached the daemon's configuration change")

	print("--- cleanup ---")
	Engine.disable()
	check(wait_for(function()
		return not Engine.is_enabled() and not Engine.runtime_pending() and services[1] ~= nil
			and services[1]:is_settled() == true
	end, 60), "switching the AI off retires the owned daemon")
	Manager.hide(APP)
	Manager.shutdown()
	check(wait_for(function() return page_windows() == 0 end, 10), "closing leaves no model page")
end

local ran, err = xpcall(run, debug.traceback)
if not ran then
	_failures = _failures + 1
	print("  FAIL the flow raised: " .. tostring(err))
end
pcall(Manager.shutdown)
if Engine.is_enabled() or Engine.runtime_pending() then pcall(Engine.disable) end
pcall(function() Engine.stop_runtime() end)
wait_for(function() return services[1] == nil or services[1]:is_settled() == true end, 30)
Http.download_output_owned, Http.get_owned, Native.start = original_download, original_get_owned, original_start
check(_checks == EXPECTED_CHECKS, string.format("every check ran (%d of %d)", _checks, EXPECTED_CHECKS))
print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
