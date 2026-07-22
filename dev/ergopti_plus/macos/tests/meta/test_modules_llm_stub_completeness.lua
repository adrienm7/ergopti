--- tests/meta/test_modules_llm_stub_completeness.lua

--- ==============================================================================
--- MODULE: Regression — every test-installed partial modules.llm stub exposes
--- get_current_model
--- DESCRIPTION:
--- modules/llm/prediction_engine.lua calls `core_llm.get_current_model()`
--- (core_llm = require("modules.llm")) UNCONDITIONALLY at module-load time
--- (not inside a function). Five test files install a partial
--- `package.loaded["modules.llm"] = { ... }` stub and never restore it
--- afterward; when the stub was missing get_current_model, the next test in
--- the same process whose require chain reached prediction_engine while that
--- incomplete stub was still cached crashed with "attempt to call a nil
--- value (field 'get_current_model')" -- an order/GC-dependent flake, exactly
--- the same contamination class as the lib.timings leak fixed alongside this
--- test (see tests/meta/test_timings_stub_isolation.lua) and the earlier
--- lib.i18n (F-T1) / modules.keymap.registry* (F-HIGH-23) leaks.
---
--- These stubs cannot be centrally cleared in load_with_stubs the way
--- lib.timings was: several of the files below install their modules.llm
--- stub BEFORE calling helpers.load_with_stubs(...), relying on it
--- surviving that call to satisfy their OWN require() a few lines later --
--- clearing it centrally would break those tests immediately. So instead
--- this meta test pins stub COMPLETENESS at each known site directly.
--- ==============================================================================

local helpers = require("tests.helpers")

local FILES_WITH_STUB = {
	"unit/ui/menu/menu_llm/test_startup_controller_generation_guard.lua",
	"unit/modules/keymap/test_utf8_offset_pcall.lua",
	"unit/modules/keymap/test_llm_bridge_no_duplicate_init.lua",
	"unit/menu/test_profile_label.lua",
	"unit/modules/keymap/test_apply_prediction_paste_ops.lua",
}

--- Reads a tests/-relative source file.
--- @param rel string Path relative to the tests/ directory.
--- @return string The file's raw source text.
local function read_test_source(rel)
	local path = helpers.driver_root() .. "tests/" .. rel
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "cannot open " .. path)
	local content = fh:read("*a")
	fh:close()
	return content
end

helpers.describe("every test-installed partial modules.llm stub exposes get_current_model", function()
	for _, rel in ipairs(FILES_WITH_STUB) do
		helpers.it(rel .. ': package.loaded["modules.llm"] stub(s) include get_current_model', function()
			local src = read_test_source(rel)
			local count = 0
			local search_from = 1
			while true do
				local pos = src:find('package.loaded%["modules%.llm"%]%s*=%s*{', search_from)
				if not pos then break end
				count = count + 1
				-- The stub table body ends at the next top-level "}" following pos;
				-- a generous 800-char window comfortably covers every stub below
				-- without needing a real brace-matching parser.
				local window = src:sub(pos, pos + 800)
				helpers.assert_true(window:find("get_current_model") ~= nil,
					rel .. ": modules.llm stub at byte " .. pos .. " is missing get_current_model -- " ..
					"prediction_engine.lua calls it unconditionally at require-time, so a later test whose " ..
					"require chain reaches prediction_engine while this uncleaned stub is cached will crash")
				search_from = pos + 1
			end
			helpers.assert_true(count > 0, rel .. ': expected at least one package.loaded["modules.llm"] stub assignment')
		end)
	end
end)
