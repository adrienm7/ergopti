--- tests/unit/lib/test_dialog_focus_is_async.lua

--- ==============================================================================
--- MODULE: Regression — the dialog focus nudge must not park the runloop
--- DESCRIPTION:
--- `focus_hammerspoon()` is the first statement of all three public dialog
--- wrappers (block_alert, text_prompt, alert). After two in-process focus
--- attempts it fired a third, redundant one as a SUBPROCESS — `hs.execute("open
--- '<bundlePath>'")` — which is synchronous: it holds the single Hammerspoon
--- runloop until Launch Services answers. That happened immediately before
--- putting up a modal dialog, which is the one moment the driver can least afford
--- to stop servicing the keyboard tap.
---
--- ROOT CAUSE ENCODED:
--- The activation itself is wanted — a menubar click steals focus and the dialog
--- would otherwise open without keyboard focus — so the fix is not to delete it
--- but to stop it blocking. The assertion below is therefore on WHICH primitive
--- launches it, not on whether the nudge exists.
---
--- Two things go with it. The hand-rolled `gsub("'", "'\\''")` disappears: argv
--- needs no shell quoting, and that escaping duplicated text_utils.shell_quote
--- while covering only the single quote. And the GC pitfall the old comment
--- worried about — an hs.task held in a local being SIGTERMed before it runs — is
--- handled by the spawner, which pins the task in a long-lived table before
--- starting it and releases it in the completion callback.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Located by the private helper's name: it is the whole subject of this guard.
local ANCHOR = "focus_hammerspoon"




-- ==================================================================
-- ==================================================================
-- ======= 1/ No synchronous shell-out from the dialog path =========
-- ==================================================================
-- ==================================================================

