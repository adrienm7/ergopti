--- tests/unit/ui/test_patch_personal_toml_dedup.lua

--- Regression test for ui-windows-b-4: hotstrings_config_window/init.lua
--- patch_personal_toml() scanned for a field line with `field_line = i`,
--- overwriting on each match. When a [_meta] block contained two "delay ="
--- lines only the last index survived, so the first stale line was left in
--- the file after patching.
---
--- The adopted UI now delegates to its captured native controller and shared
--- complete-record metadata planner. Duplicate-key sources refuse admission;
--- the historical record editor must still remove every duplicate when invoked
--- explicitly. Both invariants survive this ownership change.

local helpers = require("tests.helpers")

local Fixture = require("tests.support.hotstrings_config_window_fixture")
local Metadata = require("hotstrings.personal_metadata")

-- Check each real delegation edge instead of accepting a detached editor call.
local edges = {
	{ symbol = "local function global_default_delay_ms",
		call = 'require("infra.personal_file_controls").apply(binding, requested_section, field, value)' },
	{ symbol = "MODULE: Personal File Metadata Controller",
		call = "Config.prepare_personal_metadata(owner, binding.record, section, field, value)" },
	{ symbol = "function M.prepare_personal_metadata(owner, record, section, field, value)",
		call = 'require("hotstrings.personal_metadata").prepare(record.content, section, field, value, legacy)' },
}
for _, edge in ipairs(edges) do
	local source, detail = helpers.read_driver_unit(edge.symbol)
	helpers.assert_not_nil(source, detail)
	helpers.assert_true(source:find(edge.call, 1, true) ~= nil,
		"personal metadata must delegate complete-record edits through its actual native owner")
end

local Editor = require("infra.toml.record_editor")
local duplicated = table.concat({
	"[_meta]",
	"delay = 100",
	"description = \"kept\"",
	"delay = 200",
	"delay = 300",
	"",
	"[personal]",
	"foo = \"bar\"",
}, "\n") .. "\n"

local replaced = assert(Editor.patch_table_field(duplicated, "[_meta]", "delay", "750"))
local _, replacement_count = replaced:gsub("delay%s*=", "")
helpers.assert_eq(replacement_count, 1,
	"replacing a duplicated field must leave exactly one assignment")
helpers.assert_true(replaced:find("delay = 750", 1, true) ~= nil,
	"the first assignment must receive the replacement value")
helpers.assert_true(replaced:find('description = "kept"', 1, true) ~= nil,
	"unrelated records in the same table must survive")

local removed = assert(Editor.patch_table_field(duplicated, "[_meta]", "delay", nil))
helpers.assert_true(removed:find("delay%s*=", 1, false) == nil,
	"removing a duplicated field must delete every assignment")
helpers.assert_true(removed:find('description = "kept"', 1, true) ~= nil,
	"removing duplicates must preserve unrelated records")

print("[PASS] test_patch_personal_toml_dedup")

helpers.describe("personal metadata complete-record ownership", function()
	helpers.it("binds the shared planner to the canonical complete-record writer", function()
		local writer, bound = require("toml_codec.writer"), false
		local index = 1
		while true do
			local name, value = debug.getupvalue(Metadata.prepare, index)
			if not name then break end
			if value == writer then bound = true end
			index = index + 1
		end
		helpers.assert_true(bound, "the shared metadata planner must retain its real continuation-aware writer")
	end)

	helpers.it("refuses the historical duplicate source instead of granting it metadata admission", function()
		helpers.assert_nil(Metadata.prepare(duplicated, nil, "delay", 0.75))
		helpers.assert_nil(Metadata.prepare(duplicated, nil, "delay", nil))
	end)

	for _, operation in ipairs({ "set_delay", "clear_delay" }) do
		helpers.it("routes " .. operation .. " through complete-record metadata ownership", function()
			Fixture.with_window(function()
				local preserved = 'future_matrix = [\n [1, 2],\n]\n'
				local original = '[_meta]\ndelay = 0.33\ndescription = "kept"\n' .. preserved
					.. '\n[[live]]\n"probe" = "replacement"\n'
				local content, writes = original, 0
				package.loaded["adapters.file_system"] = {
					read_with_status = function() return content, "ok" end,
					write_if_unchanged = function(path, candidate, expected)
						helpers.assert_eq(path, "/personal/sample.toml")
						helpers.assert_eq(expected, { status = "ok", content = original })
						content, writes = candidate, writes + 1
						return true
					end,
				}
				local root, category, _, context = Fixture.install_personal_binding("/personal/sample.toml", original)
				package.loaded["ui.hotstrings_config_window"] = nil
				local window = require("ui.hotstrings_config_window")
				Fixture.prepare_personal_window(window, root)
				helpers.assert_eq(window._on_message({ body = { action = operation,
					category = category, group = "personal", section = "", ms = 750 } }), true)
				helpers.assert_eq(context.applications, 1, "the actual bridge reaches its captured native binding")
				helpers.assert_eq(writes, 1)
				helpers.assert_true(content:find(preserved, 1, true) ~= nil,
					"nested continuation data belongs to its complete record")
				local parsed, committed = require("toml_codec.reader").parse_text(content)
				helpers.assert_eq(committed, true)
				helpers.assert_eq(parsed.meta.delay, operation == "set_delay" and 0.75 or nil)
				helpers.assert_eq(parsed.meta.description, "kept")
				helpers.assert_eq(require("toml_codec").decode(content)._meta.future_matrix, { { 1, 2 } })
			end)
		end)
	end

	helpers.it("refuses a duplicate-key replacement after capturing a native UI binding", function()
		Fixture.with_window(function()
			local original = '[_meta]\ndelay = 0.33\n\n[[live]]\n"probe" = "replacement"\n'
			local content, writes = original, 0
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return content, "ok" end,
				write_if_unchanged = function() writes = writes + 1; return true end,
			}
			local root, category, _, context = Fixture.install_personal_binding("/personal/sample.toml", original)
			package.loaded["ui.hotstrings_config_window"] = nil
			local window = require("ui.hotstrings_config_window")
			Fixture.prepare_personal_window(window, root)
			content = duplicated
			helpers.assert_eq(window._on_message({ body = { action = "set_delay",
				category = category, group = "personal", section = "", ms = 750 } }), false)
			helpers.assert_eq(context.applications, 1)
			helpers.assert_eq(context.record.content, original, "the captured source is never silently replaced")
			helpers.assert_eq(writes, 0)
			helpers.assert_eq(content, duplicated, "refusal retains exact malformed bytes for explicit repair")
		end)
	end)
end)
