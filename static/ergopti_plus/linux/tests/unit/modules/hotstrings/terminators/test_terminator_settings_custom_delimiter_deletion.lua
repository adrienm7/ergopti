--- tests/unit/modules/hotstrings/terminators/test_terminator_settings_custom_delimiter_deletion.lua

--- ==============================================================================
--- MODULE: Word-Delimiter Settings (Linux)
--- DESCRIPTION:
--- The delimiter choices and the user's own delimiters are config.toml leaves:
--- written sparsely by the menu, read back into the shared catalogue at start,
--- adopted and restored exactly by the hotstrings scope, and outdated entries
--- are warned about and offered for cleanup. They used to live in storage.json,
--- where no configuration scope could reach them.
--- ==============================================================================

package.loaded["tests.support.modules.hotstrings.terminators.terminator_settings_fixture"] = nil
local Fixture = require("tests.support.modules.hotstrings.terminators.terminator_settings_fixture")
local helpers, Codec, custom_command_expected, SOURCE, with_settings, has_custom, menu_controls, custom_delete_row, observe_add_command, delay_settings_command_expected =
	Fixture.helpers, Fixture.Codec, Fixture.custom_command_expected, Fixture.SOURCE, Fixture.with_settings, Fixture.has_custom, Fixture.menu_controls, Fixture.custom_delete_row, Fixture.observe_add_command, Fixture.delay_settings_command_expected




helpers.describe("custom delimiter deletion consumes the shared command declaration", function()
	helpers.it("the actual provider follows a changed declared label without changing its target", function()
		with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
			helpers.assert_true(Settings.load())
			helpers.assert_true(Terminators.add_custom_terminator("custom_probe", "☃", "Independent snowman", true))
			helpers.assert_true(Settings.persist())
			local rows = menu_controls(Settings, false, "custom_delete_label")
			local row = assert(custom_delete_row(rows, "button.delete"), "the canonical declaration supplies the command label")
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(has_custom(Terminators, "custom_probe"), false)
			helpers.assert_eq(Codec.decode(sandbox.read_bytes(path)).other.value, 42)
		end)
	end)

	for _, verdict in ipairs({ "ack", "false", "nil", "throw", "truthy" }) do
		helpers.it("the actual Delete callback acknowledges and compensates writer " .. verdict, function()
			with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
				helpers.assert_true(Settings.load())
				helpers.assert_true(Terminators.add_custom_terminator("custom_probe", "☃", "Independent snowman", true))
				helpers.assert_true(Terminators.set_terminator_enabled("custom_probe", false))
				helpers.assert_true(Settings.persist())
				local initial = sandbox.read_bytes(path)
				local rows, _, observed = menu_controls(Settings, false, false)
				local row = assert(custom_delete_row(rows, custom_command_expected().i18n))
				local Writer = require("toml_codec.writer")
				local native_writer = Writer.batch_write
				Writer.batch_write = function(...)
					if verdict == "throw" then error("owned custom-delete writer refused") end
					if verdict == "nil" then return nil end
					if verdict == "truthy" then return 2 end
					if verdict == "false" then return false end
					return native_writer(...)
				end
				local called, committed = pcall(row.fn)
				Writer.batch_write = native_writer
				-- Observations follow both the production catch and native publisher.
				helpers.assert_eq(called, true)
				helpers.assert_eq(committed, verdict == "ack")
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(observed.redraws, verdict == "ack" and 1 or 0)
				helpers.assert_eq(has_custom(Terminators, "custom_probe"), verdict ~= "ack")
				if verdict ~= "ack" then
					helpers.assert_eq(sandbox.read_bytes(path), initial)
					helpers.assert_eq(Terminators.is_terminator_enabled("custom_probe"), false)
				end
				helpers.assert_eq(Codec.decode(sandbox.read_bytes(path)).hotstrings.unknown, "kept")
			end)
		end)
	end

	helpers.it("a held declared Delete cannot act after pause while the custom toggle remains present", function()
		with_settings(SOURCE, function(Settings, _, _, Terminators)
			helpers.assert_true(Settings.load())
			helpers.assert_true(Terminators.add_custom_terminator("custom_probe", "☃", "Independent snowman", false))
			helpers.assert_true(Settings.persist())
			local rows, ctx, observed = menu_controls(Settings, false, false)
			local row = assert(custom_delete_row(rows, custom_command_expected().i18n))
			local toggle
			for _, item in ipairs(rows) do
				if type(item.title) == "string" and item.title:find("Independent snowman", 1, true) then toggle = item end
			end
			helpers.assert_type(toggle, "table")
			helpers.assert_type(toggle.fn, "function", "the existing independent custom activation owner remains reachable")
			ctx.paused = true
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(observed.redraws, 0)
			helpers.assert_eq(has_custom(Terminators, "custom_probe"), true)
		end)
	end)
end)




