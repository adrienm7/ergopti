--- tests/unit/infra/field_check/test_field_check_input_sources.lua

--- ==============================================================================
--- MODULE: Field Run Input Sources Probe
--- DESCRIPTION:
--- The field run's input sources check over scripted ports:
--- 1. the selected source and the enabled list are reported as the
---    text-input system holds them, and an unreadable one fails its step;
--- 2. every installed Ergopti .keylayout goes through xmllint and every
---    Ergopti bundle's Info.plist through plutil -lint, one bounded command
---    each, so one broken file fails its family and names the count;
--- 3. with nothing installed the parse steps are skipped, and no step value
---    carries a file path.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

local HOME_DIR = "/Users/someone/Library/Keyboard Layouts"
local BUNDLE_LAYOUT = HOME_DIR .. "/Ergopti_v2.2.2.bundle/Contents/Resources/Ergopti.keylayout"
local LOOSE_LAYOUT = HOME_DIR .. "/Ergopti_test.keylayout"
local PLIST = HOME_DIR .. "/Ergopti_v2.2.2.bundle/Contents/Info.plist"

--- Builds scripted ports; `world` records every command.
--- @return table ports, table world
local function make_ports()
	local world = {
		commands = {},
		exits = {},
		facts = { current = "org.unknown.keylayout.Ergopti", enabled_ids = {
			"com.apple.keylayout.ABC", "org.unknown.keylayout.Ergopti", "org.unknown.keylayout.ErgoptiPlus" } },
		files = { keylayouts = { BUNDLE_LAYOUT, LOOSE_LAYOUT }, plists = { PLIST } },
	}
	local ports = {
		exec = function(executable, args, timeout_s, callback)
			local key = executable .. " " .. table.concat(args, " ")
			world.commands[#world.commands + 1] = key
			local exit = world.exits[args[#args]]
			if exit == "timeout" then return callback(nil, "") end
			callback(exit or 0, "", "")
		end,
		input_source_facts = function() return world.facts end,
		layout_files = function() return world.files end,
	}
	return ports, world
end

--- Runs the check and returns its steps keyed by id.
--- @param ports table Ports.
--- @return table steps, table result
local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("input_sources", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("input sources probe", function()
	helpers.it("passes with readable sources and every layout file parsing", function()
		local ports, world = make_ports()
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.current_source.value, "org.unknown.keylayout.Ergopti")
		helpers.assert_eq(steps.current_is_ergopti.value, "yes")
		helpers.assert_eq(steps.enabled_sources.value, "3")
		helpers.assert_eq(steps.ergopti_enabled.value, "2")
		helpers.assert_eq(steps.layout_bundles.value, "1")
		helpers.assert_eq(steps.keylayout_xml.value, "2_parsed")
		helpers.assert_eq(steps.bundle_plist.value, "1_parsed")
		helpers.assert_eq(world.commands[1], "/usr/bin/xmllint --noout --nonet " .. BUNDLE_LAYOUT)
		helpers.assert_eq(world.commands[3], "/usr/bin/plutil -lint -s " .. PLIST)
		for _, step in pairs(steps) do
			helpers.assert_true(tostring(step.value):find("/", 1, true) == nil, "a step carries a path")
		end
	end)

	helpers.it("fails the layout family whose file does not parse, and names the count", function()
		local ports, world = make_ports()
		world.exits[LOOSE_LAYOUT] = 1
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.keylayout_xml.value, "refused_1_of_2")
		helpers.assert_eq(steps.bundle_plist.state, "pass")
		world.exits[LOOSE_LAYOUT] = nil
		world.exits[PLIST] = "timeout"
		steps = run(ports)
		helpers.assert_eq(steps.bundle_plist.value, "timeout_1")
		helpers.assert_eq(steps.keylayout_xml.state, "pass")
	end)

	helpers.it("fails unreadable sources and skips the parse steps with nothing installed", function()
		local ports, world = make_ports()
		world.facts = { current = nil, enabled_ids = nil }
		world.files = { keylayouts = {}, plists = {} }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.current_source.value, "unreadable")
		helpers.assert_eq(steps.enabled_sources.state, "fail")
		helpers.assert_eq(steps.ergopti_enabled.state, "skip")
		helpers.assert_eq(steps.keylayout_xml.value, "none_installed")
		helpers.assert_eq(steps.bundle_plist.state, "skip")
		helpers.assert_eq(#world.commands, 0)
	end)
end)
