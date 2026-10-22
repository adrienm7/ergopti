--- tests/meta/boot/test_instance_admission_wired_first.lua

--- ==============================================================================
--- MODULE: Instance Admission Root Wiring
--- DESCRIPTION:
--- Root boot cannot be loaded headlessly, so this guard reads init.lua. The
--- stray runtime of 2026-10-22 resolved its paths, wrote paths.toml into the
--- signed bundle and armed the KC ledger timer before it learnt it had no
--- launcher (hs-second-instance-2026-10-22); every later fatal abort also
--- showed its modal dialog with those producers still running
--- (hs-fatal-dialog-after-producers-2026-10-22).
--- ==============================================================================

local helpers = require("tests.helpers")

local function init_code()
	local source = helpers.read_driver_unit("local function abort_pre_runtime_boot")
	helpers.assert_true(type(source) == "string" and source ~= "", "root init.lua must be discoverable")
	return (source:gsub("%-%-[^\n]*", ""))
end

helpers.describe("init: instance admission runs before any side effect (hs-second-instance-2026-10-22)", function()
	helpers.it("decides admission after privacy and before settings writes, paths, timers and modules", function()
		local code = init_code()
		local privacy_at = code:find("Logger.initialize_privacy(raw)", 1, true)
		local decide_at = code:find("InstanceAdmission.decide(admission_mode, packaged_runtime)", 1, true)
		helpers.assert_true(privacy_at ~= nil and decide_at ~= nil, "privacy and admission must be locatable")
		helpers.assert_true(privacy_at < decide_at, "no line may be logged before privacy admission")
		for _, later in ipairs({
			"Storage.migrate_legacy_namespace()",
			'require("adapters.timer_scheduler")\n',
			"config_paths.init(base_dir)",
			'require("modules.gestures")',
			"Storage.set(",
		}) do
			local at = code:find(later, 1, true)
			helpers.assert_true(at ~= nil and decide_at < at,
				"admission must precede " .. later:gsub("\n", ""))
		end
	end)

	helpers.it("exits only in the stray branch and never shows it a dialog", function()
		local code = init_code()
		local decide_at = assert(code:find("InstanceAdmission.decide(", 1, true))
		local storage_at = assert(code:find('local TimerScheduler     = require("adapters.timer_scheduler")', decide_at, true))
		local block = code:sub(decide_at, storage_at)
		local may_exit_at = block:find("InstanceAdmission.may_exit_process(decision)", 1, true)
		local cancel_at = block:find(".cancelAll()", 1, true)
		local exit_at = block:find("os.exit(0)", 1, true)
		local dialog_at = block:find("hs.dialog.blockAlert", 1, true)
		helpers.assert_true(may_exit_at ~= nil and cancel_at ~= nil and exit_at ~= nil and dialog_at ~= nil)
		helpers.assert_true(cancel_at < exit_at and cancel_at < dialog_at,
			"timers stop before the refusal can exit or block")
		helpers.assert_true(may_exit_at < exit_at and exit_at < dialog_at,
			"the stray branch exits before the foreign branch's dialog")
		local _, exits = block:gsub("os%.exit%(", "")
		helpers.assert_eq(exits, 1, "the foreign Hammerspoon branch must not exit the user's application")
		helpers.assert_true(block:find("InstanceAdmission.shows_dialog(decision)", 1, true) ~= nil,
			"the dialog is gated by the admission policy")
	end)
end)

helpers.describe("init: a fatal abort stops producers first (hs-fatal-dialog-after-producers-2026-10-22)", function()
	helpers.it("cancels every timer and the KC bridge before the dialog and the exit", function()
		local code = init_code()
		local abort_at = assert(code:find("local function abort_pre_runtime_boot(", 1, true))
		local stop = assert(code:find("\nend\n", abort_at, true))
		local body = code:sub(abort_at, stop)
		local report_at = body:find("BootFatal.report(stage, detail, message)", 1, true)
		local cancel_at = body:find("TimerScheduler.cancelAll()", 1, true)
		local bridge_at = body:find('package.loaded["modules.keylogger.kc_bridge"]', 1, true)
		local dialog_at = body:find("show_blocking_fatal_dialog(message, stage)", 1, true)
		local exit_at = body:find("os.exit(1)", 1, true)
		helpers.assert_true(report_at and cancel_at and bridge_at and dialog_at and exit_at)
		helpers.assert_true(report_at < cancel_at,
			"the durable report is written first: it is what the launcher shows")
		helpers.assert_true(cancel_at < dialog_at and bridge_at < dialog_at and dialog_at < exit_at,
			"a modal dialog keeps the run loop turning; producers must be stopped before it")
	end)
end)