helpers.describe("custom delimiter Delete translations use the shared declaration", function()
	helpers.it("the actual provider renders the canonical Delete label in every supported locale", function()
		local locales = { "ar", "cs", "da", "de", "en", "es", "fr", "hi", "he", "it", "ja", "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }
		local i18n = require("infra.i18n")
		local previous_get = i18n.get
		local observed = {}
		local passed, failure = pcall(function()
			for _, locale in ipairs(locales) do
				local path = require("infra.paths").shared("data/locales/" .. locale .. ".json")
				local file = assert(io.open(path, "rb"))
				local raw = file:read("*a")
				file:close()
				local translations = assert(require("json").decode(raw))
				i18n.get = function(key) return translations[key] or previous_get(key) end
				with_settings(SOURCE, function(Settings, _, _, Terminators)
					assert(Settings.load())
					assert(Terminators.add_custom_terminator("custom_probe", "☃", "Independent snowman", false))
					local rows, _, effects = menu_controls(Settings, false)
					local found = custom_delete_row(rows, custom_command_expected().i18n)
					observed[#observed + 1] = { locale = locale, expected = translations[custom_command_expected().i18n],
						label = found and found.title, action = found and type(found.fn), writes = effects.writes }
				end)
			end
		end)
		i18n.get = previous_get
		if not passed then error(failure, 0) end
		helpers.assert_eq(#observed, 21)
		for _, record in ipairs(observed) do
			helpers.assert_type(record.expected, "string", record.locale)
			helpers.assert_eq(record.label, record.expected, record.locale)
			helpers.assert_eq(record.action, "function", record.locale)
			helpers.assert_eq(record.writes, 0, record.locale)
		end
		helpers.assert_eq(i18n.get, previous_get, "the existing translation owner is restored exactly")
	end)
end)




helpers.describe("custom delimiter Add uses shared declaration and native acknowledgement", function()
	for _, mode in ipairs({ "ack", "consume_no", "write_false", "write_nil", "write_throw", "write_truthy" }) do
		helpers.it("keeps exact owner publication semantics after " .. mode, function()
			local observed = observe_add_command(mode)
			local acknowledged = mode == "ack" or mode == "consume_no"
			helpers.assert_eq(observed.result, acknowledged)
			helpers.assert_eq(observed.present, acknowledged)
			helpers.assert_eq(observed.writes, 1)
			helpers.assert_eq(observed.redraws, acknowledged and 1 or 0)
			helpers.assert_eq(observed.records.hotstrings.unknown, "kept")
			helpers.assert_eq(observed.records.other.value, 42)
			if not acknowledged then helpers.assert_eq(observed.source, SOURCE) end
			helpers.assert_eq(observed.prompt_restored, true)
			helpers.assert_eq(observed.execute_restored, true)
			helpers.assert_eq(observed.writer_restored, true)
		end)
	end
	for _, mode in ipairs({ "late_pause", "pause_after_prompt", "pause_after_consume", "input_cancel", "input_empty", "consume_unavailable" }) do
		helpers.it("refuses held native Add without publication after " .. mode, function()
			local observed = observe_add_command(mode)
			helpers.assert_eq(observed.present, false)
			helpers.assert_eq(observed.result, false)
			helpers.assert_eq(observed.source, SOURCE)
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(observed.redraws, 0)
			if mode == "late_pause" then helpers.assert_eq(observed.prompts, 0) end
			if mode == "pause_after_prompt" then helpers.assert_eq(observed.questions, 0) end
			helpers.assert_eq(observed.prompt_restored, true)
			helpers.assert_eq(observed.execute_restored, true)
			helpers.assert_eq(observed.writer_restored, true)
		end)
	end
end)




helpers.describe("declared delay configuration command: actual Linux provider", function()
	helpers.it("uses the shared command label and preserves existing quick-delay rows", function()
		with_settings(SOURCE, function(Settings)
			local _, _, observations = menu_controls(Settings, false, "config_shared_label")
			local rows = assert(observations.delay_controls)
			local expected = delay_settings_command_expected()
			helpers.assert_eq(rows[expected.position].title, require("infra.i18n").get("button.ok"))
			helpers.assert_eq(rows[2].title, "-")
			helpers.assert_eq(#rows, 5, "the three existing variable-delay rows stay after the command")
		end)
	end)

	helpers.it("dispatches the existing window identity without a preference write", function()
		with_settings(SOURCE, function(Settings, path, sandbox)
			local _, ctx, observations = menu_controls(Settings, false, false)
			local native = { opens = 0 }
			ctx.webview = { show = function(name) native.opens = native.opens + 1; native.name = name end }
			assert(observations.delay_controls)[1].fn()
			helpers.assert_eq(native.opens, 1)
			helpers.assert_eq(native.name, delay_settings_command_expected().window)
			helpers.assert_eq(observations.writes, 0)
			helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
		end)
	end)

	helpers.it("refuses a missing window owner without saving or redrawing", function()
		with_settings(SOURCE, function(Settings)
			local _, _, observations = menu_controls(Settings, false, false)
			assert(observations.delay_controls)[1].fn()
			helpers.assert_eq(observations.writes, 0)
			helpers.assert_eq(observations.redraws, 0)
		end)
	end)
end)

