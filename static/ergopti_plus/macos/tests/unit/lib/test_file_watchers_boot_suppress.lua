--- tests/unit/lib/test_file_watchers_boot_suppress.lua

--- ==============================================================================
--- MODULE: infra/file_watchers post-boot FSEvents-replay suppression
--- DESCRIPTION:
--- Second regression for macos-reload-during-git-pull. The git guard stops a
--- reload from firing WHILE git writes the tree, but macOS FSEvents replays the
--- pull's buffered change events to the freshly-armed watcher right AFTER the
--- post-pull reload boots — and git is idle by then, so the guard cannot help.
--- Without a boot-suppress window (the sibling menu_watchers already had, but
--- file_watchers did not) that replay re-fires the reload every boot and cascades
--- into the keyboard-freezing storm this driver first fixed in fe57ce045.
---
--- This drives a .lua change through the project watcher at two clock positions
--- and asserts a change INSIDE the boot window is dropped while one AFTER it
--- reloads normally. It fails against the pre-fix module, which armed a reload
--- regardless of how recently the watchers were (re)armed.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.ui_restore"] = {
	defer_reload = function(fn) if type(fn) == "function" then fn() end end,
	snapshot     = function() end,
	restore      = function() end,
}
-- git idle throughout: isolate the boot-suppress behaviour from the git gate.
package.loaded["infra.git_status"] = { operation_in_progress = function() return false end }

package.loaded["infra.file_watchers"] = nil
local FW = require("infra.file_watchers")

helpers.describe("infra/file_watchers — post-boot FSEvents-replay suppression (macos-reload-during-git-pull)", function()
	helpers.it("drops a change inside the boot window, then reloads once the window passes", function()
		local prev_pw, prev_timer, prev_attr, prev_reload =
			hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload

		local clock       = 0   -- drives hs.timer.secondsSinceEpoch()
		local watch_cbs   = {}
		local captured_fn = nil
		local reloads     = 0

		hs.pathwatcher = { new = function(_path, cb)
			watch_cbs[#watch_cbs + 1] = cb
			local watcher = {}
			function watcher:start() return self end
			function watcher:stop() return nil end
			return watcher
		end }
		hs.timer = {
			doAfter = function(_s, fn) captured_fn = fn; return { stop = function() end } end,
			secondsSinceEpoch = function() return clock end,
		}
		hs.fs.attributes = function(_p) return nil end
		hs.reload = function() reloads = reloads + 1 end

		_G.script_watchers = nil
		-- start() captures suppress_until = clock(0) + BOOT_SUPPRESS_SEC(5) = 5.
		FW.start({
			hotstrings_dir = "/fake/hotstrings/",
			base_dir = "/fake/base/",
			personal_hotstrings_dir = "/fake/personal",
		})

		local function fire_lua_change()
			captured_fn = nil
			for _, cb in ipairs(watch_cbs) do pcall(cb, { "/fake/base/modules/foo.lua" }) end
		end

		-- (1) Inside the boot window: a replayed change must be dropped entirely.
		clock = 1
		fire_lua_change()
		helpers.assert_true(captured_fn == nil, "a change inside the boot suppress window must NOT schedule a reload")
		helpers.assert_true(reloads == 0, "and must NOT reload")

		-- (2) After the window: a genuine change schedules and reloads exactly once.
		clock = 10
		fire_lua_change()
		helpers.assert_true(type(captured_fn) == "function", "a change after the window must schedule a reload")
		clock = 11   -- past the lone-edit settle window so the reload fires
		captured_fn()
		helpers.assert_true(reloads == 1, "and must reload once (got " .. reloads .. ")")

		hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload =
			prev_pw, prev_timer, prev_attr, prev_reload
		_G.script_watchers = nil
	end)
end)
