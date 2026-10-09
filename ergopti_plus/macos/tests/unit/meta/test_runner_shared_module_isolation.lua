--- tests/unit/meta/test_runner_shared_module_isolation.lua

--- ==============================================================================
--- MODULE: Runner Shared-Module Isolation Regression
--- DESCRIPTION:
--- Reproduces the cross-file poison left by a permissive shared-module stub and
--- proves the runner reloads the real shared catalogue before the next test.
--- ==============================================================================

local helpers = require("tests.helpers")
local Isolation = require("tests.support.module_isolation")

local helper_source = assert(package.searchpath("tests.helpers", package.path))
	:gsub("\\", "/")
local driver_root = helper_source:match("^(.*)/tests/helpers/init%.lua$")
local drivers_root = driver_root and driver_root:match("^(.*)/[^/]+$")
local shared_lua = drivers_root and (drivers_root .. "/_shared/lua")

helpers.describe("tests/run.lua isolates shared and platform modules", function()
	helpers.it("replaces a leaked shared terminator stub with the real catalogue", function()
		local helpers_identity = package.loaded["tests.helpers"]
		package.loaded["keymap.terminators"] = setmetatable({}, {
			__index = function() return function() end end,
		})
		package.loaded["keymap.utils"] = { poisoned = true }
		package.loaded["platform.remap.ke_paths"] = { poisoned = true }
		package.loaded["modules.keymap.terminators"] = nil

		Isolation.purge(driver_root, shared_lua)

		helpers.assert_nil(package.loaded["keymap.terminators"])
		helpers.assert_nil(package.loaded["keymap.utils"])
		helpers.assert_nil(package.loaded["platform.remap.ke_paths"])
		helpers.assert_eq(package.loaded["tests.helpers"], helpers_identity,
			"test infrastructure must survive the production-module purge")

		local terminators = require("modules.keymap.terminators")
		helpers.assert_eq(type(terminators.TERMINATOR_DEFS), "table",
			"the next file must receive the real shared terminator catalogue")
	end)

	for _, module_name in ipairs({ "keymap.terminators", "keymap.terminators_catalogue" }) do
		helpers.it("reloads a real catalogue after a boolean cache leak in " .. module_name, function()
			Isolation.purge(driver_root, shared_lua)
			local helpers_identity = package.loaded["tests.helpers"]
			package.loaded[module_name] = true

			local loaded, failure = pcall(require, "modules.keymap.terminators")
			helpers.assert_eq(loaded, false,
				"the leaked boolean must reproduce the original catalogue failure")
			helpers.assert_true(tostring(failure):find("boolean", 1, true) ~= nil)

			Isolation.purge(driver_root, shared_lua)
			helpers.assert_nil(package.loaded[module_name])
			helpers.assert_eq(package.loaded["tests.helpers"], helpers_identity)
			local terminators = require("modules.keymap.terminators")
			helpers.assert_eq(type(terminators), "table")
			helpers.assert_eq(type(terminators.TERMINATOR_DEFS), "table")
			helpers.assert_true(#terminators.TERMINATOR_DEFS > 0)
		end)
	end
end)
