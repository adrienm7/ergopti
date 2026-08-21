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
		helpers.it("focused target case", function() return "target" end)
	]],
	["tests.unit.test_dynamic"] = [[
		for _, suffix in ipairs(vectors) do
			helpers.it("dynamic " .. suffix, function() return suffix end)
		end
	]],
	["tests.unit.test_unrelated"] = [[
		-- focused target case is documentation, not a registered test.
		local fixture = 'helpers.it("focused target case", function() return "doc" end)'
		if os.getenv("SENTINEL") then error("unrelated module loaded") end
		helpers.it("unrelated case", function() return "unrelated" end)
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
		helpers.assert_eq(narrowed, false,
			"a runtime-generated target needs complete discovery")
		helpers.assert_eq(#selected, #MODULES)
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
		local match_guard_index = source:find("OnlySelector.require_match", 1, true)
		local summary_index = source:find("OVERALL RESULTS", 1, true)
		helpers.assert_true(match_guard_index ~= nil and summary_index ~= nil
			and match_guard_index < summary_index,
			"a zero-test focused replay must fail before printing its final verdict")
	end)

	helpers.it("turns a zero-test focused replay into a failure", function()
		local results = { passed = 0, failed = 0, failures = {} }
		helpers.assert_eq(OnlySelector.require_match(results, "missing behavior"), false)
		helpers.assert_eq(results.failed, 1)
		helpers.assert_eq(#results.failures, 1)
		helpers.assert_true(results.failures[1].err:find("no test case matched", 1, true) ~= nil)
	end)

	helpers.it("leaves unfiltered and genuinely executed results unchanged", function()
		local unfiltered = { passed = 0, failed = 0, failures = {} }
		helpers.assert_eq(OnlySelector.require_match(unfiltered, nil), true)
		helpers.assert_eq(unfiltered.failed, 0)
		local focused = { passed = 1, failed = 0, failures = {} }
		helpers.assert_eq(OnlySelector.require_match(focused, "real case"), true)
		helpers.assert_eq(focused.failed, 0)
	end)
end)
