--- tests/unit/adapters/system/test_application_notifier.lua

--- ==============================================================================
--- MODULE: Application Notification Captions
--- DESCRIPTION:
--- Records the actual native adapter boundary while preserving generic port
--- behavior. Shared application captions own branding before native decoration.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =======================================
-- =======================================
-- ======= 1/ Application Captions =======
-- =======================================
-- =======================================

helpers.describe("application notification captions", function()
	helpers.it("composes application labels without changing the generic port (application-caption-policy)", function()
		local Paths = require("infra.paths")
		local fixture = assert(loadfile(Paths.shared("tests/fixtures/application_notification_titles.lua")))()
		fixture.run(helpers.assert_eq, "linux", require("window_titles").compose, {
			default = "ErgoptiPlus", named = "ErgoptiPlus — Bare label", decorated = "ErgoptiPlus — ⚠ Bare label",
		})
	end)
end)





-- ============================================
-- ============================================
-- ======= 2/ Owned Application Notices =======
-- ============================================
-- ============================================

--- Exercises actual notice adapters and Manager over scoped recording ports.
--- The document fixture models GTK, timers and close acknowledgement only.
--- No native window, desktop command, notification delivery or click is observed.
--- @param body function Receives recording ports and actual notice owners.
local function with_owned_notice(body)
	local names = { "adapters.application_notifier", "adapters.notifier", "application_notifier",
		"window_titles", "adapters.shell_runner", "logger.shim", "infra.i18n", "infra.locale" }
	local saved, native = {}, nil
	for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
	local c = { commands = {}, quoted = {}, available = true, native_result = true }
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	package.loaded["window_titles"] = nil
	package.loaded["infra.i18n"] = {
		get_locale = function() return "en" end,
		get = function(key)
			if key == "error_dialog.heading" then return "Refusal heading" end
			if key == "error_dialog.intro" then return "Owned refusal body % ' 😀" end
			return "Ordinary app label"
		end,
	}
	package.loaded["infra.locale"] = { catalogue = function() return { ordinary = "Controlled locale" } end }
	package.loaded["adapters.shell_runner"] = {
		has_command = function(command)
			helpers.assert_eq(command, "notify-send")
			if c.on_probe then c.on_probe() end
			return c.available
		end,
		quote = function(value)
			c.quoted[#c.quoted + 1] = value
			if c.on_quote then c.on_quote(value) end
			return "Q[" .. value .. "]"
		end,
		run = function(command)
			c.commands[#c.commands + 1] = command
			return c.native_result
		end,
	}
	package.loaded["adapters.application_notifier"], package.loaded["adapters.notifier"] = nil, nil
	local ok, detail = xpcall(function()
		local generic = require("adapters.notifier")
		local application = require("adapters.application_notifier")
		local function manager()
			native = require("tests.support.document_fixture").new("changelog", {
				bridge_name = "changelog_bridge", on_message = function() end,
			}, {})
			-- Rejoin the actual dispatchers after the scoped document caller mock.
			package.loaded["adapters.notifier"], package.loaded["adapters.application_notifier"] = generic, application
			native.start_load()
			return native
		end
		body(c, application, generic, manager)
	end, debug.traceback)
	local closed, retired = true, true
	if native then closed, retired = pcall(native.close) end
	for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
	if not ok then error(detail, 0) end
	if not closed then error(retired, 0) end
	helpers.assert_eq(retired, true, "the controlled document fixture must retire before returning")
end

helpers.describe("owned application notifications", function()
	helpers.it("brands the actual Manager timeout notice once without changing its body", function()
		with_owned_notice(function(c, _, _, manager)
			local native = manager()
			native.now = 5100
			native.timers[1].expired()
			native.timers[1].expired()
			helpers.assert_eq(#c.commands, 1)
			helpers.assert_eq(c.commands[1], "notify-send --app-name=Q[Ergopti+] --urgency=normal --expire-time=5000 -- Q[ErgoptiPlus — ✖ Refusal heading] Q[Owned refusal body % ' 😀] >/dev/null 2>&1 &")
			helpers.assert_eq(#native.effects, 0)
		end)
	end)
	helpers.it("refuses the old Manager notice after capability-probe successor reentry", function()
		with_owned_notice(function(c, _, _, manager)
			local native = manager()
			c.on_probe = function() c.on_probe = nil; native.start_load() end
			native.now = 5100
			native.timers[1].expired()
			helpers.assert_eq(#c.commands, 0)
		end)
	end)
	helpers.it("refuses the old Manager notice after native-quote pause reentry", function()
		with_owned_notice(function(c, _, _, manager)
			local native = manager()
			c.on_quote = function() native.paused = true end
			native.now = 5100
			native.timers[1].expired()
			helpers.assert_eq(#c.commands, 0)
		end)
	end)
	helpers.it("preserves the exact callback, body, options and independent generic title", function()
		with_owned_notice(function(c, application, generic)
			local click, admitted = function() error("notify-send does not invoke onClick", 0) end, 0
			local opts = { title = "Bare label", level = "error", onClick = click }
			helpers.assert_eq(application.send_owned("Owned body", opts, function()
				admitted = admitted + 1
				helpers.assert_eq(#c.quoted, 3)
				helpers.assert_eq(#c.commands, 0)
				return true
			end), true)
			helpers.assert_eq(admitted, 1)
			helpers.assert_eq(c.quoted[2], "ErgoptiPlus — ✖ Bare label")
			helpers.assert_eq(c.quoted[3], "Owned body")
			helpers.assert_eq(opts.title, "Bare label")
			helpers.assert_eq(opts.level, "error")
			helpers.assert_eq(opts.onClick, click)
			helpers.assert_eq(generic.send_owned("External body", opts, function() return true end), true)
			helpers.assert_eq(c.quoted[5], "✖ Bare label")
			helpers.assert_eq(c.quoted[6], "External body")
		end)
	end)
	helpers.it("requires exact true from every current-owner admission callback", function()
		with_owned_notice(function(c, application)
			local opts = { title = "Bare label", level = "error" }
			helpers.assert_eq(application.send_owned("Owned body", opts, function() return false end), false)
			helpers.assert_eq(application.send_owned("Owned body", opts, function() error("controlled refusal", 0) end), false)
			helpers.assert_eq(application.send_owned("Owned body", opts, function() return 1 end), false)
			helpers.assert_eq(application.send_owned("Owned body", opts, nil), false)
			helpers.assert_eq(#c.commands, 0)
		end)
	end)
	helpers.it("keeps unavailable and refused native commands false", function()
		with_owned_notice(function(c, application)
			c.available = false
			helpers.assert_eq(application.send_owned("Owned body", {}, function() error("unavailable native must not admit", 0) end), false)
			helpers.assert_eq(#c.commands, 0)
		end)
		with_owned_notice(function(c, application)
			c.native_result = false
			helpers.assert_eq(application.send_owned("Owned body", {}, function() return true end), false)
			helpers.assert_eq(#c.commands, 1)
		end)
	end)
	helpers.it("restores the exact scoped dependency owners after a fixture-body refusal", function()
		local names = { "adapters.application_notifier", "adapters.notifier", "application_notifier",
			"window_titles", "adapters.shell_runner", "logger.shim", "infra.i18n", "infra.locale",
			"lgi", "infra.monotonic", "infra.timings", "infra.managed_http_deadline", "adapters.event_loop",
			"ui.webkit_host", "ui.webview_manager", "ui.changelog.bridge" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = { value = package.loaded[name] } end
		local marker = {}
		local ok, detail = pcall(with_owned_notice, function(_, _, _, manager) manager(); error(marker, 0) end)
		helpers.assert_eq(ok, false)
		-- xpcall preserves the thrown table; it is not turned into a fallback result.
		helpers.assert_eq(detail, marker)
		for _, name in ipairs(names) do helpers.assert_eq(package.loaded[name], previous[name].value) end
	end)
end)
