--- tests/meta/test_fatal_exit_reported_before_exit.lua

--- ==============================================================================
--- MODULE: Every fatal exit is reported before os.exit (silent-boot-abort)
--- DESCRIPTION:
--- Hammerspoon reports exit status 0 even after Lua calls os.exit(n), and a
--- Logger line queued for the native worker dies with the process. Release
--- v0.0.0-dev.128 therefore failed after the logger handshake with no dialog and
--- no log. Root boot cannot be loaded headlessly, so this guard reads init.lua:
--- every fatal boundary must hand a named stage to the durable reporter before
--- the process can exit.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Returns the root boot source, failing loudly when it cannot be found.
local function init_source()
	local source = helpers.read_driver_unit("local function abort_pre_runtime_boot")
	helpers.assert_true(type(source) == "string" and source ~= "",
		"root init.lua must remain discoverable by its pre-runtime abort boundary")
	return source
end

--- Returns the body of one local function up to the next top-level declaration.
local function function_body(source, header)
	local at = source:find(header, 1, true)
	helpers.assert_true(at ~= nil, "missing function: " .. header)
	local stop = source:find("\nend\n", at, true)
	helpers.assert_true(stop ~= nil, "unterminated function: " .. header)
	return source:sub(at, stop)
end

helpers.describe("fatal exits are reported before exit (silent-boot-abort)", function()
	helpers.it("pre-runtime aborts report durably before the process exits", function()
		local body = function_body(init_source(), "local function abort_pre_runtime_boot(")
		local report_at = body:find("BootFatal.report(stage, detail, message)", 1, true)
		local exit_at = body:find("os.exit(1)", 1, true)
		helpers.assert_true(report_at ~= nil and exit_at ~= nil and report_at < exit_at,
			"the durable report must precede os.exit")
		helpers.assert_true(body:find("alert.show", 1, true) == nil,
			"a transient alert is killed by os.exit and must not be the visible surface")
	end)

	helpers.it("runtime and post-onboarding failures report before the bounded exit", function()
		local body = function_body(init_source(),
			"local function emergency_exit_after_runtime_failure(")
		local report_at = body:find("BootFatal.report(", 1, true)
		local request_at = body:find("EmergencyExit.request(", 1, true)
		helpers.assert_true(report_at ~= nil and request_at ~= nil and report_at < request_at,
			"the durable report must precede the emergency exit request")
	end)

	helpers.it("(fatal-runtime-kind) a failure after boot completed is reported as a runtime stop", function()
		local body = function_body(init_source(),
			"local function emergency_exit_after_runtime_failure(")
		local presentation_at = body:find("BootFatal.presentation(", 1, true)
		helpers.assert_true(presentation_at ~= nil,
			"the report kind must be chosen by BootFatal.presentation")
		local complete_at = body:find("Boot.is_complete()", presentation_at, true)
		local runtime_at = body:find("BootFatal.report_runtime(", 1, true)
		local request_at = body:find("EmergencyExit.request(", 1, true)
		helpers.assert_true(complete_at ~= nil and complete_at < (runtime_at or 0),
			"whether boot completed must decide the presentation before reporting")
		helpers.assert_true(runtime_at ~= nil and request_at ~= nil and runtime_at < request_at,
			"the runtime report must precede the emergency exit request")
		local runtime_call = body:sub(runtime_at, request_at)
		helpers.assert_contains(runtime_call, "Logger.today_log_path()")
		helpers.assert_contains(runtime_call, "Logger.today_errors_path()")
		helpers.assert_true(body:find('"dialog.fatal_error.cannot_start"', 1, true) == nil,
			"a runtime stop must not default to the could-not-start message")
	end)

	helpers.it("every abort call names its stage", function()
		local source = init_source()
		local calls = 0
		for args in source:gmatch("\n%s*abort_pre_runtime_boot%(%s*([^\n]*)") do
			calls = calls + 1
			helpers.assert_true(args:match('^"[%w_]+",') ~= nil or args:match("^stage,") ~= nil
				or args == "",
				"abort_pre_runtime_boot must receive a stage name first, got: " .. args)
		end
		for args in source:gmatch("\n%s*abort_logger_boot%(([^\n]*)") do
			calls = calls + 1
			helpers.assert_true(args:match('^"[%w_]+",') ~= nil,
				"abort_logger_boot must receive a stage name first, got: " .. args)
		end
		helpers.assert_true(calls >= 4, "expected every pre-runtime abort call site, found "
			.. tostring(calls))
		-- A multi-line call puts its stage on the next line; check that shape too.
		for stage in source:gmatch("\n%s*abort_pre_runtime_boot%(\n%s*([^\n]*)") do
			helpers.assert_true(stage:match('^"[%w_]+",$') ~= nil or stage == "stage,",
				"multi-line abort_pre_runtime_boot must name its stage first, got: " .. stage)
		end
	end)
end)
