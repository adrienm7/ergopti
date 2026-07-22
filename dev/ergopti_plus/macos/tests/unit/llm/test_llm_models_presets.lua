--- tests/unit/llm/test_llm_models_presets.lua
local helpers = require("tests.helpers")

-- Bootstrap the hs stub so hs.json.decode is available
package.loaded["lib.logger"] = nil
helpers.load_with_stubs("lib.logger")

-- Mock required modules that might be missing or fail without full environment
package.loaded["modules.llm.models_mgr"] = {
	get_model_ram = function() return 0 end,
	is_model_installed = function() return false end
}

package.loaded["ui.menu.menu_llm.models_mgr"] = package.loaded["modules.llm.models_mgr"]

package.loaded["lib.i18n"] = {
	get = function(key) return key end
}

-- Load the module. This will trigger load_models_presets() internally
-- which reads static/ergopti_plus/_shared/modules/llm/models.json
local Models = helpers.load_with_stubs("ui.menu.menu_llm.models_manager")

helpers.describe("LLM Models Catalogue", function()
	helpers.it("can instantiate", function()
        local deps = {
            shared_system_check = function() end,
            trigger_reload = function() end
        }
		local obj = Models.new(deps)
		helpers.assert_true(type(obj) == "table", "Models.new should return an object")
		helpers.assert_true(type(obj.get_presets) == "function", "obj.get_presets should be a function")
	end)
end)
