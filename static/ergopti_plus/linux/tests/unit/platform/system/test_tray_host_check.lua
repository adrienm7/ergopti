--- tests/unit/platform/system/test_tray_host_check.lua

--- ==============================================================================
--- MODULE: Tray host check — a desktop with no tray host is told (TRAY-03)
--- DESCRIPTION:
--- With no StatusNotifierWatcher host and no XEmbed tray (GNOME without its
--- AppIndicator extension), libayatana still creates its icon, nothing shows
--- it, and the daemon said nothing. The check now reads the session after the
--- icon appears and, when nothing shows it, tells the user in their language
--- what to install, through the status window, a notification and the console.
--- ==============================================================================

local helpers = require("tests.helpers")
local HostCheck = helpers.load_module("tray.engine.host_check")

--- The deps of one check, recording what the user was told.
--- @param facts table|nil What the probe reads, nil for a probe failure.
--- @return table deps, table told
local function deps_for(facts)
	local told = { printed = {}, notices = {}, windows = {}, errors = {}, infos = {} }
	local logger = helpers.make_logger_stub()
	logger.error = function(_, message, ...) told.errors[#told.errors + 1] = string.format(message, ...) end
	logger.info = function(_, message, ...) told.infos[#told.infos + 1] = string.format(message, ...) end
	return {
		probe = function()
			if facts == nil then return nil, "session bus unavailable: no address" end
			return facts
		end,
		i18n = { get = function(key) return "<" .. key .. ":{1}>" end },
		logger = logger,
		print = function(line) told.printed[#told.printed + 1] = line end,
		notifier = { send = function(body, opts) told.notices[#told.notices + 1] = { body = body, opts = opts } end },
		tray = {
			showStatusWindow = function(title, body)
				told.windows[#told.windows + 1] = { title = title, body = body }
				return true
			end,
		},
	}, told
end




-- =====================================
-- =====================================
-- ======= 1/ The decision =============
-- =====================================
-- =====================================

helpers.describe("tray host check: what counts as a host (tray-03)", function()

	helpers.it("a watcher with a registered host, or an XEmbed tray, shows the icon", function()
		helpers.assert_eq(HostCheck.has_host({ watcher = true, host = true, xembed = false }), true)
		helpers.assert_eq(HostCheck.has_host({ watcher = true, host = nil, xembed = false }), true,
			"a watcher that does not answer the property is taken at its word")
		helpers.assert_eq(HostCheck.has_host({ watcher = false, host = nil, xembed = true }), true,
			"an X11 panel with only an XEmbed tray draws libayatana's fallback icon")
	end)

	helpers.it("no watcher and no XEmbed tray, or a watcher with no host, shows nothing", function()
		helpers.assert_eq(HostCheck.has_host({ watcher = false, host = nil, xembed = false }), false,
			"GNOME without the AppIndicator extension")
		helpers.assert_eq(HostCheck.has_host({ watcher = true, host = false, xembed = false }), false,
			"a watcher alone, with no panel registered, shows no icon")
	end)

end)




-- =====================================
-- =====================================
-- ======= 2/ Telling the user =========
-- =====================================
-- =====================================

helpers.describe("tray host check: the user is told, in their language (tray-03)", function()

	helpers.it("a session with no host tells the user what to install, three ways", function()
		local deps, told = deps_for({ watcher = false, host = nil, xembed = false })
		helpers.assert_eq(HostCheck.check(deps), false)
		local body = "<" .. HostCheck.BODY_KEY .. ":gnome-shell-extension-appindicator>"
		helpers.assert_eq(#told.windows, 1, "the status window says it: a notification can be missed")
		helpers.assert_eq(told.windows[1].body, body, "the translated body names the extension package")
		helpers.assert_eq(#told.notices, 1)
		helpers.assert_eq(told.notices[1].body, body)
		helpers.assert_eq(told.notices[1].opts.level, "warning")
		helpers.assert_eq(told.printed[2], body)
		helpers.assert_eq(#told.errors, 1, "the log carries the facts")
		helpers.assert_contains(told.errors[1], "watcher false")
	end)

	helpers.it("a session with a host says nothing to the user", function()
		local deps, told = deps_for({ watcher = true, host = true, xembed = false })
		helpers.assert_eq(HostCheck.check(deps), true)
		helpers.assert_eq(#told.windows + #told.notices + #told.printed, 0)
		helpers.assert_eq(#told.infos, 1, "the host found is logged")
	end)

	helpers.it("a probe that cannot read the session is logged, never told as a missing tray", function()
		local deps, told = deps_for(nil)
		helpers.assert_eq(HostCheck.check(deps), nil)
		helpers.assert_eq(#told.windows + #told.notices + #told.printed, 0,
			"telling a user whose tray works that it is missing would be a false alarm")
		helpers.assert_eq(#told.errors, 1)
		helpers.assert_contains(told.errors[1], "session bus unavailable")
	end)

	helpers.it("the check waits for the panel, by the shared delay", function()
		local deps, told = deps_for({ watcher = false, host = nil, xembed = false })
		local scheduled = {}
		deps.timings = require("core.timing.engine.timings")
		deps.after = function(seconds, fn)
			scheduled[#scheduled + 1] = { seconds = seconds, fn = fn }
			return true
		end
		helpers.assert_eq(HostCheck.schedule(deps), true)
		helpers.assert_eq(#scheduled, 1)
		helpers.assert_eq(scheduled[1].seconds, deps.timings.ms("ui", "tray_host_check_delay_ms") / 1000)
		helpers.assert_eq(#told.windows, 0, "nothing is said before the panel had its time")
		scheduled[1].fn()
		helpers.assert_eq(#told.windows, 1)
	end)

	helpers.it("every locale words the title and the body with the package slot", function()
		local Json = require("core.text.engine.json")
		for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no",
			"pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
			local fh = assert(io.open(helpers.driver_root() .. "/../_shared/core/i18n/data/locales/" .. code .. ".json", "r"))
			local catalogue = Json.decode(fh:read("*a"))
			fh:close()
			helpers.assert_eq(type(catalogue[HostCheck.TITLE_KEY]), "string", code)
			helpers.assert_true(type(catalogue[HostCheck.BODY_KEY]) == "string"
				and catalogue[HostCheck.BODY_KEY]:find("{1}", 1, true) ~= nil, code .. " " .. HostCheck.BODY_KEY)
		end
	end)

	helpers.it("a --tray launch schedules the check once the icon is up", function()
		local source = helpers.read_module_source("ergopti_hotstrings")
		local start = source:find("if not tray_menu.start() then", 1, true)
		local check = source:find('require("tray.engine.host_check").schedule({', 1, true)
		helpers.assert_true(start ~= nil and check ~= nil and start < check,
			"the host check follows the icon's creation")
		helpers.assert_true(source:find('probe = require("tray.adapters.status_notifier_host").probe', check, true) ~= nil,
			"it reads the real session")
	end)

end)
