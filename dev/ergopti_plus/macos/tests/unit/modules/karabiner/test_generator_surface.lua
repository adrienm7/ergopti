--- tests/unit/modules/karabiner/test_generator_surface.lua

--- ==============================================================================
--- MODULE: karabiner.generator surface Unit Tests
--- DESCRIPTION:
--- Smoke tests for the generator module's exposed public surface. The full
--- build_karabiner_json snapshot test is deferred to integration as it requires
--- the entire actions.json / tap_hold_keys.json / mod_combos.json corpus and a
--- working capsword.json on disk (see tests/fixtures/karabiner_configs/README.md).
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Generator = helpers.load_with_stubs("modules.karabiner.generator")




-- =====================================
-- =====================================
-- ======= 1/ Public surface ===========
-- =====================================
-- =====================================

helpers.describe("Generator: public surface", function()
	helpers.it("exposes build_karabiner_json", function()
		helpers.assert_eq(type(Generator.build_karabiner_json), "function")
	end)

	helpers.it("exposes merge_into_existing_config", function()
		helpers.assert_eq(type(Generator.merge_into_existing_config), "function")
	end)

	helpers.it("exposes deploy_file", function()
		helpers.assert_eq(type(Generator.deploy_file), "function")
	end)
end)





-- =========================================
--- ===========================================
--- ======= 2/ deploy_file: error paths =======
--- ===========================================
-- =========================================

helpers.describe("Generator.deploy_file", function()
	helpers.it("returns false-y when source file does not exist", function()
		local res = Generator.deploy_file("/nonexistent/path/source.json", "/tmp/dest.json")
		-- Implementation may return false, nil, or 0 depending on its contract.
		-- The important thing is no exception is raised.
		helpers.assert_true(res ~= true, "expected non-truthy for missing source")
	end)
end)
