--- tests/unit/ui/menu/test_menu_state_llm_identity_gate.lua

local helpers = require("tests.helpers")

local MenuState = helpers.load_with_stubs("ui.menu.menu_state")

local function make_state()
	return {
		hotstrings = {},
		llm_backend = "api",
		llm_active_profile = "profile-a",
		llm_user_profiles = { ["profile-a"] = { backend = "api" } },
		llm_model_ollama = "ollama-model",
		llm_model_mlx = "mlx-model",
		llm_model = "api-model",
		llm_streaming = true,
		llm_enabled = true,
	}
end

local function refusal(mode)
	if mode == "throw" then error("injected identity refusal") end
	if mode == "nil" then return nil end
	return false
end

helpers.describe("menu_state: strict LLM identity restore gates downstream keymap writes", function()
	local identity_order = {
		"set_backend",
		"set_user_profiles",
		"set_active_profile",
		"set_llm_model_ollama",
		"set_llm_model_mlx",
	}

	for failure_index, failing_name in ipairs(identity_order) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("stops after mutate-then-" .. mode .. " from llm."
				.. failing_name, function()
				local runtime = {}
				local identity_calls = {}
				local keymap_calls = 0
				local streaming_calls = 0
				local llm = {}
				for index, name in ipairs(identity_order) do
					local setter_index = index
					local setter_name = name
					llm[setter_name] = function(value)
						identity_calls[#identity_calls + 1] = setter_name
						runtime[setter_name] = value
						if setter_index == failure_index then return refusal(mode) end
						return true
					end
				end
				llm.set_llm_streaming = function()
					streaming_calls = streaming_calls + 1
				end
				local keymap = {
					set_llm_model = function()
						keymap_calls = keymap_calls + 1
						return true
					end,
					set_llm_backend_name = function()
						keymap_calls = keymap_calls + 1
					end,
				}

				local committed = MenuState.sync_state_to_modules(
					make_state(), {}, false, {
						keymap = keymap,
						hotstring_editor = {},
						core_mods = {llm = llm},
						save_prefs = function() return true end,
					})

				helpers.assert_eq(committed, false)
				helpers.assert_eq(#identity_calls, failure_index,
					"no later core identity may run after a refusal")
				helpers.assert_eq(identity_calls[#identity_calls], failing_name)
				helpers.assert_eq(runtime[failing_name] ~= nil, true,
					"the fixture must mutate before refusing")
				helpers.assert_eq(streaming_calls, 0)
				helpers.assert_eq(keymap_calls, 0,
					"no downstream keymap write may observe a partial core identity")
			end)
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("stops keymap publication after mutate-then-" .. mode
			.. " model refusal", function()
			local runtime_model
			local downstream_calls = 0
			local llm = {}
			for _, name in ipairs(identity_order) do
				llm[name] = function() return true end
			end
			local committed = MenuState.sync_state_to_modules(
				make_state(), {}, false, {
					keymap = {
						set_llm_model = function(value)
							runtime_model = value
							return refusal(mode)
						end,
						set_llm_backend_name = function()
							downstream_calls = downstream_calls + 1
						end,
						set_preview_ai_enabled = function()
							downstream_calls = downstream_calls + 1
						end,
					},
					hotstring_editor = {},
					core_mods = {llm = llm},
					save_prefs = function() return true end,
				})

			helpers.assert_eq(committed, false)
			helpers.assert_eq(runtime_model, "api-model")
			helpers.assert_eq(downstream_calls, 0)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("stops keymap publication after enabled identity " .. mode, function()
			local runtime_enabled
			local downstream_calls = 0
			local llm = {}
			for _, name in ipairs(identity_order) do
				llm[name] = function() return true end
			end
			local committed = MenuState.sync_state_to_modules(
				make_state(), {}, false, {
					keymap = {
						set_llm_model = function() return true end,
						set_llm_backend_name = function()
							downstream_calls = downstream_calls + 1
						end,
					},
					apply_llm_enabled = function(value)
						runtime_enabled = value
						return refusal(mode)
					end,
					hotstring_editor = {},
					core_mods = {llm = llm},
					save_prefs = function() return true end,
				})

			helpers.assert_eq(committed, false)
			helpers.assert_eq(runtime_enabled, true)
			helpers.assert_eq(downstream_calls, 0)
		end)
	end

	helpers.it("keeps non-identity nil-returning display setters permissive", function()
		local llm = {set_llm_streaming = function() return nil end}
		for _, name in ipairs(identity_order) do
			llm[name] = function() return true end
		end
		local display_calls = 0
		local committed = MenuState.sync_state_to_modules(
			make_state(), {}, false, {
				keymap = {
					set_llm_model = function() return true end,
					set_llm_backend_name = function()
						display_calls = display_calls + 1
						return nil
					end,
					set_llm_display_model_name = function()
						display_calls = display_calls + 1
						return nil
					end,
				},
				hotstring_editor = {},
				core_mods = {llm = llm},
				save_prefs = function() return true end,
			})

		helpers.assert_eq(committed, true)
		helpers.assert_eq(display_calls, 2)
	end)
end)

return true
