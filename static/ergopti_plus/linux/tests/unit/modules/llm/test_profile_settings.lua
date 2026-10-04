--- tests/unit/modules/llm/test_profile_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Profile Controls
--- DESCRIPTION:
--- Proves profile persistence, model-driven recommendation, and atomic manual
--- override semantics without an Ollama process.
--- ==============================================================================

local helpers = require("tests.helpers")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")
local RegistryCodec = require("modules.llm.profile_registry_codec")

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
		local encoded = {}
		for key, value in pairs(initial or {}) do
			encoded[key] = key == "llm.user_profiles" and RegistryCodec.encode(value) or value
		end
		local storage = PreferencesFixture.new({ initial = encoded, writes_fail = writes_fail })
		replace("infra.llm_preferences", storage)
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

	helpers.it("keeps every other prompt when one stored entry is unreadable", function()
		local good_a = { id = "user_a", label = "A", system_single = "Style A {context}", batch = false }
		local broken = { id = "user_broken", label = "", system_single = "", batch = "yes" }
		local good_b = { id = "user_b", label = "B", system_single = "Style B {context}", batch = false }
		local settings, storage = load_settings({ ["llm.user_profiles"] = { good_a, broken, good_b } })
		local offered = settings.list_user()
		helpers.assert_eq(#offered, 2, "the readable prompts are still offered")
		helpers.assert_true(settings.save_user_profile(
			{ id = "user_c", label = "C", system_single = "Style C {context}", batch = false }, false, false))
		local stored = RegistryCodec.decode(storage.get("llm.user_profiles") or "")
		helpers.assert_eq(#stored, 4, "A, B, the new C, and the unreadable entry, untouched")
		local ids = {}
		for _, entry in ipairs(stored) do ids[#ids + 1] = entry.id end
		helpers.assert_eq(table.concat(ids, ","), "user_a,user_b,user_c,user_broken")
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
			type(RegistryCodec.decode(storage.get("llm.user_profiles") or "")[1].system_multi_template) == "string"
				and RegistryCodec.decode(storage.get("llm.user_profiles") or "")[1].system_multi_template ~= "",
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
		helpers.assert_nil(storage.get("llm.profiles.active"), "the neutral active profile remains sparse")
		helpers.assert_eq(settings.save_user_profile(profile, false, true), false,
			"an editor opened before deletion must not silently recreate its stale target")
		restore()
	end)

	helpers.it("publishes no candidate registry when its atomic write fails", function()
		local initial = {
			["llm.user_profiles"] = {
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
			local fake = PreferencesFixture.new()
			replace("infra.llm_preferences", fake)
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
		local editor_accepted = true
		local editor_calls = 0
		replace("ui.prompt_editor.bridge", {
			open = function(existing, on_save, opts)
				editor_calls = editor_calls + 1
				opened = { existing = existing, on_save = on_save, opts = opts }
				return editor_accepted
			end,
		})
		local rebuilds = 0
		local opened_window = nil
		local menu_builder = helpers.load_module("ui.menu.menu_builder")
		local paused = false
		local context = {
			is_paused = function() return paused end,
			llm = {
				is_enabled = function() return true end,
				toggle = function() return true end,
				get_models = function() return {} end,
				get_current_model = function() return "small" end,
			},
			webview = {
				show = function(app) opened_window = app; return true end,
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
		local browse = find(menu, require("infra.i18n").get("menu.llm.browse_models_entry"))
		helpers.assert_not_nil(browse,
			"the registered model-browser bridge needs a production menu caller")
		helpers.assert_eq(browse.fn(), true)
		helpers.assert_eq(opened_window, "model_browser")
		local create = find(menu, require("infra.i18n").get("menu.profiles.create_profile"))
		helpers.assert_not_nil(create,
			"the shared editor needs a production caller, not only a registered bridge")
		helpers.assert_eq(type(create.fn), "function")
		helpers.assert_eq(create.fn(), true)
		helpers.assert_eq(opened.existing, nil)
		helpers.assert_true(opened.opts.profile_id:match("^user_") ~= nil)
		helpers.assert_eq(editor_calls, 1)
		paused = true
		helpers.assert_eq(create.fn(), false,
			"a retained Create callback must re-read the native pause owner")
		helpers.assert_eq(editor_calls, 1, "the paused callback cannot reach the editor")
		helpers.assert_eq(opened.on_save({ id = opened.opts.profile_id,
			label = "Refused", system_single = "Refused", batch = false }), false,
			"a retained editor save must not publish while paused")
		helpers.assert_eq(#settings.list_user(), 0)
		helpers.assert_eq(rebuilds, 0)
		paused = false
		editor_accepted = false
		helpers.assert_eq(create.fn(), false, "the real editor's refusal remains refusal")
		helpers.assert_eq(#settings.list_user(), 0)
		helpers.assert_eq(rebuilds, 0)
		editor_accepted = true
		helpers.assert_eq(create.fn(), true)
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
		local Paths = require("infra.paths")
		local Json = require("json")
		local file = assert(io.open(Paths.shared("modules/menu/menu_manifest.json"), "r"))
		local document = Json.decode(file:read("*a"))
		file:close()
		document.llm_profile_commands[1].i18n = "button.cancel"
		local renderer = assert(require("menu.renderer").new({
			platform = "linux",
			manifest_path = function() return Paths.shared("modules/menu/menu_manifest.json") end,
			json_decode = function() return document end,
			i18n = require("infra.i18n"),
			logger = require("logger.shim"),
		}))
		replace("infra.manifest_menu", renderer)
		menu_builder = helpers.load_module("ui.menu.menu_builder")
		local changed = find(menu_builder.build(context), require("infra.i18n").get("button.cancel"))
		helpers.assert_not_nil(changed, "the actual Create provider follows its changed declaration")
		editor_accepted = false
		helpers.assert_eq(changed.fn(), false)
		helpers.assert_eq(settings.list_user()[1].label, "Menu updated")
		restore()
	end)
end)

helpers.describe("LLM profile settings: a prompt named by a binding", function()
	local function load_settings(initial)
		local encoded = {}
		for key, value in pairs(initial or {}) do
			encoded[key] = key == "llm.user_profiles" and RegistryCodec.encode(value) or value
		end
		replace("infra.llm_preferences", PreferencesFixture.new({ initial = encoded }))
		package.loaded["modules.llm.profile_settings"] = nil
		local settings = require("modules.llm.profile_settings")
		settings._reset()
		return settings
	end

	helpers.it("offers the rewrite prompt with the other built-ins, in menu order", function()
		local settings = load_settings()
		local ids = {}
		for index, profile in ipairs(settings.list_built_in()) do ids[index] = profile.id end
		helpers.assert_eq(table.concat(ids, ","),
			"raw,basic,advanced,batch_advanced,rewrite,tone_familiar,tone_neutral,tone_formal,tone_very_formal,translate_en,translate_ja")
		helpers.assert_true(require("llm.rewrite").is_rewrite_profile(settings.resolve_id("rewrite")),
			"the rewrite built-in is recognised by its prompt")
		helpers.assert_true(settings.set("active", "rewrite", "small"), "and selectable like the others")
		restore()
	end)

	helpers.it("resolves an exact id, built-in or custom, and never falls back to basic", function()
		local settings = load_settings({ ["llm.user_profiles"] = {
			{ id = "user_formal", label = "Formal", system_single = "Formal {context}", batch = false },
		} })
		helpers.assert_eq(settings.resolve_id("advanced").id, "advanced")
		helpers.assert_eq(settings.resolve_id("user_formal").label, "Formal")
		helpers.assert_eq(settings.resolve_id("user_deleted"), nil, "an unknown id resolves to nothing")
		helpers.assert_eq(settings.resolve_id(""), nil)
		settings.resolve_id("advanced").system_single = "tampered"
		helpers.assert_true(settings.resolve_id("advanced").system_single ~= "tampered",
			"the caller gets a detached copy")
		restore()
	end)

	helpers.it("labels a profile as the menu lists it, filling only the placeholders it has", function()
		local settings = load_settings()
		local i18n = require("infra.i18n")
		local basic = settings.resolve_id("basic")
		helpers.assert_eq(settings.menu_label(basic, 3), i18n.get("llm.profile.basic.label"),
			"a label without {n} gets no count appended")
		local batch = settings.menu_label(settings.resolve_id("batch_advanced"), 3)
		helpers.assert_true(batch:find("{n}", 1, true) == nil and batch:find("{s}", 1, true) == nil
			and batch:find("3", 1, true) ~= nil, "the batch label states the count: " .. batch)
		helpers.assert_eq(settings.menu_label({ id = "user_x", label = "50% off" }, 3), "50% off")
		restore()
	end)

	helpers.it("lists the rewrite prompt in the AI menu under its own label", function()
		local settings = load_settings({ ["llm.profiles.auto_profile_for_model"] = false })
		local menu_builder = helpers.load_module("ui.menu.menu_builder")
		local menu = menu_builder.build({
			llm = {
				is_enabled = function() return true end,
				toggle = function() return true end,
				get_models = function() return {} end,
				get_current_model = function() return "small" end,
			},
			on_menu_changed = function() end,
		})
		local function find(rows, title)
			for _, row in ipairs(rows or {}) do
				if row.title == title then return row end
				local nested = find(row.menu, title)
				if nested then return nested end
			end
		end
		local i18n = require("infra.i18n")
		local rewrite = find(menu, i18n.get("llm.profile.rewrite.label"))
		helpers.assert_not_nil(rewrite, "the rewrite prompt has its row")
		helpers.assert_not_nil(find(menu, i18n.get("llm.profile.basic.label")),
			"the basic row is its label alone, with no count appended")
		rewrite.fn()
		helpers.assert_eq(settings.get("active"), "rewrite", "choosing the row selects the prompt")
		restore()
	end)
end)

helpers.describe("shared Clone Profile command", function()
	helpers.it("shared Clone Profile preserves editor refusal, live pause and exact save acknowledgement", function()
		local ok, err = xpcall(function()
			local storage_options = {}
			local storage = PreferencesFixture.new(storage_options)
			replace("infra.llm_preferences", storage)
			replace("modules.llm.model_profile", {
				recommend = function() return "basic" end, _reset = function() end,
			})
			package.loaded["modules.llm.profile_settings"] = nil
			local settings = require("modules.llm.profile_settings")
			settings._reset()
			local opened, paused = nil, false
			local calls, refreshes = 0, 0
			local accepted = true
			replace("ui.prompt_editor.bridge", {
				open = function(existing, on_save, opts)
					calls = calls + 1
					opened = { existing = existing, on_save = on_save, opts = opts }
					return accepted
				end,
			})
			local context = {
				is_paused = function() return paused end,
				llm = {
					is_enabled = function() return true end,
					get_models = function() return {} end,
					get_current_model = function() return "small" end,
				},
				on_menu_changed = function() refreshes = refreshes + 1 end,
			}
			local function find(rows, title)
				for _, row in ipairs(rows or {}) do
					if row.title == title then return row end
					local nested = find(row.menu, title)
					if nested then return nested end
				end
				return nil
			end
			local i18n = require("infra.i18n")
			local builder = helpers.load_module("ui.menu.menu_builder")
			local row = find(builder.build(context), i18n.get("menu.profiles.clone_builtin"))
			helpers.assert_not_nil(row)
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(calls, 1)
			helpers.assert_not_nil(opened.existing)
			helpers.assert_eq(opened.opts.as_new, true)
			helpers.assert_eq(#settings.list_user(), 0, "opening the existing native clone draft does not publish it")
			paused = true
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(calls, 1)
			local profile = { id = opened.opts.profile_id, label = "Cloned", system_single = "Clone {context}", batch = false }
			helpers.assert_eq(opened.on_save(profile), false)
			helpers.assert_eq(#settings.list_user(), 0)
			helpers.assert_eq(refreshes, 0)
			paused = false
			storage_options.writes_fail = true
			helpers.assert_eq(opened.on_save(profile), false, "the real profile writer refusal remains false")
			helpers.assert_eq(#settings.list_user(), 0)
			helpers.assert_eq(refreshes, 0)
			storage_options.writes_fail = false
			helpers.assert_eq(opened.on_save(profile), true)
			helpers.assert_eq(settings.list_user()[1].label, "Cloned")
			helpers.assert_eq(storage.get("llm.profiles.active"), profile.id)
			helpers.assert_eq(refreshes, 1)
			accepted = false
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(calls, 2)
			helpers.assert_eq(refreshes, 1)
			helpers.assert_eq(settings.set("active", "basic"), true,
				"the conditional Clone row requires a real active built-in before rebuilding")
			local Paths = require("infra.paths")
			local file = assert(io.open(Paths.shared("modules/menu/menu_manifest.json"), "r"))
			local manifest = require("json").decode(file:read("*a"))
			file:close()
			for _, declaration in ipairs(manifest.llm_profile_commands) do
				if declaration.id == "llm_profile_clone" then declaration.i18n = "button.cancel" end
			end
			replace("infra.manifest_menu", assert(require("menu.renderer").new({
				platform = "linux", manifest_path = function() return Paths.shared("modules/menu/menu_manifest.json") end,
				json_decode = function() return manifest end, i18n = i18n, logger = require("logger.shim"),
			})))
			builder = helpers.load_module("ui.menu.menu_builder")
			local changed = find(builder.build(context), i18n.get("button.cancel"))
			helpers.assert_not_nil(changed, "the real Clone provider must follow only the shared declaration")
			helpers.assert_eq(changed.fn(), false)
			helpers.assert_eq(calls, 3)
			helpers.assert_eq(refreshes, 1)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("Linux automatic profile toggle: actual menu owner", function()
	local KEY = "llm.profiles.auto_profile_for_model"

	--- Runs the actual profile and menu owners with observed native boundaries.
	--- @param options table Initial state and acknowledged preference outcome.
	--- @param body function Assertions outside the native callbacks.
	local function with_menu(options, body)
		options = options or {}
		local paused, writes, redraws = false, {}, 0
		local storage = PreferencesFixture.new({ initial = {
			[KEY] = options.initial,
			["llm.profiles.active"] = "advanced",
			["future.profile_metadata"] = "keep future metadata",
		} })
		local native_write = storage.set
		storage.set = function(path, value)
			writes[#writes + 1] = { path = path, value = value }
			if options.receipt == "false" then return false end
			if options.receipt == "nil" then return nil end
			if options.receipt == "text" then return "true" end
			if options.receipt == "throw" then error("Owned profile write refused", 0) end
			return native_write(path, value)
		end
		local ok, err = xpcall(function()
			replace("infra.llm_preferences", storage)
			replace("modules.llm.model_profile", {
				recommend = function() return "basic" end,
				_reset = function() end,
			})
			replace("modules.llm.profile_settings", nil)
			local settings = require("modules.llm.profile_settings")
			settings._reset()
			local context = {
				is_paused = function() return paused end,
				llm = {
					is_enabled = function() return true end,
					toggle = function() return true end,
					get_models = function() return {} end,
					get_current_model = function() return "small" end,
				},
				on_menu_changed = function() redraws = redraws + 1 end,
			}
			local function find(rows, title)
				for _, row in ipairs(rows or {}) do
					if row.title == title then return row end
					local nested = find(row.menu, title)
					if nested then return nested end
				end
			end
			replace("ui.menu.menu_builder", nil)
			local builder = helpers.load_module("ui.menu.menu_builder")
			local menu = builder.build(context)
			local row = find(menu, require("infra.i18n").get("menu.profiles.auto_detect"))
			helpers.assert_not_nil(row, "the actual profile provider exposes its checkbox")
			helpers.assert_type(row.fn, "function")
			body({
				row = row, settings = settings, storage = storage, writes = writes,
				set_paused = function(value) paused = value end,
				redraws = function() return redraws end,
				clear_observations = function()
					for index = #writes, 1, -1 do writes[index] = nil end
					redraws = 0
				end,
			})
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end

	helpers.it("autodetect-toggle: a checked row switches off through the actual preference owner", function()
		with_menu({ initial = true }, function(fixture)
			helpers.assert_true(fixture.row.checked)
			local accepted = fixture.row.fn()
			helpers.assert_eq(fixture.settings.get("auto_profile_for_model"), false,
				"a checked checkbox must not keep writing true")
			helpers.assert_eq(fixture.storage.get(KEY, true), false)
			helpers.assert_eq(fixture.settings.effective_profile("small"), "advanced")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.writes, 1)
			helpers.assert_eq(fixture.writes[1].path, KEY)
			helpers.assert_eq(fixture.writes[1].value, false)
			helpers.assert_eq(fixture.redraws(), 1)
			helpers.assert_eq(fixture.storage.get("future.profile_metadata"), "keep future metadata")
		end)
	end)

	helpers.it("autodetect-toggle: an unchecked row switches on and retains sparse defaults", function()
		with_menu({ initial = false }, function(fixture)
			helpers.assert_eq(fixture.row.checked == true, false)
			local accepted = fixture.row.fn()
			helpers.assert_eq(fixture.settings.get("auto_profile_for_model"), true)
			helpers.assert_eq(fixture.storage.get(KEY, true), true)
			helpers.assert_eq(fixture.storage.get(KEY), nil,
				"the existing preference owner removes its shared default")
			helpers.assert_eq(fixture.settings.effective_profile("small"), "basic")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.writes, 1)
			helpers.assert_eq(fixture.writes[1].value, true)
			helpers.assert_eq(fixture.redraws(), 1)
		end)
	end)

	helpers.it("autodetect-toggle: a retained row toggles the freshly adopted owner value", function()
		with_menu({ initial = false }, function(fixture)
			helpers.assert_eq(fixture.settings.set("auto_profile_for_model", true, "small"), true)
			fixture.clear_observations()
			local accepted = fixture.row.fn()
			helpers.assert_eq(fixture.settings.get("auto_profile_for_model"), false)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.writes, 1)
			helpers.assert_eq(fixture.writes[1].value, false)
			helpers.assert_eq(fixture.redraws(), 1)
		end)
	end)

	helpers.it("autodetect-toggle: live pause refuses a held command before writing", function()
		with_menu({ initial = true }, function(fixture)
			fixture.set_paused(true)
			local accepted = fixture.row.fn()
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#fixture.writes, 0)
			helpers.assert_eq(fixture.redraws(), 0)
			helpers.assert_eq(fixture.settings.get("auto_profile_for_model"), true)
			helpers.assert_eq(fixture.storage.get(KEY), true)
		end)
	end)

	helpers.it("autodetect-toggle: pause reentry during the live read cannot reach publication", function()
		with_menu({ initial = true }, function(fixture)
			local get = fixture.settings.get
			fixture.settings.get = function(name)
				local value = get(name)
				if name == "auto_profile_for_model" then fixture.set_paused(true) end
				return value
			end
			local accepted = fixture.row.fn()
			fixture.settings.get = get
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#fixture.writes, 0)
			helpers.assert_eq(fixture.redraws(), 0)
			helpers.assert_eq(fixture.settings.get("auto_profile_for_model"), true)
		end)
	end)

	helpers.it("autodetect-toggle: unknown live boolean receipts cannot reach the writer", function()
		for _, unknown in ipairs({ { value = 0 }, { value = "false" }, { value = {} }, {} }) do
			with_menu({ initial = true }, function(fixture)
				local get = fixture.settings.get
				fixture.settings.get = function(name)
					if name == "auto_profile_for_model" then return unknown.value end
					return get(name)
				end
				local accepted = fixture.row.fn()
				fixture.settings.get = get
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(#fixture.writes, 0)
				helpers.assert_eq(fixture.redraws(), 0)
				helpers.assert_eq(fixture.settings.get("auto_profile_for_model"), true)
			end)
		end
	end)

	for _, receipt in ipairs({ "false", "nil", "text", "throw" }) do
		helpers.it("autodetect-toggle: " .. receipt .. " write refusal retains runtime and menu state", function()
			with_menu({ initial = true, receipt = receipt }, function(fixture)
				local ok, accepted = pcall(fixture.row.fn)
				if receipt == "throw" then
					helpers.assert_eq(ok, false)
				else
					helpers.assert_true(ok)
					helpers.assert_eq(accepted, false)
				end
				helpers.assert_eq(#fixture.writes, 1)
				helpers.assert_eq(fixture.settings.get("auto_profile_for_model"), true)
				helpers.assert_eq(fixture.storage.get(KEY), true)
				helpers.assert_eq(fixture.storage.get("future.profile_metadata"), "keep future metadata")
				helpers.assert_eq(fixture.redraws(), 0)
			end)
		end)
	end
end)
