--- tests/unit/infra/preferences/test_llm_preferences.lua

local helpers = require("tests.helpers")
local Sandbox = require("tests.lua.settings.unused_keys_contract").sandbox
local Codec = require("core.text.engine.toml_codec")
-- Source literals can lose their zero sign on some LuaJIT builds.
-- Establish the intended IEEE sign before calling any producer under test.
local function negative_zero()
	local value = tonumber("-0.0")
	helpers.assert_eq(type(value), "number", "negative-zero request must be numeric")
	helpers.assert_eq(1 / value, -math.huge, "negative-zero request must retain its actual sign")
	return value
end
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

helpers.describe("AI preference classification", function()
	for _, vector in ipairs({
		{ name = "absent", content = "[llm.trigger]\n", status = "absent" },
		{ name = "valid array", content = '[llm.trigger]\ndisabled_apps = ["firefox"]\n', status = "ok", value = { "firefox" } },
		{ name = "wrong leaf", content = '[llm.trigger]\ndisabled_apps = "firefox"\n', status = "invalid" },
		{ name = "wrong parent", content = '[llm]\ntrigger = "firefox"\n', status = "invalid" },
	}) do
		helpers.it("classifies " .. vector.name .. " without changing source bytes", function()
			with_config(vector.content, function(path)
				local preferences = require("infra.llm_preferences")
				local before = Sandbox.read_bytes(path)
				local value, status = preferences.get_with_status("llm.trigger.disabled_apps")
				helpers.assert_eq(status, vector.status)
				helpers.assert_eq(value, vector.value)
				helpers.assert_eq(Sandbox.read_bytes(path), before)
				if value then value[1] = "mutated"; helpers.assert_eq(preferences.get("llm.trigger.disabled_apps"), vector.value) end
			end)
		end)
	end
end)

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

	helpers.it("refuses a minimum that exceeds the current saved maximum", function()
		with_config('[llm.generation]\nmin_words = 1\nmax_words = 10\n', function(path)
			local settings = require("modules.llm.settings")
			helpers.assert_eq(settings.get("max_words"), 10)
			local successor = '[llm.generation]\nmin_words = 1\nmax_words = 3\n'
			local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
			helpers.assert_eq(settings.set("min_words", 5), false)
			helpers.assert_eq(Sandbox.read_bytes(path), successor)
		end)
	end)

	helpers.it("refuses a bound read from a different image than the retained source", function()
		local first = '[llm.generation]\nmax_words = 3\n'
		local interim = '[llm.generation]\nmax_words = 10\n'
		with_config(first, function(path)
			local preferences = require("infra.llm_preferences")
			local _, expected = preferences.get_many({ "llm.generation.max_words" })
			local file = assert(io.open(path, "wb")); assert(file:write(interim)); assert(file:close())
			local original = preferences.get_many
			preferences.get_many = function(...)
				local values, source, revision = original(...)
				local restore = assert(io.open(path, "wb")); assert(restore:write(first)); assert(restore:close())
				return values, source, revision
			end
			local settings = require("modules.llm.settings")
			local ok, accepted = pcall(settings.set, "min_words", 5, expected, function() return true end)
			preferences.get_many = original
			helpers.assert_true(ok)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(Sandbox.read_bytes(path), first)
		end)
	end)

	helpers.it("accepts generation bounds against the retained matching image", function()
		with_config('[llm.generation]\nmax_words = 3\n', function(path)
			local preferences = require("infra.llm_preferences")
			local _, expected = preferences.get_many({ "llm.generation.max_words" })
			local settings = require("modules.llm.settings")
			helpers.assert_true(settings.set("min_words", 2, expected, function() return true end))
			local document = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(document.llm.generation.max_words, 3)
			helpers.assert_eq(document.llm.generation.min_words, 2)
		end)
	end)

	helpers.it("refuses generation bounds when the source changes before publication", function()
		with_config('[llm.generation]\nmax_words = 10\n', function(path)
			local settings = require("modules.llm.settings")
			local writer = require("core.text.engine.toml_codec.writer")
			local original = writer.batch_write
			local successor = '[llm.generation]\nmax_words = 3\n'
			writer.batch_write = function(...)
				local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
				return original(...)
			end
			local ok, result = pcall(settings.set, "min_words", 5)
			writer.batch_write = original
			helpers.assert_true(ok)
			helpers.assert_eq(result, false)
			helpers.assert_eq(Sandbox.read_bytes(path), successor)
		end)
	end)

	helpers.it("reclassifies malformed automatic exclusions after another trigger edit", function()
		with_config('[llm.trigger]\ndisabled_apps = []\n', function(path)
			local settings = require("modules.llm.trigger_settings")
			helpers.assert_eq(settings.is_app_disabled("editor", true), false)
			local file = assert(io.open(path, "wb"))
			assert(file:write('[llm.trigger]\ndisabled_apps = ["firefox", "Firefox"]\n')); assert(file:close())
			helpers.assert_true(settings.set("debounce_ms", 600))
			helpers.assert_eq(settings.is_app_disabled("editor", true), true)
			helpers.assert_eq(settings.is_app_disabled("editor"), false, "manual policy is unchanged")
			local snapshot = settings.configuration_snapshot()
			settings._reset()
			helpers.assert_true(settings.restore_configuration(snapshot))
			helpers.assert_eq(settings.is_app_disabled("editor", true), true)
		end)
	end)

	helpers.it("refreshes automatic app exclusions after editing another trigger setting", function()
		with_config('[llm.trigger]\ndisabled_apps = []\n', function(path)
			local settings = require("modules.llm.trigger_settings")
			helpers.assert_eq(settings.is_app_disabled("firefox", true), false)
			local file = assert(io.open(path, "wb"))
			assert(file:write('[llm.trigger]\ndisabled_apps = ["firefox"]\n')); assert(file:close())
			helpers.assert_true(settings.set("debounce_ms", 600))
			helpers.assert_eq(settings.is_app_disabled("firefox", true), true)
		end)
	end)

	helpers.it("refreshes neighboring generation settings after an external edit", function()
		with_config('[llm.generation]\ntemperature = 0.2\n', function(path)
			local settings = require("modules.llm.settings")
			helpers.assert_eq(settings.get("temperature"), 0.2)
			local file = assert(io.open(path, "wb"))
			assert(file:write('[llm.generation]\ntemperature = 0.9\n')); assert(file:close())
			helpers.assert_true(settings.set("context_length", 600))
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).llm.generation.temperature, 0.9)
			helpers.assert_eq(settings.get("temperature"), 0.9)
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
		{ name = "root inline", source = 'llm={agent_mode="auto",future=9007199254740993}\n', expected = 'llm={agent_mode="action",future=9007199254740993}\n', accepted = true },
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

