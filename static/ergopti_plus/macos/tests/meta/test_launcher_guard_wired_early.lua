--- tests/meta/test_launcher_guard_wired_early.lua

--- ==============================================================================
--- MODULE: Swift Launcher Guard Root Wiring
--- DESCRIPTION:
--- Pins the production wiring that turns the launcher's exact-PID liveness
--- signal into a bounded exact-fence request with native-EOF fallback. The
--- guard's asynchronous behavior is exercised in test_launcher_guard.lua; this
--- companion proves that production arms it before risky boot.
--- ==============================================================================

local helpers = require("tests.helpers")

local function init_source()
	local source, err = helpers.read_driver_unit("local function has_common_hotstring_groups")
	helpers.assert_true(source ~= nil, "root init.lua must be unique: " .. tostring(err))
	return source:gsub("%-%-[^\n]*", "")
end

helpers.describe("init: Swift launcher loss is wired fail-closed", function()
	helpers.it("arms the exact-PID guard after teardown and before risky remap loading", function()
		local source = init_source()
		local shutdown_at = source:find("hs.shutdownCallback = shutdown_all_resources", 1, true)
		local guard_at = source:find('require, "infra.launcher_guard"', 1, true)
		local remap_at = source:find('pcall(require, "platform.remap")', 1, true)

		helpers.assert_true(shutdown_at ~= nil, "shutdown callback must be locatable")
		helpers.assert_true(guard_at ~= nil, "launcher guard must be wired into production")
		helpers.assert_true(remap_at ~= nil, "risky platform.remap load must be locatable")
		helpers.assert_true(shutdown_at < guard_at,
			"launcher loss must not fire before the complete shutdown callback exists")
		helpers.assert_true(guard_at < remap_at,
			"launcher liveness must be armed before config-dependent remap boot can throw")
	end)

	helpers.it("shares one runtime-failure deadline and exact fence with launcher loss", function()
		local source = init_source()
		local function_at = source:find("local function emergency_exit_after_runtime_failure", 1, true)
		local guard_at = source:find('require, "infra.launcher_guard"', 1, true)
		helpers.assert_true(function_at ~= nil and guard_at ~= nil,
			"emergency callback and guard wiring must both be locatable")
		local body = source:sub(function_at, guard_at - 1)
		local emergency_at = body:find("EmergencyExit.request", 1, true)
		local deadline_at = body:find("deadline_seconds = RUNTIME_FAILURE_EXIT_DEADLINE_SEC", 1, true)
		local exit_code_at = body:find("exit_code = RUNTIME_FAILURE_EXIT_CODE", 1, true)
		local request_at = body:find("TerminationCoordinator.request_exit", 1, true)
		helpers.assert_true(emergency_at ~= nil and deadline_at ~= nil
			and exit_code_at ~= nil and request_at ~= nil)
		helpers.assert_true(emergency_at < deadline_at and deadline_at < exit_code_at
			and exit_code_at < request_at,
			"the retained deadline capability must exist before the async fence request")
		helpers.assert_true(source:find("local RUNTIME_FAILURE_EXIT_CODE = 70", 1, true) ~= nil,
			"internal failures must stay distinguishable from normal user exit status zero")
		helpers.assert_true(body:find("teardown_all_resources", 1, true) == nil,
			"EOF fallback must not dismantle F17 consumers before the exact fence")
		helpers.assert_true(body:find("os.exit", 1, true) ~= nil,
			"the bounded fallback must close native stdin by exiting Hammerspoon")
		helpers.assert_true(body:find('emergency_exit_after_runtime_failure("launcher_liveness", reason)',
			1, true) ~= nil,
			"launcher loss must be one caller of the owner-neutral runtime fail-safe")
	end)

	helpers.it("routes asynchronous logger failure through the initialized bounded fail-safe", function()
		local source = init_source()
		local coordinator_at = source:find("TerminationCoordinator.init", 1, true)
		local handler_at = source:find("Logger.set_async_sink_failure_handler", 1, true)
		local input_at = source:find("local prestart_committed = StartupTransaction.run", 1, true)
		helpers.assert_true(coordinator_at ~= nil and handler_at ~= nil and input_at ~= nil)
		helpers.assert_true(coordinator_at < handler_at,
			"logger fail-safe must not request a controlled exit before its coordinator exists")
		helpers.assert_true(handler_at < input_at,
			"native logger failure must be armed before any input/eventtap transaction")
		local handler_body = source:sub(handler_at, handler_at + 700)
		helpers.assert_true(handler_body:find(
			'emergency_exit_after_runtime_failure("native_logger", detail)', 1, true) ~= nil,
			"queue-full, NACK, and ACK-loss failures must share the exact bounded exit path")
	end)

	helpers.it("keeps managed launch fail-closed if the guard cannot load or initialize", function()
		local source = init_source()
		local guard_region_at = source:find('require, "infra.launcher_guard"', 1, true)
		local remap_at = source:find('pcall(require, "platform.remap")', 1, true)
		local region = source:sub(guard_region_at, remap_at - 1)
		local _, managed_checks = region:gsub("managed_launcher_expected%(%)", "")
		local _, emergency_calls = region:gsub("emergency_exit_after_launcher_loss%(", "")

		helpers.assert_true(managed_checks >= 3,
			"load failure, initialization throw, and rejected init must distinguish managed launch")
		helpers.assert_true(emergency_calls >= 3,
			"every managed-launch failure branch must request emergency teardown")
		helpers.assert_true(region:find("started_or_err ~= true", 1, true) ~= nil,
			"a non-throwing false init result must not be mistaken for an armed guard")
	end)
end)
