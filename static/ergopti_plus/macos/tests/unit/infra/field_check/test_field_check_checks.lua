--- tests/unit/infra/field_check/test_field_check_checks.lua

--- ==============================================================================
--- MODULE: Field Check Definitions
--- DESCRIPTION:
--- The three one-click Mac checks over scripted ports:
--- 1. lease: a missing tool, a failed phase or guardian, lease failures and lost
---    key events each fail their own step and no other;
--- 2. owned_runtime: the dormant invariants (legacy source, raw stream not
---    loaded) fail when broken, and the install state is information only;
--- 3. key_accounting: Quartz presses against ledger credits, with the HS-274
---    double count named when the legacy ledger credits;
--- 4. every external command is read-only and bounded, and no step value can
---    carry a path.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "platform.remap.ke_paths" }

--- Builds scripted ports; `world` records every command.
--- @param overrides table|nil Fields replacing the defaults.
--- @return table ports, table world
local function make_ports(overrides)
	local world = { commands = {}, existing = {}, outputs = {} }
	local ports = {
		path_exists = function(path) return world.existing[path] == true end,
		exec = function(executable, args, timeout_s, callback)
			world.commands[#world.commands + 1] = { executable = executable, args = args, timeout = timeout_s }
			local scripted = world.outputs[executable .. " " .. table.concat(args, " ")]
				or world.outputs[executable] or { 0, "" }
			callback(scripted[1], scripted[2])
		end,
		home = function() return "/Users/jane" end,
		remap_facts = function() return { enabled = true, phase = "ready", guardian = "ready" } end,
		keystats_facts = function()
			return { credit_source = "legacy", capture_loaded = false, ledger_drained = 0 }
		end,
		health_counts = function() return { lease = {}, ups_without_down = 0, downs_without_up = 0, stuck = 0 } end,
		count_keys = function(_, callback) callback({ tap_running = true, presses = 10 }) end,
	}
	for name, value in pairs(overrides or {}) do ports[name] = value end
	return ports, world
end

--- Runs one definition and returns its steps keyed by id.
--- @param name string Definition name.
--- @param ports table Ports.
--- @return table steps, table result
local function run(name, ports)
	local steps, result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run(name, ports, function(done) result = done end), "check did not start")
	end)
	steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

local CLI = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

helpers.describe("lease check", function()
	helpers.it("passes on a healthy lease", function()
		local ports, world = make_ports()
		world.existing[CLI] = true
		world.outputs[CLI .. " --version"] = { 0, "16.0.0\n" }
		local steps, result = run("lease", ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.cli_version.value, "16.0.0")
		helpers.assert_eq(steps.lease_phase.value, "ready")
		helpers.assert_eq(steps.config_present.value, "no")
	end)

	helpers.it("fails the tool step only when the integration needs it", function()
		local ports = make_ports({ remap_facts = function() return { enabled = false, phase = "idle", guardian = "not_used" } end })
		local steps = run("lease", ports)
		helpers.assert_eq(steps.cli_present.state, "pass")
		helpers.assert_eq(steps.lease_phase.state, "skip")
		helpers.assert_eq(steps.cli_version.state, "skip")
		local needy = make_ports()
		helpers.assert_eq(run("lease", needy).cli_present.state, "fail")
	end)

	helpers.it("fails a recovering lease and an unapproved guardian separately", function()
		local ports, world = make_ports({ remap_facts = function()
			return { enabled = true, phase = "recovering", guardian = "requires_approval" }
		end })
		world.existing[CLI] = true
		local steps = run("lease", ports)
		helpers.assert_eq(steps.lease_phase.state, "fail")
		helpers.assert_eq(steps.guardian_state.state, "fail")
		helpers.assert_eq(steps.guardian_state.value, "requires_approval")
	end)

	helpers.it("counts lease failures and lost key events", function()
		local ports, world = make_ports({ health_counts = function()
			return { lease = { ready_timeout = 2, pong = 1 }, ups_without_down = 1, downs_without_up = 0, stuck = 2 }
		end })
		world.existing[CLI] = true
		local steps = run("lease", ports)
		helpers.assert_eq(steps.lease_failures.state, "fail")
		helpers.assert_eq(steps.lease_failures.value, "3")
		helpers.assert_eq(steps.key_losses.value, "3")
	end)

	helpers.it("reports a command timeout instead of waiting", function()
		local ports, world = make_ports()
		world.existing[CLI] = true
		world.outputs[CLI .. " --version"] = { nil, "" }
		local steps = run("lease", ports)
		helpers.assert_eq(steps.cli_version.state, "fail")
		helpers.assert_eq(steps.cli_version.value, "timeout")
	end)
end)

