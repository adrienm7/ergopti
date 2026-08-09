--- tests/unit/platform/remap/test_set_enabled_respects_ownership.lua

--- ==============================================================================
--- MODULE: Karabiner Disable and Shutdown Use the Exact Lease Controller
--- DESCRIPTION:
--- Guards both sibling teardown paths against dismantling their local F17
--- consumers before LeaseController proves the exact generation STOPPED.
--- A process-ownership check is intentionally absent: official Karabiner PIDs
--- are shared and can never distinguish Ergopti rules from personal rules.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the uniquely identified platform.remap source.
--- @return string source
local function remap_source()
	local source, err = helpers.read_driver_unit("local KARABINER_KE_TILDE_PATH")
	helpers.assert_true(source ~= nil, "platform.remap source must be unique: " .. tostring(err))
	return source
end

--- Extracts the final public function through the module return.
--- @param signature string Exact function signature.
--- @return string body
local function final_function_body(signature)
	local source = remap_source()
	local start_at = source:find(signature, 1, true)
	helpers.assert_true(start_at ~= nil, signature .. " must exist")
	local end_at = source:find("\nreturn M", start_at, true)
	helpers.assert_true(end_at ~= nil, signature .. " must precede the module return")
	return source:sub(start_at, end_at - 1)
end

helpers.describe("platform.remap teardown authority is the exact lease", function()
	helpers.it("set_enabled(false) delegates only to the exact lease controller", function()
		local source = remap_source()
		local stop_at = source:find(
			'pcall(LeaseController.stop, "integration_disabled", function(ok, reason)',
			1,
			true
		)
		helpers.assert_true(stop_at ~= nil,
			"disable must request acknowledged revocation from the exact lease controller")
		local callback = source:sub(stop_at)
		local failed_fence = callback:find(
			"if%s+ok%s*~=%s*true%s+then%s+rollback_enabled_state%(reason%)%s+return%s+end"
		)
		local persist = callback:find("persist_enabled_flag(false)", 1, true)
		local classifier_teardown = callback:find("clear_managed_output_set()", 1, true)
		local consumer_teardown = callback:find("stop_lease_bound_inputs()", 1, true)
		helpers.assert_true(failed_fence ~= nil,
			"a rejected fence must return through rollback before any local teardown")
		helpers.assert_true(persist ~= nil and classifier_teardown ~= nil and consumer_teardown ~= nil
			and failed_fence < persist and persist < classifier_teardown
			and classifier_teardown < consumer_teardown,
			"disable may commit state and release F17 consumers only inside the successful STOPPED callback")
		helpers.assert_true(source:find("is_hs_owned_bridge", 1, true) == nil)
		helpers.assert_true(source:find("KILL_CMD", 1, true) == nil)
		helpers.assert_true(source:find("kill_async", 1, true) == nil)
	end)

	helpers.it("separates exact revocation proof from retryable local teardown", function()
		local source = remap_source()
		local revoke_at = source:find("function M.revoke(reason, on_done)", 1, true)
		local shutdown_at = source:find("function M.shutdown(reason, on_done)", 1, true)
		local teardown_at = source:find("function M.teardown_local()", 1, true)
		helpers.assert_true(revoke_at ~= nil and shutdown_at ~= nil and teardown_at ~= nil)

		local revoke_body = source:sub(revoke_at, shutdown_at - 1)
		helpers.assert_true(revoke_body:find("LeaseController.stop", 1, true) ~= nil)
		helpers.assert_true(revoke_body:find("stop_local_resources", 1, true) == nil,
			"exact STOPPED proof must never be reclassified by a local delete failure")

		local teardown_body = source:sub(teardown_at, revoke_at - 1)
		local status_at = teardown_body:find("LeaseController.status", 1, true)
		local idle_gate_at = teardown_body:find('phase ~= "idle" and phase ~= "uninitialized"', 1, true)
		local local_stop_at = teardown_body:find("xpcall(stop_local_resources, debug.traceback)", 1, true)
		helpers.assert_true(status_at ~= nil and idle_gate_at ~= nil and local_stop_at ~= nil
			and status_at < idle_gate_at and idle_gate_at < local_stop_at,
			"local consumers may be released only after the exact controller is idle")

		local shutdown_body = final_function_body("function M.shutdown(reason, on_done)")
		local composed_revoke_at = shutdown_body:find("M.revoke(reason", 1, true)
		local composed_teardown_at = shutdown_body:find("M.teardown_local()", 1, true)
		helpers.assert_true(composed_revoke_at ~= nil and composed_teardown_at ~= nil
			and composed_revoke_at < composed_teardown_at)
		helpers.assert_true(shutdown_body:find("hs.execute", 1, true) == nil)
		helpers.assert_true(shutdown_body:find("is_hs_owned_bridge", 1, true) == nil)
	end)
end)
