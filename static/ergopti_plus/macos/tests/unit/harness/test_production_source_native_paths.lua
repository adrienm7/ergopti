--- tests/unit/harness/test_production_source_native_paths.lua

--- ==============================================================================
--- MODULE: Native Production Source Census
--- DESCRIPTION:
--- Real helper copies read actual production bytes under native pathnames. No
--- production module executes and no filesystem or source-reader double answers.
--- ==============================================================================

local helpers = require("tests.helpers")
local Native = require("luv")
local Discovery = require("test.runner_discovery")
local SourceFile = require("tests.support.source_file")
local DIRECTORY_MODE = tonumber("700", 8)
local FILE_MODE = tonumber("600", 8)
local MARKER_VARIABLE = "ERGOPTI_SOURCE_CENSUS_PROBE_MARKER"
local WINDOWS = package.config:sub(1, 1) == "\\"
local helper_source = assert(Native.fs_realpath(assert(package.searchpath("tests.helpers", package.path))))
local privacy_source = assert(Native.fs_realpath(helpers.shared("modules/diagnostics/redaction.json")))

local units = {
	storage = { anchor = "MODULE: Storage Adapter (Hammerspoon)" },
	ledger = { anchor = "MODULE: Durable SQL Ledger Append Ownership" },
}
for _, path in ipairs(assert(Discovery.files(assert(Native.fs_realpath(helpers.driver_root())), function(name)
	return name:match("%.lua$") ~= nil
end, { tests = true }))) do
	local body = SourceFile.read(path)
	for _, unit in pairs(units) do
		if body:find(unit.anchor, 1, true) then
			assert(unit.path == nil, "The actual production fixture declaration must be unique")
			unit.path, unit.body = path, body
		end
	end
end
for _, unit in pairs(units) do
	assert(unit.path and unit.body, "The actual production fixture must exist")
	unit.expanded = helpers.expand_config_keys(unit.body)
end
assert(units.storage.body:find("ConfigKeys.KEY.LLM_ENABLED", 1, true))
assert(units.storage.expanded ~= units.storage.body, "The real fixture must exercise config-key expansion")

