--- tests/unit/ui/menu/test_menu_watchers_git_defer.lua

--- ==============================================================================
--- MODULE: ui/menu/menu_watchers git-pull reload deferral
--- DESCRIPTION:
--- Sibling regression for macos-reload-during-git-pull. menu_watchers'
--- start_config_watcher is the SECOND auto-reload watcher on base_dir (alongside
--- infra/file_watchers); both fire on a `git pull`, so guarding only one still lets
--- the other reload mid-pull and leave Hammerspoon dead. This drives the config
--- watcher's callback and steps the debounce timer by hand while flipping an
--- injected git gate:
---   • while git is mid-operation on_reload must be HELD,
---   • once git settles on_reload must fire EXACTLY ONCE.
--- It fails against the pre-fix module, which reloads regardless of git state.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Controllable git gate, injected before the module is required.
local git_busy = false
package.loaded["infra.git_status"] = {
	operation_in_progress = function() return git_busy end,
}

package.loaded["ui.menu.menu_watchers"] = nil
local MenuWatchers = require("ui.menu.menu_watchers")

helpers.describe("ui/menu/menu_watchers — reload deferral during git pull (macos-reload-during-git-pull)", function()
	helpers.it("holds the reload while git writes the tree, then fires exactly once when it settles", function()
		local prev_pw, prev_timer = hs.pathwatcher, hs.timer

		local captured_cb = nil   -- the pathwatcher callback (reload_config)
		local captured_fn = nil   -- latest debounce / poll timer callback
		local reloads     = 0

		hs.pathwatcher = { new = function(_path, cb)
			captured_cb = cb
			return { start = function() end }
		end }
		local clock = 1000   -- drives hs.timer.secondsSinceEpoch()
		hs.timer = {
			doAfter = function(_s, fn) captured_fn = fn; return { stop = function() end } end,
			secondsSinceEpoch = function() return clock end,
		}

		-- ui_restore pass-through so the deferred reload runs when fired.
		local ui_restore_stub = { defer_reload = function(fn) if type(fn) == "function" then fn() end end }

		git_busy = false
		local watcher = MenuWatchers.start_config_watcher(
			"/fake/base/",
			function() reloads = reloads + 1 end,   -- on_reload
			function() return 0 end,                 -- get_suppress_until: never suppress
			ui_restore_stub
		)
		helpers.assert_true(watcher ~= nil, "start_config_watcher must return a watcher")
		helpers.assert_true(type(captured_cb) == "function", "a pathwatcher callback must be registered")

		-- Simulate git rewriting a project .lua file → arms the debounce timer.
		captured_cb({ "/fake/base/modules/foo.lua" })
		helpers.assert_true(type(captured_fn) == "function", "a .lua change must schedule a reload")
		helpers.assert_true(reloads == 0, "no reload before the debounce elapses")

		-- Advance past the settle window so this isolates the GIT hold, not the
		-- quiescence hold (a lone .lua edit settles after EDIT_SETTLE_SEC).
		clock = 1001

		-- Debounce elapses while git is STILL writing the tree → must NOT reload.
		git_busy = true
		local fn1 = captured_fn
		captured_fn = nil
		fn1()
		helpers.assert_true(reloads == 0, "reload must be HELD while a git operation is in progress")
		helpers.assert_true(type(captured_fn) == "function", "the held reload must re-arm a poll timer")

		-- git finishes → the next poll tick fires the reload exactly once.
		git_busy = false
		local fn2 = captured_fn
		captured_fn = nil
		fn2()
		helpers.assert_true(reloads == 1, "reload must fire once git has settled (got " .. reloads .. ")")

		hs.pathwatcher, hs.timer = prev_pw, prev_timer
	end)

	helpers.it("revokes a pending reload and retains failed timer cleanup for an exact retry", function()
		for _, failure in ipairs({ "false", "throw" }) do
			local prev_pw, prev_timer = hs.pathwatcher, hs.timer
			local captured_cb, pending_callback
			local reloads = 0
			local timer_stops = 0

			hs.pathwatcher = { new = function(_path, callback)
				captured_cb = callback
				local watcher = {}
				function watcher:start() return watcher end
				function watcher:stop() return watcher end
				return watcher
			end }
			hs.timer = {
				doAfter = function(_delay, callback)
					pending_callback = callback
					local timer = {}
					function timer:stop()
						timer_stops = timer_stops + 1
						if timer_stops == 1 then
							if failure == "throw" then error("timer stop failed") end
							return false
						end
						return timer
					end
					return timer
				end,
				secondsSinceEpoch = function() return 10 end,
			}

			local owner = MenuWatchers.start_config_watcher(
				"/fake/base/",
				function() reloads = reloads + 1 end,
				function() return 0 end,
				{ defer_reload = function(callback) callback() end }
			)
			captured_cb({ "/fake/base/modules/change.lua" })
			helpers.assert_true(type(pending_callback) == "function", "a relevant change must arm the debounce")
			helpers.assert_eq(false, owner:stop(),
				"a failed timer cancellation must preserve the owner for retry (" .. failure .. ")")
			pending_callback()
			helpers.assert_eq(0, reloads,
				"a stale queued callback must not reload after logical teardown (" .. failure .. ")")
			helpers.assert_eq(true, owner:stop(),
				"the same owner must settle retained cleanup on retry (" .. failure .. ")")
			helpers.assert_eq(2, timer_stops,
				"cleanup must retry the exact timer once (" .. failure .. ")")

			hs.pathwatcher, hs.timer = prev_pw, prev_timer
		end
	end)
end)
