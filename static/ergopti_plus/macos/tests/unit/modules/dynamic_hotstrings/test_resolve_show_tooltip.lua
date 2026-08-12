--- tests/unit/modules/dynamic_hotstrings/test_resolve_show_tooltip.lua

--- ==============================================================================
--- MODULE: hotstrings_config resolve show_tooltip regression tests
--- DESCRIPTION:
--- Regression for dynhotstrings-3: the early-return tables in M.resolve() and
--- M.resolve_ext() (fired when called before M.init()) omitted show_tooltip,
--- so callers received nil for that field and interpreted it as "hide tooltip"
--- — the opposite of the documented default (true).
---
--- FEATURES & RATIONALE:
--- 1. Runtime test: calls resolve()/resolve_ext() before M.init() and asserts
---    that the returned table includes show_tooltip == true.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =================================================================================
-- =================================================================================
-- ======= 1/ resolve early-return has show_tooltip=true (dynhotstrings-3) =========
-- =================================================================================
-- =================================================================================

helpers.describe("hotstrings_config.resolve early-return — show_tooltip default (dynhotstrings-3 regression)", function()

	local function load_fresh()
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		-- lib.toml_reader requires toml_codec (a Hammerspoon C extension). Stub it so
		-- the module loads cleanly in headless tests. load_shared_defaults() at module
		-- level calls parse() and requires a valid sections structure or it errors out.
		package.loaded["infra.toml.reader"] = {
			parse = function()
				return {
					sections = {
						delays = { default_sec = 0.05 },
						colors = { global_default = "#cccccc", personal = "#aaaaaa" },
					},
				}, true
			end,
		}
		local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		-- Clear the stub so it doesn't leak into subsequent test files that require
		-- the real lib.toml_reader (e.g. ui.tooltip.config reads constants.toml).
		package.loaded["infra.toml.reader"] = nil
		return mod
	end

	helpers.it("M.resolve() returns show_tooltip=true when called before M.init()", function()
		-- Not calling M.init() means _state is nil; require_state fires the early-return.
		-- Pre-fix the table was { delay=..., color=nil, has_override=false } — no show_tooltip.
		-- Post-fix it is { ..., show_tooltip=true, ... }.
		local HC = load_fresh()
		local result = HC.resolve("any_category", nil)
		helpers.assert_true(result ~= nil, "resolve() must return a table even before init()")
		helpers.assert_true(result.show_tooltip == true,
			"resolve() early-return must include show_tooltip=true; got: " .. tostring(result.show_tooltip))
	end)

	helpers.it("M.resolve_ext() returns show_tooltip=true when called before M.init()", function()
		local HC = load_fresh()
		local result = HC.resolve_ext("some-ext", "/fake/path.toml", nil)
		helpers.assert_true(result ~= nil, "resolve_ext() must return a table even before init()")
		helpers.assert_true(result.show_tooltip == true,
			"resolve_ext() early-return must include show_tooltip=true; got: " .. tostring(result.show_tooltip))
	end)

	helpers.it("M.resolve() with a section also returns show_tooltip=true before init()", function()
		local HC = load_fresh()
		local result = HC.resolve("rolls", "uppercase")
		helpers.assert_true(result.show_tooltip == true,
			"resolve() with section early-return must have show_tooltip=true")
	end)

end)
