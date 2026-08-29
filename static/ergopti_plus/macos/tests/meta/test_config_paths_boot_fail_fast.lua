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

local PRE_RUNTIME_ABORT = "local function abort_pre_runtime_boot"
local CONFIG_INIT = "local config_paths_ready = config_paths.init(base_dir)"
local CONFIG_FAILURE_CALL =
	"abort_pre_runtime_boot(CONFIG_PATH_BOOT_FAILURE, \"dialog.fatal_error.cannot_start\")"


--- Removes Lua line and long-bracket comments before executable assertions.
--- @param source string
--- @return string code
local function strip_lua_comments(source)
	local code = source
	local cursor = 1
	while true do
		local open_at, open_end, equals = code:find("%-%-%[(=*)%[", cursor)
		if not open_at then break end
		local close_token = "]" .. equals .. "]"
		local _, close_end = code:find(close_token, open_end + 1, true)
		if not close_end then
			code = code:sub(1, open_at - 1)
			break
		end
		local block = code:sub(open_at, close_end)
		local newlines = block:gsub("[^\n]", "")
		code = code:sub(1, open_at - 1) .. newlines .. code:sub(close_end + 1)
		cursor = open_at + #newlines
	end
	return (code:gsub("%-%-[^\n]*", ""))
end


--- Replaces one exact occurrence and proves the mutation precondition.
--- @param source string Original source.
--- @param needle string Exact text.
--- @param replacement string Replacement text.
--- @return string mutant
local function replace_plain(source, needle, replacement)
	local at = source:find(needle, 1, true)
	helpers.assert_true(at ~= nil, "mutation precondition missing: " .. needle)
	return source:sub(1, at - 1) .. replacement .. source:sub(at + #needle)
end


--- Wraps one exact source range in a long-bracket comment.
--- @param source string Original source.
--- @param first string First exact token in the range.
--- @param last string Last exact token in the range.
--- @return string mutant
local function block_comment_range(source, first, last)
	local first_at = source:find(first, 1, true)
	helpers.assert_true(first_at ~= nil, "mutation precondition missing: " .. first)
	local last_at = source:find(last, first_at, true)
	helpers.assert_true(last_at ~= nil, "mutation precondition missing: " .. last)
	local last_end = last_at + #last - 1
	return source:sub(1, first_at - 1)
		.. "--[=[\n" .. source:sub(first_at, last_end) .. "\n]=]"
		.. source:sub(last_end + 1)
end


--- Checks that native logger refusal reaches the executable fatal boundary.
--- @param source string Root source or a synthetic mutant.
--- @return boolean valid
local function logger_abort_route_is_executable(source)
	local code = strip_lua_comments(source)
	local abort_at = code:find("local function abort_logger_boot", 1, true)
	local policy_at = code:find(
		"local logger_boot_mode, logger_boot_policy_err = Logger.classify_async_sink_boot_environment()",
		1, true)
	if not abort_at or not policy_at or abort_at >= policy_at then return false end
	local abort_body = code:sub(abort_at, policy_at - 1)
	local canonical_abort_at = abort_body:find("abort_pre_runtime_boot(", 1, true)
	local localized_at = abort_body:find('"startup.native_logger_unavailable"', 1, true)
	local cleanup_at = abort_body:find("Logger.stop_async_sink", 1, true)
	return canonical_abort_at ~= nil and localized_at ~= nil and cleanup_at ~= nil
		and canonical_abort_at < localized_at and localized_at < cleanup_at
end


--- Validates the visible, process-terminal config-path failure boundary.
--- @param source string Root source or a synthetic mutant.
--- @return boolean valid
--- @return string|nil reason
local function config_path_failure_is_terminal(source)
	source = strip_lua_comments(source)
	local i18n_at = source:find("i18n.init()", 1, true)
	local abort_at = source:find(PRE_RUNTIME_ABORT, 1, true)
	local config_require_at = source:find('local config_paths       = require("infra.config_paths")', 1, true)
	local init_at = source:find(CONFIG_INIT, 1, true)
	local consumer_at = source:find("Logger.init_log_path(config_paths.get_config_dir()", 1, true)
	if not i18n_at or not abort_at or not config_require_at or not init_at or not consumer_at then
		return false, "boot anchors are incomplete"
	end
	if not (i18n_at < abort_at and abort_at < config_require_at
		and config_require_at < init_at and init_at < consumer_at) then
		return false, "abort authority is not available before path initialization"
	end

	local abort_body = source:sub(abort_at, config_require_at - 1)
	local log_at = abort_body:find("Logger.error", 1, true)
	local protected_at = abort_body:find("pcall(function()", 1, true)
	local alert_at = abort_body:find("alert.show(", 1, true)
	local localized_at = abort_body:find(
		'i18n.get(alert_key or "dialog.fatal_error.cannot_start")', 1, true)
	local exit_at = abort_body:find("os.exit(1)", 1, true)
	if not log_at or not protected_at or not alert_at or not localized_at or not exit_at then
		return false, "pre-runtime abort is not logged, visible, localized, and terminal"
	end
	if not (log_at < protected_at and protected_at < alert_at
		and alert_at < localized_at and localized_at < exit_at) then
		return false, "pre-runtime abort operations are out of order"
	end

	local guard = source:sub(init_at, consumer_at - 1)
	local refusal_at = guard:find("config_paths_ready ~= true", 1, true)
	local call_at = guard:find(CONFIG_FAILURE_CALL, 1, true)
	local return_at = guard:find("\n\treturn\n", 1, true)
	if not refusal_at or not call_at or not return_at
		or not (refusal_at < call_at and call_at < return_at) then
		return false, "config refusal can fall through or return without terminating the process"
	end
	return true
end

helpers.describe("root boot: config-path initialization is fail-fast", function()
	helpers.it("terminates visibly before the first consumer when init does not commit", function()
		local source = helpers.read_driver_source("Path: config dir + paths.toml (config_paths.init)")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"root init.lua must remain discoverable by its config-path boot marker")
		local valid, reason = config_path_failure_is_terminal(source)
		helpers.assert_true(valid,
			"config-path refusal must alert and terminate the embedded process: "
				.. tostring(reason))
	end)

	helpers.it("rejects log-only, invisible, and non-terminal boot mutants", function()
		local source = helpers.read_driver_source("Path: config dir + paths.toml (config_paths.init)")
		helpers.assert_true(config_path_failure_is_terminal(source))
		local log_only = replace_plain(source, CONFIG_FAILURE_CALL,
			"Logger.error(LOG, CONFIG_PATH_BOOT_FAILURE)")
		local invisible = replace_plain(source,
			"alert.show(\n\t\t\t\ti18n.get(alert_key or \"dialog.fatal_error.cannot_start\"),",
			"do_not_alert(\n\t\t\t\ti18n.get(alert_key or \"dialog.fatal_error.cannot_start\"),")
		local non_terminal = replace_plain(source, "os.exit(1)", "return")
		local commented_call = replace_plain(source, CONFIG_FAILURE_CALL,
			"-- " .. CONFIG_FAILURE_CALL)
		local block_commented_call = replace_plain(source, CONFIG_FAILURE_CALL,
			"--[=[\n" .. CONFIG_FAILURE_CALL .. "\n]=]")
		helpers.assert_eq(config_path_failure_is_terminal(log_only), false)
		helpers.assert_eq(config_path_failure_is_terminal(invisible), false)
		helpers.assert_eq(config_path_failure_is_terminal(non_terminal), false)
		helpers.assert_eq(config_path_failure_is_terminal(commented_call), false)
		helpers.assert_eq(config_path_failure_is_terminal(block_commented_call), false)
	end)

	helpers.it("requires complete native logger authority before every input owner", function()
		local source = helpers.read_driver_source("Path: native asynchronous logger transport committed")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"root init.lua must remain discoverable by its asynchronous logger marker")
		local code = strip_lua_comments(source)
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
		helpers.assert_true(logger_abort_route_is_executable(source),
			"logger refusal must route its localized alert and exact cleanup through the canonical abort")

		local commented_route = block_comment_range(source,
			"\tabort_pre_runtime_boot(\n\t\tstring.format(", "Logger.stop_async_sink)")
		helpers.assert_true(commented_route:find(PRE_RUNTIME_ABORT, 1, true) ~= nil
			and commented_route:find(CONFIG_FAILURE_CALL, 1, true) ~= nil,
			"the logger mutant must preserve the canonical helper and config-path caller")
		helpers.assert_eq(logger_abort_route_is_executable(commented_route), false)
	end)
end)
