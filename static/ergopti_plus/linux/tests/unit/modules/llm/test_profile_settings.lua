--- tests/unit/modules/llm/test_profile_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Profile Controls
--- DESCRIPTION:
--- Proves profile persistence, model-driven recommendation, and atomic manual
--- override semantics without an Ollama process.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local held = {}

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
end

helpers.describe("model profile recommendation: shared policy", function()
	helpers.it("uses completion type and effective parameter thresholds", function()
		local recommendation = helpers.load_module("modules.llm.model_profile")
		local catalogue = {
			{ families = { { models = {
				{ name = "Coder Base", type = "completion", parameters = { total = "8B" } },
				{ name = "Tiny", type = "chat", parameters = { total = "0.8B" } },
				{ name = "MoE", type = "chat", parameters = { total = "30B", active = "3B" } },
				{ name = "Large", type = "chat", parameters = { total = "8B" } },
			} } },
			},
		}
		local policy = { advanced_min_parameters_b = 2, batch_min_parameters_b = 4 }
		helpers.assert_eq(recommendation.recommend_from("Coder Base", catalogue, policy), "raw")
		helpers.assert_eq(recommendation.recommend_from("Tiny", catalogue, policy), "basic")
		helpers.assert_eq(recommendation.recommend_from("MoE", catalogue, policy), "advanced")
		helpers.assert_eq(recommendation.recommend_from("Large", catalogue, policy), "batch_advanced")
	end)

	helpers.it("recognises an Ollama tag and falls back to its size suffix", function()
		local recommendation = helpers.load_module("modules.llm.model_profile")
		local catalogue = {
			{ families = { { models = { {
				name = "Published Name",
				type = "chat",
				parameters = { total = "2B" },
				urls = { ollama = "https://ollama.com/library/qwen:2b" },
			} } } },
			},
		}
		local policy = { advanced_min_parameters_b = 2, batch_min_parameters_b = 4 }
		helpers.assert_eq(recommendation.recommend_from("qwen:2b:latest", catalogue, policy), "advanced")
		helpers.assert_eq(recommendation.recommend_from("unknown:7b", {}, policy), "batch_advanced")
	end)
end)

helpers.describe("LLM profile settings: durable effective profile", function()
	local function load_settings(initial, writes_fail)
		local storage = Fakes.storage({ initial = initial, writes_fail = writes_fail })
		replace("adapters.storage", storage)
		replace("modules.llm.model_profile", {
			recommend = function(model) return model == "large" and "batch_advanced" or "basic" end,
			_reset = function() end,
		})
		package.loaded["modules.llm.profile_settings"] = nil
		local settings = require("modules.llm.profile_settings")
		settings._reset()
		return settings, storage
	end

	helpers.it("reads manifest defaults and lets auto-selection affect the request profile", function()
		local settings, storage = load_settings()
		helpers.assert_eq(settings.get("active"), "basic")
		helpers.assert_eq(settings.get("num_predictions"), 3)
		helpers.assert_eq(settings.get("auto_profile_for_model"), true)
		helpers.assert_eq(settings.effective_profile("large"), "batch_advanced")
		helpers.assert_eq(#storage.keys(), 0)
		restore()
	end)

	helpers.it("commits a non-recommended manual profile and disables auto atomically", function()
		local settings, storage = load_settings()
		helpers.assert_true(settings.set("active", "advanced", "small"))
		helpers.assert_eq(settings.get("active"), "advanced")
		helpers.assert_eq(settings.get("auto_profile_for_model"), false)
		helpers.assert_eq(storage.get("llm.profiles.active"), "advanced")
		helpers.assert_eq(storage.get("llm.profiles.auto_profile_for_model"), false)
		restore()
	end)

	helpers.it("refuses invalid counts and leaves live state unchanged on write failure", function()
		local settings = load_settings({ ["llm.profiles.num_predictions"] = 5 }, true)
		for _, invalid in ipairs({ 0, 11, 2.5, "3" }) do
			helpers.assert_eq(settings.set("num_predictions", invalid), false)
		end
		helpers.assert_eq(settings.set("num_predictions", 4), false)
		helpers.assert_eq(settings.get("num_predictions"), 5)
		restore()
	end)
end)
