--- tests/unit/infra/field_check/test_field_check_toolchain.lua

--- ==============================================================================
--- MODULE: Field Check Toolchain Definition
--- DESCRIPTION:
--- The one-click third-party tools check over scripted ports:
--- 1. a late timer, a Shortcuts tool that cannot list, a missing shortcut that
---    is not refused (or that hangs), a Homebrew that does not answer and an
---    app whose code signature is broken each fail their own step only;
--- 2. a missing Homebrew or Shortcuts tool skips what depends on it and a
---    cask that is simply not installed is information, not a failure;
--- 3. every command is read-only and bounded, the missing shortcut name is the
---    fixed absent one, and no step value can carry a shortcut name or a path;
--- 4. a broken strict signature names codesign's first known cause and logs
---    its bounded diagnostic, and Gatekeeper's own assessment is its own step,
---    so a report shows whether the app is refused or only fails --strict
---    (field report of 2026-10-27 22:32, karabiner_signature fail:exit_1).
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "platform.remap.ke_paths" }

local SHORTCUTS = "/usr/bin/shortcuts"
local BREW = "/opt/homebrew/bin/brew"
local APP = "/Applications/Karabiner-Elements.app"
local CODESIGN = "/usr/bin/codesign --verify --deep --strict --verbose=4 " .. APP
local SPCTL = "/usr/sbin/spctl --assess -vv " .. APP

