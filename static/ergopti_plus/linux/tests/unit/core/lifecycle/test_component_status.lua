--- tests/unit/core/lifecycle/test_component_status.lua

--- ==============================================================================
--- MODULE: Component Status
--- DESCRIPTION:
--- A missing component was told through one timed notification, which KDE
--- Plasma 6 dropped without keeping it in its history (field report, Arch
--- Linux, 2026-11-25): the user saw a tray and "nothing works". These cases pin
--- that a reported problem is logged once, posted as a persistent notice, and
--- leads the tray menu as its declared red row (menu.toml
--- linux_component_problems) whose click shows the explanation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A problem as gui_stack reports it.
local PROBLEM = { code = "windows_lgi", title = "Ergopti+ needs a component",
	body = "Install lua51-lgi: sudo pacman -S --needed lua51-lgi" }

-- Every code a Linux part reports: each needs its own declared tray row. The
-- KWin focus script's was missing (field report, Plasma 6.8 Wayland,
-- 2026-11-25): its problem reached the log only, each tray build saying it
-- had no row. Whole literal codes are also read from their reporters below.
local REPORTED_CODES = { "windows_lgi", "windows_webkit", "layout_unresolved", "kwin_focus_script",
	"gnome_focus_extension", "ergopti_layout_install_failed", "ergopti_layout_activate_failed", "ergopti_layout_uninstall_failed" }

-- The reporters whose codes are whole literals, read for the codes above.
local LITERAL_REPORTERS = { "platform.focus.text_automation_status", "ergopti_hotstrings" }

