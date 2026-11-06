--- tests/unit/infra/field_check/test_field_check_checks.lua

--- ==============================================================================
--- MODULE: Field Check Definitions
--- DESCRIPTION:
--- The three one-click Mac checks over scripted ports:
--- 1. lease: a missing tool, a failed phase or guardian, lease failures and lost
---    key events each fail their own step and no other;
--- 2. owned_runtime: the dormant credit source fails when broken; whether the
---    raw stream owner is loaded and the install state are information only;
--- 3. key_accounting: Quartz presses against ledger credits, with the HS-274
---    double count named when the legacy ledger credits;
--- 4. every external command is read-only and bounded, and no step value can
---    carry a path.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "platform.remap.ke_paths",
	"platform.remap.lease_memory_snapshot" }

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
		swallowed_keys = function() return 0 end,
		deploy_facts = function() return nil end,
		count_keys = function(_, callback) callback({ tap_running = true, presses = 10 }) end,
		owned_readiness = function(callback)
			callback({ unpinned = 6, source = false, helper_present = false, active = 0 })
		end,
	}
	for name, value in pairs(overrides or {}) do ports[name] = value end
	return ports, world
end

--- Runs one definition and returns its steps keyed by id.
--- @param runtime string|nil Karabiner runtime to select first; nil keeps shared.
--- @param name string Definition name.
--- @param ports table Ports.
--- @return table steps, table result
local function run_on(runtime, name, ports)
	local steps, result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["platform.remap.ke_paths"] = nil
		if runtime then require("platform.remap.ke_paths").select_runtime(runtime) end
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run(name, ports, function(done) result = done end), "check did not start")
	end)
	steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

