--- tests/unit/ui/test_hotstrings_config_window_section_boundary.lua

--- ==============================================================================
--- MODULE: Hotstrings Configuration Section Boundary Tests
--- DESCRIPTION:
--- Exercises category messages with the empty section sent by the shared page.
--- Named sections retain their identity; malformed sections never reach storage.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.hotstrings_config_window_fixture")

local FIELDS = {
	{ action = "delay", field = "delay", value = 0.42 },
	{ action = "color", field = "color", value = "#abcdef" },
	{ action = "tooltip", field = "show_tooltip", value = false },
	{ action = "priority", field = "priority", value = 7 },
}

helpers.describe("Hotstrings configuration section boundary", function()
	for _, group in ipairs({ "common", "ext:demo" }) do
		for _, field in ipairs(FIELDS) do
			helpers.it("(config-empty-section) commits " .. group .. " category " .. field.action, function()
				Fixture.with_window(function(window)
					local config = package.loaded["modules.hotstrings.hotstrings_config"]
					local calls, engine, refreshes = {}, {}, 0
					config.set_override = function(...)
						calls[#calls + 1] = table.pack(...)
						return true
					end
					config.clear_override = config.set_override
					config.resolve = function() return { delay = 0.42 } end
					package.loaded["modules.keymap"] = {
						DELAY_KEY_TO_CATEGORY = { STAR_TRIGGER = "magickey" },
						set_delay = function(key, value) engine[#engine + 1] = { key, value } end,
					}
					window._on_config_changed = function() refreshes = refreshes + 1 end
					local body = {
						category = group == "common" and "magickey" or "ext:demo:sample",
						group = group, ext_id = "demo", section = "",
						ms = 420, hex = "#abcdef", show_tooltip = false, priority = 7,
					}
					for _, operation in ipairs({ "set", "clear" }) do
						body.action = operation .. "_" .. field.action
						helpers.assert_eq(window._on_message({ body = body }), true)
					end
					helpers.assert_eq(#calls, 2)
					for _, call in ipairs(calls) do
						helpers.assert_eq(call[1], group == "common" and "magickey" or "ext.demo")
						helpers.assert_nil(call[2], "category writes must not target an empty named section")
						helpers.assert_eq(call[3], field.field)
					end
					helpers.assert_eq(calls[1][4], field.value)
					helpers.assert_eq(calls[1].n, 4)
					helpers.assert_eq(calls[2].n, 3)
					helpers.assert_eq(refreshes, 2)
					helpers.assert_eq(#engine, group == "common" and field.action == "delay" and 2 or 0)
					for _, call in ipairs(engine) do helpers.assert_eq(call, { "STAR_TRIGGER", 0.42 }) end
				end)
			end)
		end
	end

	helpers.it("(config-empty-section) preserves omitted and named section semantics", function()
		Fixture.with_window(function(window)
			local calls = {}
			package.loaded["modules.hotstrings.hotstrings_config"].set_override = function(_, section)
				calls[#calls + 1] = { section = section }
				return true
			end
			local body = { action = "set_color", category = "magickey", hex = "#abcdef" }
			helpers.assert_eq(window._on_message({ body = body }), true)
			body.section = "abbreviations"
			helpers.assert_eq(window._on_message({ body = body }), true)
			helpers.assert_eq(#calls, 2)
			helpers.assert_nil(calls[1].section)
			helpers.assert_eq(calls[2].section, "abbreviations")
		end)
	end)

	helpers.it("(config-empty-section) rejects malformed sections before mutation", function()
		Fixture.with_window(function(window, state)
			for _, section in ipairs({ false, 42, {}, " ", 'safe]\n[injected' }) do
				helpers.assert_eq(window._on_message({ body = {
					action = "set_color", category = "magickey", hex = "#abcdef", section = section,
				} }), false)
			end
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(#state.errors, 5)
		end)
	end)

	for _, field in ipairs(FIELDS) do
		helpers.it("(config-empty-section) patches personal metadata " .. field.action, function()
			Fixture.with_window(function()
				local content = "[_meta]\ndelay = 0.33\n[abbreviations]\npriority = 3\n"
				local writes = 0
				package.loaded["infra.fs_dir"].entries = function() return { "sample.toml" } end
				package.loaded["adapters.file_system"] = {
					read_with_status = function() return content, "ok" end,
					write_if_unchanged = function(path, candidate, expected_source)
						helpers.assert_eq(path, "/personal/sample.toml")
						helpers.assert_eq(expected_source, { status = "ok", content = content })
						content = candidate
						writes = writes + 1
						return true
					end,
				}
				package.loaded["ui.hotstrings_config_window"] = nil
				local window = require("ui.hotstrings_config_window")
				window.setup({ personal_dir = "/personal" })
				local body = {
					category = "personal:sample", group = "personal", section = "",
					ms = 420, hex = "#abcdef", show_tooltip = false, priority = 7,
				}
				for _, operation in ipairs({ "set", "clear" }) do
					body.action = operation .. "_" .. field.action
					helpers.assert_eq(window._on_message({ body = body }), true)
					local decoded = require("infra.toml.codec").decode(content)
					if operation == "set" then
						helpers.assert_eq(decoded._meta[field.field], field.value)
					else
						helpers.assert_nil(decoded._meta[field.field])
					end
					helpers.assert_eq(decoded.abbreviations.priority, 3)
				end
				helpers.assert_eq(writes, 2)
			end)
		end)
	end
end)
