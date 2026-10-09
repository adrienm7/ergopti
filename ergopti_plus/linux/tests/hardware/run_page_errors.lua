--- tests/hardware/run_page_errors.lua

--- ==============================================================================
--- MODULE: What the Page Says When It Breaks
--- DESCRIPTION:
--- Loads each shared UI page with an error trap installed BEFORE its own scripts,
--- and reports every exception the page raises while loading.
---
--- THE QUESTION THIS EXISTS TO SETTLE:
--- `window.setData` is undefined in the settings window, so the host's
--- `if(window.setData)` guard discards every push. Seven explanations have been
--- ruled out — the script is inlined, the tag is at body level rather than inside
--- a template, all three assembled blocks parse, `makeHostBridge` answers
--- "function" so earlier blocks run, it is not cross-window interference, it is
--- not truncation, and an explicit `window.setData = setData` at the end of the
--- file changed nothing.
---
--- That last one is the informative part: if the script ran to completion, that
--- line alone would be enough. So it does not run to completion — it throws. And
--- a throw during load is invisible to every probe run afterwards, because by
--- then the page looks merely incomplete.
---
--- WHY THE TRAP HAS TO GO IN FIRST:
--- window.onerror only catches what is raised after it is installed. Installed by
--- a later `run_javascript` — which is the only tool the other harness has — it
--- would be too late by the whole page load. So this harness builds the HTML
--- itself, splices the trap in immediately after <head>, and loads that.
---
--- THE SAME PAGE A WINDOW LOADS:
--- The HTML comes from webview_manager.build_page_html(), the builder show()
--- uses, never from a copy of it. A copy had lost the strings show() seeds into
--- the boot script (the whole catalogue as inline JSON), so the one script every
--- Linux window runs first never ran in a real engine here. Each page must also
--- hold that catalogue once loaded, and the diagnostics page, the one a failed
--- boot sends users to, must show a label as text.
---
--- Exit 0 = every page loaded without raising. 1 = at least one raised, and the
--- message says where. 2 = the environment cannot host the test.
--- ==============================================================================

local WAIT_ATTEMPTS = 60
local WAIT_SECONDS  = 0.1

-- Installed first, so it sees everything the page's own scripts raise. Kept to
-- one line of state and one handler: a trap that is itself elaborate can fail in
-- the same way as the thing it watches.
local ERROR_TRAP = [[<script>
window.__errs = [];
window.__posts = [];
window.onerror = function (message, source, line, column) {
	window.__errs.push(String(message) + " @" + String(line) + ":" + String(column));
	return false;
};
window.webkit = window.webkit || {};
window.webkit.messageHandlers = window.webkit.messageHandlers || {};
window.webkit.messageHandlers.prompt_bridge = {
	postMessage: function (payload) { window.__posts.push(payload); }
};
window.webkit.messageHandlers.healthcheck = window.webkit.messageHandlers.prompt_bridge;
</script>]]

local _failures, _checks = 0, 0

--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if condition then
		print(string.format("  ok   %s", what))
	else
		_failures = _failures + 1
		print(string.format("  FAIL %s", what))
	end
end

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

print("=== page load errors, with a trap installed before the page's own scripts ===")

if not os.getenv("DISPLAY") and not os.getenv("WAYLAND_DISPLAY") then
	abort("no display server — run under xvfb-run.")
end

local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed.") end
local ok_webkit, WebKit = pcall(function() return lgi.require("WebKit2", "4.1") end)
if not ok_webkit then
	ok_webkit, WebKit = pcall(function() return lgi.require("WebKit2", "4.0") end)
end
if not ok_webkit or not WebKit then abort("WebKit2GTK is not available to lgi.") end

local Gtk = lgi.require("Gtk", "3.0")
local WebkitHost = require("ui.webkit_host")
local WebviewManager = require("ui.webview_manager")
local Locale = require("infra.locale")

-- Every page boots in English here, and the locale core follows, as the
-- interface locale and the locale core move together in the driver
local LOCALE = "en"
Locale.set_locale(LOCALE)
local CATALOGUE = Locale.catalogue()
local CATALOGUE_SIZE = 0
for _ in pairs(CATALOGUE) do CATALOGUE_SIZE = CATALOGUE_SIZE + 1 end
if CATALOGUE_SIZE == 0 then abort("the locale catalogue did not load.") end




