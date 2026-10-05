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

helpers.describe("Obsolete scalar user-model list preservation", function()
	local LeafRows = require("toml_codec.leaf_rows")
	local Outdated = require("config_outdated")
	local Manifest = require("infra.manifest_reader")
	local tail = '[llm.models]\nuser_models = TOKEN\nactive_backend = "ollama"\n[future]\nkeep = "independent"\nempty = []\nitems = [1, 2]\n"literal.dot" = { stamp = 2026-10-05T10:20:30Z, child = [] }\n'

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
			local function write(bytes)
				local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
			end
			local function read()
				local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a"))
				assert(file:close()); return bytes
			end
			write(source)
			local ok, err = xpcall(function() body(preferences, path, read, write, warnings, errors) end, debug.traceback)
			os.remove(path)
			if not ok then error(err, 0) end
		end)
	end

	local function neutral_state(preferences, path)
		local saved, status = preferences.load(path)
		helpers.assert_eq(status, "ok")
		helpers.assert_eq(saved.llm_user_models, nil, "obsolete list never enters native runtime")
		local state = { llm_user_models = Manifest.default_for("llm.models.user_models"), gestures = true }
		helpers.assert_eq(state.llm_user_models, {}, "consume the published native default")
		preferences.merge_saved_data(state, saved)
		return state
	end

	local function clear_rows()
		local rows = {}
		for _, row in ipairs(Manifest.scope_operations("llm", "clear")) do
			if row.section == "llm.models" and row.key == "user_models" then rows[#rows + 1] = row end
		end
		helpers.assert_eq(#rows, 1, "actual published scope must own the exact optional list")
		helpers.assert_eq(rows[1].delete, true)
		return rows
	end

	for _, vector in ipairs({
		{ id = "false", token = "false", value = false }, { id = "true", token = "true", value = true },
		{ id = "integer", token = "42", value = 42 }, { id = "float", token = "1.25", value = 1.25 },
		{ id = "text", token = '"obsolete"', value = "obsolete" },
	}) do
		helpers.it("preserves the complete file model for " .. vector.id .. " during a default-carried unrelated save", function()
			with_file(tail:gsub("TOKEN", vector.token), function(preferences, path, read, _, warnings, errors)
				local state = neutral_state(preferences, path)
				local marks = {}
				local document, shapes = LeafRows.decode_source(read())
				preferences.mark_config_reads(document, function(...) marks[table.concat({ ... }, ".")] = true end, shapes)
				helpers.assert_eq(marks["llm.models.user_models"], nil, "cleanup retains ownership of the obsolete leaf")
				helpers.assert_eq(#warnings, 1, "load and cleanup-read warn once through the same policy")
				helpers.assert_contains(warnings[1], "llm.models.user_models")
				helpers.assert_eq(preferences.save(path, state, {}, {}), true)
				helpers.assert_eq(TomlCodec.decode(read()), {
					llm = { models = { user_models = vector.value, active_backend = "ollama" } },
					future = { keep = "independent", empty = {}, items = { 1, 2 },
						["literal.dot"] = { stamp = "2026-10-05T10:20:30Z", child = {} } },
					gestures = { enabled = true }, hotstrings = { modules = {} }, shortcuts = { keys = {} },
				}, "independent complete preserved-source model")
				helpers.assert_contains(read(), "empty = []")
				helpers.assert_contains(read(), "2026-10-05T10:20:30Z")
				helpers.assert_eq(#errors, 0)
			end)
		end)
	end

	for _, source in ipairs({
		'llm = { models = { user_models = false, active_backend = "ollama" }, future = { keep = [] } }\n',
		'llm.models.user_models = false\nllm.models.active_backend = "ollama"\n',
		'["llm"."models"]\n"user_models" = false\nactive_backend = "ollama"\n',
	}) do
		helpers.it("preserves an admitted equivalent scalar source spelling through ordinary save and actual neutral scope", function()
			with_file(source, function(preferences, path, read, _, warnings)
				local state = neutral_state(preferences, path)
				helpers.assert_eq(preferences.save(path, state, {}, {}), true)
				local snapshot = preferences.source_snapshot(path)
				local rows = preferences.prepare_llm_updates(snapshot, clear_rows())
				helpers.assert_eq(TomlWriter.batch_write(path, rows, require("adapters.file_system"), snapshot), true)
				helpers.assert_eq(TomlCodec.decode(read()).llm.models, { user_models = false, active_backend = "ollama" })
				helpers.assert_eq(#warnings, 1)
			end)
		end)
	end

	helpers.it("preserves the obsolete leaf while the real neutral scope updates a valid sibling", function()
		with_file('[llm.models]\nuser_models = false\nactive_backend = "mlx"\n[future]\nempty = []\n', function(preferences, path, read)
			neutral_state(preferences, path)
			local snapshot = preferences.source_snapshot(path)
			local rows = clear_rows(); rows[#rows + 1] = { section = "llm.models", key = "active_backend", value = "ollama" }
			local prepared = preferences.prepare_llm_updates(snapshot, rows)
			helpers.assert_eq(#prepared, 1, "only the declared neutral list delete is suppressed")
			helpers.assert_eq(TomlWriter.batch_write(path, prepared, require("adapters.file_system"), snapshot), true)
			helpers.assert_eq(TomlCodec.decode(read()), { llm = { models = { user_models = false, active_backend = "ollama" } }, future = { empty = {} } })
			helpers.assert_contains(read(), "empty = []")
		end)
	end)

	helpers.it("refuses nonneutral complete snapshots and scope replacements before publication", function()
		with_file(tail:gsub("TOKEN", "false"), function(preferences, path, read, _, _, errors)
			neutral_state(preferences, path)
			local original = read()
			for _, candidate in ipairs({ { { backend = "ollama", name = "new-valid-model" } }, false, 9, { named = "unsupported" } }) do
				helpers.assert_eq(preferences.save(path, { llm_user_models = candidate, gestures = true }, {}, {}), false)
				helpers.assert_eq(read(), original)
				helpers.assert_contains(errors[#errors], "llm.models.user_models")
				helpers.assert_contains(errors[#errors], "manual source cleanup")
				local err = helpers.assert_throws(function()
					preferences.prepare_llm_updates(preferences.source_snapshot(path),
						{ { section = "llm.models", key = "user_models", value = candidate } })
				end)
				helpers.assert_contains(tostring(err), "manual source cleanup")
				helpers.assert_eq(read(), original)
			end
		end)
	end)

	helpers.it("admits a valid model edit only after explicit source repair and reload", function()
		with_file('[llm.models]\nuser_models = false\n[future]\nempty = []\n', function(preferences, path, read, write)
			neutral_state(preferences, path)
			local state = { llm_user_models = { { backend = "ollama", name = "new-valid-model" } } }
			helpers.assert_eq(preferences.save(path, state, {}, {}), false)
			write('[llm.models]\nuser_models = []\n[future]\nempty = []\n')
			helpers.assert_eq(select(2, preferences.load(path)), "ok")
			helpers.assert_eq(preferences.save(path, state, {}, {}), true)
			helpers.assert_eq(TomlCodec.decode(read()), { llm = { models = { user_models = { { backend = "ollama", name = "new-valid-model" } } } },
				future = { empty = {} }, hotstrings = { modules = {} }, shortcuts = { keys = {} } })
		end)
	end)

	helpers.it("refuses a stale snapshot and preserves the newer obsolete generation on ordinary retry", function()
		with_file('[llm.models]\nuser_models = false\n[future]\nempty = []\n', function(preferences, path, read, write)
			local state = neutral_state(preferences, path)
			local later = '[llm.models]\nuser_models = 19\n[future]\nempty = []\nkeep = "later"\n'
			write(later)
			helpers.assert_eq(preferences.save(path, state, {}, {}), false)
			helpers.assert_eq(read(), later, "source mismatch never overwrites the newer file")
			helpers.assert_eq(preferences.save(path, state, {}, {}), true)
			helpers.assert_eq(TomlCodec.decode(read()), { llm = { models = { user_models = 19 } },
				future = { empty = {}, keep = "later" }, gestures = { enabled = true }, hotstrings = { modules = {} }, shortcuts = { keys = {} } })
		end)
	end)

	for _, source in ipairs({ '[llm.models]\nuser_models = []\n', '[llm.models.user_models]\n' }) do
		helpers.it("retains the valid empty-array and historical empty-header runtime contracts", function()
			with_file(source, function(preferences, path, _, _, warnings)
				local saved, status = preferences.load(path)
				helpers.assert_eq(status, "ok"); helpers.assert_eq(saved.llm_user_models, {})
				helpers.assert_eq(preferences.save(path, { llm_user_models = {} }, {}, {}), true)
				helpers.assert_eq(#warnings, 0)
			end)
		end)
	end
end)


helpers.describe("Published gesture parameter identity source preservation", function()
	local LeafRows = require("toml_codec.leaf_rows")
	local Outdated = require("config_outdated")
	local source = table.concat({
		"# Independent user comments survive the admission scan.",
		"[_meta]", "schema_version = 3", "",
		"[gestures.action_parameters]",
		'removed_gesture_slot__open_url = "https://obsolete.example" # cleanup owns this row',
		'tap_3__open_url = "https://valid.example"',
		'swipe_3_horiz__open_url = "https://axis.example"',
		'keyboard__cmd_k__open_url = "https://keyboard.example"',
		'tap_key__a__open_url = "https://tap.example"',
		'script__reload__open_url = "https://script.example"',
		'', '[future]', 'keep = "independent"', '',
	}, "\n")

	local function read_file(path)
		local file = assert(io.open(path, "rb"))
		local bytes = assert(file:read("*a")); assert(file:close())
		return bytes
	end

	local function with_file(published, body)
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim",
			"modules.gestures", "modules.gestures.actions" }, function()
			package.loaded["modules.gestures"], package.loaded["modules.gestures.actions"] = nil, nil
			local gestures
			if published then gestures = helpers.load_with_stubs("modules.gestures")
			else helpers.load_with_stubs("modules.gestures.actions") end
			local warnings, errors = {}, {}
			local logger = helpers.make_logger_stub()
			logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			Outdated.reset_for_tests()
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local ok, err = xpcall(function() body(preferences, gestures, path, warnings, errors) end, debug.traceback)
			os.remove(path)
			if not ok then error(err, 0) end
		end)
	end

	local function marks_for(preferences)
		local decoded, shapes = LeafRows.decode_source(source)
		local marks = {}
		preferences.mark_config_reads(decoded, function(...)
			marks[require("toml_codec.key_path").render({ ... })] = true
		end, shapes)
		return marks
	end

	helpers.it("ignores a retired binding, leaves it unconsumed, warns once and keeps exact bytes", function()
		with_file(true, function(preferences, _, path, warnings, errors)
			local state, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_nil(state.gesture_action_parameters.removed_gesture_slot__open_url)
			helpers.assert_eq(state.gesture_action_parameters.tap_3__open_url, "https://valid.example")
			helpers.assert_eq(state.gesture_action_parameters.swipe_3_horiz__open_url, "https://axis.example")
			helpers.assert_eq(state.gesture_action_parameters.keyboard__cmd_k__open_url, "https://keyboard.example")
			helpers.assert_eq(state.gesture_action_parameters.tap_key__a__open_url, "https://tap.example")
			helpers.assert_eq(state.gesture_action_parameters.script__reload__open_url, "https://script.example")
			local marks = marks_for(preferences)
			helpers.assert_nil(marks["gestures.action_parameters.removed_gesture_slot__open_url"])
			helpers.assert_eq(marks["gestures.action_parameters.tap_3__open_url"], true)
			helpers.assert_eq(marks["gestures.action_parameters.keyboard__cmd_k__open_url"], true)
			preferences.load(path)
			helpers.assert_eq(#warnings, 1, "read and cleanup agree on one deduplicated warning")
			helpers.assert_contains(warnings[1], "gestures.action_parameters.removed_gesture_slot__open_url")
			helpers.assert_contains(warnings[1], "no gesture slot of this build has this name")
			helpers.assert_eq(#errors, 0)
			helpers.assert_eq(read_file(path), source, "admission and marking do not rewrite the user file")
		end)
	end)

	helpers.it("preserves the obsolete row across a complete save and an ordinary current-binding edit", function()
		with_file(true, function(preferences, gestures, path, warnings, errors)
			local state = preferences.load(path)
			for key, value in pairs(state.gesture_action_parameters) do
				local binding, action = gestures.split_action_parameter_key(key)
				helpers.assert_eq(gestures.set_action_parameter(binding, action, value), true, key)
			end
			helpers.assert_eq(gestures.set_action_parameter("tap_3", "open_url", "https://changed.example"), true)
			helpers.assert_eq(gestures.set_action_parameter("removed_gesture_slot", "open_url", "https://must-not-publish.example"), false)
			helpers.assert_eq(preferences.save(path, state, {}, { gestures = gestures }), true)
			local saved = read_file(path)
			helpers.assert_contains(saved, 'removed_gesture_slot__open_url = "https://obsolete.example" # cleanup owns this row')
			helpers.assert_contains(saved, "# Independent user comments survive the admission scan.")
			local expected = {
				removed_gesture_slot__open_url = "https://obsolete.example", tap_3__open_url = "https://changed.example",
				swipe_3_horiz__open_url = "https://axis.example", keyboard__cmd_k__open_url = "https://keyboard.example",
				tap_key__a__open_url = "https://tap.example", script__reload__open_url = "https://script.example",
			}
			helpers.assert_eq(TomlCodec.decode(saved).gestures.action_parameters, expected, "complete handwritten preserved parameter model")
			helpers.assert_eq(TomlCodec.decode(saved).future, { keep = "independent" })
			helpers.assert_eq(#warnings, 1)
			helpers.assert_eq(#errors, 0)
		end)
	end)

	helpers.it("keeps unavailable-catalogue entries without guessing their retirement", function()
		with_file(false, function(preferences, _, path, warnings, errors)
			local state = preferences.load(path)
			helpers.assert_eq(state.gesture_action_parameters.removed_gesture_slot__open_url, "https://obsolete.example")
			helpers.assert_eq(marks_for(preferences)["gestures.action_parameters.removed_gesture_slot__open_url"], true)
			helpers.assert_eq(#warnings, 0)
			helpers.assert_eq(#errors, 0)
			helpers.assert_eq(read_file(path), source)
		end)
	end)
end)
