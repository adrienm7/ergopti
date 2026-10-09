--- tests/unit/platform/remap/test_guardian_notice.lua

--- ==============================================================================
--- MODULE: Guardian Approval Notice Unit Tests
--- DESCRIPTION:
--- One notice per approval episode, a click that opens Login Items, a visible
--- failure when it cannot, and no episode marked as announced when the notice
--- was never delivered. An `unavailable` guardian (helper not registered, e.g.
--- after an app update) used to leave the rules inert with no message at all
--- (guardian-unavailable-never-silent).
--- ==============================================================================

local helpers = require("tests.helpers")
local GuardianNotice = helpers.load_with_stubs("platform.remap.guardian_notice")

--- Builds a notice over recording doubles.
--- @param opts table|nil { deliver = boolean, open_ok = boolean, present = boolean }
--- @return table notice, table rec
local function make(opts)
	opts = opts or {}
	local rec = { sent = {}, opened = 0, login_items = 0, errors = 0, error_lines = {}, presented = 0,
		warn_lines = {} }
	local notice = GuardianNotice.new({
		notify = function(message, detail, kind, on_click)
			rec.sent[#rec.sent + 1] = { message = message, detail = detail, kind = kind, on_click = on_click }
			if opts.deliver == false then return false, "refused" end
			return true
		end,
		text = function(key) return key end,
		open_settings = function(on_done)
			rec.opened = rec.opened + 1
			on_done(opts.open_ok ~= false, opts.open_ok == false and "refused" or "opened")
			return true
		end,
		open_login_items = function(on_done)
			rec.login_items = rec.login_items + 1
			on_done(opts.open_ok ~= false, opts.open_ok == false and "open-exited-non-zero" or "opened")
			return true
		end,
		-- The presenter declines unless a case says the steps took the episode.
		present_approval = function()
			rec.presented = rec.presented + 1
			return opts.present == true
		end,
		logger = {
			error = function(_, message, ...)
				rec.errors = rec.errors + 1
				rec.error_lines[#rec.error_lines + 1] = string.format(message, ...)
			end,
			warn = function(_, message, ...)
				rec.warn_lines[#rec.warn_lines + 1] = string.format(message, ...)
			end,
			info = function() end,
		},
		log = "test",
	})
	return notice, rec
end

helpers.describe("guardian approval notice", function()
	helpers.it("notifies once per approval episode", function()
		local notice, rec = make()
		helpers.assert_true(notice.observe("requires_approval"))
		helpers.assert_true(not notice.observe("requires_approval"), "a repeated poll is the same episode")
		helpers.assert_true(not notice.observe(nil), "an unknown probe result does not close the episode")
		helpers.assert_true(not notice.observe("requires_approval"))
		helpers.assert_eq(#rec.sent, 1)
		helpers.assert_eq(rec.sent[1].message, "karabiner.guardian_approval_required")
		helpers.assert_eq(rec.sent[1].kind, "warning")

		helpers.assert_true(not notice.observe("ready"))
		helpers.assert_true(notice.observe("requires_approval"), "a new episode after approval notifies again")
		helpers.assert_eq(#rec.sent, 2)
	end)

	helpers.it("opens Login Items when the notice is clicked", function()
		local notice, rec = make()
		notice.observe("requires_approval")
		helpers.assert_type(rec.sent[1].on_click, "function")
		rec.sent[1].on_click()
		helpers.assert_eq(rec.opened, 1)
		helpers.assert_eq(#rec.sent, 1, "a successful open raises no second notice")
	end)

	helpers.it("says so when Login Items cannot be opened", function()
		local notice, rec = make({ open_ok = false })
		notice.observe("requires_approval")
		rec.sent[1].on_click()
		helpers.assert_eq(#rec.sent, 2)
		helpers.assert_eq(rec.sent[2].message, "karabiner.guardian_settings_open_failed")
		helpers.assert_eq(rec.sent[2].kind, "error")
		helpers.assert_true(rec.errors >= 1)
	end)

	helpers.it("retries a notice that was never delivered", function()
		local notice, rec = make({ deliver = false })
		helpers.assert_true(not notice.observe("requires_approval"))
		helpers.assert_true(not notice.observe("requires_approval"))
		helpers.assert_eq(#rec.sent, 2, "an undelivered notice must not count as announced")
		helpers.assert_true(rec.errors >= 2)
	end)

	helpers.it("never stays silent when the helper is unavailable (guardian-unavailable-never-silent)", function()
		local notice, rec = make()
		helpers.assert_true(notice.observe("unavailable"), "entry into unavailable must notify")
		helpers.assert_eq(#rec.sent, 1)
		helpers.assert_eq(rec.sent[1].message, "karabiner.guardian_unavailable")
		helpers.assert_eq(rec.sent[1].kind, "error")
		helpers.assert_eq(#rec.error_lines, 1, "the exact status must be logged as an ERROR")
		helpers.assert_contains(rec.error_lines[1], "'unavailable'")

		helpers.assert_true(not notice.observe("unavailable"), "a repeated poll is the same episode")
		helpers.assert_true(not notice.observe(nil), "an unknown probe result does not close the episode")
		helpers.assert_eq(#rec.sent, 1)
		helpers.assert_eq(#rec.error_lines, 1, "the ERROR is written once per episode")

		helpers.assert_true(not notice.observe("ready"))
		helpers.assert_true(notice.observe("unavailable"), "a new episode after recovery notifies again")
		helpers.assert_eq(#rec.sent, 2)
	end)

	helpers.it("opens Login Items directly when the unavailable notice is clicked", function()
		local notice, rec = make()
		notice.observe("unavailable")
		helpers.assert_type(rec.sent[1].on_click, "function")
		rec.sent[1].on_click()
		helpers.assert_eq(rec.login_items, 1)
		helpers.assert_eq(rec.opened, 0, "the approval-gated opener refuses an unavailable guardian")
		local failing, failed = make({ open_ok = false })
		failing.observe("unavailable")
		failed.sent[1].on_click()
		helpers.assert_eq(failed.sent[2].message, "karabiner.guardian_settings_open_failed")
	end)

	helpers.it("announces a switch between blocking states", function()
		local notice, rec = make()
		helpers.assert_true(notice.observe("requires_approval"))
		helpers.assert_true(notice.observe("unavailable"), "a different blocking cause is a new episode")
		helpers.assert_true(notice.observe("requires_approval"))
		helpers.assert_eq(#rec.sent, 3)
	end)

	helpers.it("retries an undelivered unavailable notice without repeating the ERROR status line", function()
		local notice, rec = make({ deliver = false })
		helpers.assert_true(not notice.observe("unavailable"))
		helpers.assert_true(not notice.observe("unavailable"))
		helpers.assert_eq(#rec.sent, 2, "an undelivered notice must not count as announced")
		local status_lines = 0
		for _, line in ipairs(rec.error_lines) do
			if line:find("status is 'unavailable'", 1, true) then status_lines = status_lines + 1 end
		end
		helpers.assert_eq(status_lines, 1)
	end)

	-- The approval used to reach the user only as a banner, which a fresh
	-- install may never display; the numbered steps now take the episode.
	helpers.it("lets the Login Items steps take the approval episode (guardian-approval-steps)", function()
		local notice, rec = make({ present = true })
		helpers.assert_true(notice.observe("requires_approval"), "the steps announce the episode")
		helpers.assert_eq(rec.presented, 1)
		helpers.assert_eq(#rec.sent, 0, "a banner on top of the steps would announce the episode twice")
		helpers.assert_true(not notice.observe("requires_approval"), "a repeated poll is the same episode")
		helpers.assert_eq(rec.presented, 1, "the steps are offered once per episode, not per poll")
		helpers.assert_eq(rec.errors, 0, "an approval not given yet is not an error")
		helpers.assert_eq(#rec.warn_lines, 1)
		helpers.assert_contains(rec.warn_lines[1], "awaits Login Items approval")
	end)

	helpers.it("keeps the banner when the steps decline and never offers them for unavailable", function()
		local declined, rec = make()
		helpers.assert_true(declined.observe("requires_approval"))
		helpers.assert_eq(rec.presented, 1, "the steps are asked first")
		helpers.assert_eq(#rec.sent, 1, "a declined offer (already shown this launch) falls back to the banner")
		helpers.assert_eq(rec.sent[1].message, "karabiner.guardian_approval_required")

		local unavailable, other = make({ present = true })
		helpers.assert_true(unavailable.observe("unavailable"))
		helpers.assert_eq(other.presented, 0, "the approval steps cannot register a missing helper")
		helpers.assert_eq(other.sent[1].message, "karabiner.guardian_unavailable")
	end)

	helpers.it("rejects an incomplete dependency set", function()
		local ok = pcall(GuardianNotice.new, { notify = function() end })
		helpers.assert_true(not ok, "a notice without its dependencies must fail fast")
	end)
end)
