--- tests/unit/platform/remap/test_wizard_session_guard.lua

--- ==============================================================================
--- MODULE: platform.remap — first-run wizard session guard regression
--- DESCRIPTION:
--- Locks down the bug where the Karabiner Elements first-run onboarding wizard
--- was triggered on every hs.reload() because the 2-second deferred timer in
--- M.init() called run_first_run_wizard() unconditionally.
---
--- Root cause: no session-level guard prevented the wizard from firing more than
--- once per Hammerspoon session. On hs.reload() all modules are re-required from
--- scratch, so `M.init()` runs again and re-scheduled the dialog.
---
--- Fix: a module-level `_wizard_ran_this_session` boolean is set to true on the
--- first invocation and prevents subsequent calls from reaching the shared
--- `schedule_first_run_wizard` timer transaction.
--- `hs.reload()` re-requires the module, resetting the flag — but within a
--- session the flag is sticky, so a manual menu-reload does not re-prompt.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_source()
	local src = helpers.read_driver_source("_wizard_ran_this_session")
	helpers.assert_true(src ~= nil and src ~= "",
		"platform.remap.init must remain locatable by its wizard session guard")
	return src
end




-- ==========================================================
-- ==========================================================
-- ======= 1/ Session guard present in source ===============
-- ==========================================================
-- ==========================================================

helpers.describe("karabiner.init — wizard session guard", function()
	helpers.it("declares _wizard_ran_this_session module-level flag", function()
		local src = read_source()
		helpers.assert_true(
			src:find("_wizard_ran_this_session", 1, true) ~= nil,
			"platform.remap.init must declare `_wizard_ran_this_session` to prevent the " ..
			"first-run wizard from re-prompting on every hs.reload()"
		)
	end)

	helpers.it("wizard timer is conditional on `not _wizard_ran_this_session`", function()
		local src = read_source()
		-- The guard must appear on the same conditional branch as the timer
		-- scheduling. We assert the source contains the conjunction that prevents
		-- re-scheduling.
		helpers.assert_true(
			src:find("not _wizard_ran_this_session", 1, true) ~= nil,
			"platform.remap.init: the wizard timer must be guarded by " ..
			"`not _wizard_ran_this_session` so it never fires more than once per session"
		)
	end)

	helpers.it("flag is set to true before the timer fires", function()
		local src = read_source()
		-- Bound the exact M.init branch so helper definitions earlier in the module
		-- cannot satisfy the ordering assertion.
		local branch_pos = src:find(
			"if _state.enabled and not _wizard_ran_this_session then", 1, true)
		local branch_end = branch_pos and src:find("\n\tend", branch_pos, true)
		helpers.assert_true(branch_pos ~= nil and branch_end ~= nil,
			"the guarded first-run wizard branch must remain bounded")
		local branch = src:sub(branch_pos, branch_end)
		local assign_pos = branch:find("_wizard_ran_this_session = true", 1, true)
		local timer_pos = branch:find("schedule_first_run_wizard(wizard_epoch)", 1, true)
		helpers.assert_true(
			assign_pos ~= nil,
			"_wizard_ran_this_session = true must appear in the source"
		)
		helpers.assert_true(
			timer_pos ~= nil,
			"the session guard must still reach the shared wizard scheduler"
		)
		helpers.assert_true(
			assign_pos < timer_pos,
			"the guard flag must be set BEFORE the shared wizard scheduler is called, " ..
			"so a second M.init() call during the 2-second window cannot enqueue a second dialog"
		)
	end)
end)
