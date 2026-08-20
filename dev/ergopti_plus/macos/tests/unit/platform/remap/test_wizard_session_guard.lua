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
--- first invocation and prevents subsequent calls from scheduling the timer.
--- `hs.reload()` re-requires the module, resetting the flag — but within a
--- session the flag is sticky, so a manual menu-reload does not re-prompt.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_source(module_name)
	local path = package.searchpath(module_name, package.path)
	helpers.assert_true(
		type(path) == "string" and path ~= "",
		"could not resolve " .. module_name .. " on package.path"
	)
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "could not open " .. module_name)
	local src = fh:read("*a")
	fh:close()
	return src
end




-- ==========================================================
-- ==========================================================
-- ======= 1/ Session guard present in source ===============
-- ==========================================================
-- ==========================================================

helpers.describe("karabiner.init — wizard session guard", function()
	helpers.it("declares _wizard_ran_this_session module-level flag", function()
		local src = read_source("platform.remap.init")
		helpers.assert_true(
			src:find("_wizard_ran_this_session", 1, true) ~= nil,
			"platform.remap.init must declare `_wizard_ran_this_session` to prevent the " ..
			"first-run wizard from re-prompting on every hs.reload()"
		)
	end)

	helpers.it("wizard timer is conditional on `not _wizard_ran_this_session`", function()
		local src = read_source("platform.remap.init")
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
		local src = read_source("platform.remap.init")
		-- Find the position of the assignment and the timer; the assignment must
		-- come before the doAfter call in the same branch.
		local assign_pos = src:find("_wizard_ran_this_session = true", 1, true)
		local timer_pos  = src:find("run_first_run_wizard", 1, true)
		helpers.assert_true(
			assign_pos ~= nil,
			"_wizard_ran_this_session = true must appear in the source"
		)
		helpers.assert_true(
			timer_pos ~= nil,
			"run_first_run_wizard call must still exist in the source"
		)
		helpers.assert_true(
			assign_pos < timer_pos,
			"the guard flag must be set BEFORE the timer schedules run_first_run_wizard, " ..
			"so a second M.init() call during the 2-second window cannot enqueue a second dialog"
		)
	end)
end)
