--- tests/unit/ui/menu/watchers/test_menu_watchers_git_defer.lua

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

local Fixture = require("tests.support.menu_config_watcher_fixture")

helpers.describe("ui/menu/menu_watchers — reload deferral during git pull (macos-reload-during-git-pull)", function()
	helpers.it("holds the reload while git writes the tree, then fires exactly once when it settles", function()
		local git_busy = false
		Fixture.with_watcher(function(w)
			helpers.assert_true(w.owner ~= nil, "start_config_watcher must return a watcher")
			helpers.assert_true(type(w.callback()) == "function", "a pathwatcher callback must be registered")

			-- Simulate git rewriting a project .lua file → arms the debounce timer.
			w.fire({ "/fake/base/modules/foo.lua" })
			helpers.assert_true(type(w.scheduled()) == "function", "a .lua change must schedule a reload")
			helpers.assert_true(w.reloads() == 0, "no reload before the debounce elapses")

			-- Advance past the settle window so this isolates the GIT hold, not the
			-- quiescence hold (a lone .lua edit settles after EDIT_SETTLE_SEC).
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

	helpers.it("rechecks Git ownership when the deferred reload is finally dispatched", function()
		local git_busy = false
		Fixture.with_watcher(function(w)
			w.fire({ "/fake/base/modules/foo.lua" })
			helpers.assert_true(type(w.scheduled()) == "function", "the change must arm a settle timer")
			w.set_clock(1001)
			w.poll()
			helpers.assert_true(type(w.deferred()) == "function", "an idle poll must stage a deferred reload")

			git_busy = true
			w.release()
			helpers.assert_eq(w.reloads(), 0, "Git becoming busy before dispatch must fence the reload")
			helpers.assert_true(type(w.scheduled()) == "function",
				"a fire-time Git refusal must re-arm the exact polling owner")

			git_busy = false
			w.poll()
			helpers.assert_true(type(w.deferred()) == "function", "the settled retry must reach dispatch")
			w.release()
			helpers.assert_eq(w.reloads(), 1, "the retained reload must fire exactly once after Git settles")

		end, { git_probe = function() return git_busy end, hold_reload = true })
	end)

	helpers.it("retains one source burst until the menu reload callback accepts it", function()
		Fixture.with_watcher(function(w)
			w.fire({ "/fake/base/modules/refused.lua" })
			w.set_clock(1001)
			w.poll()

			helpers.assert_eq(1, w.reloads(), "the first reload attempt must reach the menu callback")
			helpers.assert_true(type(w.scheduled()) == "function",
				"a refused menu reload must retain the source burst and re-arm its polling owner")
			w.poll()
			helpers.assert_eq(2, w.reloads(), "the retained source burst must retry exactly once")
			helpers.assert_eq(nil, w.scheduled(), "an accepted reload must settle the retained burst")

		end, { reload = function(attempt) return attempt > 1 end })
	end)

	-- Field run 2026-10-27 19:47:04 (ledger L45): a burst refused while the reload
	-- it triggered was terminating logged a WARNING; it is expected, so INFO.
	helpers.it("logs a refusal during a reload or quit at INFO and still retains the burst", function()
		local previous = package.loaded["infra.termination_coordinator"]
		local terminating = true
		package.loaded["infra.termination_coordinator"] = {
			terminal_in_progress = function() return terminating end,
		}
		local levels = {}
		local logger = helpers.make_logger_stub()
		local function record(level)
			return function(_, message)
				if tostring(message):find("Menu reload request", 1, true) then levels[#levels + 1] = level .. ":" .. message end
			end
		end
		logger.info, logger.warn, logger.debug = record("info"), record("warn"), record("debug")
		local ok, err = pcall(Fixture.with_watcher, function(w)
			w.fire({ "/fake/base/modules/refused.lua" })
			w.set_clock(1001)
			w.poll()
			helpers.assert_true(type(w.scheduled()) == "function", "the refused burst must stay owned")
			terminating = false
			w.poll()
		end, { reload = function() return false end, logger = logger })
		package.loaded["infra.termination_coordinator"] = previous
		if not ok then error(err, 0) end
		helpers.assert_eq(levels[1], "info:Menu reload request deferred: a reload or quit is in progress.")
		-- The value used to follow "remains pending for retry:", so a refused
		-- request printed "pending for retry: false" and read as a lost retry
		-- although the burst was re-armed (field run 19:47:04, 21:06:55).
		helpers.assert_eq(levels[2],
			"warn:Menu reload request was refused (%s); the source-file burst stays pending and is retried.")
	end)

	helpers.it("revokes a pending reload and retains failed timer cleanup for an exact retry", function()
		for _, failure in ipairs({ "false", "throw" }) do
			Fixture.with_watcher(function(w)
				w.fire({ "/fake/base/modules/change.lua" })
				helpers.assert_true(type(w.scheduled()) == "function", "a relevant change must arm the debounce")
				helpers.assert_eq(false, w.owner:stop(),
					"a failed timer cancellation must preserve the owner for retry (" .. failure .. ")")
				w.scheduled()()
				helpers.assert_eq(0, w.reloads(),
					"a stale queued callback must not reload after logical teardown (" .. failure .. ")")
				helpers.assert_eq(true, w.owner:stop(),
					"the same owner must settle retained cleanup on retry (" .. failure .. ")")
				helpers.assert_eq(2, w.timer_stops(),
					"cleanup must retry the exact timer once (" .. failure .. ")")

			end, { clock = 10, timer_stop = function(attempt, timer)
				if attempt == 1 then
					if failure == "throw" then error("timer stop failed") end
					return false
				end
				return timer
			end })
		end
	end)

	helpers.it("holds the reload while a developer field run runs", function()
		local previous = package.loaded["infra.field_run"]
		local running = true
		package.loaded["infra.field_run"] = { holds_reload = function() return running end }
		local ok, err = pcall(Fixture.with_watcher, function(w)
			w.fire({ "/fake/base/modules/foo.lua" })
			w.set_clock(1001)
			w.poll()
			helpers.assert_eq(w.reloads(), 0, "a field run must not reload itself")
			helpers.assert_eq(w.defer_calls(), 0, "the held burst must not reach the deferred reload")
			running = false
			w.poll()
			helpers.assert_eq(w.reloads(), 1, "the held burst reloads once the run ends")
		end)
		package.loaded["infra.field_run"] = previous
		if not ok then error(err, 0) end
	end)
end)