local function with_fixture(prefix, body)
	local root = assert(Native.fs_mkdtemp(helpers.temp_dir() .. "/ergopti-source-census.XXXXXX"))
	local owned_directories, owned_files, known = { root }, {}, { [root] = true }
	local fixture = { root = root, driver = root .. "/" .. prefix .. "/macos" }
	function fixture.mkdir(path)
		if known[path] then return end
		assert(path:sub(1, #root + 1) == root .. "/", "Fixture directories must remain owned")
		fixture.mkdir(assert(path:match("^(.*)/[^/]+$")))
		assert(Native.fs_mkdir(path, DIRECTORY_MODE))
		known[path] = true
		owned_directories[#owned_directories + 1] = path
	end
	function fixture.copy(source, destination)
		fixture.mkdir(assert(destination:match("^(.*)/[^/]+$")))
		assert(Native.fs_copyfile(source, destination, { excl = true }))
		owned_files[#owned_files + 1] = destination
	end
	function fixture.link(source, destination)
		fixture.mkdir(assert(destination:match("^(.*)/[^/]+$")))
		assert(Native.fs_symlink(source, destination))
		owned_files[#owned_files + 1] = destination
	end
	function fixture.production(unit, name)
		local path = fixture.driver .. "/adapters/" .. name .. ".lua"
		fixture.copy(unit.path, path)
		return path
	end
	function fixture.load()
		fixture.copy(helper_source, fixture.driver .. "/tests/helpers/init.lua")
		fixture.copy(privacy_source, root .. "/" .. prefix .. "/_shared/modules/diagnostics/redaction.json")
		return assert(loadfile(fixture.driver .. "/tests/helpers/init.lua"))()
	end
	function fixture.standard()
		fixture.production(units.ledger, "z-ledger")
		fixture.production(units.storage, "a-storage")
		-- The same real declaration under tests must never make the selector ambiguous.
		fixture.copy(units.ledger.path, fixture.driver .. "/tests/nested/excluded.lua")
		return fixture.load()
	end
	local previous_marker = os.getenv(MARKER_VARIABLE)
	local marker = root .. "/owned-marker"
	assert(Native.os_setenv(MARKER_VARIABLE, marker))
	local ok, failure = xpcall(function() body(fixture, marker) end, debug.traceback)
	if previous_marker == nil then assert(Native.os_unsetenv(MARKER_VARIABLE))
	else assert(Native.os_setenv(MARKER_VARIABLE, previous_marker)) end
	local marker_state = Native.fs_lstat(marker)
	if marker_state then owned_files[#owned_files + 1] = marker end
	local cleanup = {}
	for index = #owned_files, 1, -1 do
		local retired, reason = Native.fs_unlink(owned_files[index])
		if retired ~= true then cleanup[#cleanup + 1] = owned_files[index] .. ": " .. tostring(reason) end
	end
	for index = #owned_directories, 1, -1 do
		local retired, reason = Native.fs_rmdir(owned_directories[index])
		if retired ~= true then cleanup[#cleanup + 1] = owned_directories[index] .. ": " .. tostring(reason) end
	end
	if #cleanup > 0 then
		error(tostring(failure or "source fixture cleanup refused") .. "\nOwned retirement failures: " .. table.concat(cleanup, "; "), 0)
	end
	if not ok then error(failure, 0) end
end

local function assert_standard(reader, marker)
	local accepted, all = pcall(reader.read_driver_source)
	helpers.assert_nil(Native.fs_lstat(marker), "Source discovery must never execute shell substitutions")
	helpers.assert_true(accepted, "Actual source census must complete: " .. tostring(all))
	helpers.assert_eq(all, units.storage.expanded .. "\n" .. units.ledger.expanded,
		"The complete production census must be ordered and exclude actual nested tests")
	for _, unit in pairs(units) do
		helpers.assert_eq(reader.read_driver_source(unit.anchor), unit.expanded,
			"The public source selector must read the complete real production file")
		local body, reason = reader.read_driver_unit(unit.anchor)
		helpers.assert_eq(body, unit.expanded, "The unique-unit selector must preserve its actual body: " .. tostring(reason))
	end
end

local function with_moved_driver(fixture, body)
	local retained = fixture.driver .. "-held"
	assert(Native.fs_rename(fixture.driver, retained))
	local ok, failure = xpcall(body, debug.traceback)
	local restored, reason = Native.fs_rename(retained, fixture.driver)
	assert(restored, "The exact owned driver fixture must return before retirement: " .. tostring(reason))
	if not ok then error(failure, 0) end
end

helpers.describe("Native production source paths", function()
	local cases = {
		{ label = "ordinary", prefix = "ordinary" },
		{ label = "quote", prefix = "literal'quote" },
		{ label = "outer-tests", prefix = "tests/checkout" },
	}
	if not WINDOWS then
		-- These bytes cannot be basename data on Windows, whose real provider uses separators.
		cases[#cases + 1] = { label = "newline", prefix = "literal\nnewline" }
		cases[#cases + 1] = { label = "backslash-tests", prefix = "literal\\tests\\checkout" }
		-- Empty IFS keeps the controlled absolute marker one argument even under a spaced TMPDIR.
		cases[#cases + 1] = { label = "shell-substitution", prefix = "$(IFS=; touch $" .. MARKER_VARIABLE .. ")" }
	end
	for _, case in ipairs(cases) do
		helpers.it("(native-source-census) reads exact files below a " .. case.label .. " root", function()
			with_fixture(case.prefix, function(fixture, marker)
				local reader = fixture.standard()
				helpers.assert_eq(reader.driver_root(), fixture.driver .. "/", "Use the actual copied helper's source root")
				assert_standard(reader, marker)
			end)
		end)
	end
	helpers.it("(native-source-census) keeps a completed positive census cached", function()
		with_fixture("positive-cache", function(fixture, marker)
			local reader = fixture.standard()
			assert_standard(reader, marker)
			with_moved_driver(fixture, function()
				helpers.assert_nil(Native.fs_lstat(fixture.driver), "The original source path must actually be absent")
				assert_standard(reader, marker)
			end)
		end)
	end)
	helpers.it("(native-source-census) does not cache a completed empty census", function()
		with_fixture("empty-cache", function(fixture)
			local reader = fixture.load()
			helpers.assert_nil(reader.read_driver_source(units.ledger.anchor), "An empty tree supplies no source evidence")
			fixture.production(units.ledger, "present-later")
			helpers.assert_eq(reader.read_driver_unit(units.ledger.anchor), units.ledger.expanded,
				"A later real file must be discovered after the empty census")
		end)
	end)
	helpers.it("(native-source-census) preserves native enumeration failure and permits a later retry", function()
		with_fixture("walk-error", function(fixture)
			fixture.production(units.ledger, "ledger")
			local reader = fixture.load()
			with_moved_driver(fixture, function()
				local accepted, reason = pcall(reader.read_driver_source, units.ledger.anchor)
				helpers.assert_eq(accepted, false, "A missing native root cannot certify empty source coverage")
				helpers.assert_true(tostring(reason):find("ENOENT", 1, true) ~= nil,
					"Keep the real native enumeration cause: " .. tostring(reason))
			end)
			helpers.assert_eq(reader.read_driver_unit(units.ledger.anchor), units.ledger.expanded,
				"A refused census must not become cached absence")
		end)
	end)
	if not WINDOWS then
		-- Native Windows read access uses ACLs, not POSIX mode bits or unprivileged file symlinks.
		helpers.it("(native-source-census) preserves actual source-file read failures", function()
			with_fixture("read-error", function(fixture)
				local file = fixture.production(units.ledger, "ledger")
				local reader = fixture.load()
				assert(Native.fs_chmod(file, 0))
				local accepted, reason = pcall(reader.read_driver_source, units.ledger.anchor)
				assert(Native.fs_chmod(file, FILE_MODE))
				helpers.assert_eq(accepted, false, "An unreadable production file cannot become absent evidence")
				helpers.assert_true(tostring(reason):find("source open failed", 1, true) ~= nil,
					"Retain the actual source-file phase and path: " .. tostring(reason))
			end)
		end)
		helpers.it("(native-source-census) reads a legitimate owned symlink target through the canonical provider", function()
			with_fixture("native-link", function(fixture)
				local target = fixture.root .. "/owned-target.lua"
				fixture.copy(units.ledger.path, target)
				local link = fixture.driver .. "/adapters/linked.lua"
				fixture.link(target, link)
				-- Cleanup owns the link, never an inferred target outside this fixture.
				fixture.copy(units.storage.path, fixture.driver .. "/tests/excluded.lua")
				local reader = fixture.load()
				local body, reason = reader.read_driver_unit(units.ledger.anchor)
				helpers.assert_eq(body, units.ledger.expanded, "The canonical native census follows this actual target: " .. tostring(reason))
			end)
		end)
	end
end)