--- Runs one definition with the default (shared) runtime selected.
local function run(name, ports) return run_on(nil, name, ports) end

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
		helpers.assert_eq(steps.lease_failure_kinds.state, "info")
		helpers.assert_eq(steps.lease_failure_kinds.value, "pong:1+ready_timeout:2",
			"the field run names which lease answers timed out (117/140)")
	end)

	helpers.it("fails on a key consumed and never delivered (lease-swallowed-keys)", function()
		local ports, world = make_ports({ swallowed_keys = function() return 2 end })
		world.existing[CLI] = true
		world.outputs[CLI .. " --version"] = { 0, "16.0.0\n" }
		local steps, result = run("lease", ports)
		helpers.assert_eq(steps.swallowed_keys.state, "fail")
		helpers.assert_eq(steps.swallowed_keys.value, "2")
		helpers.assert_true(not result.passed, "a dropped letter the driver saw fails the lease check")
		helpers.assert_eq(steps.lease_failure_kinds.value, "none")
	end)

	helpers.it("names the last karabiner.json write, size and time (lease-deploy-write)", function()
		local ports, world = make_ports({ deploy_facts = function() return { bytes = 760832, write_ms = 41.6 } end })
		world.existing[CLI] = true
		local steps = run("lease", ports)
		helpers.assert_eq(steps.deploy_write_ms.state, "info")
		helpers.assert_eq(steps.deploy_write_ms.value, "42")
		helpers.assert_eq(steps.deploy_kb.value, "743")
		helpers.assert_eq(steps.deploy_fork_ms.value, "none", "a write without its fork share names none")
		-- (lease-deploy-fork-share) the part of the write an asynchronous
		-- publication could take off the main thread is named.
		local forked = make_ports({ deploy_facts = function()
			return { bytes = 760832, write_ms = 254.2, fork_ms = 181.6, forks = 1 }
		end })
		helpers.assert_eq(run("lease", forked).deploy_fork_ms.value, "182")
		local quiet = make_ports()
		helpers.assert_eq(run("lease", quiet).deploy_write_ms.value, "none", "no deploy this session is named")
	end)

	helpers.it("decides whether karabiner.json must shrink from its write time (lease-deploy-verdict)", function()
		local hold = require("infra.main_thread_hold").COUNT_MS
		local function verdict(write_ms)
			local ports, world = make_ports({ deploy_facts = function() return { bytes = 760832, write_ms = write_ms } end })
			world.existing[CLI] = true
			return run("lease", ports).deploy_write_verdict
		end
		local short = verdict(41.6)
		helpers.assert_eq(short.state, "pass")
		helpers.assert_eq(short.value, "keep")
		local long = verdict(hold)
		helpers.assert_eq(long.state, "fail")
		helpers.assert_eq(long.value, "shrink")
		local quiet = run("lease", make_ports()).deploy_write_verdict
		helpers.assert_eq(quiet.state, "info")
		helpers.assert_eq(quiet.value, "none")
	end)

	helpers.it("names the free memory, for the starvation hypothesis (lease-memory-free)", function()
		local ports, world = make_ports()
		world.existing[CLI] = true
		world.outputs[CLI .. " --version"] = { 0, "16.0.0\n" }
		world.outputs["/usr/bin/memory_pressure"] = { 0,
			"The system has 17179869184 (1048576 pages with a page size of 16384).\n"
				.. "Pages free: 12345\nSystem-wide memory free percentage: 37%\n" }
		local steps, result = run("lease", ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.memory_free_percent.state, "info")
		helpers.assert_eq(steps.memory_free_percent.value, "37")
		world.outputs["/usr/bin/memory_pressure"] = { nil, "" }
		helpers.assert_eq(run("lease", ports).memory_free_percent.value, "timeout")
		local no_cli = make_ports()
		helpers.assert_eq(run("lease", no_cli).memory_free_percent.state, "info",
			"the reading also runs when the command line tool is missing")
	end)

	-- Field run 2026-10-27 22:32: the check ran while this lifecycle's guardian
	-- registration was in flight and failed "unknown"; the answer was "ready".
	helpers.it("waits for the first guardian answer before judging it (lease-guardian-settle)", function()
		local reads, delays = 0, {}
		local ports, world = make_ports({
			remap_facts = function()
				reads = reads + 1
				return { enabled = true, phase = reads < 4 and "idle" or "ready", guardian = reads < 4 and "unknown" or "ready" }
			end,
			after = function(seconds, callback) delays[#delays + 1] = seconds; callback() end,
		})
		world.existing[CLI] = true
		world.outputs[CLI .. " --version"] = { 0, "16.0.0\n" }
		local steps, result = run("lease", ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.guardian_state.value, "ready")
		helpers.assert_eq(steps.lease_phase.value, "ready")
		helpers.assert_eq(steps.guardian_wait.state, "info")
		helpers.assert_eq(steps.guardian_wait.value, "1.5s")
		helpers.assert_eq(#delays, 3)
	end)

	helpers.it("fails a guardian still unknown after the bounded wait", function()
		local polls = 0
		local ports, world = make_ports({
			remap_facts = function() return { enabled = true, phase = "idle", guardian = "unknown" } end,
			after = function(_, callback) polls = polls + 1; callback() end,
		})
		world.existing[CLI] = true
		local steps = run("lease", ports)
		helpers.assert_eq(steps.guardian_state.state, "fail")
		helpers.assert_eq(steps.guardian_state.value, "unknown")
		helpers.assert_eq(steps.guardian_wait.value, "30.0s")
		helpers.assert_eq(polls, 60)
	end)

	-- Field report 2026-11-05: the lease ran before the owned runtime was
	-- admitted, waited 30 s for a guardian nobody registers and failed the tool,
	-- the guardian and the version the owned_* steps already reported missing.
	helpers.it("skips the steps an unadmitted owned runtime cannot answer (lease-owned-not-admitted)", function()
		local polls = 0
		local ports, world = make_ports({
			remap_facts = function()
				return { enabled = true, phase = "idle", guardian = "unknown", owned_admitted = false }
			end,
			after = function(_, callback) polls = polls + 1; callback() end,
		})
		local steps, result = run_on("owned", "lease", ports)
		helpers.assert_eq(polls, 0, "no guardian wait for an unadmitted owned runtime")
		helpers.assert_eq(steps.cli_present.state, "skip")
		helpers.assert_eq(steps.cli_present.value, "owned_runtime_not_admitted")
		helpers.assert_eq(steps.guardian_state.state, "skip")
		helpers.assert_eq(steps.guardian_state.value, "owned_runtime_not_admitted")
		helpers.assert_eq(steps.cli_version.state, "skip")
		helpers.assert_eq(steps.cli_version.value, "owned_runtime_not_admitted")
		helpers.assert_nil(steps.guardian_wait)
		helpers.assert_true(result.passed, "a runtime not yet admitted is not a broken lease")
		for _, command in ipairs(world.commands) do
			helpers.assert_true(command.executable ~= CLI, "no stock tool runs for the owned runtime")
		end
	end)

	helpers.it("reads the selected runtime's own configuration (lease-config-selected-runtime)", function()
		local ports, world = make_ports({
			remap_facts = function()
				return { enabled = true, phase = "ready", guardian = "ready", owned_admitted = true }
			end,
		})
		world.existing["/Users/jane/.config/karabiner/karabiner.json"] = true
		local steps = run_on("owned", "lease", ports)
		helpers.assert_eq(steps.config_present.value, "no", "the shared file says nothing of the owned runtime")
		world.existing["/Users/jane/Library/Application Support/"
			.. require("app_dirs").owned_runtime.macos_folder_name .. "/karabiner/karabiner.json"] = true
		helpers.assert_eq(run_on("owned", "lease", ports).config_present.value, "yes")
		helpers.assert_eq(run("lease", ports).config_present.value, "yes", "the shared runtime keeps its own file")
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
		world.outputs["/usr/bin/systemextensionsctl list"] = { 0, "*\t*\tG43BCU2T37\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0)\tdriver\t[activated enabled]\n" }
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

	helpers.it("reports the artifact pin, the installed source and what closing another Karabiner would meet", function()
		local ports = make_ports({ owned_readiness = function(callback)
			callback({ unpinned = 6, source = false, helper_present = true, active = 2 })
		end })
		local steps, result = run("owned_runtime", ports)
		helpers.assert_true(result.passed, "readiness facts are information, never a failure")
		helpers.assert_eq(steps.artifact_pin.value, "unpinned_6")
		helpers.assert_eq(steps.installed_source.value, "unavailable")
		helpers.assert_eq(steps.other_karabiner_helper.value, "yes")
		helpers.assert_eq(steps.other_karabiner_active.value, "2")
		for _, id in ipairs({ "artifact_pin", "installed_source", "other_karabiner_helper", "other_karabiner_active" }) do
			helpers.assert_eq(steps[id].state, "info", id)
		end
	end)

	helpers.it("names a pinned artifact, a reachable source and an unreadable process list", function()
		local ports = make_ports({ owned_readiness = function(callback)
			callback({ unpinned = 0, source = true, helper_present = false, active = nil })
		end })
		local steps = run("owned_runtime", ports)
		helpers.assert_eq(steps.artifact_pin.value, "pinned")
		helpers.assert_eq(steps.installed_source.value, "reachable")
		helpers.assert_eq(steps.other_karabiner_active.value, "unknown")
		local unreadable = run("owned_runtime", make_ports({ owned_readiness = function(callback)
			callback({ unpinned = nil, source = false, helper_present = false, active = 0 })
		end }))
		helpers.assert_eq(unreadable.artifact_pin.value, "unreadable")
	end)

	helpers.it("reports both owned jobs, the downloaded artifact and whether the launcher can install", function()
		-- WP9 reads the whole owned install from one field report: the VirtualHIDDevice
		-- job was never reported, and an ad hoc developer app cannot install at all.
		local ports, world = make_ports({ owned_readiness = function(callback)
			callback({ unpinned = 0, source = true, helper_present = false, active = 0,
				artifact = "fetched:16.3.0-ergopti.3", launcher_identity = "adhoc" })
		end })
		world.existing["/Library/LaunchDaemons/com.ergoptiplus.runtime.vhid.plist"] = true
		world.outputs["/bin/launchctl print system/com.ergoptiplus.runtime.core"] = { 0, "" }
		world.outputs["/bin/launchctl print system/com.ergoptiplus.runtime.vhid"] = { 113, "" }
		local steps, result = run("owned_runtime", ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.vhid_job_file.value, "yes")
		helpers.assert_eq(steps.job_loaded.value, "loaded")
		helpers.assert_eq(steps.vhid_job_loaded.value, "not_loaded")
		helpers.assert_eq(steps.artifact_receipt.value, "fetched:16.3.0-ergopti.3")
		helpers.assert_eq(steps.install_launcher.value, "refused:adhoc")
		local signed = run("owned_runtime", make_ports({ owned_readiness = function(callback)
			callback({ unpinned = 0, source = true, helper_present = false, active = 0, launcher_identity = "certificate" })
		end }))
		helpers.assert_eq(signed.install_launcher.value, "possible:certificate")
		helpers.assert_eq(signed.artifact_receipt.value, "unknown")
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

	-- Field report 2026-11-05: the owned runtime, now the default, loads the
	-- raw stream owner on every boot, so this step failed every owned run.
	helpers.it("reports a loaded raw stream owner as information (owned-capture-info)", function()
		local ports = make_ports({ keystats_facts = function()
			return { credit_source = "legacy", capture_loaded = true, ledger_drained = 0 }
		end })
		local steps = run("owned_runtime", ports)
		helpers.assert_eq(steps.capture_unloaded.state, "info")
		helpers.assert_eq(steps.capture_unloaded.value, "no")
	end)

	helpers.it("parses the driver listing", function()
		helpers.with_stub_scope(MODULES, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.field_check_checks"] = nil
			local Checks = require("infra.field_check_checks")
			helpers.assert_eq(Checks.parse_version("karabiner_cli 16.0.0 (x)"), "16.0.0")
		end)
	end)

	--- Runs the check over one driver listing and one pinned driver version.
	--- @param code integer|nil systemextensionsctl exit status.
	--- @param listing string Its output.
	--- @param pinned string|nil Manifest version of the driver.
	--- @return table steps
	local function driver_steps(code, listing, pinned)
		local ports, world = make_ports({ owned_readiness = function(callback)
			callback({ unpinned = 6, source = false, helper_present = false, active = 0, virtual_hid_version = pinned })
		end })
		world.outputs["/usr/bin/systemextensionsctl list"] = { code, listing }
		return (run("owned_runtime", ports))
	end

	local HEADER = "1 extension(s)\n--- com.apple.system_extension.driver_extension\n"
		.. "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n"
	local function line(flags, team, version, state)
		return flags .. "\t" .. team .. "\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice (" .. version .. "/" .. version
			.. ")\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice\t[" .. state .. "]\n"
	end

	-- (field-driver-owner-parser) The check once read the first listed copy with its
	-- own parser, so an older copy macOS keeps until reboot hid the active driver
	-- the owner's admission reads.
	helpers.it("reads the active driver the owner reads, not an older listed copy", function()
		local listing = HEADER .. line("\t", "G43BCU2T37", "5.0.0", "terminated waiting to uninstall on reboot")
			.. line("*\t*", "G43BCU2T37", "8.5.0", "activated enabled")
		local steps = driver_steps(0, listing, "8.5.0")
		helpers.assert_eq(steps.driver_state.value, "activated_enabled")
		helpers.assert_eq(steps.driver_verdict.value, "compatible")
		helpers.assert_eq(steps.driver_verdict.state, "info")
	end)

	helpers.it("names the owner's refusal of the installed driver", function()
		local function verdict(code, listing, pinned) return driver_steps(code, listing, pinned).driver_verdict.value end
		helpers.assert_eq(verdict(0, HEADER .. line("*\t*", "G43BCU2T37", "1.8.0", "activated enabled"), "8.5.0"),
			"virtual_hid_incompatible")
		helpers.assert_eq(verdict(0, HEADER .. line("*\t*", "ABCDEFGHIJ", "8.5.0", "activated enabled"), "8.5.0"),
			"virtual_hid_incompatible")
		helpers.assert_eq(verdict(0, HEADER .. line("*\t", "G43BCU2T37", "8.5.0", "activated waiting for user"), "8.5.0"),
			"virtual_hid_not_active")
		helpers.assert_eq(verdict(0, "0 extension(s)\n", "8.5.0"), "virtual_hid_absent")
		helpers.assert_eq(verdict(0, "garbage\n", "8.5.0"), "virtual_hid_unreadable")
		helpers.assert_eq(verdict(1, "", "8.5.0"), "unreadable")
		helpers.assert_eq(verdict(0, HEADER .. line("*\t*", "G43BCU2T37", "8.5.0", "activated enabled"), nil),
			"unpinned")
	end)

	helpers.it("reports the driver listing state in the owner's words", function()
		helpers.assert_eq(driver_steps(0, "0 extension(s)\n", "8.5.0").driver_state.value, "absent")
		helpers.assert_eq(driver_steps(0, "garbage\n", "8.5.0").driver_state.value, "unreadable")
		helpers.assert_eq(driver_steps(nil, "", "8.5.0").driver_state.value, "unreadable")
		helpers.assert_eq(driver_steps(0, HEADER .. line("*\t", "G43BCU2T37", "8.5.0", "activated waiting for user"),
			"8.5.0").driver_state.value, "activated_waiting_for_user")
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
			["/bin/launchctl print system/com.ergoptiplus.runtime.vhid"] = true,
			["/usr/bin/systemextensionsctl list"] = true,
			["/usr/bin/pgrep -f org.pqrs/Karabiner"] = true,
			["/usr/bin/pgrep -f ErgoptiPlus/Runtime"] = true,
			["/usr/bin/memory_pressure "] = true,
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
