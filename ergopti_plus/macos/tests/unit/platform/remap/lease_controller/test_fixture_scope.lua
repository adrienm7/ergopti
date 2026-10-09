--- tests/unit/platform/remap/lease_controller/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: Lease Controller Fixture Isolation
--- DESCRIPTION:
--- Proves exact restoration while retaining intentional shared settings reloads.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.lease_controller_fixture").with_fixture
local OWNERS = {
	"hs", "tests.stubs.hs", "infra.i18n", "infra.paths",
	"platform.remap.lease_controller", "adapters.shell_runner", "adapters.storage",
	"adapters.timer_scheduler", "platform.remap.ke_paths", "platform.remap.lease_helper",
	"infra.logger",
}

local function with_observer(callback)
	helpers.with_stub_scope(OWNERS, function()
		local preload = package.preload["platform.remap.lease_controller"]
		local outcome = table.pack(xpcall(callback, debug.traceback))
		package.preload["platform.remap.lease_controller"] = preload
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("Lease controller fixture isolation", function()
	for _, mode in ipairs({ "success", "callback failure", "construction failure" }) do
		helpers.it("(lease-fixture-scope) restores exact predecessors after " .. mode, function()
			with_observer(function()
				local expected = {}
				for _, name in ipairs(OWNERS) do
					expected[name] = {}
					package.loaded[name] = expected[name]
				end
				local native = rawget(_G, "hs")
				local marker = "lease fixture injected failure"
				if mode == "construction failure" then
					package.preload["platform.remap.lease_controller"] = function() error(marker, 0) end
				end
				local entered = false
				local ok, result = pcall(with_fixture, function(load_controller)
					entered = true
					local controller = load_controller()
					helpers.assert_type(controller.start, "function")
					if mode == "callback failure" then error(marker, 0) end
					return "completed"
				end)
				helpers.assert_eq(entered, true)
				helpers.assert_eq(ok, mode == "success")
				if mode == "success" then
					helpers.assert_eq(result, "completed")
				else
					helpers.assert_true(tostring(result):find(marker, 1, true) ~= nil)
				end
				helpers.assert_true(rawequal(rawget(_G, "hs"), native))
				for _, name in ipairs(OWNERS) do
					helpers.assert_true(package.loaded[name] == expected[name], name .. " must be restored")
				end
			end)
		end)
	end

	helpers.it("(lease-fixture-scope) reloads native storage while retaining only explicit shared data", function()
		with_observer(function()
			with_fixture(function(load_controller)
				local shared = {}
				local first = load_controller({ settings_store = shared })
				local storage = require("adapters.storage")
				helpers.assert_eq(storage.set("fixture_probe", "retained"), true)
				local second = load_controller({ settings_store = shared })
				local reloaded = require("adapters.storage")
				helpers.assert_true(first ~= second)
				helpers.assert_true(storage ~= reloaded)
				helpers.assert_eq(reloaded.get("fixture_probe"), "retained")
				load_controller()
				helpers.assert_nil(require("adapters.storage").get("fixture_probe"),
					"a separate native store must not inherit the shared reload ledger")
			end)
			for _, name in ipairs(OWNERS) do helpers.assert_nil(package.loaded[name], name) end
		end)
	end)
end)
