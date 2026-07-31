--- tests/unit/meta/test_menu_reload_reaches_the_daemon.lua

--- ==============================================================================
--- MODULE: Tray Reload Item Regression Guard
--- DESCRIPTION:
--- The tray menu's Reload item must reload THIS daemon.
---
--- ROOT CAUSE ENCODED:
--- The item ran, through os.execute:
---
---     "kill -HUP " .. tostring(os.getpid and os.getpid() or "$$") .. " 2>/dev/null"
---
--- Two independent mistakes, and each one alone was enough to make it a no-op:
---
---   1. `os.getpid` does not exist. The Lua standard `os` table has clock, date,
---      difftime, execute, exit, getenv, remove, rename, setlocale, time and
---      tmpname — and nothing else. So `os.getpid and os.getpid()` was always
---      nil and the expression always fell through to the literal "$$".
---
---   2. os.execute runs its argument in a NEW /bin/sh. Inside that shell `$$`
---      expands to the SHELL's pid, never to the Lua process that spawned it.
---      So the daemon asked a throwaway shell to reload, and the shell killed
---      itself instead.
---
--- The user-visible result: clicking Reload logged "Reload requested — sending
--- SIGHUP." and reloaded nothing, forever. Nothing errored, because nothing
--- about it could error — os.execute does not raise on a command that runs and
--- does the wrong thing, which is exactly why a "does it crash?" test would
--- have passed on this every single time.
---
--- The fix removes the subprocess entirely: the daemon owns the reload and the
--- menu asks for it via ctx.on_reload, the same shape the quit item already
--- used with ctx.on_quit.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Returns the TOP-LEVEL item whose title matches.
---
--- Deliberately not recursive. The Hotstrings submenu carries its own
--- "Recharger les hotstrings" entry, which reloads the config table but not the
--- daemon — a recursive search finds that one first and every assertion below
--- then passes against the wrong item. The daemon-wide Reload is appended at
--- top level, so searching only there identifies it unambiguously.
--- @param list table Menu item array.
--- @param needle string Lower-case substring of the title.
--- @return table|nil
local function find_item(list, needle)
	for _, item in ipairs(list or {}) do
		if type(item.title) == "string" and type(item.fn) == "function"
			and item.title:lower():find(needle, 1, true) then
			return item
		end
	end
	return nil
end


--- A config stub complete enough for build() to produce a full menu.
local function make_config()
	return {
		get_groups = function() return { "code" } end,
		is_group_enabled = function() return true end,
		toggle_group = function() end,
		reload = function() return 0 end,
	}
end





-- =========================================================================
-- =========================================================================
-- ======= 1/ The item must invoke the daemon's reload callback ============
-- =========================================================================
-- =========================================================================

helpers.describe("menu_builder: the Reload item reloads this daemon", function()
	helpers.it("invokes ctx.on_reload rather than signalling a spawned shell", function()
		local calls = 0
		local mb = helpers.load_module("modules.menu.menu_builder")
		local items = mb.build({
			config = make_config(),
			_version = "9.9.9",
			on_reload = function() calls = calls + 1 end,
		})

		local reload = find_item(items, "recharg") or find_item(items, "reload")
		helpers.assert_true(reload ~= nil, "the menu must contain a Reload item")

		reload.fn()
		helpers.assert_eq(
			calls,
			1,
			"clicking Reload must call ctx.on_reload exactly once — it used to run "
				.. '"kill -HUP $$", which signals the /bin/sh that os.execute spawned, '
				.. "never this process, so the item logged success and reloaded nothing"
		)
	end)

	helpers.it("never shells out — os.execute must not be reached at all", function()
		-- This is the assertion the original could never have failed: os.execute
		-- neither raises nor reports anything useful for a command that runs
		-- successfully and does the wrong thing, so the ONLY way to catch that
		-- shape is to assert the call does not happen.
		local real_execute = os.execute
		local captured = {}
		os.execute = function(cmd)
			captured[#captured + 1] = tostring(cmd)
			return true
		end

		local ok, err = pcall(function()
			local mb = helpers.load_module("modules.menu.menu_builder")
			local items = mb.build({
				config = make_config(),
				_version = "9.9.9",
				on_reload = function() end,
			})
			local reload = find_item(items, "recharg") or find_item(items, "reload")
			helpers.assert_true(reload ~= nil, "the menu must contain a Reload item")
			reload.fn()
		end)

		os.execute = real_execute
		helpers.assert_true(ok, "the Reload item raised: " .. tostring(err))
		helpers.assert_eq(
			#captured,
			0,
			"the Reload item shelled out ("
				.. table.concat(captured, " | ")
				.. ") — reloading this process must not go through a subprocess, "
				.. "because a subprocess cannot signal its own parent by pid and "
				.. "the previous attempt to do so silently signalled the shell instead"
		)
	end)

	helpers.it("reports loudly when the daemon supplied no reload callback", function()
		-- A Reload item that quietly does nothing is precisely the bug being
		-- fixed, so the missing-callback path must be visible rather than silent.
		local mb = helpers.load_module("modules.menu.menu_builder")
		local items = mb.build({ config = make_config(), _version = "9.9.9" })

		local reload = find_item(items, "recharg") or find_item(items, "reload")
		helpers.assert_true(reload ~= nil, "the menu must contain a Reload item")

		local ok = pcall(reload.fn)
		helpers.assert_true(ok, "a missing on_reload must not crash the menu, only log an error")
	end)
end)





-- =========================================================================
-- =========================================================================
-- ======= 2/ os.getpid does not exist — the premise, asserted ============
-- =========================================================================
-- =========================================================================

helpers.describe("Lua's os library has no getpid", function()
	helpers.it("os.getpid is nil, so any `os.getpid and os.getpid()` guard is dead", function()
		helpers.assert_eq(
			type(os.getpid),
			"nil",
			"os.getpid exists on this interpreter — if a Lua build ever grows it, "
				.. "the shape this test guards against becomes half-working rather than "
				.. "never-working, which is worse, not better"
		)
	end)
end)
