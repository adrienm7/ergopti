--- tests/meta/test_startup_optimizations.lua

--- ==============================================================================
--- MODULE: Startup Optimization Invariants
--- DESCRIPTION:
--- Pins two boot-cost optimizations so a regression re-introducing the slow path
--- fails CI instead of only showing up as a sluggish driver on the user's machine.
---
--- WHY THIS EXISTS:
---  1. keylogger-winfilter-lazy — hs.window.filter's FIRST instantiation makes
---     Hammerspoon enumerate every window of every app (multi-second on machines
---     with many apps / a VPN). The keylogger used to build its browser filter
---     eagerly at engine start (in a doAfter(0)), so the engine took seconds to
---     settle. It is now created lazily on the first browser activation; per
---     app-switch private detection runs independently via app_watcher_cb.
---  2. gestures-prewarm-no-reinit — gestures.start()'s dependency pre-warm
---     re-called Actions.init()/Engine.init(), which are already run at module
---     load. The guard turned each into a no-op that logged a spurious
---     "M.init() called more than once" WARNING every boot.
---
--- These are SOURCE invariants (the modules are heavy to start headless and these
--- run-once boot paths are not exercised by the unit suite), so they assert the
--- shape of the code, mirroring the other meta guards.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Reads a driver source file with Lua comments stripped, so counting a symbol
--- never trips over the same symbol named in a comment. Block comments first,
--- then line comments (`.` spans newlines in Lua patterns).
-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_code(selector)
	local src = helpers.read_driver_source(selector)
	src = src:gsub("%-%-%[%[.-%]%]", " ")
	local out = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		out[#out + 1] = (line:gsub("%-%-.*$", ""))
	end
	return table.concat(out, "\n")
end





-- ===================================================
-- ===================================================
-- ======= 1/ Keylogger browser filter is lazy =======
-- ===================================================
-- ===================================================

helpers.describe("startup: keylogger creates its window.filter lazily (keylogger-winfilter-lazy)", function()
	local src = read_code("local function ensure_browser_window_filter") -- modules/keylogger/init.lua

	helpers.it("hs.window.filter.new appears exactly once, in the lazy helper", function()
		local count = select(2, src:gsub("hs%.window%.filter%.new", ""))
		helpers.assert_eq(count, 1,
			"keylogger must instantiate hs.window.filter exactly once (in ensure_browser_window_filter)")
	end)

	helpers.it("the lazy helper exists and is gated by a browser activation", function()
		helpers.assert_true(src:find("function ensure_browser_window_filter", 1, true) ~= nil,
			"ensure_browser_window_filter must exist — the browser filter must be created lazily")
		-- The helper is only invoked when an activated app is a known browser.
		helpers.assert_true(src:match("BROWSER_APP_SET%[app_name%].-ensure_browser_window_filter") ~= nil,
			"ensure_browser_window_filter must be called only on a browser activation (BROWSER_APP_SET gate)")
	end)

	helpers.it("the browser filter is NOT built eagerly at engine start", function()
		-- The old slow path created the filter inside a doAfter(0) during M.start.
		helpers.assert_true(src:match("doAfter%(0,%s*function%(%).-hs%.window%.filter%.new") == nil,
			"keylogger must not create hs.window.filter eagerly in a doAfter(0) at start")
	end)
end)




-- ======================================================
-- ======================================================
-- ======= 2/ Gestures pre-warm does not re-init ========
-- ======================================================
-- ======================================================

helpers.describe("startup: gestures pre-warm does not re-initialise its sub-modules (gestures-prewarm-no-reinit)", function()
	local src = read_code("local function schedule_emergency_recycle") -- modules/gestures/init.lua

	helpers.it("Actions.init is called exactly once (at module load, not in pre-warm)", function()
		local count = select(2, src:gsub("Actions%.init%(", ""))
		helpers.assert_eq(count, 1,
			"Actions.init must run once at module load — re-calling it in the pre-warm logs a spurious 'called more than once'")
	end)

	helpers.it("the pre-warm body never calls Engine.init", function()
		local prewarm_at = src:find("local function prewarm_dependencies()", 1, true)
		local prewarm_end = prewarm_at and src:find("\nlocal function kickstart_hid", prewarm_at, true)
		helpers.assert_true(prewarm_at ~= nil and prewarm_end ~= nil,
			"the pre-warm body must remain independently locatable")
		local prewarm = src:sub(prewarm_at, prewarm_end - 1)
		helpers.assert_true(prewarm:find("Engine.init", 1, true) == nil,
			"pre-warming dependencies must not reinitialize the live engine at boot")
	end)

	helpers.it("a post-stop Engine.init remains lifecycle-gated", function()
		local gate = src:find("if engine_needs_init then", 1, true)
		local reinit = gate and src:find("Engine.init(CoreState, Actions)", gate, true)
		local stop = src:find("xpcall(Engine.stop", 1, true)
		local debt = stop and src:find("engine_needs_init = true", stop, true)
		helpers.assert_true(gate ~= nil and reinit ~= nil and gate < reinit,
			"Engine.init may recur only after the lifecycle marks a stopped engine for restart")
		helpers.assert_true(stop ~= nil and debt ~= nil and stop < debt,
			"the restart gate must be armed only after Engine.stop succeeds")
	end)
end)




-- ===========================================================
-- ===========================================================
-- ======= 3/ Duplicate bindings.start() is quiet (DEBUG) ====
-- ===========================================================
-- ===========================================================

helpers.describe("startup: duplicate shortcuts.bindings start() does not WARN (bindings-quiet-restart)", function()
	local src = read_code("local function get_frontmost_app_name") -- modules/shortcuts/bindings.lua

	helpers.it("the already-started guard logs at DEBUG, not WARNING", function()
		-- init.lua starts the bindings early, then menu_state re-starts them to
		-- apply the saved preference: a second start() every boot is the intended
		-- reconciliation (like keymap.start), so it must not emit a WARNING — that
		-- noise on every clean boot trains the user to ignore real warnings.
		helpers.assert_true(
			src:find('Logger.debug(LOG, "M.start() already active', 1, true) ~= nil,
			"the duplicate-start guard in bindings.start() must log at DEBUG (bindings-quiet-restart)")
	end)

	helpers.it("the duplicate-start path no longer emits a WARNING", function()
		helpers.assert_true(
			src:find('Logger.warn(LOG, "M.start()', 1, true) == nil,
			"bindings.start() must not WARN on a duplicate call — it is the intended boot reconciliation (bindings-quiet-restart)")
	end)
end)
