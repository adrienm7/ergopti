--- tests/unit/diagnostics/ui/field_check/test_run_all.lua

--- ==============================================================================
--- MODULE: Test Everything (macOS)
--- DESCRIPTION:
--- The Debug menu's « Test everything » on macOS:
--- 1. the shared sequencer's contract (_shared/tests/lua/diagnostics/run_all_contract.lua);
--- 2. the shipped plan builds against this driver's field run declaration and
---    coverage, classifies every macOS Tests row, and its rows start the same
---    checks as the rows themselves; the builder wires the row;
--- 3. a click runs the plan's checks one after the other over the field check
---    engine, abandons a check that misses its deadline so the next one starts,
---    and shows one combined report with a « Copy report » button; a second
---    click while it runs only notifies.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

require("tests.lua.diagnostics.run_all_contract")(helpers)

local MODULES = {
	"core.logger.engine.logger", "core.i18n.engine.i18n", "diagnostics.engine.field_check.field_check",
	"diagnostics.engine.field_check.checks", "diagnostics.ui.field_check",
}

--- Reads one JSON file.
--- @param path string
--- @return table
local function read_json(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return Json.decode(text)
end

local function shipped()
	return read_json(helpers.shared("diagnostics/data/field_check_all.json")),
		read_json(helpers.driver_root() .. "diagnostics/data/field_run.json").steps,
		read_json(helpers.driver_root() .. "diagnostics/data/field_todo_coverage.json")
end

helpers.describe("test everything: the macOS plan", function()
	helpers.it("builds against the field run, classifies every macOS Tests row and is wired in the builder", function()
		local RunAll = require("diagnostics.engine.field_check.run_all")
		local declaration, steps, coverage = shipped()
		local plan = RunAll.plan(declaration, "hs", steps, coverage)
		helpers.assert_true(#plan.run > 0)
		local Window = require("diagnostics.ui.field_check")
		local classified = { [Window.ALL_ROW] = true }
		for _, entry in ipairs(plan.run) do
			if entry.row then
				classified[entry.row] = true
				local row = Window.ROWS[entry.row] or Window.SHARED_ROWS[entry.row]
				helpers.assert_not_nil(row, "plan row without a check: " .. entry.row)
				helpers.assert_eq(row.check, entry.check, entry.row .. " runs another check alone")
			end
		end
		for _, entry in ipairs(plan.separate) do classified[entry.row] = true end
		local manifest = read_json(helpers.shared("menu/data/menu_manifest.json"))
		for _, row in ipairs(manifest.debug_tests_menu) do
			local for_mac = row.platforms == nil
			for _, platform in ipairs(row.platforms or {}) do if platform == "hs" then for_mac = true end end
			if for_mac and row.type == "command" then
				helpers.assert_true(classified[row.id] == true, "Tests row neither run nor listed: " .. row.id)
			end
		end
		helpers.assert_eq(manifest.debug_tests_menu[1].id, Window.ALL_ROW, "« Test everything » heads the Tests rows")
		local builder = assert(helpers.read_driver_unit('require("diagnostics.ui.field_check").run('))
		helpers.assert_contains(builder, '[COMMAND.FIELD_CHECK_ALL] = function() require("diagnostics.ui.field_check").run_all() end')
	end)

	helpers.it("runs no check that needs a person or changes the Karabiner runtime", function()
		local declaration = shipped()
		local banned = { key_accounting = true, field_owned_install = true, field_owned_start = true,
			field_owned_pause = true, hotstring_roundtrip = true, prediction_tooltip = true,
			field_layout_rows = true, field_apple_shortcuts = true }
		for _, entry in ipairs(declaration.platforms.hs.run) do
			helpers.assert_nil(banned[entry.step], "runs a check that needs a person or changes state: " .. entry.step)
		end
	end)
end)

--- Loads the window over a scripted clock and scripted checks.
--- @param body function(Window, services, world, Engine)
local function with_run_all(body)
	helpers.with_stub_scope(MODULES, function()
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["core.i18n.engine.i18n"] = {
			get = function(key)
				if key == "common.label_value" then return "{1} : {2}" end
				return "[" .. key .. "]"
			end,
			format = function(key, ...) return "[" .. key .. "]" .. table.concat({ ... }, ",") end,
		}
		package.loaded["diagnostics.engine.field_check.checks"] = { checks = {
			quick = function(_, report, finish) report.step("probe", "pass"); finish() end,
			stuck = function() end,
		} }
		package.loaded["diagnostics.engine.field_check.field_check"] = nil
		package.loaded["diagnostics.ui.field_check"] = nil
		local Engine = require("diagnostics.engine.field_check.field_check")
		local Window = require("diagnostics.ui.field_check")
		local world = { now = 0, queue = {}, notes = {}, alerts = {}, copies = {} }
		local services = {
			ports = function() return {} end,
			notify = function(_, text) table.insert(world.notes, text) end,
			alert = function(title, text, copy)
				table.insert(world.alerts, { title = title, text = text })
				return copy
			end,
			copy = function(text) table.insert(world.copies, text); return true end,
			after = function(seconds, fn)
				local handle = { at = world.now + seconds, fn = fn }
				table.insert(world.queue, handle)
				return handle
			end,
			cancel = function(handle) handle.cancelled = true end,
			declarations = function()
				return { platforms = { hs = {
					run = { { step = "a" }, { step = "b" }, { step = "c" } },
					separate = { { row = "field_check_key_accounting" } },
				} } }, {
					{ id = "a", kind = "field_check", check = "quick", deadline_seconds = 5 },
					{ id = "b", kind = "field_check", check = "stuck", deadline_seconds = 5 },
					{ id = "c", kind = "field_check", check = "quick", deadline_seconds = 5 },
				}, { points = { { id = "point_a", checks = { { step = "a" } } } } }
			end,
		}
		--- Runs every timer turn due by `until_time`, earliest first.
		function world.drain(until_time)
			while true do
				local best, best_index
				for index, handle in ipairs(world.queue) do
					if not handle.cancelled and handle.at <= until_time and (best == nil or handle.at < best.at) then
						best, best_index = handle, index
					end
				end
				if not best then return end
				table.remove(world.queue, best_index)
				world.now = math.max(world.now, best.at)
				best.fn()
			end
		end
		Engine._reset()
		Window._reset()
		body(Window, services, world, Engine)
	end)
end

helpers.describe("test everything: the macOS run", function()
	helpers.it("runs each check in turn, abandons the stuck one and shows one combined report", function()
		with_run_all(function(Window, services, world, Engine)
			helpers.assert_true(Window.run_all(services))
			helpers.assert_eq(world.notes[1], "[field_check.all.started]3")
			helpers.assert_true(not Window.run_all(services), "a second click starts nothing")
			helpers.assert_eq(world.notes[2], "[field_check.busy]")
			world.drain(4)
			helpers.assert_true(Engine.is_running(), "the stuck check still has time")
			world.drain(100)
			helpers.assert_true(not Engine.is_running(), "the stuck check was abandoned")
			helpers.assert_eq(#world.alerts, 1)
			local alert = world.alerts[1]
			helpers.assert_eq(alert.title, "[menu.debug.field_check_all]")
			helpers.assert_contains(alert.text, "[field_check.all.verdict_fail]")
			helpers.assert_contains(alert.text, "✅ a — point_a")
			helpers.assert_contains(alert.text, "❌ b\n    [field_check.all.timeout]")
			helpers.assert_contains(alert.text, "✅ c")
			helpers.assert_contains(alert.text, "➖ [menu.debug.field_check_key_accounting]")
			helpers.assert_eq(world.copies[1], alert.text)
			helpers.assert_true(Window.run_all(services), "a finished run can start again")
		end)
	end)
end)
