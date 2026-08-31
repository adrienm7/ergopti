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

	helpers.it("creates, resolves, edits, and deletes one user profile durably", function()
		local settings, storage = load_settings()
		local profile = {
			id = "user_fixture_1",
			label = "Fixture",
			system_single = "Continue {context}",
			batch = true,
		}
		helpers.assert_eq(settings.save_user_profile(profile, true, false), true)
		helpers.assert_eq(settings.get("active"), "user_fixture_1")
		helpers.assert_eq(settings.get("auto_profile_for_model"), false)
		helpers.assert_eq(#settings.list_user(), 1)
		helpers.assert_eq(settings.resolve("small").system_single, "Continue {context}")
		helpers.assert_true(
			type(storage.get("llm.profiles.user_profiles")[1].system_multi_template) == "string"
				and storage.get("llm.profiles.user_profiles")[1].system_multi_template ~= "",
			"batch profiles must inherit the shared batch footer, or one request cannot yield several candidates")
		local collision = {
			id = profile.id,
			label = "Collision",
			system_single = "Wrong {context}",
			batch = false,
		}
		helpers.assert_eq(settings.save_user_profile(collision, true, false), false)
		helpers.assert_eq(settings.list_user()[1].label, "Fixture")

		profile.label = "Updated"
		profile.system_single = "Updated {context}"
		helpers.assert_eq(settings.save_user_profile(profile, false, true), true)
		helpers.assert_eq(settings.list_user()[1].label, "Updated")
		helpers.assert_eq(settings.resolve("small").system_single, "Updated {context}")

		helpers.assert_eq(settings.delete_user_profile(profile.id), true)
		helpers.assert_eq(#settings.list_user(), 0)
		helpers.assert_eq(settings.get("active"), "basic")
		helpers.assert_eq(storage.get("llm.profiles.active"), "basic")
		helpers.assert_eq(settings.save_user_profile(profile, false, true), false,
			"an editor opened before deletion must not silently recreate its stale target")
		restore()
	end)

	helpers.it("publishes no candidate registry when its atomic write fails", function()
		local initial = {
			["llm.profiles.user_profiles"] = {
				{
					id = "user_retained",
					label = "Retained",
					system_single = "Keep {context}",
					batch = false,
				},
			},
		}
		local settings = load_settings(initial, true)
		helpers.assert_eq(settings.save_user_profile({
			id = "user_candidate",
			label = "Candidate",
			system_single = "Lose {context}",
			batch = false,
		}, true, false), false)
		helpers.assert_eq(#settings.list_user(), 1)
		helpers.assert_eq(settings.list_user()[1].id, "user_retained")
		restore()
	end)
end)

helpers.describe("LLM user profiles: tray reachability", function()
	helpers.it("opens the shared editor from production rows and commits its callback", function()
		local settings, storage = (function()
			local fake = Fakes.storage()
			replace("adapters.storage", fake)
			replace("modules.llm.model_profile", {
				recommend = function() return "basic" end,
				_reset = function() end,
			})
			package.loaded["modules.llm.profile_settings"] = nil
			local module = require("modules.llm.profile_settings")
			module._reset()
			return module, fake
		end)()
		local opened = nil
		replace("ui.prompt_editor.bridge", {
			open = function(existing, on_save, opts)
				opened = { existing = existing, on_save = on_save, opts = opts }
				return true
			end,
		})
		local rebuilds = 0
		local menu_builder = helpers.load_module("ui.menu.menu_builder")
		local context = {
			llm = {
				is_enabled = function() return true end,
				toggle = function() return true end,
				get_models = function() return {} end,
				get_current_model = function() return "small" end,
			},
			on_menu_changed = function() rebuilds = rebuilds + 1 end,
			confirm_profile_delete = function() return true end,
		}

		local function find(rows, title)
			for _, row in ipairs(rows or {}) do
				if row.title == title then return row end
				local nested = find(row.menu, title)
				if nested then return nested end
			end
			return nil
		end

		local menu = menu_builder.build(context)
		local create = find(menu, require("infra.i18n").get("menu.profiles.create_profile"))
		helpers.assert_not_nil(create,
			"the shared editor needs a production caller, not only a registered bridge")
		helpers.assert_eq(type(create.fn), "function")
		helpers.assert_eq(create.fn(), true)
		helpers.assert_eq(opened.existing, nil)
		helpers.assert_true(opened.opts.profile_id:match("^user_") ~= nil)
		local created_id = opened.opts.profile_id
		helpers.assert_eq(opened.on_save({
			id = created_id,
			label = "Menu custom",
			system_single = "Menu {context}",
			batch = false,
		}), true)
		helpers.assert_eq(storage.get("llm.profiles.active"), created_id)
		helpers.assert_eq(rebuilds, 1)

		menu = menu_builder.build(context)
		local custom = find(menu, "Menu custom")
		helpers.assert_not_nil(custom)
		local edit = find(custom.menu, require("infra.i18n").get("menu.profiles.edit_profile"))
		helpers.assert_not_nil(edit)
		helpers.assert_eq(edit.fn(), true)
		helpers.assert_eq(opened.existing.id, created_id)
		helpers.assert_eq(opened.on_save({
			id = created_id,
			label = "Menu updated",
			system_single = "Updated {context}",
			batch = false,
		}), true)
		helpers.assert_eq(settings.list_user()[1].label, "Menu updated")
		restore()
	end)
end)
