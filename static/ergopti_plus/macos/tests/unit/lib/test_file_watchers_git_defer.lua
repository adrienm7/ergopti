--- tests/unit/lib/test_file_watchers_git_defer.lua

--- ==============================================================================
--- MODULE: infra/file_watchers git-pull reload deferral
--- DESCRIPTION:
--- Regression test for macos-reload-during-git-pull. A `git pull` run against a
--- live driver rewrites init.lua and dozens of modules; the project .lua watcher
--- fires and — before this fix — called hs.reload() immediately, booting against
--- a half-updated tree that errors out and leaves Hammerspoon dead (config gone,
--- no watchers armed, must relaunch).
---
--- This drives the project watcher through a simulated .lua change and steps the
--- debounce timer by hand while flipping an injected git gate:
---   • while git is mid-operation the reload must be HELD (hs.reload NOT called)
---     and a poll timer re-armed,
---   • once git settles the reload must fire EXACTLY ONCE.
--- It fails against the pre-fix module, which reloads regardless of git state.
--- ==============================================================================

local helpers = require("tests.helpers")

-- ui_restore pass-through so the deferred reload fn actually runs when fired.
package.loaded["infra.ui_restore"] = {
	defer_reload = function(fn) if type(fn) == "function" then fn() end end,
	snapshot     = function() end,
	restore      = function() end,
}

-- Controllable git gate: the test flips git_busy to simulate an in-flight pull.
local git_busy = false
package.loaded["infra.git_status"] = {
	operation_in_progress = function() return git_busy end,
}

package.loaded["infra.file_watchers"] = nil
local FW = require("infra.file_watchers")

helpers.describe("infra/file_watchers — reload deferral during git pull (macos-reload-during-git-pull)", function()
	helpers.it("holds the reload while git writes the tree, then fires exactly once when it settles", function()
		local prev_pw, prev_timer, prev_attr, prev_reload =
			hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload

		local watch_cbs   = {}
		local captured_fn = nil   -- latest debounce / poll timer callback
		local reloads     = 0

		-- Controllable clock so the test can step past the post-boot suppress window.
		local clock = 0

		hs.pathwatcher = { new = function(_path, cb)
			watch_cbs[#watch_cbs + 1] = cb
			local watcher = {}
			function watcher:start() return self end
			function watcher:stop() return nil end
			return watcher
		end }
		-- Capture the timer fn instead of running it, so the test steps each
		-- debounce / poll tick manually.
		hs.timer = {
			doAfter = function(_s, fn) captured_fn = fn; return { stop = function() end } end,
			secondsSinceEpoch = function() return clock end,
		}
		hs.fs.attributes = function(_p) return nil end   -- no personal-hotstrings tree
		hs.reload = function() reloads = reloads + 1 end

		_G.script_watchers = nil
		git_busy = false
		-- A throw here fails the test directly: helpers.it wraps the body in pcall.
		FW.start({
			hotstrings_dir = "/fake/hotstrings/",
			base_dir = "/fake/base/",
			personal_hotstrings_dir = "/fake/personal",
		})

		-- Advance well past the boot suppress window so the change below is treated
		-- as a genuine edit, not a replayed FSEvents batch.
		clock = 1000

		-- Simulate git rewriting a project .lua file: the project watcher arms the
		-- debounce timer (the hotstrings watcher ignores a .lua path).
		for _, cb in ipairs(watch_cbs) do
			pcall(cb, { "/fake/base/modules/foo.lua" })
		end
		helpers.assert_true(type(captured_fn) == "function", "a .lua change must schedule a reload")
		helpers.assert_true(reloads == 0, "no reload before the debounce elapses")

		-- Advance past the settle window so this test isolates the GIT hold (not the
		-- quiescence hold): a lone .lua edit settles after EDIT_SETTLE_SEC.
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

		hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload =
			prev_pw, prev_timer, prev_attr, prev_reload
		_G.script_watchers = nil
	end)
end)