helpers.describe("owned runtime check", function()
	helpers.it("passes while dormant and reports the install state as information", function()
		local ports, world = make_ports()
		world.outputs["/bin/launchctl print system/com.ergoptiplus.runtime.core"] = { 113, "" }
		world.outputs["/usr/sbin/systemextensionsctl list"] = { 0, "*\t*\tG43BCU2T37\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0)\tdriver\t[activated enabled]\n" }
		world.outputs["/usr/bin/pgrep -f org.pqrs/Karabiner"] = { 0, "101\n102\n" }
		world.outputs["/usr/bin/pgrep -f ErgoptiPlus/Runtime"] = { 1, "" }
		local steps, result = run("owned_runtime", ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.job_loaded.value, "not_loaded")
		helpers.assert_eq(steps.driver_state.value, "activated_enabled")
		helpers.assert_eq(steps.stock_running.value, "2")
		helpers.assert_eq(steps.owned_running.value, "0")
		helpers.assert_eq(steps.runtime_installed.state, "info")
	end)

	helpers.it("fails when the stream source is selected at default startup", function()
		local ports = make_ports({ keystats_facts = function()
			return { credit_source = "gap", capture_loaded = false, ledger_drained = 0 }
		end })
		local steps, result = run("owned_runtime", ports)
		helpers.assert_eq(result.passed, false)
		helpers.assert_eq(steps.dormant_source.state, "fail")
		helpers.assert_eq(steps.dormant_source.value, "gap")
	end)

	helpers.it("fails when the raw stream owner was loaded", function()
		local ports = make_ports({ keystats_facts = function()
			return { credit_source = "legacy", capture_loaded = true, ledger_drained = 0 }
		end })
		helpers.assert_eq(run("owned_runtime", ports).capture_unloaded.state, "fail")
	end)

	helpers.it("parses the driver listing", function()
		helpers.with_stub_scope(MODULES, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.field_check_checks"] = nil
			local Checks = require("infra.field_check_checks")
			helpers.assert_eq(Checks.parse_driver_state("nothing here\n"), "absent")
			helpers.assert_eq(Checks.parse_driver_state("x org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1/1) [activated waiting for user]"),
				"activated_waiting_for_user")
			helpers.assert_eq(Checks.parse_driver_state("org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"), "unknown")
			helpers.assert_eq(Checks.parse_version("karabiner_cli 16.0.0 (x)"), "16.0.0")
		end)
	end)
end)

helpers.describe("key accounting check", function()
	local function facts(source, drained)
		return function() return { credit_source = source, capture_loaded = false, ledger_drained = drained } end
	end

	helpers.it("names the double count when the legacy ledger credits", function()
		local drained = 0
		local ports = make_ports({
			keystats_facts = function() return { credit_source = "legacy", capture_loaded = false, ledger_drained = drained } end,
			count_keys = function(seconds, callback)
				helpers.assert_eq(seconds, 30)
				drained = 4
				callback({ tap_running = true, presses = 12 })
			end,
		})
		local steps, result = run("key_accounting", ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.presses_seen.value, "12")
		helpers.assert_eq(steps.ledger_credits.value, "4")
		helpers.assert_eq(steps.double_count.value, "suspected")
	end)

	helpers.it("sees no double count without ledger credits, nor under the stream", function()
		helpers.assert_eq(run("key_accounting", make_ports({ keystats_facts = facts("legacy", 5) })).double_count.value, "none")
		helpers.assert_eq(run("key_accounting", make_ports({ keystats_facts = facts("stream", 5) })).double_count.value, "stream_only")
	end)

	helpers.it("fails when the tap is down or no key was typed", function()
		local ports = make_ports({ count_keys = function(_, callback) callback({ tap_running = false, presses = 0 }) end })
		local steps, result = run("key_accounting", ports)
		helpers.assert_eq(result.passed, false)
		helpers.assert_eq(steps.tap_running.state, "fail")
		helpers.assert_eq(steps.presses_seen.state, "fail")
	end)
end)

helpers.describe("field check commands are read-only", function()
	helpers.it("runs only the allowed executables, with a bounded timeout", function()
		local ports, world = make_ports()
		world.existing[CLI] = true
		run("lease", ports)
		run("owned_runtime", ports)
		local allowed = {
			[CLI .. " --version"] = true,
			["/bin/launchctl print system/com.ergoptiplus.runtime.core"] = true,
			["/usr/sbin/systemextensionsctl list"] = true,
			["/usr/bin/pgrep -f org.pqrs/Karabiner"] = true,
			["/usr/bin/pgrep -f ErgoptiPlus/Runtime"] = true,
		}
		helpers.assert_true(#world.commands >= 5)
		for _, command in ipairs(world.commands) do
			local line = command.executable .. " " .. table.concat(command.args, " ")
			helpers.assert_true(allowed[line], "unexpected command: " .. line)
			helpers.assert_true(command.timeout > 0 and command.timeout <= 10)
		end
	end)

	helpers.it("keeps every step value free of a path", function()
		local ports, world = make_ports()
		world.existing[CLI] = true
		world.outputs[CLI .. " --version"] = { 0, "/Users/jane/karabiner_cli 16.0.0" }
		local _, result = run("lease", ports)
		for _, step in ipairs(result.steps) do
			helpers.assert_eq(tostring(step.value):find("/", 1, true), nil, step.id)
		end
	end)
end)