helpers.describe("Linux real finite header numeric admission", function()
	helpers.it("reloads an acknowledged exact temperature while keeping foreign source tokens", function()
		with_config('[llm.generation]\ntemperature=0.25\nfuture=9007199254740993\n', function(path)
			local requested = 0.12345678901234567
			local preferences = require("infra.llm_preferences")
			helpers.assert_true(preferences.set("llm.generation.temperature", requested))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm.generation]\ntemperature = 0.12345678901234566\nfuture=9007199254740993\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), requested)
		end)
	end)

	helpers.it("refuses a wrong optional literal with no write or generation ACK and permits a repaired retry", function()
		local source = '[llm.generation]\ntemperature=0.25\nfuture=9007199254740993\n'
		with_config(source, function(path)
			local preferences = require("infra.llm_preferences")
			local LeafRows = require("core.text.engine.toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			local generation = preferences.generation()
			LeafRows.value_literal = function() return "0.12345678901235" end
			local called, accepted = pcall(preferences.set, "llm.generation.temperature", 0.12345678901234567)
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(preferences.generation(), generation)
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			helpers.assert_true(preferences.set("llm.generation.temperature", 0.12345678901234567))
			helpers.assert_true(preferences.generation() > generation, "only an acknowledged write or observed changed source advances the revision")
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm.generation]\ntemperature = 0.12345678901234566\nfuture=9007199254740993\n')
		end)
	end)
	helpers.it("retains acknowledged negative zero through actual native preference restart", function()
		with_config('[llm.generation]\ntemperature=0.25\nfuture=9007199254740993\n', function(path)
			local preferences = require("infra.llm_preferences")
			helpers.assert_true(preferences.set("llm.generation.temperature", negative_zero()))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm.generation]\ntemperature = -0.0\nfuture=9007199254740993\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_eq(1 / require("infra.llm_preferences").get("llm.generation.temperature"), -math.huge)
		end)
	end)
