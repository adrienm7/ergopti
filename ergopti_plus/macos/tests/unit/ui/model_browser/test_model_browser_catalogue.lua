--- tests/unit/ui/model_browser/test_model_browser_catalogue.lua

--- ==============================================================================
--- MODULE: model_browser — catalogue normalisation
--- DESCRIPTION:
--- Locks down the data shape the shared web table (_shared/ui/model_browser) is fed.
--- build_catalogue() flattens the provider → family → model preset tree into the
--- flat, per-row record the page renders (name, family, params_b, active_b, is_moe,
--- ram_gb, speed_tok_s, type, installed, url) and filters out models that have no
--- URL for the active backend (the catalogue mixes MLX-only and Ollama-only
--- entries). parse_billions() turns "8.03B" / "750M" parameter strings into numbers.
---
--- FEATURES & RATIONALE:
--- 1. Pure helpers: both functions are window/webview-free, exposed via M._* solely
---    for this test, so the contract is verifiable without an hs.webview.
--- 2. MoE handling: a model whose active params are below its total (e.g. gemma-4
---    5.12B total / 2B active) must report is_moe = true with both counts intact.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["ui.model_browser"] = nil
local ModelBrowser = require("ui.model_browser")




-- =====================================================
-- =====================================================
-- ======= 1/ parse_billions ===========================
-- =====================================================
-- =====================================================

