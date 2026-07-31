--- tests/unit/llm/test_llm_models_presets.lua
local helpers = require("tests.helpers")

-- Bootstrap the hs stub so hs.json.decode is available
package.loaded["lib.logger"] = nil
helpers.load_with_stubs("lib.logger")

-- No models_mgr stub here. Two used to sit at this spot — "modules.llm.models_mgr"
-- and "ui.menu.menu_llm.models_mgr" — and neither module has ever existed:
-- models_manager requires models_manager_ollama and models_manager_mlx. Both
-- stubs were inert from the day they were written, and the comment above them
-- ("modules that might be missing") shows the doubt was there at the time. An
-- inert stub is indistinguishable from a working one from inside the test, which
-- is why they survived; test-stubs-intercept-something.cjs now says so out loud.

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