-- =======================================
-- =======================================
-- ======= 1/ Driving one page ===========
-- =======================================
-- =======================================

--- Evaluates JavaScript and returns its result as a string.
--- @param webview userdata
--- @param source string
--- @return string|nil
local function eval_sync(webview, source)
	local answer, done = nil, false
	webview:run_javascript(source, nil, function(_object, result)
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
	while Gtk.events_pending() do Gtk.main_iteration_do(false) end
	return answer
end

--- Loads one page with the trap in place and reports what it raised.
--- @param app_name string Directory under _shared/ui/.
--- @param entry string The global the host pushes into.
--- @param expected_action string|nil Page lifecycle action expected at load.
--- @param label table|nil { id, key }: an element whose text must be the key's translation.
local function inspect(app_name, entry, expected_action, label)
	print(string.format("--- %s ---", app_name))

	local driver_root = "."
	local ui_root = WebkitHost.resolve_ui_root(driver_root)
	if ui_root == "" then abort("could not resolve _shared/ui from " .. driver_root) end

	local html = WebviewManager.build_page_html(app_name, LOCALE)
	check(html ~= nil and #html > 1000, app_name .. ": the page builds")
	if not html or #html < 1000 then return end

	-- Immediately after <head>, which is before every script the page carries.
	local trapped, count = html:gsub("(<head[^>]*>)", function(tag) return tag .. ERROR_TRAP end, 1)
	check(count == 1, app_name .. ": the error trap was spliced in")
	if count ~= 1 then return end

	local window = Gtk.Window({ default_width = 900, default_height = 700 })
	local webview = WebKit.WebView()
	window:add(webview)
	window:show_all()
	webview:load_html(trapped, "file:///")

	local loaded = false
	for _ = 1, WAIT_ATTEMPTS do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		if eval_sync(webview, "document.readyState") == "complete" then loaded = true ; break end
		os.execute("sleep " .. tostring(WAIT_SECONDS))
	end
	check(loaded, app_name .. ": the page finished loading")
	if not loaded then window:destroy() ; return end

	local errors = eval_sync(webview, "String((window.__errs||[]).join(' | ') || 'none')")
	local defined = eval_sync(webview, "typeof window." .. entry)

	check(errors == "none", string.format(
		"%s: the page raised nothing while loading (got: %s)", app_name, tostring(errors)))
	check(defined == "function", string.format(
		"%s: window.%s is defined after load (got %s)", app_name, entry, tostring(defined)))
	if expected_action then
		local actions = eval_sync(webview, [[String((window.__posts||[]).map(function (payload) {
			return payload && payload.action || String(payload);
		}).join(','))]])
		check(actions == expected_action, string.format(
			"%s: page announces '%s' after its API exists (got %s)",
			app_name, expected_action, tostring(actions)))
	end

	-- The seed is inline JSON of the whole catalogue: a store short of it means
	-- the engine refused or cut the boot script, and the page shows its keys
	local held = tonumber(eval_sync(webview, "String(Object.keys(window._i18n_strings||{}).length)"))
	check(held ~= nil and held >= CATALOGUE_SIZE, string.format(
		"%s: the page holds the %d strings it was built with (got %s)",
		app_name, CATALOGUE_SIZE, tostring(held)))
	if label then
		local shown = eval_sync(webview, string.format(
			"String((document.getElementById('%s')||{}).textContent)", label.id))
		check(shown == CATALOGUE[label.key], string.format(
			"%s: #%s reads '%s', not its key (got %s)",
			app_name, label.id, tostring(CATALOGUE[label.key]), tostring(shown)))
	end

	-- Printed whatever the verdict: on a green run these numbers are the baseline
	-- a later regression is read against.
	print(string.format("       scripts=%s bytes=%s makeHostBridge=%s",
		tostring(eval_sync(webview, "String(document.scripts.length)")),
		tostring(eval_sync(webview,
			"String(Array.prototype.reduce.call(document.scripts,function(n,s){return n+s.textContent.length;},0))")),
		tostring(eval_sync(webview, "typeof makeHostBridge"))))

	window:destroy()
	while Gtk.events_pending() do Gtk.main_iteration_do(false) end
end

inspect("hotstrings_config_window", "setData")
inspect("hotstring_editor", "initData")
inspect("prompt_editor", "init", "ready")
inspect("healthcheck", "receiveDiagnostics", "ready", { id = "btn-refresh", key = "healthcheck.toolbar.refresh" })

print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
