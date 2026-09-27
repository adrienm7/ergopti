--- tests/unit/ui/test_onboarding_startup.lua

--- ==============================================================================
--- MODULE: First-use Startup Tests
--- DESCRIPTION:
--- Verifies that graphical startup offers setup without confusing a displayed
--- window with completed consent, and preserves the completion marker.
--- ==============================================================================

local helpers = require("tests.helpers")
local Startup = require("ui.onboarding.startup")

local function fixture(raw)
	local record = { shown = 0, failed = 0, opened = 0 }
	return {
		graphical = true, path = "/fixture/config.toml",
		open = function()
			record.opened = record.opened + 1
			if raw == nil then return nil, "missing", 2 end
			return { read = function() return raw end, close = function() end }
		end,
		show = function(app)
			helpers.assert_eq(app, "onboarding")
			record.shown = record.shown + 1
			return true
		end,
		fail = function() record.failed = record.failed + 1 end,
	}, record
end

helpers.describe("first-use startup", function()
	helpers.it("offers missing, incomplete and completed configuration correctly (linux-first-use)", function()
		for _, case in ipairs({ {}, { "[script]\nonboarding_done = false" },
			{ "[script]\nonboarding_done = true", completed = true } }) do
			local opts, record = fixture(case[1])
			helpers.assert_true(Startup.run(opts))
			helpers.assert_eq(record.shown, case.completed and 0 or 1)
			helpers.assert_eq(record.failed, 0)
		end
	end)
	helpers.it("does not inspect configuration in headless or dry-run startup (linux-first-use)", function()
		local opts, record = fixture()
		opts.graphical = false
		helpers.assert_true(Startup.run(opts))
		helpers.assert_eq(record.opened, 0)
	end)
	helpers.it("reports unreadable configuration and unavailable windows (linux-first-use)", function()
		local opts, record = fixture()
		opts.open = function() return nil, "permission denied", 13 end
		helpers.assert_eq(Startup.run(opts), false)
		helpers.assert_eq(record.shown, 0)
		helpers.assert_eq(record.failed, 1)
		opts, record = fixture()
		opts.show = function() return false end
		helpers.assert_eq(Startup.run(opts), false)
		helpers.assert_eq(record.failed, 1)
	end)
	helpers.it("keeps completion owned by the wizard transaction (linux-first-use)", function()
		local marked = {}
		helpers.assert_eq(Startup.should_show({ script = { onboarding_done = true } }, function(...)
			marked = { ... }
		end), false)
		helpers.assert_eq(marked, { "script", "onboarding_done" })
		local opts, record = fixture()
		helpers.assert_true(Startup.run(opts))
		helpers.assert_true(Startup.run(opts))
		helpers.assert_eq(record.shown, 2, "opening cannot manufacture a completion marker")
	end)
end)
