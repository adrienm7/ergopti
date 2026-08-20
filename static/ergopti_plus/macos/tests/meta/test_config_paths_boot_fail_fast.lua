--- tests/meta/test_config_paths_boot_fail_fast.lua

--- ==============================================================================
--- MODULE: Root Boot Config-Path Fail-Fast Regression
--- DESCRIPTION:
--- `infra.config_paths.init()` returns false when `paths.toml` is unreadable,
--- dangling, a directory, or cannot be published. Root boot must consume that
--- exact result before it resolves the log/config directory or starts any input
--- and remap owner; otherwise the same failure silently falls through to defaults.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("root boot: config-path initialization is fail-fast", function()
	helpers.it("returns before the first config-path consumer when init does not commit", function()
		local source = helpers.read_driver_source("Path: config dir + paths.toml (config_paths.init)")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"root init.lua must remain discoverable by its config-path boot marker")
		local code = source:gsub("%-%-[^\n]*", "")
		local init_at = code:find("local config_paths_ready = config_paths.init(base_dir)", 1, true)
		local consumer_at = code:find("Logger.init_log_path(config_paths.get_config_dir()", 1, true)
		helpers.assert_true(init_at ~= nil and consumer_at ~= nil and init_at < consumer_at,
			"the exact init result must be captured before any fallback path is consumed")

		local guard = code:sub(init_at, consumer_at - 1)
		helpers.assert_true(guard:find("config_paths_ready ~= true", 1, true) ~= nil,
			"false and nil must both abort; truthiness would accept neither exact commit")
		helpers.assert_true(guard:find("Logger.error", 1, true) ~= nil,
			"a rejected path bootstrap must remain visible in the fallback boot log")
		helpers.assert_true(guard:find("return", 1, true) ~= nil,
			"boot must stop before logger, preferences, watchers, eventtaps, or Karabiner use defaults")
	end)

	helpers.it("requires complete native logger authority before every input owner", function()
		local source = helpers.read_driver_source("Path: native asynchronous logger transport committed")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"root init.lua must remain discoverable by its asynchronous logger marker")
		local code = source:gsub("%-%-[^\n]*", "")
		local abort_at = code:find("local function abort_logger_boot", 1, true)
		local policy_at = code:find(
			"local logger_boot_mode, logger_boot_policy_err = Logger.classify_async_sink_boot_environment()",
			1, true)
		local refusal_at = code:find('if logger_boot_mode ~= "managed" then', policy_at or 1, true)
		local standalone_diagnostic_at = code:find(
			'if logger_boot_mode == "standalone" then', refusal_at or 1, true)
		local policy_abort_at = code:find("abort_logger_boot(refusal_detail)",
			standalone_diagnostic_at or 1, true)
		local start_at = code:find(
			"local async_log_ready, async_log_err = Logger.start_async_sink(TimerScheduler)",
			policy_abort_at or 1, true)
		local managed_abort_at = code:find("abort_logger_boot(async_log_err)", start_at or 1, true)
		local capture_at = code:find("Logger.install_runtime_error_capture()", 1, true)
		local first_input_at = code:find("local prestart_committed = StartupTransaction.run", 1, true)
		helpers.assert_true(abort_at ~= nil and policy_at ~= nil and refusal_at ~= nil
			and standalone_diagnostic_at ~= nil and policy_abort_at ~= nil
			and start_at ~= nil and managed_abort_at ~= nil
			and capture_at ~= nil and first_input_at ~= nil,
			"policy, fatal surface, transport, runtime capture, and input must remain locatable")
		helpers.assert_true(abort_at < policy_at and policy_at < refusal_at
			and refusal_at < standalone_diagnostic_at
			and standalone_diagnostic_at < policy_abort_at and policy_abort_at < start_at
			and start_at < managed_abort_at and managed_abort_at < capture_at
			and capture_at < first_input_at,
			"the native logger must commit before runtime capture and every input/eventtap owner")

		local abort_body = code:sub(abort_at, policy_at - 1)
		local non_managed_body = code:sub(refusal_at, start_at - 1)
		local managed_body = code:sub(start_at, capture_at - 1)
		helpers.assert_true(non_managed_body:find("Logger.start_async_sink", 1, true) == nil
			and non_managed_body:find("abort_logger_boot(refusal_detail)", 1, true) ~= nil
			and non_managed_body:find("return", 1, true) ~= nil,
			"every absent or partial native authority must abort before transport/input startup")
		helpers.assert_true(non_managed_body:find("native logger authority absent", 1, true) ~= nil,
			"complete authority absence must explain that the full driver requires its launcher")
		helpers.assert_true(managed_body:find("async_log_ready ~= true", 1, true) ~= nil,
			"false and nil transport outcomes must both fail closed")
		helpers.assert_true(managed_body:find("abort_logger_boot(async_log_err)", 1, true) ~= nil,
			"a managed native refusal must never downgrade to the standalone sink")
		helpers.assert_true(abort_body:find("Logger.error", 1, true) ~= nil,
			"the exact transport refusal must remain visible in the pre-transport boot log")
		local protected_at = abort_body:find("pcall(function()", 1, true)
		local alert_owner_at = abort_body:find("local alert = hs.alert", 1, true)
		local alert_at = abort_body:find("alert.show", 1, true)
		helpers.assert_true(protected_at ~= nil and alert_owner_at ~= nil and alert_at ~= nil
			and protected_at < alert_owner_at and alert_owner_at < alert_at,
			"managed boot refusal must expose one protected visible failure before exiting")
		helpers.assert_true(abort_body:find('i18n.get("startup.native_logger_unavailable")',
			1, true) ~= nil,
			"the visible boot failure must use the initialized locale instead of hardcoded UI text")
		local exit_at = abort_body:find("os.exit(1)", 1, true)
		helpers.assert_true(exit_at ~= nil,
			"boot refusal must terminate the inert embedded Hammerspoon child")
		helpers.assert_true(alert_at < exit_at,
			"fatal exit must follow the visible failure and remain before runtime capture/input")
	end)
end)
