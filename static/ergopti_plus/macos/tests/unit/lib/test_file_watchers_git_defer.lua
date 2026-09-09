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

local Fixture = require("tests.support.file_watcher_self_write_fixture")

helpers.describe("infra/file_watchers — reload deferral during git pull (macos-reload-during-git-pull)", function()
	helpers.it("holds the reload while git writes the tree, then fires exactly once when it settles", function()
		local git_busy = false
		Fixture.with_watchers(function(w)
			-- Advance well past the boot suppress window so the change below is treated
			-- as a genuine edit, not a replayed FSEvents batch.
			w.set_clock(1000)

			-- Simulate git rewriting a project .lua file: the project watcher arms the
			-- debounce timer (the hotstrings watcher ignores a .lua path).
			w.fire("/fake/base/modules/foo.lua")
			helpers.assert_true(type(w.scheduled()) == "function", "a .lua change must schedule a reload")
			helpers.assert_true(w.reloads() == 0, "no reload before the debounce elapses")

			-- Advance past the settle window so this test isolates the GIT hold (not the
			-- quiescence hold): a lone .lua edit settles after EDIT_SETTLE_SEC.
			w.set_clock(1001)

			-- The Git lock remains authoritative even beyond the historical 120-poll
			-- diagnostic threshold. No deferred reload may be attempted while it exists.
			git_busy = true
			for poll = 1, 121 do
				local held_fn = w.scheduled()
				helpers.assert_true(type(held_fn) == "function",
					"persistent Git hold must retain poll ownership at tick " .. poll)
				w.poll()
			end
			helpers.assert_true(w.reloads() == 0, "reload must be HELD while a git operation is in progress")
			helpers.assert_true(type(w.scheduled()) == "function", "the held reload must re-arm a poll timer")
			helpers.assert_eq(w.defer_calls(), 0,
				"a persistent Git lock must not cross the deferred-reload boundary")

			-- git finishes → the next poll tick fires the reload exactly once.
			git_busy = false
			w.poll()
			helpers.assert_true(w.reloads() == 1, "reload must fire once git has settled (got " .. w.reloads() .. ")")

		end, { git_probe = function() return git_busy end })
	end)

	helpers.it("retains one source burst until hs.reload accepts it", function()
		local reload_attempts = 0
		Fixture.with_watchers(function(w)
			w.set_clock(1000)
			w.fire("/fake/base/modules/refused.lua")
			w.set_clock(1001)
			w.poll()

			helpers.assert_eq(1, reload_attempts, "the first reload attempt must reach hs.reload")
			helpers.assert_true(type(w.scheduled()) == "function",
				"a refused hs.reload must retain the source burst and re-arm its polling owner")
			w.poll()
			helpers.assert_eq(2, reload_attempts, "the retained source burst must retry exactly once")
			helpers.assert_eq(nil, w.scheduled(), "an accepted reload must settle the retained burst")

		end, { reload = function()
			reload_attempts = reload_attempts + 1
			return reload_attempts > 1
		end })
	end)
end)
