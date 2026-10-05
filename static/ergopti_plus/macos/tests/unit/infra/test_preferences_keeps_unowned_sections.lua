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

	helpers.it("updates owned leaves without discarding unknown siblings", function()
		local disk = { [PATH] = SOURCE }
		local preferences = load_preferences(disk)
		preferences.load(PATH)
		helpers.assert_eq(preferences.save(PATH, { gestures = false }, {}, {}), true)
		local decoded = TomlCodec.decode(disk[PATH])
		helpers.assert_nil(decoded.gestures.enabled, "neutral absence represents the desired false value")
		helpers.assert_eq(decoded.gestures.stale_owned_key, "x",
			"owning a feature does not authorize deleting an unknown sibling")
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

	helpers.it("stamps a file it creates with the rows the boot migration registered", function()
		local path = "/virtual/preferences_unowned/created.toml"
		local disk = {}
		local preferences = load_preferences(disk)
		helpers.assert_eq(select(2, preferences.load(path)), "absent")
		TomlWriter.set_create_rows(path, { { section = "_meta", key = "schema_version", value = 3 } })
		helpers.assert_eq(preferences.save(path, {}, {}, {}), true)
		helpers.assert_eq(TomlCodec.decode(disk[path])._meta, { schema_version = 3 },
			"a file this build creates is at this build's version")
	end)

	helpers.it("refuses to save over a file this session must not write", function()
		local path = "/virtual/preferences_unowned/refused.toml"
		local disk = { [path] = SOURCE }
		local preferences, writes = load_preferences(disk)
		preferences.load(path)
		TomlWriter.refuse_writes(path, "the file declares a newer schema")
		helpers.assert_eq(preferences.save(path, {}, {}, {}), false)
		helpers.assert_eq(#writes, 0, "nothing reaches the adapter")
		helpers.assert_eq(disk[path], SOURCE)
	end)
end)

helpers.describe("Intrinsic hotstring section-order preservation", function()
	local LeafRows = require("toml_codec.leaf_rows")
	local Outdated = require("config_outdated")

	local function write_file(path, source)
		local file = assert(io.open(path, "wb"))
		assert(file:write(source)); assert(file:close())
	end

	local function read_file(path)
		local file = assert(io.open(path, "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		return source
	end

	-- The configuration owner and conditional writer use real private files;
	-- only Hammerspoon and logging ports are modelled in this portable fixture.
	local function with_file(source, body)
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local warnings, errors = {}, {}
			local logger = helpers.make_logger_stub()
			logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			Outdated.reset_for_tests()
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			write_file(path, source)
			local ok, err = xpcall(function() body(preferences, path, warnings, errors) end, debug.traceback)
			os.remove(path)
			if not ok then error(err, 0) end
		end)
	end

	local function marks_for(preferences, source)
		local decoded, shapes = LeafRows.decode_source(source)
		local marks = {}
		preferences.mark_config_reads(decoded, function(...)
			marks[require("toml_codec.key_path").render({ ... })] = true
		end, shapes)
		return marks
	end

	local function model_with_order(order)
		return { hotstrings = { modules = {}, order_overrides = order }, shortcuts = { keys = {} },
			gestures = { enabled = true }, future = { keep = "independent" } }
	end

	local malformed = {
		{ name = "false", token = "false", value = false },
		{ name = "integer", token = "7", value = 7 },
		{ name = "float", token = "0.25", value = 0.25 },
		{ name = "string", token = '"old"', value = "old" },
		{ name = "empty map", token = "{}", value = {} },
		{ name = "mixed list", token = '["kept", false]', value = { "kept", false } },
		{ name = "record list", token = '[{ section = "kept" }]', value = { { section = "kept" } } },
	}
	for _, vector in ipairs(malformed) do
		helpers.it("ignores obsolete " .. vector.name .. " order and preserves its whole native source model", function()
			local source = '[hotstrings.order_overrides]\nold = ' .. vector.token
				.. '\nfuture_category = ["unknown", "-", ""]\n[future]\nkeep = "independent"\n'
			with_file(source, function(preferences, path, warnings, errors)
				local state, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(state.sections_order_overrides, { future_category = { "unknown", "-", "" } })
				local marks = marks_for(preferences, source)
				helpers.assert_nil(marks["hotstrings.order_overrides"])
				helpers.assert_nil(marks["hotstrings.order_overrides.old"])
				helpers.assert_eq(marks["hotstrings.order_overrides.future_category"], true)
				preferences.load(path)
				helpers.assert_eq(#warnings, 1, "load and cleanup report the same obsolete row only once")
				helpers.assert_contains(warnings[1], "hotstrings.order_overrides.old")
				helpers.assert_eq(#errors, 0)
				state.gestures = true
				helpers.assert_eq(preferences.save(path, state, {}, {}), true)
				helpers.assert_eq(TomlCodec.decode(read_file(path)), model_with_order({ old = vector.value,
					future_category = { "unknown", "-", "" } }), "handwritten complete preserved model")
				local decoded = LeafRows.decode_source(read_file(path))
				-- Kind is pinned independently below by the actual retained table,
				-- rather than by treating [] and {} as interchangeable Lua empties.
				if vector.name == "empty map" then
					helpers.assert_eq(LeafRows.source_origin(decoded.hotstrings.order_overrides.old).array, false)
				end
			end)
		end)
	end

	for _, vector in ipairs({
		{ name = "scalar", token = "false", value = false },
		{ name = "empty array", token = "[]", value = {} },
		{ name = "nonempty array", token = '["old"]', value = { "old" } },
	}) do
		helpers.it("keeps an obsolete " .. vector.name .. " order namespace during an empty carried save", function()
			local source = '[hotstrings]\norder_overrides = ' .. vector.token .. '\n[future]\nkeep = "independent"\n'
			with_file(source, function(preferences, path, warnings, errors)
				local state, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_true(state.sections_order_overrides == nil or next(state.sections_order_overrides) == nil)
				state.sections_order_overrides, state.gestures = {}, true
				helpers.assert_eq(preferences.save(path, state, {}, {}), true)
				helpers.assert_eq(TomlCodec.decode(read_file(path)), model_with_order(vector.value))
				helpers.assert_eq(#warnings, 1); helpers.assert_eq(#errors, 0)
				local marks = marks_for(preferences, source)
				helpers.assert_nil(marks["hotstrings.order_overrides"])
				if vector.name ~= "scalar" then
					local decoded = LeafRows.decode_source(read_file(path))
					helpers.assert_eq(LeafRows.source_origin(decoded.hotstrings.order_overrides).array, true)
				end
			end)
		end)
	end

	helpers.it("retains a valid empty array and unknown group without inferring retirement", function()
		local source = '[hotstrings.order_overrides]\nunknown = []\n[future]\nkeep = "independent"\n'
		with_file(source, function(preferences, path, warnings)
			local state = preferences.load(path)
			helpers.assert_eq(state.sections_order_overrides, { unknown = {} })
			state.gestures = true
			helpers.assert_eq(preferences.save(path, state, {}, {}), true)
			helpers.assert_eq(TomlCodec.decode(read_file(path)), model_with_order({ unknown = {} }))
			local decoded = LeafRows.decode_source(read_file(path))
			helpers.assert_eq(LeafRows.source_origin(decoded.hotstrings.order_overrides.unknown).array, true)
			helpers.assert_eq(marks_for(preferences, source)["hotstrings.order_overrides.unknown"], true)
			helpers.assert_eq(#warnings, 0)
		end)
	end)

	for _, key in ipairs({ '"literal.dot"', '""' }) do
		helpers.it("preserves obsolete literal identity " .. key .. " during a whole-order reset", function()
			local source = '[hotstrings.order_overrides]\n' .. key .. ' = false\nvalid = ["kept"]\n[future]\nkeep = "independent"\n'
			with_file(source, function(preferences, path, warnings)
				preferences.load(path)
				helpers.assert_eq(preferences.save(path, { sections_order_overrides = {}, gestures = true }, {}, {}), true)
				local identity = key == '""' and "" or "literal.dot"
				helpers.assert_eq(TomlCodec.decode(read_file(path)), model_with_order({ [identity] = false }))
				helpers.assert_contains(warnings[1], "hotstrings.order_overrides." .. key)
			end)
		end)
	end

	for _, candidate in ipairs({ {}, { "replacement" } }) do
		helpers.it("refuses replacing obsolete false order with " .. (#candidate == 0 and "empty" or "nonempty") .. " candidate", function()
			local source = '[hotstrings.order_overrides]\nold = false\nfuture_category = ["kept"]\n'
			with_file(source, function(preferences, path, _, errors)
				preferences.load(path)
				helpers.assert_eq(preferences.save(path, { sections_order_overrides = { old = candidate } }, {}, {}), false)
				helpers.assert_eq(read_file(path), source, "refused publication keeps every original byte")
				helpers.assert_contains(errors[#errors], "hotstrings.order_overrides.old")
				local repaired = '[hotstrings.order_overrides]\nold = ["valid"]\nfuture_category = ["kept"]\n'
				write_file(path, repaired); preferences.load(path)
				helpers.assert_eq(preferences.save(path, { sections_order_overrides = { old = candidate } }, {}, {}), true,
					"manual repair retires the obsolete source fence")
			end)
		end)
	end

	helpers.it("acknowledges an explicit valid reorder and a later valid order clear", function()
		local source = '[hotstrings.order_overrides]\nvalid = ["first", "second"]\nfuture_category = ["kept"]\n'
		with_file(source, function(preferences, path, warnings)
			preferences.load(path)
			helpers.assert_eq(preferences.save(path, { sections_order_overrides = { valid = { "second", "first" } } }, {}, {}), true)
			helpers.assert_eq(TomlCodec.decode(read_file(path)).hotstrings.order_overrides,
				{ valid = { "second", "first" }, future_category = { "kept" } })
			helpers.assert_eq(preferences.save(path, { sections_order_overrides = { valid = {} } }, {}, {}), true)
			helpers.assert_eq(TomlCodec.decode(read_file(path)).hotstrings.order_overrides, { future_category = { "kept" } },
				"an acknowledged clear cannot leave the prior order on disk")
			helpers.assert_eq(#warnings, 0)
		end)
	end)

	helpers.it("retains a later external obsolete edit and refuses the stale first save", function()
		local source = '[hotstrings.order_overrides]\nold = false\n'
		with_file(source, function(preferences, path)
			preferences.load(path)
			local external = '[hotstrings.order_overrides]\nold = 37\n[future]\nkeep = "independent"\n'
			write_file(path, external)
			helpers.assert_eq(preferences.save(path, { gestures = true }, {}, {}), false)
			helpers.assert_eq(read_file(path), external)
			helpers.assert_eq(preferences.save(path, { gestures = true }, {}, {}), true)
			helpers.assert_eq(TomlCodec.decode(read_file(path)), model_with_order({ old = 37 }))
		end)
	end)

	helpers.it("never replaces a malformed whole document with neutral order defaults", function()
		local source = '[hotstrings.order_overrides\nold = false\n'
		with_file(source, function(preferences, path)
			helpers.assert_eq(select(2, preferences.load(path)), "corrupt")
			helpers.assert_eq(preferences.save(path, { sections_order_overrides = {}, gestures = true }, {}, {}), false)
			helpers.assert_eq(read_file(path), source)
		end)
	end)

	helpers.it("prepares owned deletes without deleting obsolete siblings", function()
		local source = { status = "ok", content = '[hotstrings.order_overrides]\nold = false\nvalid = ["kept"]\n' }
		with_file(source.content, function(preferences)
			helpers.assert_eq(preferences.prepare_hotstring_updates(source,
				{ { section = "hotstrings", key = "order_overrides", delete = true } }),
				{ { section = "hotstrings.order_overrides", key = "valid", delete = true } })
			local err = helpers.assert_throws(function()
				preferences.prepare_hotstring_updates(source,
					{ { section = "hotstrings.order_overrides", key = "old", value = { "replacement" } } })
			end)
			helpers.assert_contains(tostring(err), "hotstrings.order_overrides.old")
		end)
	end)

	helpers.it("refuses malformed declared candidates before any publication", function()
		with_file('[hotstrings.order_overrides]\nvalid = ["kept"]\n', function(preferences, path)
			local source = read_file(path); preferences.load(path)
			helpers.assert_eq(preferences.save(path, { sections_order_overrides = false }, {}, {}), false)
			helpers.assert_eq(read_file(path), source)
			for _, invalid in ipairs({ { false }, { named = "section" }, { [2] = "section" } }) do
				helpers.assert_eq(preferences.save(path, { sections_order_overrides = { valid = invalid } }, {}, {}), false)
				helpers.assert_eq(read_file(path), source)
			end
			local err = helpers.assert_throws(function()
				preferences.prepare_hotstring_updates({ status = "ok", content = source },
					{ { section = "hotstrings.order_overrides.valid", key = "nested", value = "unowned" } })
			end)
			helpers.assert_contains(tostring(err), "whole text list")
		end)
	end)
end)

helpers.describe("Explicit section-order namespace source-shape admission", function()
	local LeafRows = require("toml_codec.leaf_rows")
	local source = '[hotstrings.order_overrides]\nvalid = ["kept"]\n[future]\nkeep = "independent"\n'

	local function with_admitted_file(body)
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local errors = {}
			local logger = helpers.make_logger_stub()
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local function read_current()
				local current = assert(io.open(path, "rb")); local bytes = assert(current:read("*a"))
				assert(current:close()); return bytes
			end
			local ok, err = xpcall(function()
				helpers.assert_eq(select(2, preferences.load(path)), "ok")
				body(preferences, path, read_current, errors)
			end, debug.traceback)
			os.remove(path)
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("refuses a proven empty array namespace before native save can delete a valid order", function()
		with_admitted_file(function(preferences, path, read_current, errors)
			local array = LeafRows.decode_source('value = []\n').value
			helpers.assert_eq(preferences.save(path, { sections_order_overrides = array }, {}, {}), false)
			helpers.assert_eq(read_current(), source, "explicit malformed candidate leaves every admitted source byte")
			helpers.assert_contains(errors[#errors], "section orders candidate is not a table of settings")
			helpers.assert_eq(preferences.save(path, { sections_order_overrides = {} }, {}, {}), true,
				"a later plain neutral map remains a valid explicit reset")
		end)
	end)

	helpers.it("refuses a proven empty array namespace before the reset preparation shortcut", function()
		with_admitted_file(function(preferences, _, read_current)
			local array = LeafRows.decode_source('value = []\n').value
			local err = helpers.assert_throws(function()
				preferences.prepare_hotstring_updates({ status = "ok", content = source },
					{ { section = "hotstrings", key = "order_overrides", value = array } })
			end)
			helpers.assert_contains(tostring(err), "section orders candidate is not a table of settings")
			helpers.assert_eq(read_current(), source)
		end)
	end)

	helpers.it("admits a proven empty map namespace and verifies the actual whole reset model", function()
		with_admitted_file(function(preferences, path, read_current, errors)
			local map = LeafRows.decode_source('value = {}\n').value
			helpers.assert_eq(preferences.save(path, { sections_order_overrides = map }, {}, {}), true)
			helpers.assert_eq(TomlCodec.decode(read_current()), {
				hotstrings = { modules = {}, order_overrides = {} }, shortcuts = { keys = {} },
				future = { keep = "independent" },
			})
			helpers.assert_eq(#errors, 0)
		end)
	end)

	helpers.it("admits the existing plain-map and proven-map preparation contracts", function()
		with_admitted_file(function(preferences, _, read_current)
			for _, map in ipairs({ {}, LeafRows.decode_source('value = {}\n').value }) do
				local rows = { { section = "hotstrings", key = "order_overrides", value = map } }
				helpers.assert_eq(preferences.prepare_hotstring_updates({ status = "ok", content = source }, rows), rows)
			end
			helpers.assert_eq(read_current(), source)
		end)
	end)
end)
