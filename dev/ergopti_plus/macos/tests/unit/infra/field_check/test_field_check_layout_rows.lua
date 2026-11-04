--- tests/unit/infra/field_check/test_field_check_layout_rows.lua

--- ==============================================================================
--- MODULE: Field Check, Layout Rows Live Replace
--- DESCRIPTION:
--- The field run's layout rows check over the real build owner and an in-memory
--- Mac: two builds, the second replacing the first live, then the user's
--- selected source and enabled list put back exactly; a failing build still
--- restores; a restore that leaves a difference fails by name
--- (field-layout-rows).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Report = require("field_check_report")
local Check = require("infra.field_check_layout_rows")
local Build = require("modules.keymap.layout_rows_build")
local FakeMac = require("tests.support.layout_rows_fake_mac")

local REGISTRY_DIR = helpers.driver_root() .. "/../../layouts/registry/"

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local SOURCE = { id = "ergol", keyboard_name = "Ergopti Field Rows", text = read(REGISTRY_DIR .. "ergol/ergol.keylayout"),
	convention = "ansi" }

--- The check's environment over a fake Mac whose user types "Ergo-L".
local function env_over(mac, deps, options)
	options = options or {}
	mac.selected = "Ergo-L"
	mac.enabled["Ergo-L"] = "/bundle/Ergo-L.keylayout"
	mac.enabled["ABC"] = "/system/ABC"
	local function state()
		local names = {}
		for name in pairs(mac.enabled) do names[#names + 1] = name end
		table.sort(names)
		return { selected = "id." .. mac.selected, enabled_json = Json.encode(names) }
	end
	return {
		source = SOURCE,
		replace = function(source, rows, on_done) return Build.replace(source, rows, on_done, deps) end,
		retire_all = function(on_done) return Build.retire_all(on_done, deps) end,
		exists = deps.exists,
		sources_state = function(on_done) on_done(true, state()) end,
		select_id = function(id, on_done)
			mac.selected = options.stuck_selection and mac.selected or id:gsub("^id%.", "")
			on_done(true)
		end,
	}
end

--- Runs the check and returns its steps by id.
local function run(env)
	local report = Report.new_report("layout_rows")
	local finished = 0
	Check.layout_rows({ layout_rows_env = function() return env end }, report, function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1, "the check must finish exactly once")
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps
end

helpers.describe("field check layout rows: a live replace proved and undone (field-layout-rows)", function()
	helpers.it("builds, replaces live, then restores the user's exact input sources", function()
		Build._reset()
		local mac, deps = FakeMac.new()
		local steps = run(env_over(mac, deps))
		helpers.assert_eq(steps.rows_build.state, Report.STATE_PASS)
		helpers.assert_eq(steps.rows_build.value, "keys_13")
		helpers.assert_eq(steps.rows_replace.state, Report.STATE_PASS)
		helpers.assert_eq(steps.rows_replace.value, "edges_true")
		helpers.assert_eq(steps.rows_retire.state, Report.STATE_PASS)
		helpers.assert_eq(steps.rows_restore.state, Report.STATE_PASS)
		helpers.assert_eq(mac.selected, "Ergo-L")
		for path in pairs(mac.files) do
			helpers.assert_true(not path:match("%.keylayout$"), "a build file was left: " .. path)
		end
	end)

	helpers.it("restores after a failed build and names the failure", function()
		Build._reset()
		local mac, deps = FakeMac.new({ stale_cells = true })
		local steps = run(env_over(mac, deps))
		helpers.assert_eq(steps.rows_build.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.rows_build.value, Build.FAILURE_READBACK)
		helpers.assert_eq(steps.rows_replace.state, Report.STATE_SKIP)
		helpers.assert_eq(steps.rows_restore.state, Report.STATE_PASS)
	end)

	helpers.it("fails the restore when the user's selection is not back", function()
		Build._reset()
		local mac, deps = FakeMac.new()
		local steps = run(env_over(mac, deps, { stuck_selection = true }))
		helpers.assert_eq(steps.rows_restore.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.rows_restore.value, "selection_differs")
	end)
end)
