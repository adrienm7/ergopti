--- tests/unit/diagnostics/engine/field_check/test_setup_check.lua

--- ==============================================================================
--- MODULE: Session Setup Check (Linux)
--- DESCRIPTION:
--- The field run's « setup » check, the collector's former probe steps read
--- from inside the daemon (diagnostics/engine/field_check/setup_check.lua):
--- 1. a set-up session passes every step, the two commands run one after
---    the other with their fixed argv;
--- 2. each refusal is a fail with its closed code: no write access to
---    /dev/uinput, no readable evdev node, the unit not enabled, no polkit
---    agent, a focus source that failed;
--- 3. what does not apply to the session is a skip: no compositor focus source
---    (X11, another desktop), no systemctl;
--- 4. the field run declares the step, its check and its title, and the
---    coverage decides physical_acceptance and wayland_focus by it.
--- ==============================================================================

local helpers = require("tests.helpers")

local Check = require("diagnostics.engine.field_check.setup_check")
local Report = require("diagnostics.engine.field_check.report")

--- Ports over a scripted session; each field of `world` overrides one fact.
local function ports(world)
	local calls = {}
	return {
		access = function(path, mode)
			table.insert(calls, mode .. ":" .. path)
			local answer = (world.access or {})[path]
			if answer == nil then return true end
			return false, answer
		end,
		list_dir = function() return world.nodes or { "by-id", "event0", "event3" } end,
		run = function(argv, timeout_ms, done)
			table.insert(calls, table.concat(argv, " "))
			helpers.assert_eq(timeout_ms, Check.COMMAND_TIMEOUT_MS)
			local answer = (world.exits or {})[argv[1]]
			if answer == "not_found" then return nil, "not_found" end
			if answer == "timeout" then done(nil, "timeout") else done(answer or 0) end
			return {}
		end,
		focus_status = function() return world.focus end,
	}, calls
end

--- Runs the check and returns its steps by id and the port calls.
local function run(world)
	local report = Report.new_report(Check.CHECK_ID)
	local finished = 0
	local scripted, calls = ports(world)
	Check.run(scripted, report, function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1, "the check finishes once")
	local result, by_id = report.result(), {}
	for _, step in ipairs(result.steps) do by_id[step.id] = step end
	return by_id, result, calls
end

helpers.describe("field run setup check (linux)", function()
	helpers.it("passes a set-up session and runs its two commands in turn (setup-check)", function()
		local steps, result, calls = run({ focus = "ready" })
		helpers.assert_true(result.passed)
		for _, id in ipairs({ "uinput_writable", "evdev_readable", "focus_listening", "unit_enabled", "polkit_agent" }) do
			helpers.assert_eq(steps[id].state, Report.STATE_PASS, id)
		end
		helpers.assert_eq(calls, { "W:/dev/uinput", "R:/dev/input/event0",
			"systemctl --user is-enabled --quiet " .. Check.UNIT, "pgrep -f " .. Check.POLKIT_PATTERN })
	end)

	helpers.it("fails each refusal with its closed code (setup-check)", function()
		local steps, result = run({ focus = "failed", access = { ["/dev/uinput"] = "EACCES",
			["/dev/input/event0"] = "EACCES", ["/dev/input/event3"] = "EACCES" }, exits = { systemctl = 1, pgrep = 1 } })
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.uinput_writable.value, "denied")
		helpers.assert_eq(steps.evdev_readable.value, "denied", "every node was tried")
		helpers.assert_eq(steps.focus_listening.value, "failed")
		helpers.assert_eq(steps.unit_enabled.value, "not_enabled")
		helpers.assert_eq(steps.polkit_agent.value, "not_running")
		steps = run({ nodes = { "mice" }, access = { ["/dev/uinput"] = "ENOENT" }, exits = { pgrep = "not_found",
			systemctl = "timeout" } })
		helpers.assert_eq(steps.uinput_writable.value, "missing")
		helpers.assert_eq(steps.evdev_readable.value, "no_device")
		helpers.assert_eq(steps.unit_enabled.value, "timeout")
		helpers.assert_eq(steps.polkit_agent.state, Report.STATE_FAIL, "without pgrep nothing proves an agent runs")
		helpers.assert_eq(steps.polkit_agent.value, "no_pgrep")
	end)

	helpers.it("skips what the session does not have (setup-check)", function()
		local steps, result = run({ focus = nil, exits = { systemctl = "not_found" } })
		helpers.assert_eq(steps.focus_listening.state, Report.STATE_SKIP)
		helpers.assert_eq(steps.focus_listening.value, "no_compositor_source")
		helpers.assert_eq(steps.unit_enabled.state, Report.STATE_SKIP)
		helpers.assert_eq(steps.unit_enabled.value, "no_systemd")
		helpers.assert_true(result.passed, "a skip is not a failure")
	end)

	helpers.it("is a field run step whose coverage decides two field points (setup-check)", function()
		local Json = require("core.text.engine.json")
		local root = helpers.driver_root() .. "/diagnostics/data/"
		local function read(name)
			local handle = assert(io.open(root .. name, "rb"))
			local text = handle:read("*a")
			handle:close()
			return Json.decode(text)
		end
		local FieldRun = require("diagnostics.engine.field_run.field_run")
		helpers.assert_eq(FieldRun.CHECK_RUNNERS.setup, "diagnostics.ui.field_check.setup_check")
		local runner = require(FieldRun.CHECK_RUNNERS.setup)
		helpers.assert_eq(runner.title_key, "field_check.setup.title")
		local declared = false
		for _, step in ipairs(read("field_run_steps.json").steps) do
			if step.id == "field_setup" then declared = step.kind == "field_check" and step.check == "setup" end
		end
		helpers.assert_true(declared, "the field run declares the setup step")
		local decided = {}
		for _, point in ipairs(read("field_todo_coverage.json").points) do
			for _, check in ipairs(point.checks or {}) do
				if check.step == "field_setup" then decided[point.id] = true end
			end
		end
		helpers.assert_true(decided.physical_acceptance and decided.wayland_focus)
		for _, step in ipairs(read("field_guided_steps.json").steps) do
			helpers.assert_true(step.mode ~= "probe" or not step.id:match("^linux_"),
				"the collector no longer probes what the daemon checks: " .. step.id)
		end
	end)
end)
