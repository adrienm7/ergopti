--- tests/unit/ui/healthcheck/test_healthcheck_local_state_probe.lua

--- ==============================================================================
--- MODULE: Diagnostics Local State Probe (macOS)
--- DESCRIPTION:
--- The synchronous diagnostics (phase A) took 90 to 150 ms on the Mac against
--- their 5 ms budget (field report 2026-10-31): the Wi-Fi signal
--- (hs.wifi.interfaceDetails, about 50 ms) and the module contract check
--- (requiring every adapter, 30 to 65 ms) ran inside it. They are now the
--- local_state probe's:
--- 1. phase A asks for no Wi-Fi signal and checks no adapter;
--- 2. the probe runs the steps in slices that each stop at the phase A budget,
---    on timers, and publishes the Wi-Fi signal and the module check;
--- 3. a raising step costs its own fact: the answer is an error that carries
---    the others;
--- 4. a report collected without a page (the field run) completes them after
---    phase A was measured, and the field run names phase A's cost and fails
---    over its budget (healthcheck-local-state).
--- ==============================================================================

local helpers = require("tests.helpers")

local SCHEMA = require("diagnostics.engine.healthcheck.snapshot").load_config(require("infra.paths").shared).schema

--- The real core over a counted network adapter.
--- @param body function(Core, world)
local function with_core(body)
	-- A case may script hs.usb; the shared hs stub outlives this module
	local saved_usb = hs.usb
	local ok, err = pcall(helpers.with_stub_scope, {
		"infra.logger", "adapters.network_info", "ui.healthcheck.core", "ui.healthcheck.helpers",
		"adapters.accessibility_permission", "adapters.screen_capture",
	}, function()
		helpers.load_with_stubs("infra.logger")
		local world = { signal_reads = 0, tcc_reads = {} }
		package.loaded["adapters.accessibility_permission"] = {
			is_trusted = function()
				world.tcc_reads[#world.tcc_reads + 1] = "accessibility"
				return true
			end,
		}
		package.loaded["adapters.screen_capture"] = {
			permission_state = function()
				world.tcc_reads[#world.tcc_reads + 1] = "screen_recording"
				return false
			end,
		}
		package.loaded["adapters.network_info"] = {
			getSsidHash = function() return nil end,
			getSignalStrength = function() world.signal_reads = world.signal_reads + 1; return 64 end,
			isInternetReachable = function() return true end,
			isVpnActive = function() return false end,
		}
		package.loaded["ui.healthcheck.helpers"] = nil
		package.loaded["ui.healthcheck.core"] = nil
		body(require("ui.healthcheck.core"), world)
	end)
	hs.usb = saved_usb
	if not ok then error(err, 0) end
end

--- The real probes over recorded timers and a scripted core; the monotonic
--- clock advances by each step's own cost.
--- @param step_costs table Milliseconds each scripted step holds.
--- @param failing integer|nil Index of a step that raises.
--- @return table world { timers, answers, ran, slices }
local function run_local_state(step_costs, failing)
	local world = { timers = {}, answers = {}, ran = 0, slices = 0 }
	local saved_absolute = hs.timer.absoluteTime
	local clock_ns = 0
	local ok, err = pcall(helpers.with_stub_scope, {
		"infra.logger", "ui.healthcheck.probes", "ui.healthcheck.core", "core.events.timer_scheduler",
	}, function()
		helpers.load_with_stubs("infra.logger")
		hs.timer.absoluteTime = function() return clock_ns end
		package.loaded["core.events.timer_scheduler"] = {
			after = function(delay, callback)
				local handle = { delay = delay, callback = callback }
				world.timers[#world.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle) handle.cancelled = true; return true end,
			onSettled = function() return true end,
		}
		package.loaded["ui.healthcheck.core"] = {
			local_state_steps = function()
				local sections = { network = {}, developer = { modules_ok = {}, modules_failed = {} } }
				local steps = {}
				for index, cost in ipairs(step_costs) do
					steps[index] = function()
						world.ran = world.ran + 1
						clock_ns = clock_ns + cost * 1e6
						if index == failing then error("step raised") end
						sections.developer.modules_ok[#sections.developer.modules_ok + 1] = "adapter_" .. index
					end
				end
				return steps, sections
			end,
		}
		package.loaded["ui.healthcheck.probes"] = nil
		local snapshot = { detailed = false, extensive = false, sections = { paths = {}, peripherals = { items = {} } } }
		require("ui.healthcheck.probes").start(SCHEMA, snapshot, function(id, result, sections)
			world.answers[id] = { result = result, sections = sections }
		end, { local_only = true, overrides = {} })
		-- Fires every slice the probe arms, in order; the timeouts stay armed
		local fired = 0
		while true do
			local next_timer = nil
			for _, handle in ipairs(world.timers) do
				if not handle.fired and not handle.cancelled
					and handle.delay < SCHEMA.probes.local_state.timeout_ms / 1000
					and handle.callback ~= nil and world.answers.local_state == nil then
					next_timer = handle
					break
				end
			end
			if not next_timer or world.answers.local_state then break end
			next_timer.fired = true
			fired = fired + 1
			if fired > 100 then error("the local_state probe never settled") end
			local before = world.ran
			pcall(next_timer.callback)
			if world.ran > before then world.slices = world.slices + 1 end
		end
	end)
	hs.timer.absoluteTime = saved_absolute
	if not ok then error(err, 0) end
	return world
end

helpers.describe("healthcheck (macOS): local_state probe (healthcheck-local-state)", function()
	helpers.it("phase A reads no Wi-Fi signal and checks no adapter (healthcheck-local-state)", function()
		with_core(function(Core, world)
			local snapshot = Core.run()
			helpers.assert_eq(world.signal_reads, 0, "phase A read the Wi-Fi signal on the run loop")
			helpers.assert_nil(snapshot.sections.developer.modules_ok, "phase A ran the module contract check")
			helpers.assert_nil(snapshot.sections.network.wifi_signal, "phase A filled the Wi-Fi signal")
			helpers.assert_eq(snapshot.probes.local_state.state, "pending", "the probe owns them")
			local undeclared = require("diagnostics.engine.healthcheck.snapshot").check_fields(snapshot, Core.config().schema)
			helpers.assert_eq(undeclared, {}, "phase A fields stay declared")
		end)
	end)

	helpers.it("the steps read the Wi-Fi signal and check every adapter (healthcheck-local-state)", function()
		with_core(function(Core, world)
			local steps, sections = Core.local_state_steps()
			for _, step in ipairs(steps) do step() end
			helpers.assert_eq(world.signal_reads, 1)
			helpers.assert_eq(sections.network.wifi_signal, "64%")
			helpers.assert_true(#sections.developer.modules_ok + #sections.developer.modules_failed
				== #steps - 4 - #sections.permissions.items,
				"one step per adapter, after the versions, input, USB, Wi-Fi and permission ones")
			helpers.assert_true(#steps > 10, "the adapter specs were enumerated")
		end)
	end)

	-- Field report 2026-11-03: phase A still took 21.5 ms against 5, of which
	-- the USB devices 7.2, the versions 5.9 and the keyboard state 5.2.
	helpers.it("phase A leaves the versions, the keyboard state and the USB devices to the steps (healthcheck-local-state)", function()
		with_core(function(Core)
			hs.usb = { attachedDevices = function() return { { productName = "USB Keyboard", vendorID = 1, productID = 2 } } end }
			local snapshot = Core.run()
			helpers.assert_nil(next(snapshot.sections.versions), "phase A collected the versions")
			helpers.assert_nil(next(snapshot.sections.input), "phase A read the keyboard state")
			helpers.assert_eq(snapshot.sections.peripherals.items, {}, "phase A listed the USB devices")
			for _, collector in ipairs(Core.last_phase_a().collectors) do
				helpers.assert_true(collector.name ~= "versions" and collector.name ~= "input"
					and collector.name ~= "peripherals", "phase A still runs " .. collector.name)
			end
			local completed = Core.run({ complete_local = true, configuration = {} })
			helpers.assert_true(completed.sections.versions.commit ~= nil, "the steps fill the versions")
			helpers.assert_true(completed.sections.input.shift ~= nil, "the steps fill the keyboard state")
			helpers.assert_eq(#completed.sections.peripherals.items, 1, "the steps list the USB devices")
			local undeclared = require("diagnostics.engine.healthcheck.snapshot").check_fields(completed, Core.config().schema)
			helpers.assert_eq(undeclared, {}, "the moved fields stay declared")
		end)
	end)

	-- Field report 2026-11-06: phase A took 10.2 ms against 5, of which the
	-- permissions 9.2: the Accessibility and Screen Recording queries are TCC
	-- calls into another process, not memory reads.
	helpers.it("phase A queries no TCC permission; the steps read them one per step (healthcheck-tcc-off-phase-a)", function()
		with_core(function(Core, world)
			local snapshot = Core.run()
			helpers.assert_eq(world.tcc_reads, {}, "phase A queried a TCC permission on the run loop")
			helpers.assert_eq(snapshot.sections.permissions.items, {}, "phase A reported a permission state")
			for _, collector in ipairs(Core.last_phase_a().collectors) do
				helpers.assert_true(collector.name ~= "permissions", "phase A still runs the permissions")
			end
			local steps = Core.local_state_steps(snapshot)
			for _, step in ipairs(steps) do
				local before = #world.tcc_reads
				step()
				helpers.assert_true(#world.tcc_reads - before <= 1, "one step queried more than one TCC permission")
			end
			helpers.assert_eq(#world.tcc_reads, 2, "the steps read Accessibility and Screen Recording once each")
			local completed = Core.run({ complete_local = true, configuration = {} })
			local states = {}
			for _, item in ipairs(completed.sections.permissions.items) do states[item.id] = item.state end
			helpers.assert_eq(states, { accessibility = "granted", input_monitoring = "unknown",
				login_items = "unknown", screen_recording = "missing" }, "the report reads every permission live")
			local ids = {}
			for _, item in ipairs(completed.sections.permissions.items) do ids[#ids + 1] = item.id end
			helpers.assert_eq(ids, { "accessibility", "input_monitoring", "login_items", "screen_recording" },
				"the schema's order is kept")
			local undeclared = require("diagnostics.engine.healthcheck.snapshot").check_fields(completed, Core.config().schema)
			helpers.assert_eq(undeclared, {}, "the moved fields stay declared")
		end)
	end)

	helpers.it("the USB step keeps the Bluetooth devices a faster probe already added (healthcheck-local-state)", function()
		with_core(function(Core)
			hs.usb = { attachedDevices = function() return { { productName = "USB Mouse", vendorID = 3, productID = 4 } } end }
			local bluetooth = { bus = "bluetooth", kind = "keyboard", vendor_id = "004c", product_id = "029c" }
			local snapshot = { detailed = false, sections = { peripherals = { items = { bluetooth } } } }
			local steps, sections = Core.local_state_steps(snapshot)
			for _, step in ipairs(steps) do pcall(step) end
			helpers.assert_eq(#sections.peripherals.items, 2)
			helpers.assert_eq(sections.peripherals.items[1].bus, "usb")
			helpers.assert_eq(sections.peripherals.items[2], bluetooth)
		end)
	end)

	helpers.it("a report without a page completes them after phase A (healthcheck-local-state)", function()
		with_core(function(Core, world)
			local snapshot = Core.run({ complete_local = true, configuration = {} })
			helpers.assert_eq(world.signal_reads, 1)
			helpers.assert_eq(snapshot.sections.network.wifi_signal, "64%")
			helpers.assert_true(type(snapshot.sections.developer.modules_ok) == "table")
			helpers.assert_eq(snapshot.probes.local_state.state, "ok")
			local phase_a = Core.last_phase_a()
			helpers.assert_eq(phase_a.budget_ms, SCHEMA.phase_a_budget_ms)
			helpers.assert_true(#phase_a.collectors > 5, "every collector's cost is kept")
		end)
	end)

	helpers.it("slices stop at the phase A budget and the answer carries the facts (healthcheck-local-state)", function()
		local budget = SCHEMA.phase_a_budget_ms
		-- Each step holds 40 % of the budget: three fit before a slice yields
		local cost = budget * 0.4
		local world = run_local_state({ cost, cost, cost, cost, cost, cost, cost })
		helpers.assert_eq(world.ran, 7)
		local answer = world.answers.local_state
		helpers.assert_true(answer ~= nil, "the probe answered")
		helpers.assert_eq(answer.result.state, "ok")
		helpers.assert_eq(#answer.sections.developer.modules_ok, 7)
		helpers.assert_eq(world.slices, 3, "seven steps of 0.4 budget run as three slices")
	end)

	helpers.it("a raising step costs its fact, not the others (healthcheck-local-state)", function()
		local world = run_local_state({ 1, 1, 1 }, 2)
		helpers.assert_eq(world.ran, 3)
		local answer = world.answers.local_state
		helpers.assert_eq(answer.result.state, "error")
		helpers.assert_true(tostring(answer.result.detail):find("step 2", 1, true) ~= nil)
		helpers.assert_eq(answer.sections.developer.modules_ok, { "adapter_1", "adapter_3" })
	end)

	helpers.it("the field run names phase A's cost and fails over its budget (healthcheck-local-state)", function()
		local Ports = require("adapters.field_run_ports")
		local issues = { warn_count = 2, err_count = 0 }
		local verdict, codes = Ports.diagnostics_codes(issues, { ms = 149.5, budget_ms = 5, collectors = {
			{ name = "paths", ms = 0.4 }, { name = "developer", ms = 64.8 }, { name = "network", ms = 52.7 },
		} })
		helpers.assert_eq(verdict, "fail")
		helpers.assert_eq(codes, { "warnings_2", "errors_0", "phase_a_ms_150", "phase_a_developer_64.8",
			"phase_a_network_52.7", "phase_a_paths_0.4", "fail_phase_a_budget" })
		verdict, codes = Ports.diagnostics_codes(issues, { ms = 3.2, budget_ms = 5, collectors = {} })
		helpers.assert_eq(verdict, "pass")
		helpers.assert_eq(codes, { "warnings_2", "errors_0", "phase_a_ms_3" })
		verdict = Ports.diagnostics_codes(issues, nil)
		helpers.assert_eq(verdict, "fail", "an unmeasured phase A is not a pass")
	end)
end)