--- The problem rows built over a status, with the status window recorded.
--- @param Status table
--- @return table rows, table shown
local function problem_rows(Status)
	local shown = {}
	local Rows = helpers.load_module("menu.ui.builder.component_status_rows")
	local rows = Rows.build({ status = Status, show = function(title, body)
		shown[#shown + 1] = { title, body }
		return true
	end })
	return rows, shown
end

helpers.describe("component_status: a problem stays visible", function()

	helpers.it("posts the problem once as a persistent error notice", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		local sent = {}
		local notifier = { send = function(body, opts) sent[#sent + 1] = { body = body, opts = opts } end }
		helpers.assert_true(Status.report(PROBLEM, { notifier = notifier }))
		helpers.assert_true(not Status.report(PROBLEM, { notifier = notifier }), "a second report is refused")
		helpers.assert_eq(#sent, 1)
		helpers.assert_eq(sent[1].body, PROBLEM.body)
		helpers.assert_true(sent[1].opts.persistent, "the notice stays until closed")
		helpers.assert_eq(sent[1].opts.level, "error")
		helpers.assert_true(Status.has("windows_lgi"))
	end)

	helpers.it("leads the tray menu with a declared red row that shows the explanation", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		helpers.assert_eq(#problem_rows(Status), 0, "no row and no separator when nothing is wrong")
		Status.report(PROBLEM, {})
		local rows, shown = problem_rows(Status)
		helpers.assert_eq(#rows, 2)
		local I18n = require("core.i18n.engine.i18n")
		helpers.assert_eq(rows[1].label, "🔴 " .. I18n.get("startup.linux_gui_stack_windows_label"),
			"the shared unreachable dot, then the declared label: " .. tostring(rows[1].label))
		helpers.assert_true(rows[2].separator)
		rows[1].action()
		helpers.assert_eq(shown[1][1], PROBLEM.title)
		helpers.assert_eq(shown[1][2], PROBLEM.body)
	end)

	helpers.it("(component-problem-rows) every whole literal code a reporter names is listed", function()
		local listed = {}
		for _, code in ipairs(REPORTED_CODES) do listed[code] = true end
		local found = 0
		for _, module_name in ipairs(LITERAL_REPORTERS) do
			local source = assert(helpers.read_module_source(module_name), module_name)
			for code in source:gmatch('\n%s*code = "([a-z0-9_]+)",') do
				found = found + 1
				helpers.assert_true(listed[code] == true, code .. " (" .. module_name .. ") has no listed tray row")
			end
		end
		helpers.assert_true(found >= 2, "the reporters' literal codes were read")
	end)

	helpers.it("(component-problem-rows) draws a row for every code a Linux part reports", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		for _, code in ipairs(REPORTED_CODES) do
			Status.report({ code = code, title = "t " .. code, body = "b " .. code }, {})
		end
		local rows = problem_rows(Status)
		helpers.assert_eq(#rows, #REPORTED_CODES + 1, "one row per reported problem, then the separator")
		for index = 1, #REPORTED_CODES do
			helpers.assert_true(type(rows[index].label) == "string" and rows[index].label:find("🔴 ", 1, true) == 1,
				REPORTED_CODES[index] .. " shows a red row")
		end
	end)

	helpers.it("leaves the tray once a recoverable problem recovers", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		local unresolved = true
		Status.report({ code = "layout_unresolved", title = "t", body = "b",
			active = function() return unresolved end }, {})
		helpers.assert_eq(#problem_rows(Status), 2)
		unresolved = false
		helpers.assert_eq(#problem_rows(Status), 0, "the layout was read later")
	end)

	helpers.it("refuses a problem without its explanation", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		local ok = pcall(Status.report, { code = "x", title = "t" })
		helpers.assert_true(not ok)
	end)

	helpers.it("an unread layout before the grab becomes a recoverable tray problem", function()
		-- Without a layout the daemon types no replacement: the core looked
		-- inactive with nothing but a warning in the log.
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		local guard = source:find("resolve again before grabbing", 1, true)
		local report = source:find('code = "layout_unresolved"', guard or 1, true)
		helpers.assert_true(guard ~= nil and report ~= nil, "the last check before the grab reports it")
		helpers.assert_true(source:find("active = function() return not keyboard_layout.is_ready() end", report, true) ~= nil,
			"the row leaves once a layout is read")
		helpers.assert_true(source:find("if reported and rebuild_tray_menu then rebuild_tray_menu() end", report, true) ~= nil,
			"the tray, built before this check, is redrawn with the row")
		local Json = require("core.text.engine.json")
		for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no",
			"pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
			local handle = assert(io.open(helpers.driver_root() .. "/../_shared/core/i18n/data/locales/" .. code .. ".json", "r"))
			local catalogue = Json.decode(handle:read("*a"))
			handle:close()
			helpers.assert_eq(type(catalogue["startup.linux_layout_unresolved_label"]), "string", code)
			helpers.assert_true((catalogue["startup.linux_layout_unresolved_body"] or ""):find("{1}", 1, true) ~= nil, code)
			if code == "en" then
				-- keyboard_hook.start refuses without XKB capture, so the daemon
				-- stops here: the notice promised a layout switch would fix a
				-- daemon that had already exited.
				local body = catalogue["startup.linux_layout_unresolved_body"]
				helpers.assert_contains(body, "stopped")
				helpers.assert_true(body:find("Switching the layout", 1, true) == nil, "no fix the stopped daemon cannot see")
			end
		end
		helpers.assert_true(source:find("XKB capture cannot start, so the daemon stops", guard, true) ~= nil,
			"the log line before the grab says the start ends")
	end)

	helpers.it("the shared menu declares the rows and the tray adapter draws none of its own", function()
		local source = assert(helpers.read_module_source("tray.adapters.menu"))
		helpers.assert_true(source:find("component_status", 1, true) == nil, "replace_menu prepends nothing")
		local frame = require("menu.engine.manifest_menu").get_array("linux_component_problems")
		helpers.assert_eq(#frame, #REPORTED_CODES, "one declared row per reported code")
		for _, entry in ipairs(frame) do helpers.assert_eq(entry.platforms, { "linux" }) end
		local builder = assert(helpers.read_module_source("menu.ui.builder.builder"))
		local problems = builder:find('require("menu.ui.builder.component_status_rows").build()', 1, true)
		local header = builder:find("rows[#rows + 1] = header", 1, true)
		helpers.assert_true(problems ~= nil and header ~= nil and problems < header, "the problems lead the root, above its title")
	end)
end)
