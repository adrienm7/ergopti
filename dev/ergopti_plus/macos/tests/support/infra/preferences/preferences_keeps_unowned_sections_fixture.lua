--- tests/support/infra/preferences/preferences_keeps_unowned_sections_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_preferences_keeps_unowned_sections
--- DESCRIPTION:
--- Prelude shared by the test_preferences_keeps_unowned_sections_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers    = require("tests.helpers")
local TomlCodec  = require("toml_codec")
local TomlWriter = require("toml_codec.writer")

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

return {
	PATH = PATH,
	SOURCE = SOURCE,
	TomlCodec = TomlCodec,
	TomlWriter = TomlWriter,
	load_preferences = load_preferences,
}
