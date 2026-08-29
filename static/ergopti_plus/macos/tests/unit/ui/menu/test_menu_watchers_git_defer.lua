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
		local defer_reload_calls = 0
		local ui_restore_stub = { defer_reload = function(fn)
			defer_reload_calls = defer_reload_calls + 1
			if type(fn) == "function" then fn() end
		end }

		git_busy = false
		local watcher = MenuWatchers.start_config_watcher(
			"/fake/base/",
			function() reloads = reloads + 1; return true end, -- on_reload
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

		-- The Git lock remains authoritative even beyond the historical 120-poll
		-- diagnostic threshold. No deferred reload may be attempted while it exists.
		git_busy = true
		for poll = 1, 121 do
			local held_fn = captured_fn
			captured_fn = nil
			helpers.assert_true(type(held_fn) == "function",
				"persistent Git hold must retain poll ownership at tick " .. poll)
			held_fn()
		end
		helpers.assert_true(reloads == 0, "reload must be HELD while a git operation is in progress")
		helpers.assert_true(type(captured_fn) == "function", "the held reload must re-arm a poll timer")
		helpers.assert_eq(defer_reload_calls, 0,
			"a persistent Git lock must not cross the deferred-reload boundary")

		-- git finishes → the next poll tick fires the reload exactly once.
		git_busy = false
		local fn2 = captured_fn
		captured_fn = nil
		fn2()
		helpers.assert_true(reloads == 1, "reload must fire once git has settled (got " .. reloads .. ")")

		hs.pathwatcher, hs.timer = prev_pw, prev_timer
	end)

	helpers.it("rechecks Git ownership when the deferred reload is finally dispatched", function()
		local prev_pw, prev_timer = hs.pathwatcher, hs.timer
		local captured_cb, pending_timer, pending_reload
		local reloads = 0
		local clock = 1000

		hs.pathwatcher = { new = function(_path, callback)
			captured_cb = callback
			return { start = function() end }
		end }
		hs.timer = {
			doAfter = function(_delay, callback)
				pending_timer = callback
				return { stop = function() end }
			end,
			secondsSinceEpoch = function() return clock end,
		}

		git_busy = false
		MenuWatchers.start_config_watcher(
			"/fake/base/",
			function() reloads = reloads + 1; return true end,
			function() return 0 end,
			{ defer_reload = function(callback) pending_reload = callback; return true end }
		)
		captured_cb({ "/fake/base/modules/foo.lua" })
		helpers.assert_true(type(pending_timer) == "function", "the change must arm a settle timer")
		clock = 1001
		pending_timer()
		helpers.assert_true(type(pending_reload) == "function", "an idle poll must stage a deferred reload")

		git_busy = true
		pending_timer = nil
		pending_reload()
		helpers.assert_eq(reloads, 0, "Git becoming busy before dispatch must fence the reload")
		helpers.assert_true(type(pending_timer) == "function",
			"a fire-time Git refusal must re-arm the exact polling owner")

		git_busy = false
		pending_reload = nil
		pending_timer()
		helpers.assert_true(type(pending_reload) == "function", "the settled retry must reach dispatch")
		pending_reload()
		helpers.assert_eq(reloads, 1, "the retained reload must fire exactly once after Git settles")

		hs.pathwatcher, hs.timer = prev_pw, prev_timer
	end)

	helpers.it("retains one source burst until the menu reload callback accepts it", function()
		local prev_pw, prev_timer = hs.pathwatcher, hs.timer
		local captured_cb, pending_timer
		local clock, reload_attempts = 1000, 0

		hs.pathwatcher = { new = function(_path, callback)
			captured_cb = callback
			return { start = function() return true end, stop = function() return true end }
		end }
		hs.timer = {
			doAfter = function(_delay, callback)
				pending_timer = callback
				return { stop = function() return true end }
			end,
			secondsSinceEpoch = function() return clock end,
		}

		git_busy = false
		MenuWatchers.start_config_watcher(
			"/fake/base/",
			function()
				reload_attempts = reload_attempts + 1
				return reload_attempts > 1
			end,
			function() return 0 end,
			{ defer_reload = function(callback) callback() end }
		)
		captured_cb({ "/fake/base/modules/refused.lua" })
		clock = 1001
		local first = pending_timer
		pending_timer = nil
		first()

		helpers.assert_eq(1, reload_attempts, "the first reload attempt must reach the menu callback")
		helpers.assert_true(type(pending_timer) == "function",
			"a refused menu reload must retain the source burst and re-arm its polling owner")
		local retry = pending_timer
		pending_timer = nil
		retry()
		helpers.assert_eq(2, reload_attempts, "the retained source burst must retry exactly once")
		helpers.assert_eq(nil, pending_timer, "an accepted reload must settle the retained burst")

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
