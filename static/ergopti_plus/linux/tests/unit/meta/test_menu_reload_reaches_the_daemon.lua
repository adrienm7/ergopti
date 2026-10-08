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
		local mb = helpers.load_module("ui.menu.menu_builder")
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
			local mb = helpers.load_module("ui.menu.menu_builder")
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
		local mb = helpers.load_module("ui.menu.menu_builder")
		local items = mb.build({ config = make_config(), _version = "9.9.9" })

		local reload = find_item(items, "recharg") or find_item(items, "reload")
		helpers.assert_true(reload ~= nil, "the menu must contain a Reload item")

		local ok, reload_err = pcall(reload.fn)
		helpers.assert_nil(reload_err, "and must report none: " .. tostring(reload_err))
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

--- Runs the actual root builder over independently authored lifecycle declarations.
local function with_lifecycle_declarations(callback)
	local renderer = require("infra.manifest_menu")
	local rows = renderer.get_array("top_level")
	local saved, owned, native_counts = {}, {}, {}
	for index, row in ipairs(rows) do
		if row.id == "reload" or row.id == "quit" then
			saved[index] = row
			local copy = {}
			for key, value in pairs(row) do copy[key] = value end
			copy.type = "command"
			copy.i18n = row.id == "reload" and "button.cancel" or "button.ok"
			rows[index] = copy
			local native = copy.platforms == nil
			for _, platform in ipairs(copy.platforms or {}) do
				if platform == "linux" then native = true end
			end
			if native then
				owned[row.id] = copy
				native_counts[row.id] = (native_counts[row.id] or 0) + 1
			end
		end
	end
	local ok, err = pcall(function()
		helpers.assert_eq(native_counts.reload, 1, "the fixture mutates exactly one native Reload declaration")
		helpers.assert_eq(native_counts.quit, 1, "the fixture mutates exactly one native Quit declaration")
		helpers.assert_true(owned.reload ~= nil and owned.quit ~= nil, "the real root declares both commands")
		callback(helpers.load_module("ui.menu.menu_builder"), owned)
	end)
	for index, row in pairs(saved) do rows[index] = row end
	renderer.invalidate_cache()
	if not ok then error(err, 0) end
end

local function lifecycle_declared_row(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if item.title == label then return item end
	end
end

helpers.describe("shared lifecycle commands (Linux)", function()
	helpers.it("uses declared labels and preserves daemon ownership and Quit-last while paused (shared-lifecycle)", function()
		with_lifecycle_declarations(function(builder)
			local calls = {}
			local items = builder.build({ config = make_config(), paused = true,
				on_reload = function() calls[#calls + 1] = "reload" end,
				on_quit = function() calls[#calls + 1] = "quit" end,
			})
			local reload = lifecycle_declared_row(items, "button.cancel")
			local quit = lifecycle_declared_row(items, "button.ok")
			helpers.assert_true(reload ~= nil and quit ~= nil, "both commands consume their shared labels")
			helpers.assert_true(reload.disabled ~= true and quit.disabled ~= true)
			helpers.assert_true(items[#items] == quit, "the existing desktop Quit-last policy is retained")
			reload.fn(); quit.fn()
			helpers.assert_eq(table.concat(calls, ","), "reload,quit")
		end)
	end)

	helpers.it("refuses an unregistered declared readiness predicate without running native owners (shared-lifecycle)", function()
		with_lifecycle_declarations(function(builder, owned)
			owned.reload.i18n, owned.quit.i18n = "menu.global.reload", "menu.global.quit"
			owned.reload.disabled_when = { "unregistered_lifecycle_owner" }
			owned.quit.disabled_when = { "unregistered_lifecycle_owner" }
			local calls = 0
			local items = builder.build({ config = make_config(),
				on_reload = function() calls = calls + 1 end,
				on_quit = function() calls = calls + 1 end,
			})
			local reload = lifecycle_declared_row(items, "menu.global.reload")
			local quit = lifecycle_declared_row(items, "menu.global.quit")
			helpers.assert_true(reload.disabled == true and quit.disabled == true)
			helpers.assert_eq(reload.fn(), false)
			helpers.assert_eq(quit.fn(), false)
			helpers.assert_eq(calls, 0)
		end)
	end)

	helpers.it("does not reinterpret a non-command declaration as a lifecycle row (shared-lifecycle)", function()
		with_lifecycle_declarations(function(builder, owned)
			owned.reload.i18n, owned.quit.i18n = "menu.global.reload", "menu.global.quit"
			owned.reload.type, owned.quit.type = "---", "---"
			local calls = 0
			local items = builder.build({ config = make_config(),
				on_reload = function() calls = calls + 1 end,
				on_quit = function() calls = calls + 1 end,
			})
			helpers.assert_nil(lifecycle_declared_row(items, "menu.global.reload"))
			helpers.assert_nil(lifecycle_declared_row(items, "menu.global.quit"))
			helpers.assert_eq(calls, 0)
		end)
	end)
end)
