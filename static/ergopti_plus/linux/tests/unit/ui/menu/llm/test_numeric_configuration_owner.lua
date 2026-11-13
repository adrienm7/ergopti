--- tests/unit/ui/menu/llm/test_numeric_configuration_owner.lua

--- ==============================================================================
--- MODULE: Numeric Menu Configuration Ownership
--- DESCRIPTION:
--- A live native page does not authorize a stale draft to write the successor
--- configuration. Original settings and conditional disk publication stay joined.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.menu.llm.numeric_configuration_fixture")

local function setting_row(f, key, changed, prefix_match)
	local i18n = require("infra.i18n")
	local title = i18n.get(key)
	local prefix = title:match("^(.-)%%[ds]") or title
	local rows = require("ui.menu.builder").build({ _version = "0.0.0-dev.12", paused = false,
		is_paused = function() return false end,
		llm = { is_enabled = function() return true end, get_backend = function() return "ollama" end,
			streaming_revision = function() return 0 end }, webview = f.host,
		on_menu_changed = changed })
	local function find(items)
		for _, row in ipairs(items or {}) do
			if row.title == title or (prefix_match and type(row.title) == "string" and row.title:sub(1, #prefix) == prefix and type(row.menu) == "table") then return row end
			local nested = find(row.menu); if nested then return nested end
		end
	end
	return assert(find(rows), "actual setting row is available: " .. key)
end

helpers.describe("numeric menu originating configuration", function()
	helpers.it("independent: do not publish old display state after the configuration switches post commit", function()
		Fixture.with_configuration(function(f)
			local redraws = 0
			local row = setting_row(f, "menu.llm.show_info_bar", function() redraws = redraws + 1 end)
			local original = f.writer.batch_write
			f.writer.batch_write = function(...) local a,b,c = original(...); f.switch("b"); return a,b,c end
			local called, result = pcall(row.fn)
			f.writer.batch_write = original
			helpers.assert_true(called)
			local current = f.preferences.get_many({ "llm.display.show_info_bar" })
			helpers.assert_eq(require("modules.llm.display_settings").get("show_info_bar"), current["llm.display.show_info_bar"], "successor configuration must not inherit the previous commit")
			helpers.assert_eq(redraws, 0, "new configuration must not be redrawn as though its setting changed")
			helpers.assert_eq(result, false, "retained old menu cannot acknowledge new owner")
			helpers.assert_eq(f.bytes("b"), f.initial.b)
		end)
	end)

	for _, sample in ipairs({
		{ title="menu.llm.instant_on_word_end", module="modules.llm.trigger_settings", name="instant_on_word_end", path="llm.trigger.instant_on_word_end" },
		{ title="menu.llm.generation.temperature", module="modules.llm.settings", name="temperature", path="llm.generation.temperature", picker=true },
		{ title="menu.llm.num_predictions_label", module="modules.llm.profile_settings", name="num_predictions", path="llm.profiles.num_predictions", picker=true },
	}) do
		helpers.it("independent: post-commit owner switch " .. sample.name, function()
			Fixture.with_configuration(function(f)
				local redraws = 0
				local row = setting_row(f, sample.title, function() redraws = redraws + 1 end, sample.picker)
				if sample.picker then row = assert(row.menu[1]) end
				local owner = require(sample.module)
				local original = f.writer.batch_write
				f.writer.batch_write = function(...) local a,b,c = original(...); f.switch("b"); return a,b,c end
				local called, result = pcall(row.fn); f.writer.batch_write = original
				helpers.assert_true(called)
				local current = f.preferences.get_many({sample.path})
				helpers.assert_eq(owner.get(sample.name), current[sample.path], "successor runtime follows successor source")
				helpers.assert_eq(redraws, 0, "no old-menu redraw on successor")
			end)
		end)
	end

	for _, sample in ipairs({
		{ name = "temperature", value = 0.9, module = "modules.llm.settings", path = "llm.generation.temperature" },
		{ name = "debounce_ms", value = 450, module = "modules.llm.trigger_settings", path = "llm.trigger.debounce_ms" },
	}) do
		helpers.it("does not publish an old deferred save after commit: " .. sample.name, function()
			Fixture.with_configuration(function(f)
				assert(f.open(sample.name))
				local original = f.writer.batch_write
				f.writer.batch_write = function(...) local a,b,c = original(...); f.switch("b"); return a,b,c end
				f.save(sample.value)
				f.writer.batch_write = original
				local values = f.preferences.get_many({ sample.path })
				helpers.assert_eq(require(sample.module).get(sample.name), values[sample.path])
				helpers.assert_eq(f.bytes("b"), f.initial.b)
			end)
		end)
	end

	for _, key in ipairs({ "menu.llm.debounce_label", "menu.llm.generation.temperature", "menu.llm.num_predictions_label" }) do
		helpers.it("does not apply a retained preset to an identical replacement folder: " .. key, function()
			Fixture.with_configuration(function(f)
				local file = assert(io.open(f.dirs.b .. "/config.toml", "wb"))
				assert(file:write(f.initial.a)); assert(file:close())
				local picker = setting_row(f, key, function() error("unexpected redraw") end, true)
				local row = assert(picker.menu[1])
				f.switch("b")
				local called, result = pcall(row.fn)
				helpers.assert_true(called); helpers.assert_eq(result, false)
				helpers.assert_eq(f.bytes("a"), f.initial.a); helpers.assert_eq(f.bytes("b"), f.initial.a)
				helpers.assert_eq(#f.notifications, 0)
			end)
		end)
	end
	helpers.it("classifies invalid choices without changing the historical setter arity", function()
		Fixture.with_configuration(function(f)
			local display = require("modules.llm.display_settings")
			local trigger = f.trigger
			local result, reason, noticed = display.set_with_reason_notice("pred_indent", 999)
			helpers.assert_eq({ result, reason, noticed }, { false, "invalid", false })
			result, reason, noticed = trigger.set_with_reason_notice("instant_on_word_end", "invalid")
			helpers.assert_eq({ result, reason, noticed }, { false, "invalid", false })
			helpers.assert_eq(select("#", display.set("pred_indent", 999)), 1)
			helpers.assert_eq(select("#", trigger.set("instant_on_word_end", "invalid")), 1)
			helpers.assert_eq(f.bytes("a"), f.initial.a)
			helpers.assert_eq(#f.notifications, 0)
		end)
	end)
	helpers.it("refuses a stale display menu without reporting a failed write", function()
		Fixture.with_configuration(function(f)
			local redraws = 0
			local row = setting_row(f, "menu.llm.show_info_bar", function() redraws = redraws + 1 end)
			assert(f.preferences.set("llm.display.show_info_bar", false))
			local changed = f.bytes("a")
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(f.bytes("a"), changed)
			helpers.assert_eq({ #f.notifications, redraws }, { 0, 0 })
		end)
	end)
	helpers.it("does not apply a retained display choice to a byte-identical replacement folder", function()
		Fixture.with_configuration(function(f)
			local file = assert(io.open(f.dirs.b .. "/config.toml", "wb"))
			assert(file:write(f.initial.a)); assert(file:close())
			local row = setting_row(f, "menu.llm.show_info_bar", function() error("unexpected redraw") end)
			f.switch("b")
			local called, result = pcall(row.fn)
			helpers.assert_true(called); helpers.assert_eq(result, false)
			helpers.assert_eq(f.bytes("a"), f.initial.a); helpers.assert_eq(f.bytes("b"), f.initial.a)
			helpers.assert_eq(#f.notifications, 0)
		end)
	end)
	helpers.it("does not apply a retained trigger choice to a byte-identical replacement folder", function()
		Fixture.with_configuration(function(f)
			local file = assert(io.open(f.dirs.b .. "/config.toml", "wb"))
			assert(file:write(f.initial.a)); assert(file:close())
			local row = setting_row(f, "menu.llm.instant_on_word_end", function() error("unexpected redraw") end)
			f.switch("b")
			local called, result = pcall(row.fn)
			helpers.assert_true(called); helpers.assert_eq(result, false)
			helpers.assert_eq(f.bytes("a"), f.initial.a); helpers.assert_eq(f.bytes("b"), f.initial.a)
			helpers.assert_eq(#f.notifications, 0)
		end)
	end)
	helpers.it("does not reverse a newer trigger choice using a stale cached value", function()
		Fixture.with_configuration(function(f)
			local row = setting_row(f, "menu.llm.instant_on_word_end", function() error("unexpected redraw") end)
			assert(f.preferences.set("llm.trigger.instant_on_word_end", false))
			local changed = f.bytes("a")
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(f.bytes("a"), changed)
			helpers.assert_eq(#f.notifications, 0)
		end)
	end)
	helpers.it("refuses a replaced write port during a menu choice's revision check", function()
		Fixture.with_configuration(function(f)
			local row = setting_row(f, "menu.llm.show_info_bar", function() error("unexpected redraw") end)
			local original_check, original_write = f.preferences.is_current_revision, f.preferences.set_many_with_notice
			local foreign = 0
			f.preferences.is_current_revision = function(revision)
				f.preferences.set_many_with_notice = function() foreign = foreign + 1; return true end
				return original_check(revision)
			end
			local called, result = pcall(row.fn)
			f.preferences.is_current_revision, f.preferences.set_many_with_notice = original_check, original_write
			helpers.assert_true(called); helpers.assert_eq(result, false)
			helpers.assert_eq(foreign, 0)
			helpers.assert_eq(f.bytes("a"), f.initial.a)
			helpers.assert_eq(#f.notifications, 0)
		end)
	end)
	helpers.it("does not notify a new configuration after translating a menu refusal", function()
		Fixture.with_configuration(function(f)
			local row = setting_row(f, "menu.llm.show_info_bar", function() error("unexpected redraw") end)
			local rename, i18n = os.rename, require("infra.i18n")
			local translate = i18n.get
			os.rename = function(from, to) if to == f.dirs.a .. "/config.toml" then return false, "inert refusal" end; return rename(from, to) end
			i18n.get = function(key, ...)
				local text = translate(key, ...)
				if key == "dialog.personal_info.save_failed_title" then f.switch("b") end
				return text
			end
			local called, result = pcall(row.fn)
			os.rename, i18n.get = rename, translate
			helpers.assert_true(called); helpers.assert_eq(result, false)
			helpers.assert_eq(#f.notifications, 0)
			helpers.assert_eq(f.bytes("a"), f.initial.a); helpers.assert_eq(f.bytes("b"), f.initial.b)
		end)
	end)
	for _, sample in ipairs({
		{ key = "menu.llm.instant_on_word_end", section = "llm.trigger", leaf = "instant_on_word_end" },
		{ key = "menu.llm.show_info_bar", section = "llm.display", leaf = "show_info_bar" },
	}) do
		helpers.it("reports a real unconfirmed menu write: " .. sample.leaf, function()
			Fixture.with_configuration(function(f)
				local changed = 0
				local row = setting_row(f, sample.key, function() changed = changed + 1 end)
				local rename, attempts = os.rename, 0
				os.rename = function(from, to)
					if to == f.dirs.a .. "/config.toml" then attempts = attempts + 1; return false, "inert refusal" end
					return rename(from, to)
				end
				local called, result = pcall(row.fn)
				os.rename = rename
				helpers.assert_true(called); helpers.assert_eq(result, false)
				helpers.assert_eq(attempts, 1); helpers.assert_eq(changed, 0)
				helpers.assert_eq(f.bytes("a"), f.initial.a)
				helpers.assert_eq(f.notifications, { require("infra.i18n").get("dialog.personal_info.save_failed_title") })
			end)
		end)
		helpers.it("does not duplicate this menu choice's case-twin notice: " .. sample.leaf, function()
			Fixture.with_configuration(function(f)
				local path = f.dirs.a .. "/config.toml"
				local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
				local added = sample.leaf .. " = true\n" .. sample.leaf:upper() .. " = false\n"
				local marker = sample.section == "llm.trigger" and "[llm.trigger]\n" or "[independent]\n"
				local replacement = sample.section == "llm.trigger" and marker .. added or "[llm.display]\n" .. added .. marker
				local pos = assert(bytes:find(marker, 1, true))
				local source = bytes:sub(1, pos - 1) .. replacement .. bytes:sub(pos + #marker)
				file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
				local reports, redraws = 0, 0
				f.writer.set_case_twin_reporter(function() reports = reports + 1 end)
				local row = setting_row(f, sample.key, function() redraws = redraws + 1 end)
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq({ reports, #f.notifications, redraws }, { 1, 0, 0 })
				helpers.assert_eq(f.bytes("a"), source)
			end)
		end)
		helpers.it("does not claim an unconfirmed failure after publication: " .. sample.leaf, function()
			Fixture.with_configuration(function(f)
				local row = setting_row(f, sample.key, function() error("unexpected redraw") end)
				local original = f.writer.batch_write
				f.writer.batch_write = function(...) assert(original(...) == true); error("inert post-publication failure") end
				local called, result = pcall(row.fn)
				f.writer.batch_write = original
				helpers.assert_true(called); helpers.assert_eq(result, false)
				helpers.assert_true(f.bytes("a") ~= f.initial.a)
				helpers.assert_eq(#f.notifications, 0)
			end)
		end)
		helpers.it("does not report a stale source as a storage failure: " .. sample.leaf, function()
			Fixture.with_configuration(function(f)
				local row = setting_row(f, sample.key, function() error("unexpected redraw") end)
				local original = f.writer.batch_write
				f.writer.batch_write = function(...) f.switch("b"); return original(...) end
				local called, result = pcall(row.fn)
				f.writer.batch_write = original
				helpers.assert_true(called); helpers.assert_eq(result, false)
				helpers.assert_eq(f.bytes("a"), f.initial.a); helpers.assert_eq(f.bytes("b"), f.initial.b)
				helpers.assert_eq(#f.notifications, 0)
			end)
		end)
	end
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
		local names = { "infra.config_paths", "core.fs.adapters.storage" }
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