end)

helpers.describe("Linux real root inline scalar publication", function()
	local source = 'llm = { generation = { temperature=0.25, future=9007199254740993 }, private="untouched" } # exact trailer\n'
	helpers.it("acknowledges precise inline temperature and restarts the actual source owner", function()
		with_config(source, function(path)
			local preferences = require("infra.llm_preferences")
			local wanted = 0.12345678901234567
			helpers.assert_true(preferences.set("llm.generation.temperature", wanted))
			helpers.assert_eq(Sandbox.read_bytes(path), 'llm = { generation = { temperature=0.12345678901234566, future=9007199254740993 }, private="untouched" } # exact trailer\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), wanted)
		end)
	end)
	helpers.it("retains acknowledged inline negative zero and exact foreign bytes through restart", function()
		with_config(source, function(path)
			helpers.assert_true(require("infra.llm_preferences").set("llm.generation.temperature", negative_zero()))
			helpers.assert_eq(Sandbox.read_bytes(path), 'llm = { generation = { temperature=-0.0, future=9007199254740993 }, private="untouched" } # exact trailer\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_eq(1 / require("infra.llm_preferences").get("llm.generation.temperature"), -math.huge)
		end)
	end)
	helpers.it("deletes only the explicitly reset inline leaf and restarts at its manifest default", function()
		with_config(source, function(path)
			helpers.assert_true(require("infra.llm_preferences").delete("llm.generation.temperature"))
			helpers.assert_eq(Sandbox.read_bytes(path), 'llm = { generation = { future=9007199254740993 }, private="untouched" } # exact trailer\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_nil(require("infra.llm_preferences").get("llm.generation.temperature"), "the native reader owns absence after explicit deletion")
			helpers.assert_eq(require("modules.llm.settings").get("temperature"), require("infra.manifest_reader").default_for("llm.generation.temperature"))
		end)
	end)
	helpers.it("refuses an inexact inline literal with unchanged revision then accepts a repaired explicit retry", function()
		with_config(source, function(path)
			local preferences = require("infra.llm_preferences")
			local revision = preferences.generation()
			local LeafRows = require("core.text.engine.toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			LeafRows.value_literal = function() return "0.12345678901235" end
			local called, accepted = pcall(preferences.set, "llm.generation.temperature", 0.12345678901234567)
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			helpers.assert_eq(preferences.generation(), revision)
			helpers.assert_true(preferences.set("llm.generation.temperature", 0.12345678901234567))
			helpers.assert_eq(Sandbox.read_bytes(path), 'llm = { generation = { temperature=0.12345678901234566, future=9007199254740993 }, private="untouched" } # exact trailer\n')
		end)
	end)
	helpers.it("keeps an actual external inline successor and refuses the stale source owner", function()
		with_config(source, function(path)
			local successor = source .. '# external successor\n'
			local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
			local preferences = require("infra.llm_preferences")
			helpers.assert_eq(preferences.set_many({ ["llm.generation.temperature"] = 0.75 }, { status = "ok", content = source }), false)
			helpers.assert_eq(Sandbox.read_bytes(path), successor)
			helpers.assert_true(preferences.set("llm.generation.temperature", 0.75))
			helpers.assert_eq(Sandbox.read_bytes(path), 'llm = { generation = { temperature=0.75, future=9007199254740993 }, private="untouched" } # exact trailer\n# external successor\n')
		end)
	end)
end)

helpers.describe("Linux real section-relative dotted scalar publication", function()
	local source = '[llm] # exact header\ngeneration.temperature=0.25 # owned scalar\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n'
	helpers.it("acknowledges precise section-relative dotted temperature and restarts the actual source owner", function()
		with_config(source, function(path)
			local preferences = require("infra.llm_preferences")
			local wanted = 0.12345678901234567
			helpers.assert_true(preferences.set("llm.generation.temperature", wanted))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration.temperature = 0.12345678901234566\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), wanted)
		end)
	end)
	helpers.it("retains acknowledged section-relative dotted negative zero and exact foreign bytes through restart", function()
		with_config(source, function(path)
			helpers.assert_true(require("infra.llm_preferences").set("llm.generation.temperature", negative_zero()))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration.temperature = -0.0\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_eq(1 / require("infra.llm_preferences").get("llm.generation.temperature"), -math.huge)
		end)
	end)
	helpers.it("deletes only the explicitly reset section-relative dotted leaf and restarts at its manifest default", function()
		with_config(source, function(path)
			helpers.assert_true(require("infra.llm_preferences").delete("llm.generation.temperature"))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_nil(require("infra.llm_preferences").get("llm.generation.temperature"), "the native reader owns absence after explicit deletion")
			helpers.assert_eq(require("modules.llm.settings").get("temperature"), require("infra.manifest_reader").default_for("llm.generation.temperature"))
		end)
	end)
	helpers.it("refuses an inexact section-relative dotted literal with unchanged revision then accepts a repaired explicit retry", function()
		with_config(source, function(path)
			local preferences = require("infra.llm_preferences")
			local revision = preferences.generation()
			local LeafRows = require("core.text.engine.toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			LeafRows.value_literal = function() return "0.12345678901235" end
			local called, accepted = pcall(preferences.set, "llm.generation.temperature", 0.12345678901234567)
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			helpers.assert_eq(preferences.generation(), revision)
			helpers.assert_true(preferences.set("llm.generation.temperature", 0.12345678901234567))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration.temperature = 0.12345678901234566\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n')
		end)
	end)
	helpers.it("keeps an actual external section-relative dotted successor and refuses the stale source owner", function()
		with_config(source, function(path)
			local successor = source .. '# external successor\n'
			local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
			local preferences = require("infra.llm_preferences")
			helpers.assert_eq(preferences.set_many({ ["llm.generation.temperature"] = 0.75 }, { status = "ok", content = source }), false)
			helpers.assert_eq(Sandbox.read_bytes(path), successor)
			helpers.assert_true(preferences.set("llm.generation.temperature", 0.75))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration.temperature = 0.75\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n# external successor\n')
		end)
	end)
end)

helpers.describe("Linux real section-relative inline scalar publication", function()
	local source = '[llm] # exact header\ngeneration = { temperature=0.25, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n'
	helpers.it("acknowledges precise section-relative inline temperature and restarts the actual source owner", function()
		with_config(source, function(path)
			local preferences = require("infra.llm_preferences")
			local wanted = 0.12345678901234567
			helpers.assert_true(preferences.set("llm.generation.temperature", wanted))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration = { temperature=0.12345678901234566, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), wanted)
		end)
	end)
	helpers.it("retains acknowledged section-relative inline negative zero and exact foreign bytes through restart", function()
		with_config(source, function(path)
			helpers.assert_true(require("infra.llm_preferences").set("llm.generation.temperature", negative_zero()))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration = { temperature=-0.0, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_eq(1 / require("infra.llm_preferences").get("llm.generation.temperature"), -math.huge)
		end)
	end)
	helpers.it("deletes only the explicitly reset section-relative inline leaf and restarts at its manifest default", function()
		with_config(source, function(path)
			helpers.assert_true(require("infra.llm_preferences").delete("llm.generation.temperature"))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration = { future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n')
			package.loaded["infra.llm_preferences"] = nil
			helpers.assert_nil(require("infra.llm_preferences").get("llm.generation.temperature"), "the native reader owns absence after explicit deletion")
			helpers.assert_eq(require("modules.llm.settings").get("temperature"), require("infra.manifest_reader").default_for("llm.generation.temperature"))
		end)
	end)
	helpers.it("refuses an inexact section-relative inline literal with unchanged revision then accepts a repaired explicit retry", function()
		with_config(source, function(path)
			local preferences = require("infra.llm_preferences")
			local revision = preferences.generation()
			local LeafRows = require("core.text.engine.toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			LeafRows.value_literal = function() return "0.12345678901235" end
			local called, accepted = pcall(preferences.set, "llm.generation.temperature", 0.12345678901234567)
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			helpers.assert_eq(preferences.generation(), revision)
			helpers.assert_true(preferences.set("llm.generation.temperature", 0.12345678901234567))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration = { temperature=0.12345678901234566, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n')
		end)
	end)
	helpers.it("keeps an actual external section-relative inline successor and refuses the stale source owner", function()
		with_config(source, function(path)
			local successor = source .. '# external successor\n'
			local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
			local preferences = require("infra.llm_preferences")
			helpers.assert_eq(preferences.set_many({ ["llm.generation.temperature"] = 0.75 }, { status = "ok", content = source }), false)
			helpers.assert_eq(Sandbox.read_bytes(path), successor)
			helpers.assert_true(preferences.set("llm.generation.temperature", 0.75))
			helpers.assert_eq(Sandbox.read_bytes(path), '[llm] # exact header\ngeneration = { temperature=0.75, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n# external successor\n')
		end)
	end)
end)

helpers.describe("Linux actual native exact integer publication", function()
	helpers.it("writes exact requested integer through root inline and cold-restarts the native reader", function()
		with_config("llm={generation={temperature=9007199254740993,future=[]}} # exact\n", function(path)
			local preferences=require("infra.llm_preferences")
			helpers.assert_true(preferences.set("llm.generation.temperature", 9007199254740992))
			helpers.assert_eq(Sandbox.read_bytes(path), "llm={generation={temperature=9007199254740992,future=[]}} # exact\n")
			package.loaded["infra.llm_preferences"]=nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), 9007199254740992)
		end)
	end)
	helpers.it("writes exact requested integer through root dotted and cold-restarts the native reader", function()
		with_config("llm.generation.temperature=9007199254740993 # owned\nfuture=[] # exact\n", function(path)
			local preferences=require("infra.llm_preferences")
			helpers.assert_true(preferences.set("llm.generation.temperature", 9007199254740992))
			helpers.assert_eq(Sandbox.read_bytes(path), "llm.generation.temperature = 9007199254740992\nfuture=[] # exact\n")
			package.loaded["infra.llm_preferences"]=nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), 9007199254740992)
		end)
	end)
	helpers.it("writes exact requested integer through section dotted and cold-restarts the native reader", function()
		with_config("[llm]\ngeneration.temperature=9007199254740993 # owned\nfuture=[] # exact\n", function(path)
			local preferences=require("infra.llm_preferences")
			helpers.assert_true(preferences.set("llm.generation.temperature", 9007199254740992))
			helpers.assert_eq(Sandbox.read_bytes(path), "[llm]\ngeneration.temperature = 9007199254740992\nfuture=[] # exact\n")
			package.loaded["infra.llm_preferences"]=nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), 9007199254740992)
		end)
	end)
	helpers.it("writes exact requested integer through header leaf and cold-restarts the native reader", function()
		with_config("[llm.generation]\ntemperature=9007199254740993 # owned\nfuture=[] # exact\n", function(path)
			local preferences=require("infra.llm_preferences")
			helpers.assert_true(preferences.set("llm.generation.temperature", 9007199254740992))
			helpers.assert_eq(Sandbox.read_bytes(path), "[llm.generation]\ntemperature = 9007199254740992\nfuture=[] # exact\n")
			package.loaded["infra.llm_preferences"]=nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), 9007199254740992)
		end)
	end)
	helpers.it("writes exact requested integer through section inline and cold-restarts the native reader", function()
		with_config("[llm]\ngeneration={temperature=9007199254740993,future=[]} # exact\n", function(path)
			local preferences=require("infra.llm_preferences")
			helpers.assert_true(preferences.set("llm.generation.temperature", 9007199254740992))
			helpers.assert_eq(Sandbox.read_bytes(path), "[llm]\ngeneration={temperature=9007199254740992,future=[]} # exact\n")
			package.loaded["infra.llm_preferences"]=nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"), 9007199254740992)
		end)
	end)
