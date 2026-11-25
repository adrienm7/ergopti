--- tests/unit/core/lifecycle/test_component_status.lua

--- ==============================================================================
--- MODULE: Component Status
--- DESCRIPTION:
--- A missing component was told through one timed notification, which KDE
--- Plasma 6 dropped without keeping it in its history (field report, Arch
--- Linux, 2026-11-25): the user saw a tray and "nothing works". These cases pin
--- that a reported problem is logged once, posted as a persistent notice, and
--- leads the tray menu as a red row whose click shows the explanation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A problem as gui_stack reports it.
local PROBLEM = { code = "windows_lgi", label = "Windows unavailable", title = "Ergopti+ needs a component",
	body = "Install lua51-lgi: sudo pacman -S --needed lua51-lgi" }

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

	helpers.it("leads the tray menu with a red row that shows the explanation", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		helpers.assert_eq(#Status.tray_rows(function() end), 0, "no row when nothing is wrong")
		Status.report(PROBLEM, {})
		local shown
		local rows = Status.tray_rows(function(title, body) shown = { title, body } end)
		helpers.assert_eq(#rows, 2)
		helpers.assert_eq(rows[1].title, "🔴 Windows unavailable")
		helpers.assert_true(rows[2].separator)
		rows[1].fn()
		helpers.assert_eq(shown[1], PROBLEM.title)
		helpers.assert_eq(shown[2], PROBLEM.body)
	end)

	helpers.it("leaves the tray once a recoverable problem recovers", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		local unresolved = true
		Status.report({ code = "layout_unresolved", label = "Layout", title = "t", body = "b",
			active = function() return unresolved end }, {})
		helpers.assert_eq(#Status.tray_rows(function() end), 2)
		unresolved = false
		helpers.assert_eq(#Status.tray_rows(function() end), 0, "the layout was read later")
	end)

	helpers.it("refuses a problem without its explanation", function()
		local Status = helpers.load_module("core.ui.engine.component_status")
		local ok = pcall(Status.report, { code = "x", label = "l", title = "t" })
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

	helpers.it("the tray adapter publishes the rows before the menu", function()
		local source = assert(helpers.read_module_source("tray.adapters.menu"))
		helpers.assert_true(source:find('require("core.ui.engine.component_status").tray_rows(', 1, true) ~= nil,
			"replace_menu prepends the status rows")
	end)
end)
