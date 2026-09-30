--- tests/unit/platform/remap/guardian_recovery/test_approval_steps.lua

--- ==============================================================================
--- MODULE: The Guardian's First Approval Answer Opens The Login Items Steps
--- DESCRIPTION:
--- Tap-holds stayed off until the remap guardian was allowed in the background,
--- and the user could not guess where. Drives the real remap bridge through the
--- guardian recovery fixture with the real Login Items guide registered as the
--- boot does: the first requires_approval answer shows the steps once, instead
--- of the banner; approving them closes the steps and the retained regeneration
--- deploys through the bridge's own readiness wait. With the switch off or the
--- guardian ready, nothing is shown.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local count_logs = fixture.count_logs
local with_remap = fixture.with_remap

local GUIDE_MODULES = { "ui.permission_dialog", "ui.permission_dialog.login_items_guide" }

--- Registers the real guide over a recording dialog, as the boot does, and
--- gives the fixture's scheduler the recurring timer the guide polls with.
--- @param remap table Real platform.remap module.
--- @return table dialog Recording dialog double { shows, open }.
--- @return table polls Guide poll handles.
local function register_guide(remap)
	local dialog = { shows = {}, open = nil }
	package.loaded["ui.permission_dialog"] = {
		show = function(spec)
			dialog.shows[#dialog.shows + 1] = spec
			dialog.open = spec
			return true
		end,
		close = function(kind)
			local open = dialog.open
			if open == nil or open.kind ~= kind then return true end
			dialog.open = nil
			if open.on_closed then open.on_closed() end
			return true
		end,
		is_open = function(kind) return dialog.open ~= nil and dialog.open.kind == kind end,
	}
	local polls = {}
	-- The fixture's cancel settles any handle that still holds a native timer.
	package.loaded["adapters.timer_scheduler"].every = function(seconds, fn)
		local handle = { seconds = seconds, fn = fn, timer = {} }
		polls[#polls + 1] = handle
		return handle, true
	end
	local guide = require("ui.permission_dialog.login_items_guide")
	helpers.assert_true(remap.set_approval_presenter(function() return guide.offer(remap) end) == true)
	return dialog, polls
end

helpers.describe("the guardian's approval opens the Login Items steps (guardian-approval-steps)", function()
	helpers.it("shows the steps once, then closes them and deploys once the guardian is ready", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "not_requested",
			guardian_registration_due = true,
			guardian_probe_deferred = true,
		}, function(remap, calls)
			helpers.with_fresh_modules(GUIDE_MODULES, function()
				local dialog, polls = register_guide(remap)
				-- The boot's deploy registers the guardian by itself (SMAppService,
				-- or the legacy LaunchAgent), and macOS then holds it for approval.
				helpers.assert_true(remap.regenerate(function() end))
				helpers.assert_eq(calls.guardian_registrations, 1, "registration is automatic")
				helpers.assert_eq(calls.guardian_probes[1].kind, "register")
				calls.deliver_guardian_probe("requires_approval", nil, 1)
				helpers.assert_eq(#dialog.shows, 1, "the first approval answer must show the steps")
				helpers.assert_eq(dialog.shows[1].kind, "login_items")
				helpers.assert_eq(#calls.notices, 0, "the steps replace the banner for this episode")
				helpers.assert_eq(calls.builds, 0, "nothing deploys before the guardian is ready")

				calls.recovery_timers[#calls.recovery_timers]:fire()
				calls.deliver_guardian_probe("requires_approval", nil, 2)
				polls[1].fn()
				helpers.assert_eq(#dialog.shows, 1, "each readiness poll must not show the steps again")
				helpers.assert_true(dialog.open ~= nil, "the steps stay while approval is missing")

				calls.recovery_timers[#calls.recovery_timers]:fire()
				calls.deliver_guardian_probe("ready", nil, 3)
				helpers.assert_eq(calls.builds, 1, "the retained regeneration deploys through the readiness wait")
				helpers.assert_eq(calls.starts_paused, 1, "readiness provisions the lease")
				polls[1].fn()
				helpers.assert_nil(dialog.open, "approval closes the steps by itself")
				helpers.assert_nil(polls[1].timer, "the guide's poll is cancelled")
				helpers.assert_eq(count_logs(calls, "error"), 0, "an approval not given yet is never an error")
			end)
		end)
	end)

	helpers.it("shows nothing while « Ergopti uses Karabiner » is off", function()
		with_remap({
			enabled = false,
			initial_phase = "idle",
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			helpers.with_fresh_modules(GUIDE_MODULES, function()
				local dialog, polls = register_guide(remap)
				remap.regenerate(function() end)
				helpers.assert_eq(calls.guardian_probe_count, 0, "no guardian is observed with the switch off")
				local guide = require("ui.permission_dialog.login_items_guide")
				helpers.assert_true(guide.offer(remap) == false, "a switch that is off needs no approval")
				helpers.assert_eq(#dialog.shows, 0)
				helpers.assert_eq(#polls, 0)
			end)
		end)
	end)

	helpers.it("shows nothing when the guardian is already approved", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "ready",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			helpers.with_fresh_modules(GUIDE_MODULES, function()
				local dialog, polls = register_guide(remap)
				helpers.assert_true(remap.regenerate(function() end))
				calls.deliver_guardian_probe("ready", nil, 1)
				helpers.assert_eq(calls.builds, 1)
				helpers.assert_eq(#dialog.shows, 0, "an approved guardian needs nothing from the user")
				helpers.assert_eq(#polls, 0)
			end)
		end)
	end)

	helpers.it("accepts one presenter only", function()
		with_remap({ initial_phase = "idle" }, function(remap)
			helpers.assert_true(remap.set_approval_presenter(function() return false end) == true)
			helpers.assert_true(remap.set_approval_presenter(function() return true end) == false,
				"a second registration must not replace the boot's presenter")
			helpers.assert_true(not pcall(remap.set_approval_presenter, "steps"), "a non-function fails fast")
		end)
	end)
end)