--- Builds scripted ports; `world` records every command.
--- @param overrides table|nil Fields replacing the defaults.
--- @return table ports, table world
local function make_ports(overrides)
	local world = { commands = {}, existing = {}, outputs = {}, late_ms = 4 }
	local ports = {
		path_exists = function(path) return world.existing[path] == true end,
		exec = function(executable, args, timeout_s, callback)
			world.commands[#world.commands + 1] = { executable = executable, args = args, timeout = timeout_s }
			local scripted = world.outputs[executable .. " " .. table.concat(args, " ")]
				or world.outputs[executable] or { 0, "" }
			callback(scripted[1], scripted[2], scripted[3])
		end,
		timer_probe = function(_, callback) callback(world.late_ms) end,
	}
	for name, value in pairs(overrides or {}) do ports[name] = value end
	return ports, world
end

--- Makes every tool present and healthy.
--- @param world table From make_ports.
local function healthy(world)
	world.existing[SHORTCUTS] = true
	world.existing[BREW] = true
	world.existing[APP] = true
	world.outputs[SHORTCUTS .. " list"] = { 0, "Morning\nNight\nWork\n" }
	world.outputs[SHORTCUTS .. " run ergopti-field-check-absent-shortcut"] = { 1, "" }
	world.outputs[BREW .. " --version"] = { 0, "Homebrew 4.6.3\n" }
	world.outputs[BREW .. " list --cask --versions karabiner-elements"] = { 0, "karabiner-elements 15.4.0\n" }
	world.outputs[CODESIGN] = { 0, "", APP .. ": valid on disk\n" .. APP .. ": satisfies its Designated Requirement\n" }
	world.outputs[SPCTL] = { 0, "", APP .. ": accepted\nsource=Notarized Developer ID\n"
		.. "origin=Developer ID Application: Fumihiko Takayama (G43BCU2T37)\n" }
end

--- Runs the toolchain check and returns its steps keyed by id.
--- @param ports table Ports.
--- @return table steps, table result
local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("toolchain", ports, function(done) result = done end), "check did not start")
	end)
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("toolchain check", function()
	helpers.it("passes when every tool answers as the driver assumes", function()
		local ports, world = make_ports()
		healthy(world)
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.timer_late_ms.value, "4")
		helpers.assert_eq(steps.shortcuts_list.value, "3")
		helpers.assert_eq(steps.shortcuts_refusal.value, "refused")
		helpers.assert_eq(steps.brew_version.value, "4.6.3")
		helpers.assert_eq(steps.karabiner_cask.value, "installed")
		helpers.assert_eq(steps.karabiner_signature.value, "valid")
		helpers.assert_eq(steps.karabiner_gatekeeper.value, "accepted:notarized_developer_id")
	end)

	helpers.it("fails only the timer step when the timer fires late", function()
		local ports, world = make_ports()
		healthy(world)
		world.late_ms = 900.7
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.timer_late_ms.state, "fail")
		helpers.assert_eq(steps.timer_late_ms.value, "900")
		helpers.assert_eq(steps.shortcuts_refusal.state, "pass")
	end)

	helpers.it("fails a missing shortcut that is not refused and one that hangs", function()
		local ports, world = make_ports()
		healthy(world)
		world.outputs[SHORTCUTS .. " run ergopti-field-check-absent-shortcut"] = { 0, "" }
		local steps = run(ports)
		helpers.assert_eq(steps.shortcuts_refusal.state, "fail")
		helpers.assert_eq(steps.shortcuts_refusal.value, "unexpected_success")
		world.outputs[SHORTCUTS .. " run ergopti-field-check-absent-shortcut"] = { nil, "" }
		steps = run(ports)
		helpers.assert_eq(steps.shortcuts_refusal.state, "fail")
		helpers.assert_eq(steps.shortcuts_refusal.value, "timeout")
	end)

	helpers.it("fails the Shortcuts tool that is absent and skips what needs it", function()
		local ports, world = make_ports()
		healthy(world)
		world.existing[SHORTCUTS] = nil
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.shortcuts_cli.state, "fail")
		helpers.assert_eq(steps.shortcuts_list.state, "skip")
		helpers.assert_eq(steps.shortcuts_refusal.state, "skip")
		helpers.assert_eq(steps.brew_version.state, "pass")
	end)

	helpers.it("names a Shortcuts listing that exits non-zero or times out", function()
		local ports, world = make_ports()
		healthy(world)
		world.outputs[SHORTCUTS .. " list"] = { 3, "" }
		helpers.assert_eq(run(ports).shortcuts_list.value, "exit_3")
		world.outputs[SHORTCUTS .. " list"] = { nil, "" }
		helpers.assert_eq(run(ports).shortcuts_list.value, "timeout")
	end)

	helpers.it("skips the Homebrew steps without Homebrew and still checks the signature", function()
		local ports, world = make_ports()
		healthy(world)
		world.existing[BREW] = nil
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.brew_present.value, "no")
		helpers.assert_eq(steps.brew_version.state, "skip")
		helpers.assert_eq(steps.karabiner_cask.state, "skip")
		helpers.assert_eq(steps.karabiner_signature.state, "pass")
	end)

	helpers.it("reads the Intel Homebrew location too", function()
		local ports, world = make_ports()
		healthy(world)
		world.existing[BREW] = nil
		world.existing["/usr/local/bin/brew"] = true
		world.outputs["/usr/local/bin/brew --version"] = { 0, "Homebrew 4.5.0\n" }
		world.outputs["/usr/local/bin/brew list --cask --versions karabiner-elements"] = { 1, "" }
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.brew_version.value, "4.5.0")
		helpers.assert_eq(steps.karabiner_cask.state, "info")
		helpers.assert_eq(steps.karabiner_cask.value, "absent")
	end)

	helpers.it("fails a Homebrew that does not answer and a broken signature", function()
		local ports, world = make_ports()
		healthy(world)
		world.outputs[BREW .. " --version"] = { nil, "" }
		world.outputs[BREW .. " list --cask --versions karabiner-elements"] = { nil, "" }
		world.outputs[CODESIGN] = { 1, "", "" }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.brew_version.value, "timeout")
		helpers.assert_eq(steps.karabiner_cask.state, "fail")
		helpers.assert_eq(steps.karabiner_signature.value, "exit_1:unclassified")
	end)

	helpers.it("skips the signature of an app that is not installed", function()
		local ports, world = make_ports()
		healthy(world)
		world.existing[APP] = nil
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.karabiner_signature.state, "skip")
		helpers.assert_eq(steps.karabiner_signature.value, "not_installed")
	end)

	helpers.it("only reads: every command is bounded and none installs, runs or edits", function()
		local ports, world = make_ports()
		healthy(world)
		run(ports)
		-- shortcuts list and run, brew --version and list, codesign, spctl: the
		-- timer step is a port of its own, not a command.
		helpers.assert_eq(#world.commands, 6, "the healthy check runs each of its six commands")
		local forbidden = { install = true, uninstall = true, upgrade = true, update = true, ["-f"] = true, edit = true }
		for _, command in ipairs(world.commands) do
			helpers.assert_true(type(command.timeout) == "number" and command.timeout > 0 and command.timeout <= 20,
				"unbounded command " .. command.executable)
			for _, argument in ipairs(command.args) do
				helpers.assert_true(not forbidden[argument], "mutating argument " .. argument)
			end
			if command.executable == SHORTCUTS and command.args[1] == "run" then
				helpers.assert_eq(command.args[2], "ergopti-field-check-absent-shortcut")
			end
		end
	end)

	helpers.it("names the strict signature's cause and logs codesign's diagnostic", function()
		local ports, world = make_ports()
		healthy(world)
		world.outputs[CODESIGN] = { 1, "", APP .. ": a sealed resource is missing or invalid\n"
			.. "file modified: " .. APP .. "/Contents/Resources/en.lproj/Localizable.strings\n" }
		local logged = {}
		local steps, result
		helpers.with_stub_scope({ "infra.logger" }, function()
			local logger = helpers.make_logger_stub()
			logger.evidence = function(_, format, ...) logged[#logged + 1] = string.format(format, ...) end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.field_check_checks"] = nil
			package.loaded["infra.field_check"] = nil
			local Engine = require("infra.field_check")
			assert(Engine.run("toolchain", ports, function(done) result = done end), "check did not start")
			package.loaded["infra.field_check_checks"] = nil
			package.loaded["infra.field_check"] = nil
		end)
		steps = {}
		for _, step in ipairs(result.steps) do steps[step.id] = step end
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.karabiner_signature.state, "fail")
		helpers.assert_eq(steps.karabiner_signature.value, "exit_1:sealed_resource_invalid")
		helpers.assert_eq(steps.karabiner_gatekeeper.state, "pass", "Gatekeeper's answer is reported on its own")
		local verification
		for _, line in ipairs(logged) do
			if line:find("strict signature verification", 1, true) then verification = line end
		end
		helpers.assert_eq(verification, "Karabiner-Elements strict signature verification: exit=1, "
			.. "<app>: a sealed resource is missing or invalid | "
			.. "file modified: <app>/Contents/Resources/en.lproj/Localizable.strings")
	end)

	helpers.it("fails a Gatekeeper rejection with its cause", function()
		local ports, world = make_ports()
		healthy(world)
		world.outputs[SPCTL] = { 3, "", APP .. ": rejected\nsource=Unnotarized Developer ID\n" }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.karabiner_gatekeeper.state, "fail")
		helpers.assert_eq(steps.karabiner_gatekeeper.value, "rejected:unnotarized_developer_id")
		world.outputs[SPCTL] = { 3, "", APP .. ": code or signature have been modified\n" }
		helpers.assert_eq(run(ports).karabiner_gatekeeper.value, "rejected:signature_modified")
		world.outputs[SPCTL] = { nil, "", "" }
		helpers.assert_eq(run(ports).karabiner_gatekeeper.value, "timeout")
	end)

	helpers.it("bounds a long diagnostic in the log", function()
		local Checks
		helpers.with_stub_scope(MODULES, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.field_check_checks"] = nil
			Checks = require("infra.field_check_checks")
		end)
		local many = {}
		for index = 1, 40 do many[#many + 1] = "file added: " .. APP .. "/x" .. index .. string.rep("y", 300) end
		local excerpt = Checks.diagnostic_excerpt(table.concat(many, "\n"), APP)
		local _, separators = excerpt:gsub(" | ", "")
		helpers.assert_eq(separators, Checks.DIAGNOSTIC_MAX_LINES, "the lines past the bound become one ellipsis")
		helpers.assert_true(#excerpt < (Checks.DIAGNOSTIC_MAX_LINE_CHARS + 8) * (Checks.DIAGNOSTIC_MAX_LINES + 1))
		helpers.assert_eq(excerpt:find(APP, 1, true), nil, "the app path is shortened")
	end)
end)
