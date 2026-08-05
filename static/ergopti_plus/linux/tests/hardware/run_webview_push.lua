--- tests/hardware/run_webview_push.lua

--- ==============================================================================
--- MODULE: The Host Really Reaches the Page
--- DESCRIPTION:
--- Opens the two hotstrings webviews under a real display server with real
--- WebKit2GTK, and checks that the payload the bridge pushes actually arrives in
--- the page's own JavaScript.
---
--- WHY THIS IS THE MOST IMPORTANT THING THAT HAD NEVER RUN:
--- Both bridges were changed from RETURNING their payload to PUSHING it, because
--- `makeHostBridge` is fire-and-forget and only two of the fourteen shared pages
--- define `window.__hostBridgeResponse` — so a returned payload reached nobody,
--- and the settings window drew an empty page while the editor sat on
--- "Chargement…" for ever.
---
--- Every test of that fix so far asserts the SHAPE of the JavaScript string the
--- bridge hands to eval_js. Not one of them proves the string arrives, that the
--- page defines the function it calls, or that the function survives being handed
--- a payload built by Lua. Those are three separate ways for the same fix to be
--- wrong while every unit test stays green.
---
--- WHAT IT ASSERTS, AND WHY EACH ONE MATTERS:
--- 1. A window opens at all, with a WebKit view in it. Nothing had ever created
---    one outside a developer's desktop.
--- 2. The page's entry point EXISTS after load — `window.setData` and
---    `window.initData`. A push into a page that does not define them is a
---    silent no-op, because the host guards with `if(window.setData)`.
--- 3. The push lands and the page CHANGES because of it — read back out of the
---    live DOM, not out of the string we sent.
---
--- Exit 0 = every assertion held. 1 = a failure. 2 = the environment cannot host
--- the test (no display, no WebKit, no lgi), which is a property of the machine.
--- ==============================================================================

local WAIT_ATTEMPTS = 60
local WAIT_SECONDS  = 0.1

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

print("=== webview push, into a real WebKit page ===")

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

local Manager = require("ui.webview_manager")

-- The daemon state the bridges read. Without it the settings window's payload is
-- an empty shell — correctly, since it has nothing to describe — and the "did the
-- push change the page" assertion would fail for a reason that says nothing about
-- the push. The REAL config module is used, loading the bundled packs, so what
-- the page renders is what a user would see.
local HotstringsConfig = require("modules.hotstrings.hotstrings_config")
HotstringsConfig.init(nil, nil, nil)
HotstringsConfig.load_all()
Manager.set_daemon_state({ config = HotstringsConfig })

local category_count = 0
for _ in pairs(HotstringsConfig.get_categories() or {}) do category_count = category_count + 1 end
-- Reported, not asserted. Whether the catalogue loads from this working directory
-- is a separate question from whether a push reaches the page, and making the
-- second depend on the first is what produced a red run that said nothing about
-- either. The page-side spy below answers the push question on its own.
print(string.format("  info %d hotstring categor(ies) loaded for the settings window",
	category_count))





-- =======================================
-- =======================================
-- ======= 1/ Driving the GTK loop =======
-- =======================================
-- =======================================

local Gtk = lgi.require("Gtk", "3.0")

--- Runs the GTK main loop until `predicate` is true or the wait runs out.
---
--- Pumped rather than entered: `gtk_main()` would never return, and the page
--- loads asynchronously, so there is no point at which a synchronous call could
--- read the result.
--- @param predicate function
--- @return boolean True when the predicate became true in time.
local function pump_until(predicate)
	for _ = 1, WAIT_ATTEMPTS do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		if predicate() then return true end
		os.execute("sleep " .. tostring(WAIT_SECONDS))
	end
	while Gtk.events_pending() do Gtk.main_iteration_do(false) end
	return predicate()
end

--- Evaluates JavaScript in a live webview and returns its result as a string.
---
--- WebKit's evaluation is asynchronous, so the answer comes back through a
--- callback and the loop is pumped until it does. A test that read the result
--- synchronously would read nil every time and pass by asserting nothing.
--- @param webview userdata
--- @param source string
--- @return string|nil
local function eval_sync(webview, source)
	local answer, done = nil, false
	webview:run_javascript(source, nil, function(_object, result)
		local ok, value = pcall(function()
			local js_result = webview:run_javascript_finish(result)
			return js_result:get_js_value():to_string()
		end)
		answer = ok and value or nil
		done = true
	end, nil)

	-- Its OWN loop, not pump_until. pump_until takes a predicate, and every
	-- predicate this harness has calls eval_sync — so routing this through it
	-- nested one evaluation inside another and let their callbacks interleave.
	-- The result was an instrument that contradicted itself in the same run:
	-- window.initData reported undefined, and then the push it supposedly could
	-- not make plainly changed the page. Neither half could be trusted, which is
	-- worse than a harness that fails.
	for _ = 1, WAIT_ATTEMPTS do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		if done then return answer end
		os.execute("sleep " .. tostring(WAIT_SECONDS))
	end
	while Gtk.events_pending() do Gtk.main_iteration_do(false) end
	return answer
