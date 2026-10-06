--- tests/unit/adapters/test_update_launcher.lua

--- ==============================================================================
--- MODULE: Regression — the Lua update command crosses into the native launcher
--- DESCRIPTION:
--- The embedded Hammerspoon process does not own the outer ErgoptiPlus bundle.
--- Its update action must therefore send one exact command to the already-running
--- launcher, where Sparkle owns verification, installation, progress, and relaunch.
--- The command names the subscribed channel so Sparkle reads that channel's feed;
--- anything that is not a channel id never reaches Launch Services.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_subject(open_url, alert)
	local errors = {}
	local dialogs = {}
	local notifications = {}
	package.loaded["infra.logger"] = {
		start = function() end,
		success = function() end,
		info = function() end,
		error = function(_tag, message) errors[#errors + 1] = message end,
	}
	package.loaded["infra.dialog_util"] = {
		block_alert = alert or function(...) dialogs[#dialogs + 1] = { ... } end,
	}
	package.loaded["adapters.application_notifier"] = {
		send = function(...) notifications[#notifications + 1] = { ... } end,
	}
	local subject = helpers.load_with_stubs("adapters.update_launcher", {
		urlevent = { openURL = open_url },
	})
	return subject, errors, dialogs, notifications
end

helpers.describe("update_launcher: exact native updater command", function()
	helpers.it("sends exactly one channel check and reports success only for true", function()
		local seen = {}
		local subject, errors, dialogs = load_subject(function(url)
			seen[#seen + 1] = url
			return true
		end)

		helpers.assert_eq(subject.request_check("dev"), true)
		helpers.assert_eq(seen, { "ergoptiplus://updater/check/dev" },
			"the check must name the subscribed channel so Sparkle reads its feed")
		helpers.assert_eq(#errors, 0)
		helpers.assert_eq(#dialogs, 0)
	end)

	helpers.it("tells the launcher the channel of Sparkle's scheduled checks", function()
		local seen = {}
		local subject, errors, dialogs = load_subject(function(url)
			seen[#seen + 1] = url
			return true
		end)

		helpers.assert_eq(subject.select_channel("main"), true)
		helpers.assert_eq(seen, { "ergoptiplus://updater/channel/main" })
		helpers.assert_eq(#errors, 0)
		helpers.assert_eq(#dialogs, 0, "selecting a channel never opens a dialog")
	end)

	helpers.it("never sends a value that is not a channel id", function()
		local seen = {}
		local subject, errors, dialogs = load_subject(function(url)
			seen[#seen + 1] = url
			return true
		end)

		for _, value in ipairs({ "Dev", "dev/../check", "dev?x=1", "", false }) do
			helpers.assert_eq(subject.select_channel(value), false, tostring(value))
		end
		helpers.assert_eq(subject.request_check("dev check"), false)
		helpers.assert_eq(#seen, 0, "nothing may reach Launch Services")
		helpers.assert_eq(#dialogs, 1, "a refused check stays visible")
		helpers.assert_true(#errors >= 6)
	end)

	helpers.it("fails visibly when Hammerspoon refuses the URL", function()
		local subject, errors, dialogs = load_subject(function() return false end)

		helpers.assert_eq(subject.request_check("main"), false)
		helpers.assert_eq(#errors, 1)
		helpers.assert_eq(#dialogs, 1)
	end)

	helpers.it("contains a synchronous URL-handler exception and fails visibly", function()
		local subject, errors, dialogs = load_subject(function() error("launch failed") end)

		local ok, result = pcall(subject.request_check, "main")
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

		helpers.assert_eq(subject.request_check("main"), false)
		helpers.assert_eq(#notifications, 1)
	end)
end)

-- A refused check command used to tell the user that "the update installation
-- failed": nothing had been downloaded or installed, only the request to look
-- for an update never reached the launcher. Every surface of that failure must
-- name the check. The unit environment has no catalogue, so the stub echoes
-- the requested key; translation parity is the JS catalogue gates' job.
local CHECK_FAILED_KEY = "updater.check_request_failed"

--- Runs one refused check under an i18n double that echoes each key.
--- @param open_url function URL opener double.
--- @param alert function|nil Modal alert double.
--- @return table dialogs, table notifications
local function refuse_with_echoed_keys(open_url, alert)
	return helpers.with_fresh_modules({ "infra.i18n", "adapters.update_launcher" }, function()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		local subject, _, dialogs, notifications = load_subject(open_url, alert)
		helpers.assert_eq(subject.request_check(), false)
		return dialogs, notifications
	end)
end

helpers.describe("update_launcher: a refused check names the check", function()
	helpers.it("shows the check-failure text in the modal alert", function()
		local dialogs = refuse_with_echoed_keys(function() return false end)

		helpers.assert_eq(#dialogs, 1)
		helpers.assert_eq(dialogs[1][2], CHECK_FAILED_KEY)
	end)

	helpers.it("shows the check-failure text in the fallback notification", function()
		local _, notifications = refuse_with_echoed_keys(
			function() error("launch failed") end,
			function() error("dialog unavailable") end
		)

		helpers.assert_eq(#notifications, 1)
		helpers.assert_eq(notifications[1][2].body, CHECK_FAILED_KEY)
	end)
end)
