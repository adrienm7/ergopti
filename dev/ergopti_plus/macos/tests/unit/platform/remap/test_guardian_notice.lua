--- tests/unit/platform/remap/test_guardian_notice.lua

--- ==============================================================================
--- MODULE: Guardian Approval Notice Unit Tests
--- DESCRIPTION:
--- One notice per approval episode, a click that opens Login Items, a visible
--- failure when it cannot, and no episode marked as announced when the notice
--- was never delivered.
--- ==============================================================================

local helpers = require("tests.helpers")
local GuardianNotice = helpers.load_with_stubs("platform.remap.guardian_notice")

--- Builds a notice over recording doubles.
--- @param opts table|nil { deliver = boolean, open_ok = boolean }
--- @return table notice, table rec
local function make(opts)
	opts = opts or {}
	local rec = { sent = {}, opened = 0, errors = 0 }
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
		logger = {
			error = function() rec.errors = rec.errors + 1 end,
			warn = function() end,
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

	helpers.it("rejects an incomplete dependency set", function()
		local ok = pcall(GuardianNotice.new, { notify = function() end })
		helpers.assert_true(not ok, "a notice without its dependencies must fail fast")
	end)
end)