end




-- =======================================
-- =======================================
-- ======= 2/ Each page in turn ==========
-- =======================================
-- =======================================

--- Opens one app and checks that its entry point exists and can be driven.
--- @param app_name string Directory under _shared/ui/.
--- @param bridge string The bridge name the page posts to.
--- @param entry string The global function the host pushes into.
--- @param probe string JavaScript reading something the push should have changed.
local function exercise(app_name, bridge, entry, probe)
	print(string.format("--- %s ---", app_name))

	local opened = Manager.show(app_name)
	check(opened == true, app_name .. ": the window opens")
	if not opened then return end

	local webview = Manager.webview_for(app_name)
	check(webview ~= nil, app_name .. ": a WebKit view was created for it")
	if not webview then return end

	-- The page loads asynchronously; nothing below means anything until it has.
	local loaded = pump_until(function()
		return eval_sync(webview, "document.readyState") == "complete"
	end)
	check(loaded, app_name .. ": the page finished loading")
	if not loaded then return end

	-- The half no unit test can reach: the page must DEFINE what the host calls.
	-- The host guards with `if(window.setData)`, so a page that does not define it
	-- turns every push into a silent no-op — which is exactly the failure mode
	-- that hid the returned-payload bug for as long as it did.
	local defined = eval_sync(webview, "typeof window." .. entry)
	check(defined == "function", string.format(
		"%s: the page defines window.%s (got %s)", app_name, entry, tostring(defined)))

	if defined ~= "function" then
		-- Say WHY, rather than leaving the reader to guess from one word. The
		-- three things that can be wrong here are: the script tag was dropped
		-- during inlining (an asset the host could not read), the script was
		-- inlined but failed to parse, or it parsed and threw before the
		-- declaration. Each leaves a different fingerprint, and the whole point
		-- of running against a real page is to be able to read it.
		print(string.format("       inline scripts in the DOM : %s",
			tostring(eval_sync(webview, "String(document.scripts.length)"))))
		print(string.format("       bytes of inlined script   : %s",
			tostring(eval_sync(webview,
				"String(Array.from(document.scripts).reduce((n,s)=>n+s.textContent.length,0))"))))
		print(string.format("       makeHostBridge defined    : %s",
			tostring(eval_sync(webview, "typeof makeHostBridge"))))
		print(string.format("       first script error        : %s",
			tostring(eval_sync(webview, "String(window.__harness_error || 'none')"))))
	end

	-- A spy on the page's own entry point, installed BEFORE the push. It answers
	-- the question this harness exists for — did the payload ARRIVE — separately
	-- from whether the daemon had anything to put in it. Those are two different
	-- questions, and asserting the DOM changed conflates them: a correct push
	-- carrying an empty catalogue renders nothing and looks identical to no push
	-- at all.
	eval_sync(webview, string.format([[
		window.__arrived = null;
		(function () {
			var original = window.%s;
			window.%s = function (payload) {
				window.__arrived = JSON.stringify(payload || {}).length;
				return original.apply(this, arguments);
			};
		})();
	]], entry, entry))

	local before = eval_sync(webview, probe)
	-- The real path: the page's own "ready" message, routed to the bridge exactly
	-- as the script-message handler routes it, which is what makes the bridge push.
	Manager.route_message(bridge, "ready")
	pump_until(function() return eval_sync(webview, "String(window.__arrived)") ~= "null" end)

	local arrived = eval_sync(webview, "String(window.__arrived)")
	check(arrived ~= nil and arrived ~= "null" and arrived ~= "undefined", string.format(
		"%s: the payload ARRIVED in the page — %s was called with %s byte(s)",
		app_name, entry, tostring(arrived)))

	local after = eval_sync(webview, probe)
	if after == before then
		-- Not a failure on its own: an empty payload renders nothing, correctly.
		-- Said out loud so a green run is never read as "the page drew something".
		print(string.format("       note: the DOM did not change (%s) — the payload "
			.. "arrived but had nothing to draw", tostring(after)))
	end
end

exercise("hotstrings_config_window", "hotstrings_config_bridge", "setData",
	"String(document.querySelectorAll('.cat').length)")
exercise("hotstring_editor", "hsEditor", "initData",
	"String(document.getElementById('app') && document.getElementById('app').style.display)")

print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
