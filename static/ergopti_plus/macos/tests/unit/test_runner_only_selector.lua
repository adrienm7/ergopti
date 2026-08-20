--- tests/unit/test_runner_only_selector.lua

--- ==============================================================================
--- MODULE: Hammerspoon Focused-Test Runner Regression Tests
--- DESCRIPTION:
--- Verifies that the `--only` replay path selects candidate files before Lua
--- requires them, while an unknown or dynamically generated name falls back to
--- complete discovery so filtering can never hide a real test.
--- ==============================================================================

local helpers = require("tests.helpers")
local OnlySelector = require("tests.support.only_selector")





-- ======================================
-- ======================================
-- ======= 1/ Selection Behaviour =======
-- ======================================
-- ======================================

local MODULES = {
	"tests.unit.test_target",
	"tests.unit.test_dynamic",
	"tests.unit.test_unrelated",
}

local SOURCES = {
	["tests.unit.test_target"] = [[
		helpers.it("focused target case", function() end)
	]],
	["tests.unit.test_dynamic"] = [[
		for _, suffix in ipairs(vectors) do
			helpers.it("dynamic " .. suffix, function() end)
		end
	]],
	["tests.unit.test_unrelated"] = [[
		if os.getenv("SENTINEL") then error("unrelated module loaded") end
		helpers.it("unrelated case", function() end)
	]],
}

local function load_source(module_name)
	return SOURCES[module_name]
end

helpers.describe("Hammerspoon --only selects modules before require", function()
	helpers.it("excludes an unrelated module with load-time side effects", function()
		local selected, narrowed = OnlySelector.select_modules(
			MODULES,
			"focused target case",
			load_source
		)
		helpers.assert_eq(narrowed, true)
		helpers.assert_eq(#selected, 2)
		helpers.assert_eq(selected[1], "tests.unit.test_target")
		helpers.assert_eq(selected[2], "tests.unit.test_dynamic")
	end)

	helpers.it("retains modules whose test names are assembled at load time", function()
		local selected, narrowed = OnlySelector.select_modules(
			MODULES,
			"dynamic generated-value",
			load_source
		)
		helpers.assert_eq(narrowed, true)
		helpers.assert_eq(#selected, 1)
		helpers.assert_eq(selected[1], "tests.unit.test_dynamic")
	end)

	helpers.it("falls back to all modules when no source contains the requested case", function()
		local static_modules = { MODULES[1], MODULES[3] }
		local selected, narrowed = OnlySelector.select_modules(
			static_modules,
			"runtime-generated-case-42",
			load_source
		)
		helpers.assert_eq(narrowed, false)
		helpers.assert_eq(#selected, #static_modules)
		helpers.assert_eq(selected[1], static_modules[1])
		helpers.assert_eq(selected[2], static_modules[2])
	end)

	helpers.it("keeps complete discovery when no --only filter is present", function()
		local selected, narrowed = OnlySelector.select_modules(MODULES, nil, load_source)
		helpers.assert_eq(narrowed, false)
		helpers.assert_eq(#selected, #MODULES)
	end)

	helpers.it("the production runner invokes selection before requiring modules", function()
		local path = helpers.driver_root() .. "tests/run.lua"
		local handle = assert(io.open(path, "rb"))
		local source = handle:read("*a")
		handle:close()
		local select_index = source:find("OnlySelector.select_modules", 1, true)
		local require_index = source:find("pcall(require, mod_name)", 1, true)
		helpers.assert_true(select_index ~= nil, "runner must invoke the focused module selector")
		helpers.assert_true(require_index ~= nil, "runner must retain protected module loading")
		helpers.assert_true(select_index < require_index,
			"module selection must happen before any discovered test module is required")
	end)
end)
