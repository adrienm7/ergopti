--- tests/meta/test_shutdown_callback_armed_early.lua

--- ==============================================================================
--- MODULE: Regression — the teardown must exist before boot can throw
---         (shutdown-callback-armed-early)
--- DESCRIPTION:
--- hs.shutdownCallback was installed as the LAST boot phase. A reload sets up a
--- fresh Lua state, so the previous session's teardown is already gone; if the
--- new boot then threw anywhere between the module requires and that final line,
--- the session ran with NO teardown at all. Quitting afterwards left Karabiner
--- still remapping the keyboard, eventtaps and timers never released, and the
--- MLX server and helper processes orphaned — recoverable only by killing the
--- grabber by hand.
---
--- The window was not narrow: everything between the requires and the end of
--- boot sits inside it — the first-launch guard, the Karabiner deploy, the menu
--- build, the deps checkers, the file watchers.
---
--- ROOT CAUSE ENCODED: the callback was placed by narrative order ("cleanup goes
--- at the end") rather than by dependency. Its body is fully defensive — every
--- module reference is nil-checked inside its own pcall — and every upvalue it
--- closes over exists as soon as the config-dependent requires are done, so
--- nothing ever required it to be last.
---
--- Both bounds are asserted. It must come AFTER the requires it closes over: a
--- closure written above the `local` it uses binds a nil GLOBAL instead, and the
--- resulting error inside a shutdown callback is swallowed to the Hammerspoon
--- Console where infra/logger never sees it. And it must come BEFORE the boot
--- phases that can throw, which is the whole point.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the driver's init.lua.
--- @return string
local function init_source()
	-- Selected by a declaration unique to init.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function has_common_hotstring_groups")
	helpers.assert_true(src ~= nil, "init.lua source must be locatable")
	return src
end

--- Byte offset of a literal in the comment-free source.
--- @param code string
--- @param needle string
--- @return number|nil
local function at(code, needle)
	return code:find(needle, 1, true)
end




-- ==============================================================
-- ==============================================================
-- ======= 1/ Armed before anything that can throw ==============
-- ==============================================================
-- ==============================================================

helpers.describe("init: the shutdown callback is armed before the risky boot phases", function()
	helpers.it("is installed before every later boot phase", function()
		local code = init_source():gsub("%-%-[^\n]*", "")

		local shutdown = at(code, "hs.shutdownCallback = shutdown_all_resources")
		helpers.assert_true(shutdown ~= nil, "init.lua must install a shutdown callback")

		-- Each of these runs after the requires and can throw: a missing config, a
		-- Karabiner deploy failure, a menu build error, an unreadable watch root.
		-- Anything that throws here used to leave the session with no teardown.
		local later_phases = {
			'require("infra.file_watchers").start',
			"menu.start",
			"Boot.mark(\"Boot complete",
		}

		local checked = 0
		for _, phase in ipairs(later_phases) do
			local phase_at = at(code, phase)
			if phase_at then
				checked = checked + 1
				helpers.assert_true(shutdown < phase_at,
					"hs.shutdownCallback must be installed BEFORE '" .. phase .. "'. A reload whose "
						.. "new boot throws in between runs with no teardown at all: Karabiner keeps "
						.. "remapping the keyboard on the next quit, and taps, timers and helper "
						.. "processes are never released")
			end
		end

		helpers.assert_true(checked >= 2,
			"the scan must find real later phases to compare against (found " .. checked
				.. ") — a scan that matches nothing cannot fail")
	end)

	helpers.it("is installed after the modules it closes over", function()
		local code = init_source():gsub("%-%-[^\n]*", "")
		local closure = at(code, "local function shutdown_all_resources()")
		local shutdown = at(code, "hs.shutdownCallback = shutdown_all_resources")

		-- The callback names these directly. A closure written ABOVE the local it
		-- uses silently binds a nil global instead, and the error surfaces only in
		-- the Hammerspoon Console during shutdown — the least observable moment
		-- there is (project-lua-closure-before-local-nil-global).
		-- Anchored on the DECLARATION of each name, not on the whole
		-- `local x = require(...)` line. karabiner is now forward-declared and
		-- assigned later, because the shutdown callback had to move above the
		-- requires that can raise: platform/remap/defaults.lua calls error()
		-- by design when the shared tap-hold TOML is unreadable, and arming the
		-- teardown after that meant the one failure which leaves the keyboard
		-- remapped was also the one that prevented the teardown existing.
		-- What must hold is that the NAME is in scope above the closure — which
		-- a forward declaration satisfies exactly as an inline require does.
		local required = {
			"local karabiner",
			"local LauncherGuard",
			"local ok_lease_controller, LeaseController",
			"local keymap",
			"local gestures",
			"local shortcuts",
			"local reload_guard",
		}

		local checked = 0
		for _, decl in ipairs(required) do
			local decl_at = at(code, decl)
			helpers.assert_true(decl_at ~= nil,
				"the declaration '" .. decl .. "' must be locatable — if it was reformatted, "
					.. "re-anchor this guard rather than dropping it")
			if decl_at then
				checked = checked + 1
				helpers.assert_true(decl_at < closure,
					"'" .. decl .. "' must be declared ABOVE the shutdown callback, which closes "
						.. "over it. Below, the callback binds a nil global and the teardown fails "
						.. "silently at the one moment nothing is watching the log")
			end
		end
		helpers.assert_eq(checked, #required, "every closed-over module must be checked")
	end)

	helpers.it("retains complete controlled teardown without running it in native shutdown", function()
		local code = init_source():gsub("%-%-[^\n]*", "")
		local teardown = at(code, "local function teardown_all_resources")
		local shutdown = at(code, "local function shutdown_all_resources()")
		local armed = at(code, "hs.shutdownCallback = shutdown_all_resources")
		helpers.assert_true(teardown ~= nil and shutdown ~= nil and armed ~= nil)
		local teardown_body = code:sub(teardown, shutdown - 1)
		local shutdown_body = code:sub(shutdown, armed - 1)

		-- Moving the assignment must not have moved a truncated copy of it: the
		-- teardown is only worth arming early if it is still the whole teardown.
		for _, step in ipairs({
			"return keymap.stop(true)", "gestures.stop", "shortcuts.stop",
			"LauncherGuard.stop",
			"restore_all_overrides",
			"terminate_helper_processes", "script_watchers",
		}) do
			helpers.assert_true(teardown_body:find(step, 1, true) ~= nil,
				"the shared local teardown must still perform '" .. step .. "'")
		end
		helpers.assert_true(
			teardown_body:find("TeardownTransaction.run(_local_teardown_state, steps)", 1, true) ~= nil,
			"throws and explicit false results must remain visible and retryable per teardown step"
		)
		helpers.assert_true(teardown_body:find("_local_teardown_complete", 1, true) == nil,
			"teardown must never certify itself before resource release has run")
		helpers.assert_true(shutdown_body:find("request_exact_lease_revoke", 1, true) ~= nil,
			"the armed callback must request the exact token fence")
		helpers.assert_true(shutdown_body:find("teardown_all_resources", 1, true) == nil,
			"the unawaitable callback must keep F17 consumers live until process EOF")
		helpers.assert_true(shutdown_body:find("shortcuts.stop", 1, true) == nil)
	end)
end)