end)

helpers.describe("Linux actual native authenticated integer candidate proof", function()
	helpers.it("refuses a wrong genuine prepared scalar then cold-reloads a repaired exact publication", function()
		local source='[llm.generation]\ntemperature=0\nfuture=9223372036854775807 # exact\n'
		with_config(source,function(path)
			local LeafRows=require("core.text.engine.toml_codec.leaf_rows")
			local Writer=require("core.text.engine.toml_codec.writer")
			local original=LeafRows.value_literal
			local capability
			LeafRows.value_literal=function(value) if value==9007199254740992 then return "9007199254740993" end return original(value) end
			local called,accepted=pcall(function()
				local rows=LeafRows.prepare(source,{ {path={"llm","generation","temperature"},value=9007199254740992} })
				capability=LeafRows.publication_capability(rows[1])
				return Writer.batch_write(path,rows)
			end)
			LeafRows.value_literal=original
			helpers.assert_eq(called,true,accepted)
			helpers.assert_true(capability~=nil)
			helpers.assert_eq(accepted,false)
			helpers.assert_eq(Sandbox.read_bytes(path),source)
			local rows=LeafRows.prepare(source,{ {path={"llm","generation","temperature"},value=9007199254740992} })
			helpers.assert_true(Writer.batch_write(path,rows))
			helpers.assert_eq(Sandbox.read_bytes(path),'[llm.generation]\ntemperature = 9007199254740992\nfuture=9223372036854775807 # exact\n')
			package.loaded["infra.llm_preferences"]=nil
			helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"),9007199254740992)
		end)
	end)
end)

