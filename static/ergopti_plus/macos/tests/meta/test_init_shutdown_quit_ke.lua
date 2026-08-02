--- tests/meta/test_init_shutdown_quit_ke.lua

--- ==============================================================================
--- MODULE: Regression — genuine-quit shutdown tears down KE robustly (F-HIGH-3)
--- DESCRIPTION:
--- On a genuine Cmd+Q quit the shutdown callback ran only KILL_FAST_CMD — a bare
--- pkill with no `launchctl bootout`. launchd's KeepAlive plist respawns the
--- bridge within milliseconds, so the keyboard stayed remapped after HS exited.
--- It also ran unconditionally, ignoring is_hs_owned_bridge, so a user-managed KE
--- was pkilled too. The robust teardown M.kill() (KILL_CMD bootout + ownership
--- gate) existed but was never wired into the shutdown callback.
---
--- Fix: the genuine-quit branch calls karabiner.kill(). This is the macOS twin of
--- project_hs_script_quit_kills_karabiner (the os.exit script_quit path was
--- already robust; the genuine-quit shutdown path was not).
---
--- init.lua boots the whole driver, so it cannot be required headlessly; this
--- test pins the root cause at the source level.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("init.lua: genuine-quit shutdown KE teardown (F-HIGH-3)", function()
	local function shutdown_region()
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")
		-- The shutdownCallback closure ends at the first column-0 `end` (its own
		-- nested if/pcall/for ends are all tab-indented).
		local sc = src:match("hs%.shutdownCallback%s*=%s*function.-\nend")
		helpers.assert_true(sc ~= nil, "shutdownCallback closure must be locatable")
		return sc
	end

	helpers.it("kills KE via karabiner.kill() (bootout), not a bare KILL_FAST_CMD pkill", function()
		local sc = shutdown_region()
		helpers.assert_true(sc:find("karabiner.kill()", 1, true) ~= nil,
			"genuine-quit shutdown must call karabiner.kill() (launchctl bootout, respects is_hs_owned_bridge)")
		helpers.assert_true(sc:find("hs.execute(kl.KILL_FAST_CMD)", 1, true) == nil,
			"shutdown must NOT run the bare KILL_FAST_CMD pkill — launchd KeepAlive respawns it within ms")
	end)

	helpers.it("keeps the KE teardown gated to a genuine quit (never on reload)", function()
		local sc = shutdown_region()
		helpers.assert_true(sc:find("reload_guard.is_reloading()", 1, true) ~= nil,
			"KE teardown must stay gated behind reload_guard.is_reloading() so a reload never tears KE down")
	end)
end)
