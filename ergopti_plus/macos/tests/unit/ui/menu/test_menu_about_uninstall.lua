--- tests/unit/ui/menu/test_menu_about_uninstall.lua

--- ==============================================================================
--- MODULE: Uninstall Closes The Version / Updates Submenu (macOS)
--- DESCRIPTION:
--- « Désinstaller Ergopti » sat at the bottom of Configuration, between the
--- rows that tune the configuration, where removing the application read as
--- one more setting. It now closes the Version / Updates submenu, set apart by
--- a separator, next to the build it removes; it keeps its label key and runs
--- the same action (the menu session's uninstall transaction), and stays live
--- while the script is paused. Startup sits immediately above it; Configuration
--- keeps its configuration windows, with no dangling separator.
---
--- On a local version run from source there is nothing to remove: the row
--- stays in place, greyed like every row greyed with a reason, « Désinstaller
--- Ergopti… — Version locale (depuis les sources) » (the head of the
--- manifest's disabled_reason_key), with nothing to run, and is live again on
--- the installed app.
---
--- Driven through Builder.generate with the real About module, so the
--- assertion is on what the menu offers and on the action it is handed.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Actions that record which one ran.
--- @param fired table Receives the name of every action invoked.
--- @return table actions
local function recording_actions(fired)
	return setmetatable({}, { __index = function(_, name)
		return function() fired[#fired + 1] = name end
	end })
end

--- Builds the tray with the real About module and returns a submenu by title key.
--- @param paused boolean ctx.paused for this build.
--- @param fired table Action recorder.
--- @param title_key string Locale key of the submenu's row.
--- @param source_run boolean|nil What Updater.is_local_source answers (false by default).
--- @return table|nil rows
local function submenu(paused, fired, title_key, source_run, startup_enabled)
	local builder = helpers.load_with_stubs("ui.menu.builder")
	-- The About module reads the one installed-build owner; it is reloaded so it
	-- binds the answer this case sets.
	local Updater = require("modules.updater")
	local real_is_local_source = Updater.is_local_source
	Updater.is_local_source = function() return source_run == true end
	package.loaded["ui.menu.menu_about"] = nil
	local About = require("ui.menu.menu_about")
	local previous_startup = package.loaded["ui.menu.start_at_login"]
	package.loaded["ui.menu.start_at_login"] = { enabled = function() return startup_enabled == true end }
	local i18n = require("infra.i18n")
	i18n.get = function(key) return key end
	i18n.build_language_menu_items = function() return {} end
	local owner = { get = function() return "dev" end, set = function() return true end, subscribe = function() end }
	local ok, menu = pcall(builder.generate, { config = { log_level = 2 }, paused = paused, channel_owner = owner },
		{ about = About }, recording_actions(fired))
	Updater.is_local_source = real_is_local_source
	package.loaded["ui.menu.start_at_login"] = previous_startup
	helpers.assert_true(ok, "Builder.generate raised: " .. tostring(menu))
	for _, item in ipairs(menu) do
		if item.title == title_key then return item.menu end
	end
	return nil
end

helpers.describe("about submenu (macOS): Uninstall closes it", function()
	for _, paused in ipairs({ false, true }) do
		helpers.it("is the last row, after a separator, and runs the uninstall action (paused=" .. tostring(paused) .. ")",
			function()
				local fired = {}
				local rows = submenu(paused, fired, "menu.about.title")
				helpers.assert_true(type(rows) == "table" and #rows >= 3, "the tray must carry the About submenu")
				local last = rows[#rows]
				helpers.assert_eq(last.title, "menu.global.uninstall", "Uninstall closes the submenu")
				helpers.assert_eq(rows[#rows - 1].title, "menu.global.start_at_login", "startup immediately precedes Uninstall")
				helpers.assert_eq(rows[#rows - 2].title, "-", "a separator sets the installation group apart")
				helpers.assert_true(last.disabled ~= true, "Uninstall stays live")
				helpers.assert_eq(type(last.fn), "function", "Uninstall carries its handler")
				helpers.assert_eq(#fired, 0, "building the menu must not run any action")
				last.fn()
				helpers.assert_eq(fired, { "uninstall" }, "the row runs the session's uninstall action")
			end)
	end

	helpers.it("is greyed on a source run, naming why, and live again on the installed app", function()
		local fired = {}
		local rows = submenu(false, fired, "menu.about.title", true)
		helpers.assert_true(type(rows) == "table" and #rows >= 3, "the tray must carry the About submenu")
		local last = rows[#rows]
		-- Keys stand for their text here, and a key has no colon: the head of the
		-- reason is the whole key.
		helpers.assert_eq(last.title, "menu.global.uninstall — menu.about.source_run_reason",
			"the row stays in place and names why, as every greyed row with a reason")
		helpers.assert_eq(last.disabled, true, "a source run greys Uninstall")
		helpers.assert_true(last.fn == nil, "with nothing to run")
		helpers.assert_eq(#fired, 0, "building the menu runs nothing")
		helpers.assert_eq(rows[#rows - 1].title, "menu.global.start_at_login", "at the same place, below startup")
		local installed = submenu(false, {}, "menu.about.title", false)
		helpers.assert_eq(installed[#installed].title, "menu.global.uninstall")
		helpers.assert_true(installed[#installed].disabled ~= true, "the installed app keeps it live")
	end)

	helpers.it("is drawn once in the whole tray, never in Configuration", function()
		local rows = submenu(false, {}, "menu.configuration.title")
		helpers.assert_true(type(rows) == "table", "the tray must carry the Configuration submenu")
		for _, row in ipairs(rows) do
			helpers.assert_true(row.title ~= "menu.global.uninstall", "Configuration no longer offers Uninstall")
			helpers.assert_true(row.title ~= "menu.global.start_at_login", "Configuration no longer offers startup")
		end
		helpers.assert_true(rows[#rows].title ~= "-", "Configuration ends on a row, not a separator")
	end)
end)

helpers.describe("about submenu (macOS): startup keeps its owner", function()
	for _, paused in ipairs({ false, true }) do
		for _, enabled in ipairs({ false, true }) do
			helpers.it("reads state and invokes the session action (paused=" .. tostring(paused)
				.. ", enabled=" .. tostring(enabled) .. ")", function()
				local fired = {}
				local rows = submenu(paused, fired, "menu.about.title", false, enabled)
				helpers.assert_true(type(rows) == "table" and #rows >= 3, "the About submenu must be drawn")
				local startup = rows[#rows - 1]
				helpers.assert_eq(startup.title, "menu.global.start_at_login", "startup immediately precedes Uninstall")
				helpers.assert_eq(startup.checked, enabled, "its state comes from the startup owner")
				helpers.assert_true(startup.disabled ~= true, "startup remains independent of keyboard pause")
				helpers.assert_eq(type(startup.fn), "function", "the row retains its session action")
				helpers.assert_eq(#fired, 0, "building the menu never changes startup")
				startup.fn()
				helpers.assert_eq(fired, { "start_at_login" }, "one click invokes the startup action once")
			end)
		end
	end
end)
