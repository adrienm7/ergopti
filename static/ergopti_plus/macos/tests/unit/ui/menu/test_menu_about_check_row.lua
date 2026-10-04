--- tests/unit/ui/menu/test_menu_about_check_row.lua

--- ==============================================================================
--- MODULE: The About Check Row Opens The Update-Check Window (macOS)
--- DESCRIPTION:
--- "Check for updates" used to hand the check to Sparkle, whose English,
--- left-aligned alert named no channel. The row now opens the shared
--- update-check window over the menu session's automatic-check and channel
--- owners; a row that already names a found release is the user's consent and
--- still goes straight to Sparkle. Built through the real builder and renderer.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the About submenu of a packaged build and returns its check row with
--- the recorded window opens and Sparkle requests.
local function build(latest)
	local recorded = { opens = {}, requests = {} }
	local saved = {
		window = package.loaded["ui.update_check"],
		launcher = package.loaded["adapters.update_launcher"],
	}
	package.loaded["ui.update_check"] = {
		open = function(opts) recorded.opens[#recorded.opens + 1] = opts; return true end,
	}
	package.loaded["adapters.update_launcher"] = {
		request_check = function(channel) recorded.requests[#recorded.requests + 1] = channel; return true end,
		select_channel = function() return true end,
	}
	local Updater = require("modules.updater")
	local real_local = Updater.is_local_source
	Updater.is_local_source = function() return false end
	package.loaded["ui.menu.menu_about"] = nil
	local owner = { get = function() return "dev" end, set = function() return true end, subscribe = function() end }
	local checks = {
		presets = function() return {} end,
		interval_code = function() return "1d" end,
		interval = function() return 86400 end,
		set_interval = function() return true end,
		latest = function() return latest end,
	}
	local refresh = function() end
	local ok, rows = pcall(function()
		local About = helpers.load_with_stubs("ui.menu.menu_about")
		return About.build({ channel_owner = owner, update_checks = checks, updateMenu = refresh }, {
			start_at_login = function() error("Building About must not change startup.") end,
			uninstall = function() error("Building About must not uninstall the application.") end,
		}).submenu
	end)
	Updater.is_local_source = real_local
	package.loaded["ui.menu.menu_about"] = nil
	local function restore()
		package.loaded["ui.update_check"] = saved.window
		package.loaded["adapters.update_launcher"] = saved.launcher
	end
	if not ok then restore(); error(rows, 0) end
	recorded.owner, recorded.checks, recorded.refresh, recorded.restore = owner, checks, refresh, restore
	local i18n = require("infra.i18n")
	for _, row in ipairs(rows) do
		if row.title == i18n.get("menu.about.check_for_updates")
			or (latest and type(row.title) == "string" and row.title:find(latest.tag, 1, true)) then
			recorded.row = row
		end
	end
	return recorded
end

helpers.describe("menu_about: the check row (macOS)", function()
	helpers.it("opens the update-check window over the menu session's owners", function()
		local recorded = build(nil)
		local ok, err = pcall(function()
			helpers.assert_not_nil(recorded.row, "the About submenu offers the check row")
			recorded.row.fn()
			helpers.assert_eq(#recorded.opens, 1, "the click opens the update-check window")
			helpers.assert_eq(#recorded.requests, 0, "Sparkle is not asked to check")
			helpers.assert_true(recorded.opens[1].checks == recorded.checks, "the window checks through the Lua owner")
			helpers.assert_true(recorded.opens[1].channel_owner == recorded.owner, "switches go through the channel owner")
			helpers.assert_true(recorded.opens[1].on_change == recorded.refresh, "the menu refreshes after an answer")
		end)
		recorded.restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("a row that names a found release installs it through Sparkle", function()
		local recorded = build({ tag = "v0.0.0-dev.150", channel = "dev" })
		local ok, err = pcall(function()
			helpers.assert_not_nil(recorded.row, "the row names the found release")
			recorded.row.fn()
			helpers.assert_eq(recorded.requests, { "dev" }, "Sparkle installs from the release's channel")
			helpers.assert_eq(#recorded.opens, 0, "no second check before the consented install")
		end)
		recorded.restore()
		if not ok then error(err, 0) end
	end)
end)


--- Exercises the actual source-only provider through its native-bound renderer.
--- @param alternative boolean True to independently replace the declared label and reason.
local function with_source_row(alternative, callback)
	helpers.with_stub_scope({ "ui.menu.menu_about", "infra.manifest_menu", "infra.paths", "infra.i18n",
		"infra.logger", "adapters.json_codec", "modules.updater", "modules.updater.auto_check",
		"ui.changelog", "adapters.update_launcher", "ui.menu.start_at_login", "hs", "tests.stubs.hs" }, function()
		local native = require("tests.stubs.hs")
		native.__reset()
		_G.hs = native
		package.loaded["hs"] = native
		local seen = { effects = 0 }
		local function effect() seen.effects = seen.effects + 1; return false end
		local labels = { ["menu.about.source_run_reason"] = "Source checkout: use an installed release.",
			["common.restore_recommended"] = "Canonical alternate label",
			["common.clear_to_system"] = "Canonical alternate reason: inert control." }
		package.loaded["infra.i18n"] = { get = function(key) return labels[key] or key end,
			section = function(key) return labels[key] or key end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = { shared = helpers.shared }
		package.loaded["modules.updater"] = {
			is_local_source = function() return true end,
			installed_channel = function() return "dev" end,
			build_identity = function() return { kind = "local", version = "", commit = "known" } end,
			releases_page_url = function() return "https://example.invalid/releases" end,
		}
		local defaults_file = assert(io.open(helpers.shared("modules/updater/defaults.json"), "rb"))
		local defaults = assert(require("adapters.json_codec").decode(assert(defaults_file:read("*a"))))
		assert(defaults_file:close())
		package.loaded["modules.updater.auto_check"] = { stored_interval = function()
			return defaults.timing.default_check_interval_sec
		end }
		package.loaded["ui.changelog"] = { open = effect }
		package.loaded["adapters.update_launcher"] = { request_check = effect, select_channel = effect }
		package.loaded["ui.menu.start_at_login"] = { enabled = function() return false end }
		local renderer = require("infra.manifest_menu")
		local declaration = renderer.get_array("about_source_menu")
		helpers.assert_eq(#declaration, 1)
		if alternative then
			declaration[1].i18n = "common.restore_recommended"
			declaration[1].disabled_reason_key = "common.clear_to_system"
		end
		local title = alternative and labels["common.restore_recommended"] or "menu.about.check_for_updates"
		local reason = alternative and "Canonical alternate reason" or "Source checkout"
		local owner = { get = function() return "dev" end, set = effect }
		local About = require("ui.menu.menu_about")
		local rows = About.build({ channel_owner = owner, state = {} }, {
			start_at_login = effect, uninstall = effect,
		}).submenu
		local found
		for _, row in ipairs(rows) do if row.title == title .. " — " .. reason then found = row end end
		callback(found, seen)
	end)
end

helpers.describe("About source check shared command", function()
	helpers.it("keeps the original disabled reason and exposes no native update or window action (about-source-command)", function()
		with_source_row(false, function(row, seen)
			helpers.assert_type(row, "table")
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
			helpers.assert_nil(row.checked)
			helpers.assert_eq(seen.effects, 0)
		end)
	end)

	helpers.it("uses the actual declared label and reason instead of source-only native literals (about-source-command)", function()
		with_source_row(true, function(row, seen)
			helpers.assert_type(row, "table")
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
			helpers.assert_nil(row.checked)
			helpers.assert_eq(seen.effects, 0)
		end)
	end)
end)
