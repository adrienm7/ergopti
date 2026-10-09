--- tests/unit/llm/test_llm_models_presets.lua
local helpers = require("tests.helpers")

-- Bootstrap the hs stub so hs.json.decode is available
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

-- No models_mgr stub here. Two used to sit at this spot — "modules.llm.models_mgr"
-- and "ui.menu.menu_llm.models_mgr" — and neither module has ever existed:
-- models_manager requires models_manager_ollama and models_manager_mlx. Both
-- stubs were inert from the day they were written, and the comment above them
-- ("modules that might be missing") shows the doubt was there at the time. An
-- inert stub is indistinguishable from a working one from inside the test, which
-- is why they survived; test-stubs-intercept-something.cjs now says so out loud.

package.loaded["infra.i18n"] = {
	get = function(key) return key end
}

-- Load the module. This will trigger load_models_presets() internally
-- which reads static/ergopti_plus/_shared/modules/llm/models.json
local Models = helpers.load_with_stubs("ui.menu.menu_llm.models_manager")

helpers.describe("LLM Models Catalogue", function()
	helpers.it("keeps equal model metadata independent when one catalogue entry changes", function()
		helpers.with_fresh_modules({ "adapters.json_codec" }, function()
			local fresh_models = helpers.load_with_stubs("ui.menu.menu_llm.models_manager")
			local tags = { "chat" }
			local model = { name = "fixture", capabilities = { tags = tags } }
			local native = {{ label = "fixture", families = {{ label = "fixture", models = { model, model } }} }}
			local original_decode = hs.json.decode
			local catalogue_reads = 0
			hs.json.decode = function(raw)
				if raw:match("^%s*%[") then
					catalogue_reads = catalogue_reads + 1
					return native
				end
				return original_decode(raw)
			end
			local owner = fresh_models.new({ trigger_reload = function() end })
			local models = owner.get_presets()[1].families[1].models
			helpers.assert_eq(catalogue_reads, 1, "the real catalogue reader must consume the native graph")
			models[1].capabilities.tags[1] = "edited"
			models[1].capabilities.tags[2] = "added"
			helpers.assert_eq(models[2].capabilities.tags[1], "chat")
			helpers.assert_eq(#models[2].capabilities.tags, 1)
			helpers.assert_eq(tags[1], "chat", "catalogue mutations must not reach the native graph")
			helpers.assert_eq(#tags, 1)
		end)
	end)

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
