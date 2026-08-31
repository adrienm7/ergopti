--- tests/unit/adapters/test_update_launcher.lua

--- ==============================================================================
--- MODULE: Regression — the Lua update command crosses into the native launcher
--- DESCRIPTION:
--- The embedded Hammerspoon process does not own the outer ErgoptiPlus bundle.
--- Its update action must therefore send one exact command to the already-running
--- launcher, where Sparkle owns verification, installation, progress, and relaunch.
--- ==============================================================================

local helpers = require("tests.helpers")

local COMMAND_URL = "ergoptiplus://updater/check"

local function load_subject(open_url, alert)
	local errors = {}
	local dialogs = {}
	local notifications = {}
	package.loaded["infra.logger"] = {
		start = function() end,
		success = function() end,
		error = function(_tag, message) errors[#errors + 1] = message end,
	}
	package.loaded["infra.dialog_util"] = {
		block_alert = alert or function(...) dialogs[#dialogs + 1] = { ... } end,
	}
	package.loaded["adapters.notifier"] = {
		send = function(...) notifications[#notifications + 1] = { ... } end,
	}
	local subject = helpers.load_with_stubs("adapters.update_launcher", {
		urlevent = { openURL = open_url },
	})
	return subject, errors, dialogs, notifications
end

helpers.describe("update_launcher: exact native updater command", function()
	helpers.it("sends exactly one command and reports success only for true", function()
		local seen = {}
		local subject, errors, dialogs = load_subject(function(url)
			seen[#seen + 1] = url
			return true
		end)

		helpers.assert_eq(subject.request_check(), true)
		helpers.assert_eq(#seen, 1)
		helpers.assert_eq(seen[1], COMMAND_URL)
		helpers.assert_eq(#errors, 0)
		helpers.assert_eq(#dialogs, 0)
	end)

	helpers.it("fails visibly when Hammerspoon refuses the URL", function()
		local subject, errors, dialogs = load_subject(function() return false end)

		helpers.assert_eq(subject.request_check(), false)
		helpers.assert_eq(#errors, 1)
		helpers.assert_eq(#dialogs, 1)
	end)

	helpers.it("contains a synchronous URL-handler exception and fails visibly", function()
		local subject, errors, dialogs = load_subject(function() error("launch failed") end)

		local ok, result = pcall(subject.request_check)
		helpers.assert_true(ok, "the adapter must contain native boundary exceptions")
		helpers.assert_eq(result, false)
		helpers.assert_eq(#errors, 1)
		helpers.assert_eq(#dialogs, 1)
	end)

	helpers.it("falls back to a notification when the modal boundary throws", function()
		local subject, _, _, notifications = load_subject(
			function() return false end,
			function() error("dialog unavailable") end
		)

		helpers.assert_eq(subject.request_check(), false)
		helpers.assert_eq(#notifications, 1)
	end)
end)
