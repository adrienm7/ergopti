--- tests/unit/infra/field_check/test_field_check_permissions.lua

--- ==============================================================================
--- MODULE: Field Run Permissions Probe
--- DESCRIPTION:
--- The field run's permissions check over scripted ports:
--- 1. a missing or unreadable Accessibility grant fails its own step only, and
---    the other grants are named without failing the check;
--- 2. a bundle identifier outside the declared ones fails, so a report shows
---    when macOS files the grants under another app;
--- 3. a broken signature names codesign's first known cause, an ad hoc
---    signature is named (grants do not survive a rebuild), and no step value
---    carries the bundle path the commands were given;
--- 4. without a bundle path the signature steps are skipped, not failed.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

local BUNDLE = "/Users/someone/ergopti/build/macos/ErgoptiPlus.app"
local VERIFY = "/usr/bin/codesign --verify --strict --verbose=2 " .. BUNDLE
local DESCRIBE = "/usr/bin/codesign -dv --verbose=2 " .. BUNDLE

--- Builds scripted ports; `world` records every command.
--- @return table ports, table world
local function make_ports()
	local world = {
		commands = {},
		outputs = {
			[VERIFY] = { 0, "", BUNDLE .. ": valid on disk\n" },
			[DESCRIBE] = { 0, "", "Identifier=com.ergoptiplus.app\nSignature size=9000\nTeamIdentifier=ABCDE12345\n" },
		},
		facts = { accessibility = true, screen_recording = false, input_monitoring = nil, secure_input = false,
			bundle_id = "com.ergoptiplus.app" },
		bundle = BUNDLE,
	}
	local ports = {
		exec = function(executable, args, timeout_s, callback)
			local key = executable .. " " .. table.concat(args, " ")
			world.commands[#world.commands + 1] = { key = key, timeout = timeout_s }
			local scripted = world.outputs[key] or { 0, "" }
			callback(scripted[1], scripted[2], scripted[3])
		end,
		permission_facts = function() return world.facts end,
		running_bundle_path = function() return world.bundle end,
		input_monitoring_access = function(callback)
			world.access_reads = (world.access_reads or 0) + 1
			callback(world.access)
		end,
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
		assert(Engine.run("permissions", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("permissions probe", function()
	helpers.it("(input-monitoring-reader) reads Input Monitoring through the launcher role when Hammerspoon cannot", function()
		local ports, world = make_ports()
		for answer, value in pairs({ granted = "granted", denied = "missing", unknown = "unknown" }) do
			world.access = answer
			helpers.assert_eq(run(ports).input_monitoring.value, value)
		end
		world.access = nil
		helpers.assert_eq(run(ports).input_monitoring.value, "not_queryable", "an unreadable role stays named")
		local reads = world.access_reads
		world.facts.input_monitoring = true
		helpers.assert_eq(run(ports).input_monitoring.value, "granted")
		helpers.assert_eq(world.access_reads, reads, "a Hammerspoon answer needs no launcher read")
	end)

	helpers.it("passes with Accessibility, the declared bundle and a valid team signature", function()
		local ports = make_ports()
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.accessibility.value, "granted")
		helpers.assert_eq(steps.input_monitoring.value, "not_queryable")
		helpers.assert_eq(steps.screen_recording.state, "info")
		helpers.assert_eq(steps.screen_recording.value, "missing")
		helpers.assert_eq(steps.automation.state, "skip")
		helpers.assert_eq(steps.secure_input.value, "off")
		helpers.assert_eq(steps.bundle_id.value, "launcher")
		helpers.assert_eq(steps.app_signature.value, "valid")
		helpers.assert_eq(steps.signing_identity.value, "team:ABCDE12345")
	end)

	helpers.it("fails only the Accessibility step when it is missing or unreadable", function()
		local ports, world = make_ports()
		world.facts.accessibility = false
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.accessibility.state, "fail")
		helpers.assert_eq(steps.accessibility.value, "missing")
		helpers.assert_eq(steps.app_signature.state, "pass")
		world.facts.accessibility = nil
		steps = run(ports)
		helpers.assert_eq(steps.accessibility.state, "fail")
		helpers.assert_eq(steps.accessibility.value, "unreadable")
	end)

	helpers.it("fails a bundle identifier macOS files under another app", function()
		local ports, world = make_ports()
		world.facts.bundle_id = "org.hammerspoon.Hammerspoon"
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.bundle_id.value, "other")
		world.facts.bundle_id = "com.ergoptiplus.app.hammerspoon"
		helpers.assert_eq(run(ports).bundle_id.value, "hammerspoon")
	end)

	helpers.it("names a broken signature's cause and an ad hoc identity, never the path", function()
		local ports, world = make_ports()
		world.outputs[VERIFY] = { 1, "", BUNDLE .. ": a sealed resource is missing or invalid\n" }
		world.outputs[DESCRIBE] = { 0, "", "Identifier=com.ergoptiplus.app\nSignature=adhoc\nTeamIdentifier=not set\n" }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.app_signature.value, "exit_1:sealed_resource_invalid")
		helpers.assert_eq(steps.signing_identity.value, "adhoc")
		for _, step in pairs(steps) do
			helpers.assert_true(tostring(step.value):find("Users", 1, true) == nil, "a step carries the path")
		end
		world.outputs[VERIFY] = { nil, "" }
		helpers.assert_eq(run(ports).app_signature.value, "timeout")
	end)

	helpers.it("skips the signature steps without a bundle path", function()
		local ports, world = make_ports()
		world.bundle = nil
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.app_signature.state, "skip")
		helpers.assert_eq(steps.signing_identity.state, "skip")
		helpers.assert_eq(#world.commands, 0)
	end)

	helpers.it("reads every signing identity form", function()
		helpers.with_stub_scope(MODULES, function()
			package.loaded["infra.field_check_probes"] = nil
			local Probes = require("infra.field_check_probes")
			helpers.assert_eq(Probes.parse_signing_identity("TeamIdentifier=G43BCU2T37\n"), "team:G43BCU2T37")
			helpers.assert_eq(Probes.parse_signing_identity("x: code object is not signed at all\n"), "unsigned")
			helpers.assert_eq(Probes.parse_signing_identity("TeamIdentifier=not set\n"), "adhoc")
			helpers.assert_eq(Probes.parse_signing_identity(""), "unknown")
		end)
	end)
end)