helpers.describe("Linux native absent inline scalar preference",function()
	local vectors={
		{source='llm={generation={top_p=0.75,future=[]}} # keep\n',expected='llm={generation={top_p=0.75,future=[],temperature = 0.25}} # keep\n'},
		{source='[llm]\ngeneration={top_p=0.75,future=[]} # keep\n',expected='[llm]\ngeneration={top_p=0.75,future=[],temperature = 0.25} # keep\n'},
	}
	for index,vector in ipairs(vectors) do
		helpers.it("inserts absent known scalar through actual native owner "..index,function()
			with_config(vector.source,function(path)
				local preferences=require("infra.llm_preferences")
				helpers.assert_true(preferences.set("llm.generation.temperature",0.25))
				helpers.assert_eq(Sandbox.read_bytes(path),vector.expected)
				package.loaded["infra.llm_preferences"]=nil
				helpers.assert_eq(require("infra.llm_preferences").get("llm.generation.temperature"),0.25)
			end)
		end)
	end
	helpers.it("refuses stale source before actual scalar insertion and admits repaired fresh intent",function()
		local source=vectors[2].source
		with_config(source,function(path)
			local successor=source..'# foreign successor\n'
			local file=assert(io.open(path,"wb"));assert(file:write(successor));assert(file:close())
			local preferences=require("infra.llm_preferences")
			helpers.assert_eq(preferences.set_many({["llm.generation.temperature"]=0.25},{status="ok",content=source}),false)
			helpers.assert_eq(Sandbox.read_bytes(path),successor)
			helpers.assert_true(preferences.set("llm.generation.temperature",0.25))
			helpers.assert_eq(Sandbox.read_bytes(path),vectors[2].expected..'# foreign successor\n')
		end)
	end)
end)

