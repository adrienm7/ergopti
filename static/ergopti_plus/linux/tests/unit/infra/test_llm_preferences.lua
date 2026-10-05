--- tests/unit/infra/test_llm_preferences.lua

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Codec = require("toml_codec")
local SETTINGS = { "settings", "trigger_settings", "display_settings", "navigation_settings" }

local function with_config(source, body)
	Sandbox.with_config(source, function(path)
		local names = { "infra.config_paths", "infra.llm_preferences", "adapters.storage" }
		for _, name in ipairs(SETTINGS) do names[#names + 1] = "modules.llm." .. name end
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = require("tests.fakes").storage({ initial = {
				["llm.generation.temperature"] = 0.2, ["llm.trigger.debounce_ms"] = 300,
				["llm.display.show_info_bar"] = true,
			} })
			body(path)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("canonical Linux AI settings", function()
	helpers.it("round-trips the agent-mode enum through the real durable owner without changing neighbors", function()
		with_config('[llm]\nagent_mode = "auto"\nfuture = "keep"\n[other]\nvalue = 42\n', function(path)
			local preferences = require("infra.llm_preferences")
			helpers.assert_eq(preferences.get("llm.agent_mode"), "auto")
			helpers.assert_eq(preferences.set("llm.agent_mode", "action"), true)
			local document = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(document.llm.agent_mode, "action")
			helpers.assert_eq(document.llm.future, "keep")
			helpers.assert_eq(document.other.value, 42)
			package.loaded["infra.llm_preferences"] = nil
			preferences = require("infra.llm_preferences")
			helpers.assert_eq(preferences.get("llm.agent_mode"), "action", "a fresh reader owns the durable value")
			helpers.assert_eq(preferences.set("llm.agent_mode", "off"), true)
			helpers.assert_nil(Codec.decode(Sandbox.read_bytes(path)).llm.agent_mode, "the neutral default remains sparse")
		end)
	end)

	helpers.it("refuses nonmember agent-mode values and preserves actual configuration bytes", function()
		with_config('[llm]\nagent_mode = "action"\nfuture = "keep"\n', function(path)
			local preferences = require("infra.llm_preferences")
			local before = Sandbox.read_bytes(path)
			for _, invalid in ipairs({ "AUTO", "sometimes", false, 1, {} }) do
				helpers.assert_eq(preferences.set("llm.agent_mode", invalid), false)
				helpers.assert_eq(Sandbox.read_bytes(path), before)
			end
			helpers.assert_eq(preferences.get("llm.agent_mode"), "action")
		end)
	end)

	helpers.it("cleanup retains consumed AI leaves and lists unknown neighbors", function()
		with_config('[llm.generation]\ntemperature = 0.9\nfuture = 42\n[llm.trigger]\nafter_hotstring = false\n'
			.. '[llm.display]\nshow_info_bar = false\n[llm.navigation]\nval_modifiers = ["ctrl"]\n', function(path)
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(scan.status, "ok")
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].key, "future")
		end)
	end)

	helpers.it("reads canonical generation and trigger values instead of legacy storage", function()
		with_config('[llm.generation]\ntemperature = 0.9\n[llm.trigger]\ndebounce_ms = 750\n', function()
			helpers.assert_eq(require("modules.llm.settings").get("temperature"), 0.9)
			helpers.assert_eq(require("modules.llm.trigger_settings").get("debounce_ms"), 750)
		end)
	end)

	helpers.it("writes sparse settings and reloads from disk while preserving unknown neighbors", function()
		with_config('[llm.generation]\nfuture = "keep"\n[other]\nvalue = 42\n', function(path)
			local settings = require("modules.llm.settings")
			helpers.assert_true(settings.set("temperature", 0.9))
			local document = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(document.llm.generation.temperature, 0.9)
			helpers.assert_eq(document.llm.generation.future, "keep")
			helpers.assert_eq(document.other.value, 42)
			package.loaded["modules.llm.settings"] = nil
			settings = require("modules.llm.settings")
			helpers.assert_eq(settings.get("temperature"), 0.9)
			helpers.assert_true(settings.set("temperature", require("infra.manifest_reader").default_for("llm.generation.temperature")))
			helpers.assert_nil(Codec.decode(Sandbox.read_bytes(path)).llm.generation.temperature)
		end)
	end)

	helpers.it("keeps false display values and modifier arrays across a fresh reader", function()
		with_config('[llm.display]\nshow_info_bar = false\n[llm.navigation]\nval_modifiers = ["ctrl", "shift"]\n', function(path)
			helpers.assert_eq(require("modules.llm.display_settings").get("show_info_bar"), false)
			local navigation = require("modules.llm.navigation_settings")
			helpers.assert_eq(table.concat(navigation.get(), "+"), "ctrl+shift")
			helpers.assert_true(navigation.set({ "cmd" }))
			package.loaded["modules.llm.navigation_settings"] = nil
			helpers.assert_eq(require("modules.llm.navigation_settings").get()[1], "cmd")
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).llm.navigation.val_modifiers[1], "cmd")
		end)
	end)

	helpers.it("ignores an old-shape canonical value without a legacy fallback or overwrite (config-outdated-llm)", function()
		-- An outdated value is read as absent (the manifest value), never as the
		-- legacy storage value, never raised on, and offered by the cleanup.
		with_config('[llm.generation]\ntemperature = "bad"\n', function(path)
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq(require("modules.llm.settings").get("temperature"),
				require("infra.manifest_reader").default_for("llm.generation.temperature"))
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key }, { "llm.generation", "temperature" })
		end)
	end)
