--- tests/unit/diagnostics/ui/field_check/test_run_all.lua

--- ==============================================================================
--- MODULE: Test Everything (Linux)
--- DESCRIPTION:
--- The Debug menu's « Test everything » on Linux:
--- 1. the shared sequencer's contract (_shared/tests/lua/diagnostics/run_all_contract.lua);
--- 2. the shipped plan builds against the Linux field run declaration and
---    coverage, classifies every Linux Tests row, and the Debug menu routes
---    the row to this module;
--- 3. a click runs each check's headless runner in turn and shows one combined
---    report from a fresh loop turn; a second click while it runs only says so.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

require("tests.lua.diagnostics.run_all_contract")(helpers)

--- Reads one JSON file.
--- @param path string
--- @return table
local function read_json(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return Json.decode(text)
end

local SHARED = helpers.driver_root() .. "/../_shared/"

helpers.describe("test everything: the Linux plan", function()
	helpers.it("builds against the field run, classifies every Linux Tests row and is routed by the menu", function()
		local RunAll = require("diagnostics.engine.field_check.run_all")
		local FieldRun = require("diagnostics.engine.field_run.field_run")
		local spec = FieldRun.load(SHARED, helpers.driver_root())
		local plan = RunAll.plan(read_json(SHARED .. "diagnostics/data/field_check_all.json"), "linux", spec.steps,
			read_json(helpers.driver_root() .. "/diagnostics/data/field_todo_coverage.json"))
		helpers.assert_true(#plan.run > 0)
		local classified = { field_check_all = true }
		for _, entry in ipairs(plan.run) do
			helpers.assert_not_nil(FieldRun.CHECK_RUNNERS[entry.check], "no headless runner for " .. entry.check)
			if entry.row then classified[entry.row] = true end
		end
		for _, entry in ipairs(plan.separate) do classified[entry.row] = true end
		local manifest = read_json(SHARED .. "menu/data/menu_manifest.json")
		for _, row in ipairs(manifest.debug_tests_menu) do
			local for_linux = row.platforms == nil
			for _, platform in ipairs(row.platforms or {}) do if platform == "linux" then for_linux = true end end
			if for_linux and row.type == "command" then
				helpers.assert_true(classified[row.id] == true, "Tests row neither run nor listed: " .. row.id)
			end
		end
		local handle = assert(io.open(helpers.driver_root() .. "/diagnostics/ui/menu_debug.lua", "rb"))
		local source = handle:read("*a")
		handle:close()
		helpers.assert_contains(source,
			'[COMMAND.FIELD_CHECK_ALL] = function() require("diagnostics.ui.field_check.run_all").run() end')
	end)
end)

helpers.describe("test everything: the Linux run", function()
	helpers.it("runs each headless runner in turn and shows one combined report", function()
		local saved = package.loaded["diagnostics.ui.field_check.run_all"]
		package.loaded["diagnostics.ui.field_check.run_all"] = nil
		local RunAllUi = require("diagnostics.ui.field_check.run_all")
		RunAllUi._reset()
		local Report = require("diagnostics.engine.field_check.report")
		local world = { notes = {}, dialogs = {}, copies = {}, deferred = {}, timers = {}, started = {} }
		local pending = {}
		local services = {
			translate = function(key)
				if key == "common.label_value" then return "{1} : {2}" end
				if key == "field_check.all.started" then return "started {1}" end
				return "[" .. key .. "]"
			end,
			notify = function(message) table.insert(world.notes, message) end,
			dialog = function(title, text)
				table.insert(world.dialogs, { title = title, text = text })
				return true
			end,
			copy = function(text) table.insert(world.copies, text); return true end,
			defer = function(fn) table.insert(world.deferred, fn) end,
			after = function(_, fn)
				local handle = { fn = fn }
				table.insert(world.timers, handle)
				return handle
			end,
			cancel = function(handle) handle.cancelled = true end,
			declarations = function()
				return { platforms = { linux = { run = { { step = "one", row = "composer_check" }, { step = "two" } }, separate = {} } } },
					{ { id = "one", kind = "field_check", check = "composer", deadline_seconds = 5 },
						{ id = "two", kind = "field_check", check = "network", deadline_seconds = 5 } },
					{ points = { { id = "composer_point", checks = { { step = "one" } } } } }
			end,
			runner = function(check)
				return { run_headless = function(on_result)
					table.insert(world.started, check)
					pending[check] = on_result
					return true
				end }
			end,
		}
		--- Runs the zero-delay timers, as the loop's next turns would.
		local function turn()
			local due = world.timers
			world.timers = {}
			for _, handle in ipairs(due) do if not handle.cancelled then handle.fn() end end
		end
		local function report_of(check)
			local report = Report.new_report(check)
			report.step("probe", Report.STATE_PASS)
			return report.result()
		end
		local ok, err = pcall(function()
			helpers.assert_true(RunAllUi.run(services))
			helpers.assert_eq(world.notes[1], "started 2")
			helpers.assert_true(not RunAllUi.run(services), "a second click starts nothing")
			helpers.assert_eq(world.notes[2], "[field_check.busy]")
			turn()
			helpers.assert_eq(table.concat(world.started, ","), "composer")
			pending.composer(report_of("composer"))
			turn()
			helpers.assert_eq(table.concat(world.started, ","), "composer,network")
			pending.network(report_of("network"))
			turn()
			helpers.assert_true(not RunAllUi.is_running())
			helpers.assert_eq(#world.dialogs, 0, "the report opens from a fresh loop turn")
			for _, fn in ipairs(world.deferred) do fn() end
			helpers.assert_eq(#world.dialogs, 1)
			helpers.assert_eq(world.dialogs[1].title, "[menu.debug.field_check_all]")
			helpers.assert_contains(world.dialogs[1].text, "[field_check.all.verdict_pass]")
			helpers.assert_contains(world.dialogs[1].text, "✅ [menu.debug.composer_check] — one, composer_point")
			helpers.assert_contains(world.dialogs[1].text, "✅ two")
			helpers.assert_eq(world.copies[1], world.dialogs[1].text)
		end)
		RunAllUi._reset()
		package.loaded["diagnostics.ui.field_check.run_all"] = saved
		if not ok then error(err, 0) end
	end)
end)