helpers.describe("Linux actual preference schema drift and runtime reload", function()
	local Migration = require("settings.engine.migration.migrate")
	local registry = assert(Migration.load_registry(require("infra.paths").shared(Migration.REGISTRY_PATH)))
	local function current(enabled)
		return '# retain every foreign byte\n[_meta]\nschema_version = ' .. registry.current
			.. '\n[llm]\nenabled = ' .. tostring(enabled)
			.. '\n[future]\nprecise = 0.1234567890123456789\nmax = 9223372036854775807\nempty = [] # exact\n'
	end
	local function put(path, content)
		local file = assert(io.open(path, "wb"))
		assert(file:write(content))
		assert(file:close())
	end
	for _, token in ipairs({ tostring(registry.current + 1), "true", '"11"', "11.5" }) do
		helpers.it("refuses actual ordinary publication after current boot and later schema replacement " .. token, function()
			with_config(current(false), function(path)
				helpers.assert_eq(Migration.boot({ path = path, driver = "linux", registry = registry }).status, "current")
				local preferences = require("infra.llm_preferences")
				local drift = current(false):gsub("schema_version = " .. registry.current, "schema_version = " .. token)
				put(path, drift)
				helpers.assert_eq(preferences.set("llm.enabled", true), false)
				helpers.assert_eq(Sandbox.read_bytes(path), drift, "the genuine file is neither repaired nor rewritten")
				put(path, current(false))
				helpers.assert_true(preferences.set("llm.enabled", true), "manual repair permits a fresh explicit request")
				helpers.assert_eq(Sandbox.read_bytes(path), current(true), "complete independently authored source")
				package.loaded["infra.llm_preferences"] = nil
				helpers.assert_eq(require("infra.llm_preferences").get("llm.enabled"), true, "fresh native readback")
			end)
		end)
	end
	helpers.it("the actual profile reload refuses future consent and keeps the old runtime state", function()
		with_config(current(false), function(path)
			helpers.assert_eq(Migration.boot({ path = path, driver = "linux", registry = registry }).status, "current")
			local previous = package.loaded["modules.llm.profiles"]
			package.loaded["modules.llm.profiles"] = nil
			local Profiles = require("modules.llm.profiles")
			local called, detail = pcall(function()
				Profiles.init()
				helpers.assert_eq(Profiles.is_enabled(), false)
				local future = current(true):gsub("schema_version = " .. registry.current,
					"schema_version = " .. (registry.current + 1))
				put(path, future)
				local reloaded, accepted = pcall(Profiles.reload_configuration)
				helpers.assert_true(not reloaded or accepted ~= true)
				helpers.assert_eq(Profiles.is_enabled(), false, "future source cannot grant runtime consent")
				helpers.assert_eq(Sandbox.read_bytes(path), future)
			end)
			package.loaded["modules.llm.profiles"] = previous
			if not called then error(detail, 0) end
		end)
	end)
end)


