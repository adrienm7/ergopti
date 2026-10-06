--- tests/unit/infra/test_llm_preferences.lua

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Codec = require("toml_codec")
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
			local LeafRows = require("toml_codec.leaf_rows")
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
			local LeafRows = require("toml_codec.leaf_rows")
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
			local LeafRows = require("toml_codec.leaf_rows")
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
			local LeafRows = require("toml_codec.leaf_rows")
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
			local LeafRows=require("toml_codec.leaf_rows")
			local Writer=require("toml_codec.writer")
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
