--- tests/unit/modules/llm/test_configuration_scope.lua

--- Exercises dormant configuration on the real core without starting services.
local helpers = require("tests.helpers")

local function fixture()
	local core = helpers.load_with_stubs("modules.llm")
	local ollama = package.loaded["modules.llm.api_ollama"]
	local starts = 0
	ollama.ensure_running = function() starts = starts + 1; return true end
	return core, function() return starts end
end

helpers.describe("llm-configuration-scope", function()
	helpers.it("configures and restores dormant identity without daemon startup", function()
		local core, starts = fixture()
		local before = core.configuration_snapshot()
		local next_value = core.configuration_snapshot()
		next_value.backend = "ollama"
		next_value.llm_model_ollama = "private-model"
		next_value.llm_model_mlx = ""
		next_value.user_profiles = { { id = "private", title = "Private" } }
		next_value.active_profile_id = "private"
		next_value.user_override_backend = true
		helpers.assert_true(core.apply_configuration(next_value))
		helpers.assert_eq(core.get_current_model(), "private-model")
		helpers.assert_eq(core.configuration_snapshot().active_profile_id, "private")
		helpers.assert_eq(starts(), 0)
		helpers.assert_eq(core.get_runtime_llm_enabled(), false)
		next_value.user_profiles[1].title = "changed outside"
		helpers.assert_eq(core.configuration_snapshot().user_profiles[1].title, "Private")
		helpers.assert_true(core.apply_configuration(before))
		helpers.assert_eq(core.configuration_snapshot().active_profile_id, before.active_profile_id)
		helpers.assert_eq(starts(), 0)
	end)

	helpers.it("refuses a live gate before publishing any identity", function()
		local core, starts = fixture()
		local next_value = core.configuration_snapshot()
		next_value.backend = "mlx"
		next_value.llm_model_mlx = "different"
		helpers.assert_true(core.set_runtime_llm_enabled(true))
		local before = core.configuration_snapshot()
		helpers.assert_eq(core.apply_configuration(next_value), false)
		helpers.assert_eq(core.configuration_snapshot().llm_model_mlx, before.llm_model_mlx)
		helpers.assert_eq(starts(), 0)
	end)

	helpers.it("validates the complete candidate before changing the backend", function()
		local core, starts = fixture()
		local before = core.configuration_snapshot()
		for _, key in ipairs({ "backend", "llm_model_mlx", "llm_model_ollama", "active_profile_id", "user_profiles", "user_override_backend" }) do
			local next_value = core.configuration_snapshot()
			next_value[key] = nil
			helpers.assert_eq(core.apply_configuration(next_value), false)
			helpers.assert_eq(core.configuration_snapshot().backend, before.backend)
		end
		local invalid = core.configuration_snapshot()
		invalid.user_profiles = { false }
		helpers.assert_eq(core.apply_configuration(invalid), false)
		helpers.assert_eq(starts(), 0)
	end)

	helpers.it("keeps explicit ordinary backend selection authorized to start Ollama", function()
		local core, starts = fixture()
		-- Only with the AI on and Ollama installed (llm-backend-ollama-start-gate)
		helpers.assert_true(core.set_backend("ollama"))
		helpers.assert_eq(starts(), 0)
		helpers.assert_true(core.set_runtime_llm_enabled(true))
		local binary = package.loaded["modules.llm.ollama_binary"]
		local original_resolve = binary.resolve
		binary.resolve = function() return "/Applications/Ollama.app/Contents/Resources/ollama", nil, binary.SOURCE_APP end
		local ok, err = xpcall(function()
			helpers.assert_true(core.set_backend("ollama"))
			helpers.assert_eq(starts(), 1)
		end, debug.traceback)
		binary.resolve = original_resolve
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses a failed readiness reset instead of claiming configuration completion", function()
		local core, starts = fixture()
		local candidate = core.configuration_snapshot()
		package.loaded["modules.llm.api_ollama"].reset_ready = function() error("native reset refusal") end
		helpers.assert_eq(core.apply_configuration(candidate), false)
		helpers.assert_eq(starts(), 0)
	end)

	helpers.it("refuses a gate reopened during the backend identity boundary", function()
		local core, starts = fixture()
		local candidate = core.configuration_snapshot()
		candidate.active_profile_id = "different"
		package.loaded["modules.llm.api_ollama"].reset_ready = function()
			core.set_runtime_llm_enabled(true)
		end
		helpers.assert_eq(core.apply_configuration(candidate), false)
		helpers.assert_true(core.configuration_snapshot().active_profile_id ~= "different")
		helpers.assert_eq(starts(), 0)
	end)

end)