helpers.describe("Linux AI runtime source admission", function()
	helpers.it("a genuine newer-schema boot refuses ordinary runtime admission (ai-readonly-admission)", function()
		local Migration = require("settings.engine.migration.migrate")
		local registry = assert(Migration.load_registry(require("infra.paths").shared(Migration.REGISTRY_PATH)))
		local source = '[_meta]\nschema_version = ' .. (registry.current + 1)
			.. '\n[llm]\nenabled = false\n[private]\nkeep = "exact"\n'
		with_config(source, function(path)
			local boot = Migration.boot({ path = path, driver = "linux", registry = registry })
			helpers.assert_eq(boot.status, "newer")
			helpers.assert_eq(boot.read_only, true)
			helpers.assert_type(require("core.text.engine.toml_codec.writer").write_refusal(path), "string", "the genuine writer owns the refusal")
			local preferences = require("infra.llm_preferences")
			helpers.assert_eq(preferences.admit(), false, "a refused file cannot admit AI runtime mutation")
			helpers.assert_eq(preferences.set("llm.enabled", true), false)
			helpers.assert_eq(Sandbox.read_bytes(path), source, "read-only admission never repairs or changes source bytes")
		end)
	end)

	helpers.it("current source and exact scope release keep admission while foreign refusals do not block it (ai-readonly-admission)", function()
		with_config('[llm]\nenabled = false\n', function(path)
			local preferences = require("infra.llm_preferences")
			require("core.text.engine.toml_codec.writer").refuse_writes(path .. ".foreign", "Controlled unrelated refusal")
			helpers.assert_eq(preferences.admit(), true, "only this configuration path owns admission")
			local owner = { pending = function() return false end }
			helpers.assert_true(preferences.acquire(owner))
			helpers.assert_eq(preferences.admit(), false, "source permission cannot bypass the retained scope")
			helpers.assert_true(preferences.release(owner))
			helpers.assert_eq(preferences.admit(), true)
		end)
	end)
end)