end)

helpers.describe("AI enable source generation (ai-enable-admission)", function()
	helpers.it("records acknowledged A-B-A writes and refuses an old enable source (ai-enable-admission)", function()
		with_config('[llm]\nenabled = false\n[llm.models]\nollama = "model:2b"\n[future]\nkeep = "personal"\n', function(path)
			local preferences = require("infra.llm_preferences")
			local _, source = preferences.get_many({ "llm.enabled", "llm.models.ollama" })
			local initial = preferences.generation()
			helpers.assert_true(preferences.set("llm.models.ollama", "model:3b"))
			helpers.assert_true(preferences.set("llm.models.ollama", "model:2b"))
			helpers.assert_true(preferences.generation() > initial)
			local external = assert(io.open(path, "ab"))
			external:write("\n# External edit while enable is pending\n")
			external:close()
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq(preferences.set_many({ ["llm.enabled"] = true }, source), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before, "the existing writer rejects the stale exact source")
			helpers.assert_eq(Codec.decode(before).future.keep, "personal")
		end)
	end)

	helpers.it("a refused scoped write never advances the acknowledged revision (ai-enable-admission)", function()
		with_config('[llm]\nenabled = false\n', function(path)
			local preferences = require("infra.llm_preferences")
			local owner = { pending = function() return false end }
			local initial = preferences.generation()
			helpers.assert_true(preferences.acquire(owner))
			helpers.assert_true(preferences.generation() > initial, "scope acquisition fences pending enables")
			local scoped = preferences.generation()
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq(preferences.set("llm.enabled", true), false)
			helpers.assert_eq(preferences.generation(), scoped)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_true(preferences.release(owner))
		end)
	end)
end)

helpers.describe("Linux real AI root dotted scalar publication", function()
	local vectors = {
		{ name = "header", source = '[llm]\nagent_mode="auto"\nfuture=9007199254740993\n', expected = '[llm]\nagent_mode = "action"\nfuture=9007199254740993\n', accepted = true },
		{ name = "root dotted", source = 'llm.agent_mode="auto"\nfuture.keep=9007199254740993\n', expected = 'llm.agent_mode = "action"\nfuture.keep=9007199254740993\n', accepted = true },
		{ name = "root inline", source = 'llm={agent_mode="auto",future=9007199254740993}\n', accepted = false },
		{ name = "obsolete scalar", source = 'llm="obsolete"\nfuture.keep=9007199254740993\n', accepted = false },
	}
	for _, vector in ipairs(vectors) do
		helpers.it("uses the actual native source owner for " .. vector.name, function()
			with_config(vector.source, function(path)
				local preferences = require("infra.llm_preferences")
				helpers.assert_eq(Sandbox.read_bytes(path), vector.source)
				helpers.assert_eq(preferences.set("llm.agent_mode", "action"), vector.accepted)
				helpers.assert_eq(Sandbox.read_bytes(path), vector.expected or vector.source, "complete independently handwritten physical image")
				package.loaded["infra.llm_preferences"] = nil
				local restarted = require("infra.llm_preferences").get("llm.agent_mode")
				if vector.accepted then helpers.assert_eq(restarted, "action")
				elseif vector.name == "root inline" then helpers.assert_eq(restarted, "auto")
				else helpers.assert_nil(restarted) end
			end)
		end)
	end
end)

helpers.describe("Linux real root dotted numeric admission", function()
	helpers.it("acknowledges the exact requested finite temperature and reloads it without rounding", function()
		with_config('llm.generation.temperature=0.25\nfuture.keep=9007199254740993\n', function(path)
			local requested = 0.12345678901234567
			local preferences = require("infra.llm_preferences")
			helpers.assert_true(preferences.set("llm.generation.temperature", requested))
			helpers.assert_eq(Sandbox.read_bytes(path), 'llm.generation.temperature = 0.12345678901234566\nfuture.keep=9007199254740993\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), requested)
		end)
	end)
end)
