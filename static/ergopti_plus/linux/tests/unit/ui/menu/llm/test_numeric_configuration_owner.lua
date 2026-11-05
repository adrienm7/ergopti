--- tests/unit/ui/menu/llm/test_numeric_configuration_owner.lua

--- ==============================================================================
--- MODULE: Numeric Menu Configuration Ownership
--- DESCRIPTION:
--- A live native page does not authorize a stale draft to write the successor
--- configuration. Original settings and conditional disk publication stay joined.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.menu.llm.numeric_configuration_fixture")

helpers.describe("numeric menu originating configuration", function()
	for _, sample in ipairs({
		{ name = "temperature", leaf = "temperature", value = "0.7", twin = "0.8", candidate = 0.9 },
		{ name = "debounce_ms", leaf = "debounce_ms", value = "300", twin = "400", candidate = 450 },
	}) do
		helpers.it("does not duplicate the numeric dialog's own case-twin notice: " .. sample.name, function()
			Fixture.with_configuration(function(f)
				local path = f.dirs.a .. "/config.toml"
				local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
				local original = sample.leaf .. " = " .. sample.value
				local replacement = original .. "\n" .. sample.leaf:upper() .. " = " .. sample.twin
				local changed, count = bytes:gsub(original, replacement, 1); assert(count == 1)
				file = assert(io.open(path, "wb")); assert(file:write(changed)); assert(file:close())
				local reports = 0
				f.writer.set_case_twin_reporter(function() reports = reports + 1 end)
				assert(f.open(sample.name))
				helpers.assert_eq(f.save(sample.candidate).saved, false)
				helpers.assert_eq({ reports, #f.notifications }, { 1, 0 })
				helpers.assert_eq(f.bytes("a"), changed)
			end)
		end)
	end
	helpers.it("does not report a case twin from a numeric page replaced during preparation", function()
		Fixture.with_configuration(function(f)
			local path = f.dirs.a .. "/config.toml"
			local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
			local changed = bytes:gsub("temperature = 0%.7", "temperature = 0.7\nTEMPERATURE = 0.8", 1)
			file = assert(io.open(path, "wb")); assert(file:write(changed)); assert(file:close())
			local reports = 0; f.writer.set_case_twin_reporter(function() reports = reports + 1 end)
			assert(f.open("temperature"))
			local original = f.writer.prepare_batch
			f.writer.prepare_batch = function(...)
				assert(f.host.hide("numeric_prompt")); assert(f.host.show("numeric_prompt"))
				return original(...)
			end
			local result = f.save(0.9)
			f.writer.prepare_batch = original
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq({ reports, #f.notifications }, { 0, 0 })
			helpers.assert_eq(f.bytes("a"), changed)
		end)
	end)
	helpers.it("does not report a case twin after its page changes during translation", function()
		Fixture.with_configuration(function(f)
			local path = f.dirs.a .. "/config.toml"
			local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
			local changed = bytes:gsub("temperature = 0%.7", "temperature = 0.7\nTEMPERATURE = 0.8", 1)
			file = assert(io.open(path, "wb")); assert(file:write(changed)); assert(file:close())
			local reports = 0; f.writer.set_case_twin_reporter(function() reports = reports + 1 end)
			assert(f.open("temperature"))
			local i18n, original = require("infra.i18n"), require("infra.i18n").get
			i18n.get = function(key, ...)
				local text = original(key, ...)
				if key == "dialog.config_save.case_twin" then
					assert(f.host.hide("numeric_prompt")); assert(f.host.show("numeric_prompt"))
				end
				return text
			end
			local called, result = pcall(f.save, 0.9)
			i18n.get = original
			helpers.assert_true(called); helpers.assert_eq(result.saved, false)
			helpers.assert_eq({ reports, #f.notifications }, { 0, 0 })
			helpers.assert_eq(f.bytes("a"), changed)
		end)
	end)
	helpers.it("explains an incompatible word range without reporting a storage error", function()
		Fixture.with_configuration(function(f)
			assert(f.open("min_words"))
			helpers.assert_eq(f.save(15).saved, false)
			helpers.assert_eq(f.bytes("a"), f.initial.a)
			helpers.assert_eq(f.notifications, { require("infra.i18n").get("menu.llm.word_limits_incompatible") })
		end)
	end)
	helpers.it("does not claim rollback when the actual writer raises after publication", function()
		Fixture.with_configuration(function(f)
			assert(f.open("temperature"))
			local original = f.writer.batch_write
			f.writer.batch_write = function(...) assert(original(...) == true); error("inert post-publication failure") end
			local result = f.save(0.9)
			f.writer.batch_write = original
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(f.document("a").llm.generation.temperature, 0.9)
			helpers.assert_eq(#f.notifications, 0)
		end)
	end)
	helpers.it("does not send a refusal notice to a replacement prompt", function()
		Fixture.with_configuration(function(f)
			assert(f.open("temperature"))
			local original = f.writer.batch_write
			f.writer.batch_write = function(...)
				assert(f.host.hide("numeric_prompt")); assert(f.host.show("numeric_prompt"))
				return false
			end
			local result = f.save(0.9)
			f.writer.batch_write = original
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(#f.notifications, 0)
		end)
	end)
	helpers.it("rechecks the prompt after translating a refusal", function()
		Fixture.with_configuration(function(f)
			assert(f.open("temperature"))
			assert(f.settings.set("context_length", 1900))
			local i18n = require("infra.i18n")
			local original = i18n.get
			i18n.get = function(key, ...)
				local text = original(key, ...)
				if key == "dialog.personal_info.save_failed_title" then
					assert(f.host.hide("numeric_prompt")); assert(f.host.show("numeric_prompt"))
				end
				return text
			end
			local called, result = pcall(f.save, 0.9)
			i18n.get = original
			helpers.assert_true(called)
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(#f.notifications, 0)
		end)
	end)
	helpers.it("returns reloaded original Paths and Storage to the runner's locator", function()
		local names = { "infra.config_paths", "adapters.storage" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local function selected()
			for _, name in ipairs(names) do package.loaded[name] = nil end
			return require("infra.config_paths").get_config_dir()
		end
		local ok, err = pcall(function()
			local before = selected()
			Fixture.with_configuration(function(f) assert(f.open("temperature")); f.switch("b") end)
			helpers.assert_eq(selected(), before, "a later module cannot reload the removed scenario locator")
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
	for _, setting in ipairs({ { "temperature", 0.9 }, { "context_length", 1800 },
		{ "min_words", 4 }, { "max_words", 12 }, { "debounce_ms", 450 } }) do
		helpers.it("saves " .. setting[1] .. " in its unchanged opening configuration", function()
			Fixture.with_configuration(function(f)
				helpers.assert_not_nil(f.open(setting[1]))
				helpers.assert_eq(f.save(setting[2]), { saved = true, closed = true })
				helpers.assert_eq(f.bytes("b"), f.initial.b)
				helpers.assert_eq(f.document("a").independent.keep, "a")
			end)
		end)
		helpers.it("refuses " .. setting[1] .. " after the paths editor selects another folder", function()
			Fixture.with_configuration(function(f)
				helpers.assert_not_nil(f.open(setting[1])); f.switch("b")
				helpers.assert_eq(f.save(setting[2]).saved, false)
				helpers.assert_eq(f.bytes("a"), f.initial.a); helpers.assert_eq(f.bytes("b"), f.initial.b)
				helpers.assert_true(f.prompt.is_pending()); helpers.assert_eq(#f.notifications, 1)
			end)
		end)
	end
	for _, owner in ipairs({ "settings", "preferences", "paths" }) do
		helpers.it("refuses withdrawal of the retained " .. owner .. " API", function()
			Fixture.with_configuration(function(f)
				assert(f.open("temperature"))
				local name = owner == "settings" and "set" or owner == "paths" and "config" or "set_many"
				local original = f[owner][name]
				f[owner][name] = function(...) return original(...) end
				helpers.assert_eq(f.save(0.9).saved, false)
				helpers.assert_eq(f.bytes("a"), f.initial.a); helpers.assert_eq(f.bytes("b"), f.initial.b)
			end)
		end)
	end
	helpers.it("refuses a root change during the exact displayed-value capture", function()
		Fixture.with_configuration(function(f)
			local request = f.open("temperature", function()
				local original = f.preferences.get_many
				f.preferences.get_many = function(paths)
					local values, source, revision = original(paths)
					f.switch("b")
					return values, source, revision
				end
			end)
			helpers.assert_nil(request, "A's value cannot be published under B's owner")
			helpers.assert_eq(f.bytes("a"), f.initial.a); helpers.assert_eq(f.bytes("b"), f.initial.b)
		end)
	end)
	helpers.it("rechecks the root at the original conditional writer admission", function()
		Fixture.with_configuration(function(f)
			assert(f.open("temperature"))
			local original, switched = f.writer.batch_write, false
			f.writer.batch_write = function(...)
				if not switched then switched = true; f.switch("b") end
				return original(...)
			end
			helpers.assert_eq(f.save(0.9).saved, false)
			helpers.assert_true(switched, "the real conditional writer boundary was reached")
			helpers.assert_eq(f.bytes("a"), f.initial.a); helpers.assert_eq(f.bytes("b"), f.initial.b)
			helpers.assert_eq(#f.notifications, 0, "a successor source cannot receive the old failure")
		end)
	end)
	helpers.it("refuses a cooperative preference ABA even when bytes return to the opening image", function()
		Fixture.with_configuration(function(f)
			assert(f.open("temperature"))
			assert(f.preferences.set("llm.generation.temperature", 0.8))
			assert(f.preferences.set("llm.generation.temperature", 0.7))
			local before = f.bytes("a")
			helpers.assert_eq(f.save(0.9).saved, false); helpers.assert_eq(f.bytes("a"), before)
		end)
	end)
	helpers.it("refuses a source edited after opening even while the root stays unchanged", function()
		Fixture.with_configuration(function(f)
			assert(f.open("temperature")); assert(f.settings.set("context_length", 1900))
			local before = f.bytes("a")
			helpers.assert_eq(f.save(0.9).saved, false); helpers.assert_eq(f.bytes("a"), before)
		end)
	end)
end)