-- The managed download re-checks the AI source about 80 times per 64 KiB chunk
-- (runtime_source.unchanged through get_many and the engine's get_backend), and
-- each read decoded config.toml again: 1.8 million decodes for one Ollama
-- archive. Identical bytes now share one decode; freshness stays per call.
helpers.describe("AI preferences decode identical bytes once (llm-preferences-decode-once)", function()
	helpers.it("repeated reads of unchanged bytes decode once and an edit is seen at once", function()
		with_config('[llm]\nagent_mode = "auto"\n', function(path)
			local decodes, original = 0, Codec.decode
			Codec.decode = function(...)
				local caller = debug.getinfo(2, "S")
				if caller and caller.source:find("llm_preferences%.lua$") then decodes = decodes + 1 end
				return original(...)
			end
			local ok, err = pcall(function()
				local preferences = require("infra.llm_preferences")
				for _ = 1, 50 do helpers.assert_eq(preferences.get("llm.agent_mode"), "auto") end
				for _ = 1, 50 do preferences.get_many({ "llm.agent_mode" }) end
				helpers.assert_eq(decodes, 1, "unchanged bytes must be decoded once")
				Sandbox.write_bytes(path, '[llm]\nagent_mode = "action"\n')
				helpers.assert_eq(preferences.get("llm.agent_mode"), "action", "an external edit is read at once")
				helpers.assert_eq(decodes, 2)
			end)
			Codec.decode = original
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("a table value handed out cannot change what the next read returns", function()
		with_config('[llm.navigation]\nval_modifiers = ["ctrl"]\n', function()
			local preferences = require("infra.llm_preferences")
			local first = preferences.get("llm.navigation.val_modifiers")
			helpers.assert_eq(first, { "ctrl" })
			first[1], first[2] = "shift", "alt"
			helpers.assert_eq(preferences.get("llm.navigation.val_modifiers"), { "ctrl" })
			local values = preferences.get_many({ "llm.navigation.val_modifiers" })
			values["llm.navigation.val_modifiers"][1] = "super"
			helpers.assert_eq(preferences.get("llm.navigation.val_modifiers"), { "ctrl" })
		end)
	end)
end)

helpers.describe("AI preference enums written in another case", function()
	helpers.it("reads them in their manifest spelling, as Windows does (config-enum-case)", function()
		with_config('[llm]\nagent_mode = "Auto"\n[llm.trigger]\nwhile_hotstring_tooltip = "BOTH"\n', function()
			local preferences = require("infra.llm_preferences")
			local value, status = preferences.get_with_status("llm.agent_mode")
			helpers.assert_eq({ value, status }, { "auto", "ok" })
			helpers.assert_eq(preferences.get("llm.trigger.while_hotstring_tooltip"), "both")
		end)
	end)
end)