helpers.describe("dialog_util: the focus nudge is asynchronous", function()

	helpers.it("launches the activation through the async spawner, not hs.execute", function()
		local src = helpers.read_driver_source(ANCHOR)
		helpers.assert_true(src ~= nil and src ~= "",
			"dialog_util must be locatable by '" .. ANCHOR .. "'; an empty corpus would make "
			.. "every assertion below vacuous")

		-- Comments stripped: this module's own prose discusses hs.execute and the
		-- hs.task GC pitfall, so a raw scan would flag the explanation as the defect.
		local code = src:gsub("%-%-[^\n]*", "")

		helpers.assert_true(code:find("hs.execute", 1, true) == nil,
			"hs.execute holds the runloop until the child exits, and `open` waits on "
			.. "Launch Services. Parking the main thread right before a modal dialog is the "
			.. "worst possible moment: the keyboard tap is serviced from that same runloop, "
			.. "and a tap that misses its deadline is disabled outright by macOS")

		helpers.assert_true(code:find("ShellRunner.spawn", 1, true) ~= nil,
			"the activation must still happen — a menubar click steals focus and the dialog "
			.. "would otherwise open without keyboard focus. It just has to be launched "
			.. "asynchronously, through the spawner that also pins the task against the GC")
	end)

	helpers.it("no longer hand-rolls shell quoting", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- argv needs no quoting at all. The old escaping covered the single quote and
		-- nothing else, and duplicated text_utils.shell_quote while doing it.
		helpers.assert_true(code:find("gsub(\"'\"", 1, true) == nil,
			"with argv there is no shell to quote for, so a hand-rolled escape is both dead "
			.. "and a second source of truth for a rule text_utils already owns")
	end)

	helpers.it("the activation is still deferred", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- Without this case the assertions above would pass against a version that
		-- fires the nudge inline. The 100 ms delay is load-bearing: hs.dialog.* blocks
		-- the main runloop, so anything scheduled AFTER the dialog opens will not run
		-- until it is dismissed — the nudge has to be armed before that.
		helpers.assert_true(code:find("TimerScheduler.after(0.1", 1, true) ~= nil,
			"the nudge must still be armed on a short delay before the dialog blocks the "
			.. "runloop, or it can never reach the dialog it exists to focus")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 2/ Timer acquisition is an exact transaction =============
-- ==================================================================
-- ==================================================================

--- Runs one dialog fixture and restores every process-global dependency.
--- @param timer_mode string Scheduler outcome.
--- @param cancel_result boolean|nil Cancellation outcome.
--- @param scenario function Scenario receiving Dialog, counters, and handle getter.
local function with_dialog_fixture(timer_mode, cancel_result, scenario)
	local previous_logger = package.loaded["infra.logger"]
	local previous_shell_runner = package.loaded["adapters.shell_runner"]
	local previous_scheduler = package.loaded["adapters.timer_scheduler"]
	local previous_dialog = package.loaded["infra.dialog_util"]
	local previous_hs_module = package.loaded["hs"]
	local previous_hs_stub = package.loaded["tests.stubs.hs"]
	local previous_global_hs = _G.hs
	local calls = { alerts = 0, spawns = 0, starts = 0, cancels = 0, errors = 0 }
	local candidate = nil
	package.loaded["infra.logger"] = setmetatable({
		error = function() calls.errors = calls.errors + 1 end,
	}, { __index = function() return function() end end })
	package.loaded["adapters.shell_runner"] = {
		spawn = function()
			calls.spawns = calls.spawns + 1
			return { start = function() calls.starts = calls.starts + 1; return true end }
		end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_, callback)
			if timer_mode == "throw" then error("focus timer exploded") end
			candidate = { callback = callback, timer = {}, committed = timer_mode ~= "uncommitted" }
			return candidate, candidate.committed
		end,
		cancel = function(handle)
			calls.cancels = calls.cancels + 1
			if cancel_result == false then return false end
			handle.timer = nil
			handle.committed = false
			return true
		end,
	}

	local hs_stub = {
		focus = function() return true end,
		application = { get = function() return { activate = function() return true end } end },
		processInfo = { bundlePath = "/Applications/Hammerspoon.app" },
		dialog = {
			alert = function(...)
				calls.alerts = calls.alerts + 1
				return "shown", ...
			end,
			blockAlert = function() return "blocked" end,
			textPrompt = function() return "prompted", "text" end,
		},
	}
	package.loaded["infra.dialog_util"] = nil
	local Dialog = helpers.load_with_stubs("infra.dialog_util", hs_stub)
	local ok, err = xpcall(function()
		scenario(Dialog, calls, function() return candidate end)
	end, debug.traceback)
	package.loaded["infra.logger"] = previous_logger
	package.loaded["adapters.shell_runner"] = previous_shell_runner
	package.loaded["adapters.timer_scheduler"] = previous_scheduler
	package.loaded["infra.dialog_util"] = previous_dialog
	package.loaded["hs"] = previous_hs_module
	package.loaded["tests.stubs.hs"] = previous_hs_stub
	_G.hs = previous_global_hs
	if not ok then error(err, 0) end
end

helpers.describe("dialog_util: deferred focus timer transaction", function()
	helpers.it("reports and rolls back an uncommitted nudge without suppressing the alert", function()
		with_dialog_fixture("uncommitted", true, function(Dialog, calls, get_candidate)
			helpers.assert_eq(Dialog.alert("body"), "shown",
				"focus assistance is best-effort; timer refusal must not suppress the user's dialog")
			helpers.assert_eq(calls.alerts, 1)
			helpers.assert_eq(calls.spawns, 0)
			helpers.assert_eq(calls.cancels, 1,
				"the exact uncommitted timer candidate must be rolled back")
			helpers.assert_true(calls.errors > 0,
				"the missing focus nudge must be visible in the file logger")
			get_candidate().callback()
			helpers.assert_eq(calls.spawns, 0,
				"a retained callback from rejected acquisition must remain inert")
		end)
	end)

	helpers.it("contains a throwing timer and still opens the alert truthfully", function()
		with_dialog_fixture("throw", nil, function(Dialog, calls)
			helpers.assert_eq(Dialog.alert("body"), "shown")
			helpers.assert_eq(calls.alerts, 1)
			helpers.assert_eq(calls.spawns, 0)
			helpers.assert_true(calls.errors > 0,
				"a scheduler exception must reach the file logger instead of disappearing in pcall")
		end)
	end)
end)
