--- tests/unit/ui/test_about_menu_uninstall.lua

--- ==============================================================================
--- MODULE: Uninstall Closes The Version / Updates Submenu (Linux tray)
--- DESCRIPTION:
--- « Désinstaller Ergopti » sat at the bottom of Configuration, between the
--- rows that tune the configuration, where removing the application read as
--- one more setting. It now closes the Version / Updates submenu, set apart by
--- a separator, next to the build it removes; it keeps its label key and runs
--- the same transaction (ui/menu/uninstall.lua), which quits the daemon through
--- ctx.on_quit. Startup sits immediately above it, outside Configuration.
--- Built through the real tray builder and renderer.
---
--- On a local version run from source there is nothing to remove: the row
--- stays in place, greyed like every row greyed with a reason, « Désinstaller
--- Ergopti… — Version locale (depuis les sources) » (the head of the
--- manifest's disabled_reason_key), with nothing to run, and a click that
--- still reaches the action does nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The head of a translated reason, cut as the renderers cut it: the text
--- before its first colon, ASCII or full-width.
local function reason_head(text)
	local cut = nil
	for _, mark in ipairs({ ":", "\239\188\154" }) do
		local at = text:find(mark, 1, true)
		if at and (cut == nil or at < cut) then cut = at end
	end
	return ((cut and text:sub(1, cut - 1) or text):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The submenu of the top-level row whose title is the translation of `key`.
local function submenu_of(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if item.title == label then return item.menu end
	end
	return nil
end

--- Builds the tray with the uninstall transaction replaced by a recorder.
--- @param quits table Counts ctx.on_quit calls.
--- @param source_run boolean|nil What the installed-build owner answers (false by default).
--- @return table items, table runs, function restore
local function build(quits, source_run, startup, paused)
	local runs = {}
	startup = startup or { enabled = false, toggles = 0, changes = 0 }
	local previous_startup = package.loaded["ui.menu.start_at_login"]
	package.loaded["ui.menu.start_at_login"] = {
		enabled = function() return startup.enabled end,
		toggle = function()
			startup.toggles = startup.toggles + 1
			startup.enabled = not startup.enabled
			return true
		end,
	}
	local previous = package.loaded["ui.menu.uninstall"]
	package.loaded["ui.menu.uninstall"] = { run = function(opts) runs[#runs + 1] = opts end }
	-- The suite runs from a checkout, which is a source run: each case says.
	local Installation = require("infra.installation")
	local real_is_source_run = Installation.is_source_run
	Installation.is_source_run = function() return source_run == true end
	local function restore()
		package.loaded["ui.menu.uninstall"] = previous
		package.loaded["ui.menu.start_at_login"] = previous_startup
		Installation.is_source_run = real_is_source_run
	end
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ctx = {
		_version = "9.9.9",
		paused = paused == true,
		on_quit = function() quits.count = quits.count + 1 end,
		on_menu_changed = function() startup.changes = startup.changes + 1 end,
	}
	local ok, items = pcall(mb.build, ctx)
	if not ok then
		restore()
		error(items, 0)
	end
	return items, runs, restore, function() return mb.build(ctx) end
end

helpers.describe("tray (linux): Uninstall closes the Version / Updates submenu", function()
	helpers.it("is the last About row, after a separator, and runs the uninstall transaction", function()
		local quits = { count = 0 }
		local items, runs, restore = build(quits)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local rows = submenu_of(items, "menu.about.title")
			helpers.assert_true(type(rows) == "table" and #rows >= 3, "the tray must carry the About submenu")
			local last = rows[#rows]
			helpers.assert_eq(last.title, i18n.get("menu.global.uninstall"), "Uninstall closes the submenu")
			helpers.assert_eq(rows[#rows - 1].title, i18n.get("menu.global.start_at_login"), "startup immediately precedes Uninstall")
			helpers.assert_eq(rows[#rows - 2].title, "-", "a separator sets the installation group apart")
			helpers.assert_true(last.disabled ~= true, "Uninstall stays live")
			local fn = last.fn or last.action
			helpers.assert_eq(type(fn), "function", "Uninstall carries its handler")
			helpers.assert_eq(#runs, 0, "building the menu must not start the transaction")
			fn()
			helpers.assert_eq(#runs, 1, "the row starts the uninstall transaction once")
			helpers.assert_eq(runs[1].title, i18n.get("menu.global.uninstall"), "under its own label")
			helpers.assert_eq(type(runs[1].confirm), "function", "the transaction asks before removing")
			runs[1].quit()
			helpers.assert_eq(quits.count, 1, "the transaction quits through the daemon's own quit")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("is greyed on a source run, naming why, at the same place", function()
		local items, _, restore = build({ count = 0 }, true)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local rows = submenu_of(items, "menu.about.title")
			helpers.assert_true(type(rows) == "table" and #rows >= 3, "the tray must carry the About submenu")
			local last = rows[#rows]
			local head = reason_head(i18n.get("menu.about.source_run_reason"))
			helpers.assert_true(head ~= "" and head ~= "menu.about.source_run_reason", "the reason is translated")
			helpers.assert_eq(last.title, i18n.get("menu.global.uninstall") .. " — " .. head,
				"the row names why in the menu itself, as every greyed row with a reason")
			helpers.assert_eq(last.disabled, true, "a source run greys Uninstall")
			helpers.assert_true(last.fn == nil, "with nothing to run")
			helpers.assert_eq(rows[#rows - 1].title, i18n.get("menu.global.start_at_login"), "at the same place, below startup")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("does nothing when a click reaches the action on a source run", function()
		local Uninstall = helpers.load_module("ui.menu.uninstall")
		local calls = { commands = 0, failures = 0, quits = 0 }
		local launched = Uninstall.run({
			root = "/checkout/static/ergopti_plus/linux",
			version_source = "local",
			title = "t", confirmation = "c", failure = "f",
			run = function() calls.commands = calls.commands + 1; return true end,
			confirm = function() return true end,
			fail = function() calls.failures = calls.failures + 1 end,
			quit = function() calls.quits = calls.quits + 1 end,
		})
		helpers.assert_eq(launched, false)
		helpers.assert_eq(calls.commands, 0, "no removal command")
		helpers.assert_eq(calls.failures, 0, "no failure dialog")
		helpers.assert_eq(calls.quits, 0, "the daemon keeps running")
	end)

	helpers.it("is drawn once in the whole tray, never in Configuration", function()
		local items, _, restore = build({ count = 0 })
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local label = i18n.get("menu.global.uninstall")
			local rows = submenu_of(items, "menu.configuration.title")
			helpers.assert_true(type(rows) == "table", "the tray must carry the Configuration submenu")
			for _, row in ipairs(rows) do
				helpers.assert_true(row.title ~= label, "Configuration no longer offers Uninstall")
				helpers.assert_true(row.title ~= i18n.get("menu.global.start_at_login"), "Configuration no longer offers startup")
			end
			helpers.assert_true(rows[#rows].title ~= "-", "Configuration ends on a row, not a separator")
			local found = 0
			for _, item in ipairs(items) do
				for _, row in ipairs(type(item.menu) == "table" and item.menu or {}) do
					if row.title == label then found = found + 1 end
				end
			end
			helpers.assert_eq(found, 1, "Uninstall is drawn once in the tray")
		end)
		restore()
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("tray (linux): startup keeps its native owner", function()
	for _, paused in ipairs({ false, true }) do
		for _, enabled in ipairs({ false, true }) do
			helpers.it("reads and toggles startup without resuming keyboard features (paused=" .. tostring(paused)
				.. ", enabled=" .. tostring(enabled) .. ")", function()
				local state = { enabled = enabled, toggles = 0, changes = 0 }
				local items, _, restore, rebuild = build({ count = 0 }, false, state, paused)
				local ok, err = pcall(function()
					local i18n = require("infra.i18n")
					local rows = submenu_of(items, "menu.about.title")
					helpers.assert_true(type(rows) == "table" and #rows >= 3, "the About submenu must be drawn")
					local startup = rows[#rows - 1]
					helpers.assert_eq(startup.title, i18n.get("menu.global.start_at_login"))
					helpers.assert_eq(startup.checked, enabled, "the native owner supplies its state")
					helpers.assert_true(startup.disabled ~= true, "keyboard pause leaves startup available")
					helpers.assert_eq(state.toggles, 0, "building the menu never changes startup")
					helpers.assert_eq(type(startup.fn), "function", "the row retains its startup callback")
					startup.fn()
					helpers.assert_eq(state.toggles, 1, "one click invokes the native owner once")
					helpers.assert_eq(state.changes, 1, "the native owner's result refreshes the tray")
					local updated = submenu_of(rebuild(), "menu.about.title")
					helpers.assert_eq(updated[#updated - 1].checked, not enabled, "a rebuild reads the acknowledged state")
				end)
				restore()
				if not ok then error(err, 0) end
			end)
		end
	end
end)
