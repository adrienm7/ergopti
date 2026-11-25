--- tests/unit/diagnostics/engine/field_check/test_tray_check.lua

--- ==============================================================================
--- MODULE: Tray Check (Linux)
--- DESCRIPTION:
--- The field run's « tray » check (diagnostics/engine/field_check/tray_check.lua)
--- against a scripted dbusmenu exporter that answers busctl's JSON:
--- 1. a menu as the daemon draws it passes every step, and the clicked
---    emulation choice and « Suspendre » are put back;
--- 2. the KDE hover regression of 2026-11-25 (AboutToShow unticking a
---    checkable submenu row) fails hover_keeps_checks;
--- 3. checkmarks instead of radios, two ticks, a click that changes nothing,
---    « Suspendre » away from « Recharger », a missing hint, an ungreyed
---    title, a console row and a wrong problem row count each fail by name;
--- 4. no busctl makes the check not run, no watcher fails tray_exported;
--- 5. the field run declares the step, its check and its title.
--- tests/hardware/run_field_tray_check.lua runs the same check against the
--- real libdbusmenu-gtk export.
--- ==============================================================================

local helpers = require("tests.helpers")

local Check = require("diagnostics.engine.field_check.tray_check")
local Report = require("diagnostics.engine.field_check.report")

local NAME, ITEM, MENU = ":1.42", "/org/ayatana/NotificationItem/ergopti_plus", "/org/ayatana/NotificationItem/ergopti_plus/Menu"

