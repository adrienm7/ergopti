--- tests/meta/test_init_shutdown_quit_ke.lua

--- ==============================================================================
--- MODULE: Root Shutdown Revokes the Exact Karabiner Lease First
--- DESCRIPTION:
--- Pins the root ordering and ownership boundary. Controlled reload/quit waits
--- for the exact token fence; hs.shutdownCallback requests the same fence before
--- native process exit and relies on native EOF when it cannot wait. The native
--- callback must not dismantle F17 consumers before that fence.
--- ==============================================================================

local helpers = require("tests.helpers")

local function init_source()
	local source, err = helpers.read_driver_unit("local function has_common_hotstring_groups")
	helpers.assert_true(source ~= nil, "root init.lua must be unique: " .. tostring(err))
	return source:gsub("%-%-[^\n]*", "")
end

helpers.describe("init.lua shutdown uses exact Karabiner lease revocation", function()
	helpers.it("keeps native reload recovery before the coordinator can own a lease", function()
		local code = init_source()
		local wrapper_at = code:find("hs.reload = function", 1, true)
		local i18n_at = code:find("i18n.set_locale_injector", 1, true)
		helpers.assert_true(wrapper_at ~= nil and i18n_at ~= nil and wrapper_at < i18n_at)
		local body = code:sub(wrapper_at, i18n_at - 1)
		local initialized_at = body:find("TerminationCoordinator.is_initialized", 1, true)
		local native_at = body:find("return _native_hs_reload(...)", 1, true)
		local coordinated_at = body:find('TerminationCoordinator.request_reload("hammerspoon_reload", ...)', 1, true)
		helpers.assert_true(initialized_at ~= nil and native_at ~= nil and coordinated_at ~= nil)
		helpers.assert_true(initialized_at < native_at and native_at < coordinated_at,
			"boot errors must retain native reload before the exact lease coordinator is initialized")
	end)

	helpers.it("routes only through the remap lease API and controller fallback", function()
		local code = init_source()
		local revoke_at = code:find("local function request_exact_lease_revoke", 1, true)
		local teardown_at = code:find("local function teardown_all_resources", 1, true)
		helpers.assert_true(revoke_at ~= nil and teardown_at ~= nil and revoke_at < teardown_at)
		local body = code:sub(revoke_at, teardown_at - 1)
		helpers.assert_true(body:find("karabiner.revoke(reason, finish)", 1, true) ~= nil)
		helpers.assert_true(body:find('LeaseController.stop(reason .. "_fallback", finish)', 1, true) ~= nil)
		helpers.assert_true(body:find("LeaseController.is_initialized", 1, true) ~= nil,
			"first-run reload must be allowed before any lease generation can exist")
		helpers.assert_true(body:find("hs.execute", 1, true) == nil)
		helpers.assert_true(body:find("KILL_CMD", 1, true) == nil)
	end)

	helpers.it("keeps native shutdown consumers live while requesting revocation", function()
		local code = init_source()
		local shutdown_at = code:find("local function shutdown_all_resources()", 1, true)
		local armed_at = code:find("hs.shutdownCallback = shutdown_all_resources", 1, true)
		helpers.assert_true(shutdown_at ~= nil and armed_at ~= nil)
		local body = code:sub(shutdown_at, armed_at - 1)
		local revoke_at = body:find("request_exact_lease_revoke(lease_reason", 1, true)
		helpers.assert_true(revoke_at ~= nil, "native shutdown must request the exact fence")
		helpers.assert_true(body:find("teardown_all_resources", 1, true) == nil,
			"an unawaitable native callback must not tear down F17 consumers before EOF")
		helpers.assert_true(body:find("shortcuts.stop", 1, true) == nil)
		helpers.assert_true(body:find("terminate_helper_processes", 1, true) == nil)
		helpers.assert_true(body:find('"hammerspoon_reload"', 1, true) ~= nil)
		helpers.assert_true(body:find('"hammerspoon_quit"', 1, true) ~= nil)
		helpers.assert_true(body:find("reload_guard.is_reloading()", 1, true) ~= nil)
	end)

	helpers.it("wires controlled terminal actions behind the shared exact fence", function()
		local code = init_source()
		local init_at = code:find("TerminationCoordinator.init", 1, true)
		helpers.assert_true(init_at ~= nil)
		local region = code:sub(init_at, init_at + 1400)
		helpers.assert_true(region:find("request_lease = request_exact_lease_revoke", 1, true) ~= nil)
		helpers.assert_true(region:find("teardown = teardown_all_resources", 1, true) ~= nil)
		helpers.assert_true(region:find("reload = function", 1, true) ~= nil)
		helpers.assert_true(region:find("exit = function", 1, true) ~= nil)
	end)
end)
