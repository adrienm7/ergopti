--- tests/meta/harness/test_driver_module_predicate.lua

--- ==============================================================================
--- MODULE: Driver Module Predicate
--- DESCRIPTION:
--- Tests reset package.loaded between cases. They used to match the names of
--- the folders to clear (modules, adapters, infra, ui), and a module moved to
--- another folder silently escaped the sweep: its state then leaked
--- into every later case. helpers.is_driver_module reads the folders from the
--- tree instead. This file proves it covers every production module wherever
--- it lives, and stubs under those folders, and never a test or shared module.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Every production module name of this driver, from its files.
--- @return string[]
local function production_names()
	local root = (helpers.driver_root():gsub("[/\\]$", ""))
	local paths = assert(require("tests.lua.core.runner_discovery").files(root, function(file)
		return file:match("%.lua$") ~= nil
	end, { tests = true }))
	local names = {}
	for _, path in ipairs(paths) do
		local relative = path:sub(#root + 2):gsub("%.lua$", ""):gsub("/init$", "")
		if relative:find("/", 1, true) then names[#names + 1] = (relative:gsub("/", ".")) end
	end
	return names
end

helpers.describe("driver module predicate (package.loaded sweeps)", function()
	helpers.it("(driver-module-predicate) covers every production module of the driver, whatever its folder", function()
		local names = production_names()
		helpers.assert_true(#names > 100, "production inventory too small: " .. #names)
		for _, name in ipairs(names) do
			helpers.assert_true(helpers.is_driver_module(name), name)
		end
	end)

	helpers.it("(driver-module-predicate) covers a stub a test places under a production folder", function()
		local head = production_names()[1]:match("^([%w_]+)%.")
		helpers.assert_true(helpers.is_driver_module(head .. ".zz_absent_stub_probe"))
	end)

	helpers.it("(driver-module-predicate) leaves test modules, shared modules and one-word names alone", function()
		helpers.assert_true(not helpers.is_driver_module("tests.helpers"))
		helpers.assert_true(not helpers.is_driver_module("tests.lua.core.runner_discovery"))
		helpers.assert_true(not helpers.is_driver_module("hs"))
		helpers.assert_true(not helpers.is_driver_module(42))
		local shared = 0
		for name in pairs(package.loaded) do
			local file = type(name) == "string" and package.searchpath(name, package.path)
			if file and file:gsub("\\", "/"):find("/_shared/", 1, true) then
				shared = shared + 1
				helpers.assert_true(not helpers.is_driver_module(name), name)
			end
		end
		helpers.assert_true(shared > 0, "no shared module loaded to check")
	end)
end)