--- The menu the daemon draws, from a mutable state; `world.options` breaks one part.
local function model(world)
	local o, st = world.options, world.state
	local function check(label, on, extra)
		local row = { label = label, toggle_type = "checkmark", toggle_state = on and 1 or 0 }
		for key, value in pairs(extra or {}) do row[key] = value end
		return row
	end
	local function radio(label)
		return { label = label, toggle_type = o.checkmarks and "checkmark" or "radio",
			toggle_state = (st.emulated == label or (o.two_ticks and label == "Bépo")) and 1 or 0,
			click = function() if not o.inert_choice then st.emulated = label; world.rebuild() end end }
	end
	local root = {
		{ label = st.paused and "Ergopti+ ⏸" or "Ergopti+ 2.2", enabled = false },
		{ separator = true },
		check("Hotstrings", true, { children = { { label = "Child" } }, lazy = true }),
		check("🎯 Shortcuts", true, { children = { { label = "Child" } }, lazy = true }),
		{ label = "Layout", lazy = true, children = {
			{ label = "Layout to emulate : " .. st.emulated, lazy = true,
				children = { radio("None"), radio("Ergopti"), radio("Bépo") } },
		} },
		{ label = "Configuration", lazy = true, children = {
			{ label = "— Reset —", enabled = o.title_enabled == true },
			{ label = "Restore" },
			{ separator = true },
			{ label = "— Files —", enabled = false },
			{ label = "Window font: Default" },
		} },
		{ label = "⚠ Debug", lazy = true, children = {
			{ label = o.console and "Console" or "Report a bug" },
			{ label = "— Logs —", enabled = false },
			check("Detailed log", false),
			check("Error window", true),
			{ separator = true },
			{ label = "Open logs" },
		} },
		{ separator = true },
	}
	if o.problem_row then table.insert(root, 1, { label = "🔴 KWin focus script missing" }) end
	local suspend = check("Suspend" .. (o.no_hint and "" or " (AltGr + Enter)"), st.paused,
		{ click = function() st.paused = not st.paused; world.rebuild() end })
	local reload = { label = "Reload (AltGr + ⌫)" }
	if o.reload_first then root[#root + 1] = reload; root[#root + 1] = suspend
	else root[#root + 1] = suspend; root[#root + 1] = reload end
	root[#root + 1] = { separator = true }
	root[#root + 1] = { label = "Quit (AltGr + Esc)" }
	return root
end

--- The exporter: ids renewed on each rebuild, lazy submenus filled on AboutToShow.
local function exporter(world)
	world.base, world.rows = 0, {}
	function world.rebuild()
		world.base = world.base + 1000
		world.rows = {}
		local next_id = world.base
		local function assign(list)
			for _, row in ipairs(list) do
				next_id = next_id + 1
				row.id = next_id
				world.rows[row.id] = row
				if row.children then assign(row.children) end
			end
		end
		world.tree = model(world)
		assign(world.tree)
	end
	world.rebuild()
	local function variant(kind, data) return { type = kind, data = data } end
	local function encode(row)
		local props = {}
		if row.separator then props.type = variant("s", "separator") else props.label = variant("s", row.label) end
		if row.enabled == false then props.enabled = variant("b", false) end
		if row.toggle_type then props["toggle-type"] = variant("s", row.toggle_type) end
		if row.toggle_state then props["toggle-state"] = variant("i", row.toggle_state) end
		local children = {}
		if row.children then
			props["children-display"] = variant("s", "submenu")
			if row.lazy and not row.filled then
				children[1] = variant("(ia{sv}av)", { row.id + 500, { label = variant("s", ""),
					visible = variant("b", false) }, {} })
			else
				for _, child in ipairs(row.children) do children[#children + 1] = variant("(ia{sv}av)", encode(child)) end
			end
		end
		return { row.id or 0, props, children }
	end
	return function(args)
		world.calls[#world.calls + 1] = table.concat(args, " ")
		if args[1] == "get-property" then
			if args[2] == Check.WATCHER_NAME then
				if world.options.no_watcher then return nil, "exit" end
				return { type = "as", data = { ":1.7/StatusNotifierItem", NAME .. ITEM } }
			end
			if args[5] == "Id" then return { type = "s", data = "ergopti-plus" } end
			if args[5] == "Menu" then return { type = "o", data = MENU } end
		end
		local method = args[5]
		if method == "GetLayout" then
			local parent = tonumber(args[7])
			local row = parent == 0 and { id = 0, children = world.tree } or world.rows[parent]
			if not row then return nil, "exit" end
			return { type = "u(ia{sv}av)", data = { world.base, encode(row) } }
		end
		local id = tonumber(args[7])
		local row = world.rows[id]
		if method == "AboutToShow" then
			if row and row.lazy then row.filled = true end
			-- The bug of 2026-11-25: GTK toggled the parent's check on the activate an AboutToShow became.
			if row and world.options.hover_bug and row.toggle_type == "checkmark" and row.children then
				row.toggle_state = 1 - row.toggle_state
			end
			return { type = "b", data = { false } }
		end
		if method == "Event" then
			if row and args[8] == "clicked" and row.click then
				world.clicks[#world.clicks + 1] = row.label
				row.click()
			end
			return { data = {} }
		end
		if method == "GetGroupProperties" then
			-- aias: the id count, then the id.
			id = tonumber(args[8])
			row = world.rows[id]
			return { type = "a(ia{sv})", data = { { { id, { ["toggle-state"] = variant("i", row and row.toggle_state or 0) } } } } }
		end
		return nil, "exit"
	end
end

--- The ports over the exporter; timers run at once.
local function ports(options)
	local world = { options = options or {}, state = { emulated = "None", paused = false }, calls = {}, clicks = {} }
	local answer = exporter(world)
	world.restores = 0
	world.ports = {
		bus_name = function() return NAME end,
		bus = function(args, done)
			if world.options.no_busctl then return nil, "not_found" end
			local reply, why = answer(args)
			done(reply, why)
			return true
		end,
		after = function(_, fn) fn(); return true end,
		expect = function()
			local function script(id, base, hint)
				return { id = id, base = base, label = hint and (base .. " (" .. hint .. ")") or base }
			end
			return {
				indicator_id = "ergopti-plus",
				suspend = script("suspend", "Suspend", "AltGr + Enter"), reload = script("reload", "Reload", "AltGr + ⌫"),
				quit = script("quit", "Quit", "AltGr + Esc"),
				checkable_groups = { "Hotstrings", "Shortcuts" },
				layout_group = "Layout", emulated = "Layout to emulate",
				configuration = "Configuration", configuration_titles = { "— Reset —", "— Files —" },
				reading_font = "Window font",
				debug = "Debug", console = "Console", logs_title = "— Logs —", logs_switches = { "Detailed log", "Error window" },
				detailed_log = false, problem_dot = "🔴", problem_count = world.options.problems or 0,
			}
		end,
		emulation_state = function() return world.state.emulated end,
		config_snapshot = function() return { bytes = "a = 1\n" } end,
		config_restore = function(snapshot)
			world.restores = world.restores + 1
			return snapshot.bytes == "a = 1\n"
		end,
	}
	return world
end

--- Runs the check; returns its steps by id, its result and the world.
local function run(options)
	local world = ports(options)
	local report = Report.new_report("tray")
	local finished = 0
	Check.run(world.ports, report, function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1, "the check finishes once")
	local result, by_id = report.result(), {}
	for _, step in ipairs(result.steps) do by_id[step.id] = step end
	return by_id, result, world
end

helpers.describe("field run tray check (linux)", function()
	helpers.it("passes the menu the daemon draws and puts every click back (tray-check)", function()
		local steps, result, world = run({})
		helpers.assert_true(result.passed, Report.format_log_line(result))
		for _, id in ipairs({ "tray_exported", "problem_rows", "suspend_before_reload", "shortcut_hints",
			"hover_keeps_checks", "configuration_titles", "reading_font_row", "debug_logs_rows", "emulation_radio",
			"emulation_live", "suspend_toggle" }) do
			helpers.assert_eq(steps[id].state, Report.STATE_PASS, id)
		end
		helpers.assert_eq(steps.shortcut_hints.value, "3")
		helpers.assert_eq(steps.hover_keeps_checks.value, "2")
		helpers.assert_eq(world.clicks, { "Ergopti", "None", "Suspend (AltGr + Enter)", "Suspend (AltGr + Enter)" })
		helpers.assert_eq({ world.state.emulated, world.state.paused, world.restores }, { "None", false, 1 })
		-- GetLayout's recursion depth is the argument -1, after the signature.
		helpers.assert_contains(world.calls[4], "call " .. NAME .. " " .. MENU .. " com.canonical.dbusmenu GetLayout iias 0 -1 0")
	end)

	helpers.it("fails the hover that unticked Hotstrings on KDE Plasma 6 (tray-check)", function()
		local steps, result = run({ hover_bug = true })
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.hover_keeps_checks.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.hover_keeps_checks.value, "changed:1")
	end)

	helpers.it("fails each drawing defect by name (tray-check)", function()
		helpers.assert_eq(run({ checkmarks = true }).emulation_radio.value, "not_radio")
		helpers.assert_eq(run({ two_ticks = true }).emulation_radio.value, "ticked:2")
		helpers.assert_eq(run({ inert_choice = true }).emulation_live.value, "not_ticked")
		helpers.assert_eq(run({ reload_first = true }).suspend_before_reload.value, "not_adjacent")
		helpers.assert_eq(run({ no_hint = true }).shortcut_hints.value, "wrong_label:suspend")
		helpers.assert_eq(run({ title_enabled = true }).configuration_titles.value, "not_greyed:1")
		helpers.assert_eq(run({ console = true }).debug_logs_rows.value, "console_row")
		helpers.assert_eq(run({ problem_row = true }).problem_rows.value, "shown:1+held:0")
		helpers.assert_eq(run({ problem_row = true, problems = 1 }).problem_rows.state, Report.STATE_PASS)
	end)

	helpers.it("does not run without busctl and fails without a watcher (tray-check)", function()
		local steps, result = run({ no_busctl = true })
		helpers.assert_eq(result.not_run, "no_busctl")
		helpers.assert_eq(steps.tray_exported.state, Report.STATE_SKIP)
		steps = run({ no_watcher = true })
		helpers.assert_eq({ steps.tray_exported.state, steps.tray_exported.value }, { Report.STATE_FAIL, "no_watcher" })
	end)

	helpers.it("reads a dbusmenu label as the panel draws it (tray-check)", function()
		helpers.assert_eq(Check.plain_label("_Fichier"), "Fichier")
		helpers.assert_eq(Check.plain_label("config__dir"), "config_dir")
		local node = Check.decode_node({ 3, { label = { type = "s", data = "A" } }, { { type = "(ia{sv}av)",
			data = { 4, { visible = { type = "b", data = false } }, {} } } } })
		helpers.assert_eq({ node.id, node.label, node.enabled, #node.children, #Check.visible_rows(node) }, { 3, "A", true, 1, 0 })
	end)

	helpers.it("is a field run step with its runner and title (tray-check)", function()
		local FieldRun = require("diagnostics.engine.field_run.field_run")
		helpers.assert_eq(FieldRun.CHECK_RUNNERS.tray, "diagnostics.ui.field_check.tray_check")
		helpers.assert_eq(require(FieldRun.CHECK_RUNNERS.tray).title_key, "field_check.tray.title")
		local spec = FieldRun.load(helpers.driver_root() .. "/../_shared", helpers.driver_root())
		helpers.assert_eq(spec.step_by_id.field_tray.check, "tray")
	end)
end)
