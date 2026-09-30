--- tests/unit/modules/llm/test_model_preferences_canonical.lua

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Codec = require("toml_codec")

local function with_config(source, body)
	Sandbox.with_config(source, function(path)
		local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.profiles",
			"modules.llm.prediction_engine", "adapters.storage" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = require("tests.fakes").storage({ initial = {
				["llm.model"] = "legacy-model", ["llm.enabled"] = true, ["llm.models.selected"] = "ollama",
			} })
			body(path)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("canonical Linux model preferences", function()
	helpers.it("loads canonical model and consent without importing the legacy store", function()
		with_config('[llm]\nenabled = false\n[llm.models]\nollama = "canonical-model"\n', function()
			local profiles = require("modules.llm.profiles")
			profiles.init()
			helpers.assert_eq(profiles.get_current_model(), "canonical-model")
			helpers.assert_eq(profiles.is_enabled(), false)
		end)
	end)

	helpers.it("takes absence from the manifest and persists only explicit changes", function()
		with_config('[llm]\nfuture = "keep"\n', function(path)
			local manifest = require("infra.manifest_reader")
			local profiles = require("modules.llm.profiles")
			profiles.init()
			helpers.assert_eq(profiles.is_enabled(), manifest.default_for("llm.enabled"))
			helpers.assert_eq(profiles.get_current_model(), manifest.default_for("llm.models.ollama"))
			helpers.assert_true(profiles.set_model("chosen-model"))
			helpers.assert_true(profiles.enable())
			local stored = Codec.decode(Sandbox.read_bytes(path)).llm
			helpers.assert_eq(stored.enabled, true)
			helpers.assert_eq(stored.models.ollama, "chosen-model")
			helpers.assert_eq(stored.future, "keep")
			helpers.assert_true(profiles.disable())
			helpers.assert_nil(Codec.decode(Sandbox.read_bytes(path)).llm.enabled)
		end)
	end)

	helpers.it("reads the canonical backend and reports a refused save", function()
		with_config('[llm.models]\nselected = "api"\n', function(path)
			local engine = require("modules.llm.prediction_engine")
			helpers.assert_eq(engine.get_backend(), "api")
			local writer = require("toml_codec.writer")
			local original = writer.batch_write
			local before = Sandbox.read_bytes(path)
			writer.batch_write = function() return false, "fixture refusal" end
			local ok, err = pcall(function()
				helpers.assert_eq(engine.set_backend("ollama"), false)
				helpers.assert_eq(engine.get_backend(), "api")
				helpers.assert_eq(Sandbox.read_bytes(path), before)
			end)
			writer.batch_write = original
			if not ok then error(err, 0) end
			helpers.assert_true(engine.set_backend("ollama"))
			local stored = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_nil(stored.llm and stored.llm.models and stored.llm.models.selected)
		end)
	end)

	helpers.it("reads a retired backend as the default, warns once and offers it (config-outdated-llm-backend)", function()
		local source = '[llm.models]\nselected = "openai"\n'
		with_config(source, function()
			require("config_outdated").reset_for_tests()
			local engine = require("modules.llm.prediction_engine")
			local reported = require("config_outdated").collect_reports(function()
				helpers.assert_eq(engine.get_backend(), require("infra.manifest_reader").default_for("llm.models.selected"),
					"a retired backend never raises on the menu or typing path")
			end)
			helpers.assert_eq(reported, { ["llm.models.selected"] = true })
			local scan = require("config_unused_keys").find_in_source(source,
				require("ui.menu.unused_keys_cleanup").collect)
			helpers.assert_eq(#scan.keys, 1, "the cleanup offers what the reader ignores")
			helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key }, { "llm.models", "selected" })
		end)
	end)

	helpers.it("keeps the prior model and consent after a refused canonical write", function()
		with_config('[llm]\nenabled = false\n[llm.models]\nollama = "canonical-model"\n', function(path)
			local profiles = require("modules.llm.profiles")
			profiles.init()
			local preferences = require("infra.llm_preferences")
			local original = preferences.set
			preferences.set = function() return false end
			local before = Sandbox.read_bytes(path)
			local ok, err = pcall(function()
				helpers.assert_eq(profiles.set_model("refused-model"), false)
				helpers.assert_eq(profiles.enable(), false)
				helpers.assert_eq(profiles.get_current_model(), "canonical-model")
				helpers.assert_eq(profiles.is_enabled(), false)
				helpers.assert_eq(Sandbox.read_bytes(path), before)
			end)
			preferences.set = original
			if not ok then error(err, 0) end
		end)
	end)
end)
