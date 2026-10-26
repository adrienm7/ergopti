--- tests/unit/infra/config/test_shared_manifest_reader.lua

--- ==============================================================================
--- MODULE: Shared Manifest Reader Tests (macOS)
--- DESCRIPTION:
--- Pins the shared manifest reader (_shared/lua/manifest_reader.lua) that
--- infra/manifest_reader.lua binds: a missing or malformed generated manifest
--- raises, the platform hooks run before a value that includes their default
--- and never for declaration metadata, the absences split by whether they say
--- why, and the driver binding answers from the generated manifest.
--- ==============================================================================

local helpers = require("tests.helpers")
local Reader = require("manifest_reader")

local function silent_logger()
	return { done = function() end }
end

local function temp_manifest(body)
	local path = os.tmpname()
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(body)); assert(handle:close())
	return path
end

local function raised(fn) return tostring(helpers.assert_throws(fn)) end

local VALID = [[return {
	version = "9.9.9",
	features = { { path = "a.b", id = "a_b", section = "a", default = true, recommended = true, type = "boolean" } },
	scopes = {},
	unavailable = {
		{ path = "x.y", reason_key = "why.key" },
		{ path = "x.z" },
		{ path = "x.w", reason_key = "" },
	},
}]]

helpers.describe("shared manifest reader (macOS)", function()
	helpers.it("raises for a manifest that cannot be loaded or is not a manifest", function()
		helpers.assert_contains(raised(function()
			Reader.new({ logger = silent_logger(), log = "t", manifest_path = "/nonexistent/features_manifest.lua" })
		end), "cannot load generated manifest")
		local path = temp_manifest("return 7")
		local failure = raised(function() Reader.new({ logger = silent_logger(), log = "t", manifest_path = path }) end)
		os.remove(path)
		helpers.assert_contains(failure, "did not return a valid table")
	end)

	helpers.it("refuses a reader built without its ports", function()
		helpers.assert_contains(raised(function() Reader.new({}) end), "needs a logger")
		helpers.assert_contains(raised(function()
			Reader.new({ logger = silent_logger(), log = "t", manifest_path = "x", resolve_path = 1 })
		end), "resolve_path must be a function")
	end)

	helpers.it("answers metadata without invoking the platform hooks", function()
		local path = temp_manifest(VALID)
		local calls = {}
		local reader = Reader.new({ logger = silent_logger(), log = "t", manifest_path = path,
			resolve_path = function(_, requested) calls[#calls + 1] = requested or "*" end })
		os.remove(path)
		helpers.assert_eq(reader.version(), "9.9.9")
		helpers.assert_eq(reader.find_declared_entry_by_path("a.b").id, "a_b")
		helpers.assert_eq(#reader.declared_section_entries("a"), 1)
		helpers.assert_eq(#reader.declared_section_entries("none"), 0)
		helpers.assert_eq(#calls, 0)
		reader.find_entry_by_path("a.b")
		reader.features()
		helpers.assert_eq(calls, { "a.b", "*" })
	end)

	helpers.it("splits the absences by whether they carry a reason", function()
		local path = temp_manifest(VALID)
		local reader = Reader.new({ logger = silent_logger(), log = "t", manifest_path = path })
		os.remove(path)
		local explained, silent = reader.coverage_gaps()
		helpers.assert_eq(#explained, 1)
		helpers.assert_eq(explained[1].path, "x.y")
		helpers.assert_eq(#silent, 2)
	end)

	helpers.it("binds the driver to the generated manifest", function()
		local driver = require("infra.manifest_reader")
		helpers.assert_true(#driver.features() > 0)
		local entry = driver.features()[1]
		helpers.assert_eq(driver.find_entry_by_path(entry.path), entry)
		helpers.assert_true(driver.has_default(entry.path))
		helpers.assert_contains(raised(function() driver.default_for("no.such.path") end), "no.such.path")
	end)
end)
