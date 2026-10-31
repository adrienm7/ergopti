--- tests/unit/infra/field_check/test_field_check_pac_fallback.lua

--- ==============================================================================
--- MODULE: Field Check, PAC Direct Fallback
--- DESCRIPTION:
--- The field run's reading of the PAC-then-direct lines: the awk pass counts
--- the three shapes every writer prints, a fallback without an outcome or with
--- a stage outside the shared policy fails, and a PAC that works is information.
--- ==============================================================================

local helpers = require("tests.helpers")
local Report = require("field_check_report")
local PacFallback = require("infra.field_check_pac_fallback")
local Checks = require("infra.field_check_checks")

local function steps_of(report)
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps
end

local function listed(stage) return stage == "native_pac_download" or stage == "native_pac_evaluation" end

local TIMEOUT = {}

local function run(output, code)
	local report = Report.new_report("pac_fallback")
	PacFallback.pac_fallback({
		today_log_path = function() return "/logs/today.log" end,
		is_pac_fallback_stage = listed,
		exec = function(executable, args, _, callback)
			helpers.assert_eq(executable, "/usr/bin/awk")
			helpers.assert_eq(args[2], "/logs/today.log")
			if code == TIMEOUT then callback(nil, output) else callback(code or 0, output) end
		end,
	}, report, function() end)
	return steps_of(report)
end

helpers.describe("Field check: PAC direct fallback", function()
	helpers.it("is a field-run check of data/field_run.json", function()
		helpers.assert_eq(Checks.checks.pac_fallback, PacFallback.pac_fallback)
		local handle = assert(io.open(helpers.driver_root() .. "/data/field_run.json", "rb"))
		local text = handle:read("*a")
		handle:close()
		helpers.assert_true(text:find('"check": "pac_fallback"', 1, true) ~= nil,
			"the field run must ask for the pac_fallback check")
	end)

	helpers.it("a fallback whose direct try worked passes and names its stage", function()
		local steps = run("warning native_pac_download 2\nworked native_pac_download 1\nfailed native_pac_download 1\n"
			.. "totals 2 1 1\n")
		helpers.assert_eq(steps.pac_fallback_log.state, Report.STATE_PASS)
		helpers.assert_eq(steps.pac_fallback_stages.value, "native_pac_download")
		helpers.assert_eq(steps.pac_fallback_counts.value, "2:1:1")
		helpers.assert_eq(steps.pac_fallback_outcome.state, Report.STATE_PASS)
		helpers.assert_eq(steps.pac_fallback_outcome.value, "direct_worked")
	end)

	helpers.it("no fallback is information, a missing outcome or a failed direct try fails", function()
		local quiet = run("totals 0 0 0\n")
		helpers.assert_eq(quiet.pac_fallback_outcome.state, Report.STATE_INFO)
		helpers.assert_eq(quiet.pac_fallback_outcome.value, "no_pac_failure")
		local silent = run("warning native_pac_evaluation 1\ntotals 1 0 0\n")
		helpers.assert_eq(silent.pac_fallback_outcome.state, Report.STATE_FAIL)
		helpers.assert_eq(silent.pac_fallback_outcome.value, "no_outcome")
		local failed = run("warning native_pac_evaluation 1\nfailed native_pac_evaluation 1\ntotals 1 0 1\n")
		helpers.assert_eq(failed.pac_fallback_outcome.value, "direct_failed")
		local unlisted = run("warning native_route_refused 1\nworked native_route_refused 1\ntotals 1 1 0\n")
		helpers.assert_eq(unlisted.pac_fallback_outcome.state, Report.STATE_FAIL)
		helpers.assert_eq(unlisted.pac_fallback_outcome.value, "unlisted_stage:native_route_refused")
	end)

	helpers.it("an unreadable log or summary fails by name", function()
		helpers.assert_eq(run("", TIMEOUT).pac_fallback_log.value, "timeout")
		helpers.assert_eq(run("garbage\n", 0).pac_fallback_log.value, "unreadable")
		local report = Report.new_report("pac_fallback")
		PacFallback.pac_fallback({ today_log_path = function() return nil end }, report, function() end)
		helpers.assert_eq(steps_of(report).pac_fallback_log.value, "no_log")
	end)

	helpers.it("the awk program reads the lines of the shell, Swift, Python and Lua writers", function()
		local awk = io.open("/usr/bin/awk", "rb")
		if not awk then return end
		awk:close()
		local base = os.tmpname()
		local log, program = base .. ".log", base .. ".awk"
		local function write(path, text)
			local handle = assert(io.open(path, "wb"))
			handle:write(text)
			handle:close()
		end
		write(program, PacFallback.PAC_FALLBACK_AWK)
		write(log, table.concat({
			"10:00 [INFO] ollama_deps: [OLLAMA-DEPS] WARNING: The automatic network configuration could not be used"
				.. " (native_pac_download). Trying a direct connection.",
			"10:01 [INFO] models_manager_ollama: The direct connection worked after the automatic network configuration"
				.. " failed (native_pac_download).",
			"10:02 [WARN] mlx_deps: WARNING: The automatic network configuration could not be used (native_pac_evaluation)."
				.. " Trying a direct connection.",
			"10:03 [ERROR] mlx_deps: The automatic network configuration was unreachable (native_pac_evaluation) and the"
				.. " direct connection failed (code 7).",
			"10:04 [INFO] network: route_lookup info direct_pac_download",
		}, "\n") .. "\n")
		local pipe = assert(io.popen("/usr/bin/awk -f '" .. program .. "' '" .. log .. "'"))
		local output = pipe:read("*a")
		pipe:close()
		os.remove(log)
		os.remove(program)
		os.remove(base)
		local summary = assert(PacFallback.parse_summary(output), "the awk summary does not parse: " .. output)
		helpers.assert_eq(summary.warnings, 2)
		helpers.assert_eq(summary.worked, 1)
		helpers.assert_eq(summary.failed, 1)
		helpers.assert_true(summary.stages.native_pac_download and summary.stages.native_pac_evaluation,
			"both stages are named")
		local state, value = PacFallback.verdict(summary, listed)
		helpers.assert_eq(state, Report.STATE_PASS)
		helpers.assert_eq(value, "direct_worked")
	end)
end)