helpers.describe("model_browser — parse_billions", function()
	local pb = ModelBrowser._parse_billions
	helpers.it("parses a 'B' billions string", function()
		helpers.assert_eq(pb("8.03B"), 8.03)
		helpers.assert_eq(pb("3B"), 3)
	end)
	helpers.it("converts an 'M' millions string to billions", function()
		helpers.assert_eq(pb("750M"), 0.75)
	end)
	helpers.it("passes a number through and defaults junk to 0", function()
		helpers.assert_eq(pb(5), 5)
		helpers.assert_eq(pb(nil), 0)
		helpers.assert_eq(pb(""), 0)
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 2/ build_catalogue ==========================
-- =====================================================
-- =====================================================

local function fixture_presets()
	return {
		{
			label = "Meta (Llama)",
			families = {
				{
					label = "Llama 3.1",
					models = {
						{
							name = "Llama-3.1-8B-Instruct",
							type = "chat",
							parameters = { total = "8.03B", active = "8.03B" },
							capabilities = { speed_tok_s = 50 },
							hardware_requirements = { mlx = { ram_gb = 4.9 }, ollama = { ram_gb = 4.9 } },
							urls = { hf = "https://hf/llama", mlx = "https://hf/mlx/llama", ollama = "https://ollama/llama" },
						},
						{
							-- Ollama-only entry: must be filtered out for the mlx backend.
							name = "OllamaOnly-3B",
							type = "chat",
							parameters = { total = "3B" },
							urls = { ollama = "https://ollama/x" },
						},
					},
				},
			},
		},
		{
			label = "Google",
			families = {
				{
					label = "Gemma",
					models = {
						{
							name = "gemma-4-E2B-it",
							type = "chat",
							parameters = { total = "5.12B", active = "2B" }, -- MoE
							capabilities = { speed_tok_s = 40 },
							hardware_requirements = { mlx = { ram_gb = 3.3 } },
							urls = { hf = "https://hf/gemma", mlx = "https://hf/mlx/gemma" },
						},
					},
				},
			},
		},
	}
end

helpers.describe("model_browser — build_catalogue", function()
	local function build()
		return ModelBrowser._build_catalogue({
			presets        = fixture_presets(),
			active_backend = "mlx",
			active_model   = "gemma-4-E2B-it",
			models_mgr     = { is_model_installed = function(n) return n == "Llama-3.1-8B-Instruct" end },
		})
	end

	helpers.it("carries the backend and active model", function()
		local cat = build()
		helpers.assert_eq(cat.backend, "mlx")
		helpers.assert_eq(cat.active, "gemma-4-E2B-it")
	end)

	helpers.it("filters out models with no URL for the active backend", function()
		local cat = build()
		helpers.assert_eq(#cat.models, 2) -- Llama + gemma; OllamaOnly-3B dropped for mlx
		for _, m in ipairs(cat.models) do
			helpers.assert_true(m.name ~= "OllamaOnly-3B", "Ollama-only model must not appear under mlx")
		end
	end)

	helpers.it("normalises a dense model's fields", function()
		local cat = build()
		local llama
		for _, m in ipairs(cat.models) do if m.name == "Llama-3.1-8B-Instruct" then llama = m end end
		helpers.assert_true(llama ~= nil, "expected the Llama row")
		helpers.assert_eq(llama.params_b, 8.03)
		helpers.assert_eq(llama.active_b, 8.03)
		helpers.assert_eq(llama.is_moe, false)
		helpers.assert_eq(llama.ram_gb, 4.9)
		helpers.assert_eq(llama.speed_tok_s, 50)
		helpers.assert_eq(llama.type, "chat")
		helpers.assert_eq(llama.installed, true)
		helpers.assert_eq(llama.family, "Llama 3.1")
		helpers.assert_eq(llama.url, "https://hf/llama")
	end)

	helpers.it("flags a MoE model with both param counts", function()
		local cat = build()
		local gemma
		for _, m in ipairs(cat.models) do if m.name == "gemma-4-E2B-it" then gemma = m end end
		helpers.assert_true(gemma ~= nil, "expected the gemma row")
		helpers.assert_eq(gemma.params_b, 5.12)
		helpers.assert_eq(gemma.active_b, 2)
		helpers.assert_eq(gemma.is_moe, true)
		helpers.assert_eq(gemma.installed, false)
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 3/ normalise_name ===========================
-- =====================================================
-- =====================================================

-- A model arrives under two identities: the catalogue display name and the
-- backend-native tag. build() decides which row is ACTIVE with this rule, and
-- each driver's bridge decides which rows are INSTALLED with the same one. The
-- Linux bridge used to keep a byte-identical private copy, so the two could
-- drift apart into "active but not installed" with nothing failing
-- (llm-model-identity-single-normaliser).
helpers.describe("model_catalogue — normalise_name", function()
	local ModelCatalogue = require("llm.model_catalogue")

	helpers.it("is exported, because two callers must share one rule", function()
		helpers.assert_eq(type(ModelCatalogue.normalise_name), "function",
			"the rule must be public: M.build and every bridge's installed lookup "
			.. "have to reach the same implementation")
	end)

	helpers.it("folds case, whitespace and the implicit ':latest' tag", function()
		local n = ModelCatalogue.normalise_name
		helpers.assert_eq(n("Qwen3:latest"), "qwen3")
		helpers.assert_eq(n("QWEN3"), "qwen3",
			"Ollama tags are case-insensitive, so the key must be too")
		helpers.assert_eq(n(" qwen3 "), "qwen3")
		helpers.assert_eq(n("qwen3:8b"), "qwen3:8b",
			"only the implicit ':latest' is dropped -- an explicit size tag is part "
			.. "of the identity and must survive")
	end)

	helpers.it("answers empty for a non-string rather than raising", function()
		local n = ModelCatalogue.normalise_name
		helpers.assert_eq(n(nil), "")
		helpers.assert_eq(n(42), "")
		helpers.assert_eq(n({}), "")
	end)

	-- The coupling itself: one model, two identities, one verdict. This is what a
	-- second copy of the rule silently breaks.
	helpers.it("matches an active tag and an installed tag identically", function()
		local presets = {
			{
				label = "Alibaba",
				families = {
					{
						label = "Qwen3",
						models = {
							{
								name = "Qwen3 8B",
								parameters = { total = "8B" },
								urls = { ollama = "https://ollama.com/library/qwen3" },
							},
						},
					},
				},
			},
		}
		-- The daemon reports installed models under the backend-native tag with an
		-- explicit ':latest'; the catalogue knows the display name.
		local installed = {}
		installed[ModelCatalogue.normalise_name("qwen3:latest")] = true

		local catalogue = ModelCatalogue.build(presets, "ollama", "qwen3:latest",
			function(_display_name, runtime_name)
				return installed[ModelCatalogue.normalise_name(runtime_name)] == true
			end)

		helpers.assert_eq(#catalogue.models, 1)
		helpers.assert_eq(catalogue.models[1].runtime_name, "qwen3",
			"the Ollama library URL carries the backend-native tag")
		helpers.assert_eq(catalogue.models[1].installed, true,
			"the installed lookup must recognise the same model the active match did")
		helpers.assert_eq(catalogue.active, "Qwen3 8B",
			"and the active identity must resolve to the display name the page shows "
			.. "-- a divergent normaliser leaves the row active but not installed "
			.. "(llm-model-identity-single-normaliser)")
	end)
end)
