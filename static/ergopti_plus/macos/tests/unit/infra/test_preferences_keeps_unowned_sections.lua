--- tests/unit/infra/test_preferences_keeps_unowned_sections.lua

--- ==============================================================================
--- MODULE: Preferences Keep Sections They Do Not Own
--- DESCRIPTION:
--- Preferences.save serialised only its own sections and replaced config.toml
--- wholesale, so [_meta] (the schema version the boot migration stamps), the
--- expert [script] and [features] overrides config_overrides reads, and any
--- other top-level table vanished at the first menu change. The next boot then
--- took the file for an unstamped one and migrated it again. These tests pin
--- that a save keeps every top-level table outside the sections it owns, that
--- the sections it owns still come from the state, and that a file it can no
--- longer decode is never replaced by the owned sections alone.
--- ==============================================================================

local helpers   = require("tests.helpers")
local TomlCodec = require("toml_codec")

local PATH = "/virtual/preferences_unowned/config.toml"

--- Loads Preferences over an in-memory disk with exact-source publication.
--- @param disk table `{ [path] = content }`.
--- @return table preferences, table writes
local function load_preferences(disk)
	local writes = {}
	package.loaded["adapters.file_system"] = {
		read_with_status = function(path)
			if disk[path] == nil then return nil, "absent" end
			return disk[path], "ok"
		end,
		write = function(path, content)
			writes[#writes + 1] = path
			disk[path] = content
			return true
		end,
		write_if_unchanged = function(path, content, expected)
			local status = disk[path] == nil and "absent" or "ok"
			if status ~= expected.status or (status == "ok" and disk[path] ~= expected.content) then
				return false, "source changed"
			end
			writes[#writes + 1] = path
			disk[path] = content
			return true
		end,
	}
	package.loaded["infra.preferences"] = nil
	return require("infra.preferences"), writes
end

local SOURCE = table.concat({
	"[_meta]",
	"schema_version = 3",
	"",
	"[script]",
	"log_level = \"DEBUG\"",
	"",
	"[features]",
	"preview_star_enabled = false",
	"",
	"[gestures]",
	"enabled = true",
	"stale_owned_key = \"x\"",
	"",
	"[another_reader]",
	"kept = 1",
	"",
	"[another_reader.child]",
	"deep = [\"a\", \"b\"]",
	"",
}, "\n")

helpers.describe("Preferences.save keeps what it does not own (preferences-unowned-sections)", function()
	helpers.it("keeps [_meta], [script], [features] and every other foreign table", function()
		local disk = { [PATH] = SOURCE }
		local preferences = load_preferences(disk)
		preferences.load(PATH)
		helpers.assert_eq(preferences.save(PATH, {}, {}, {}), true)
		local decoded = TomlCodec.decode(disk[PATH])
		helpers.assert_eq(decoded._meta, { schema_version = 3 }, "the schema stamp survives a save")
		helpers.assert_eq(decoded.script, { log_level = "DEBUG" }, "the expert [script] layer survives")
		helpers.assert_eq(decoded.features, { preview_star_enabled = false }, "the expert [features] layer survives")
		helpers.assert_eq(decoded.another_reader, { kept = 1, child = { deep = { "a", "b" } } },
			"a table another reader owns survives with its sub-tables")
	end)

	helpers.it("still rewrites the sections it owns from the state", function()
		local disk = { [PATH] = SOURCE }
		local preferences = load_preferences(disk)
		preferences.load(PATH)
		helpers.assert_eq(preferences.save(PATH, { gestures = false }, {}, {}), true)
		local decoded = TomlCodec.decode(disk[PATH])
		helpers.assert_eq(decoded.gestures.enabled, false, "the owned section takes the state")
		helpers.assert_nil(decoded.gestures.stale_owned_key,
			"an owned section is the state's projection, not a merge with the old file")
	end)

	helpers.it("never replaces a file it can no longer decode with its own sections alone", function()
		local path = "/virtual/preferences_unowned/corrupt.toml"
		local corrupt = "[script\nlog_level = \"DEBUG\"\n"
		local disk = { [path] = corrupt }
		local preferences, writes = load_preferences(disk)
		helpers.assert_eq(select(2, preferences.load(path)), "corrupt")
		helpers.assert_eq(preferences.save(path, { gestures = false }, {}, {}), false,
			"a save that cannot keep the other tables must not publish")
		helpers.assert_eq(#writes, 0, "nothing reaches the adapter")
		helpers.assert_eq(disk[path], corrupt, "the file keeps its exact bytes")
	end)
end)
