--- tests/meta/harness/test_modules_llm_stub_completeness.lua

--- ==============================================================================
--- MODULE: Regression — every test-installed partial modules.llm stub exposes
--- get_current_model
--- DESCRIPTION:
--- ai/engine/prediction/engine.lua calls `core_llm.get_current_model()`
--- (core_llm = require("ai.engine")) UNCONDITIONALLY at module-load time
--- (not inside a function). Four test files install a partial
--- `package.loaded["ai.engine"] = { ... }` stub and never restore it
--- afterward; when the stub was missing get_current_model, the next test in
--- the same process whose require chain reached prediction_engine while that
--- incomplete stub was still cached crashed with "attempt to call a nil
--- value (field 'get_current_model')" -- an order/GC-dependent flake, exactly
--- the same contamination class as the lib.timings leak fixed alongside this
--- test (see tests/meta/harness/test_timings_stub_isolation.lua) and the earlier
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

-- Named by module, not by path: a structure step respells a module name where
-- a tests/-relative path held in a table stays stale.
local FILES_WITH_STUB = {
	"tests.unit.ai.ui.menu.backend.test_startup_controller_generation_guard",
	"tests.unit.hotstrings.engine.expander.expansion.test_utf8_offset_pcall",
	"tests.unit.hotstrings.engine.expander.llm_bridge.test_no_duplicate_init",
	"tests.unit.ai.ui.menu.profiles.test_label",
}

--- Reads a test module's source, found as require would find it.
--- @param module_name string Dotted test module name.
--- @return string The file's raw source text.
local function read_test_source(module_name)
	local content, missing = helpers.read_module_source(module_name)
	helpers.assert_true(content ~= nil, "cannot find " .. module_name .. ": " .. tostring(missing))
	return content
end

helpers.describe("every test-installed partial ai.engine stub exposes get_current_model", function()
	for _, rel in ipairs(FILES_WITH_STUB) do
		helpers.it(rel .. ': package.loaded["ai.engine"] stub(s) include get_current_model', function()
			local src = read_test_source(rel)
			local count = 0
			local search_from = 1
			while true do
				local pos = src:find('package.loaded%["ai%.engine"%]%s*=%s*{', search_from)
				if not pos then break end
				count = count + 1
				-- The stub table body ends at the next top-level "}" following pos;
				-- a generous 800-char window comfortably covers every stub below
				-- without needing a real brace-matching parser.
				local window = src:sub(pos, pos + 800)
				helpers.assert_true(window:find("get_current_model") ~= nil,
					rel .. ": ai.engine stub at byte " .. pos .. " is missing get_current_model -- " ..
					"prediction_engine.lua calls it unconditionally at require-time, so a later test whose " ..
					"require chain reaches prediction_engine while this uncleaned stub is cached will crash")
				search_from = pos + 1
			end
			helpers.assert_true(count > 0, rel .. ': expected at least one package.loaded["ai.engine"] stub assignment')
		end)
	end
end)
