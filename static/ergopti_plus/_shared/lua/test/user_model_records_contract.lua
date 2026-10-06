--- _shared/lua/test/user_model_records_contract.lua

--- ==============================================================================
--- MODULE: Saved Model Physical Row Contract
--- DESCRIPTION:
--- Independent hand images cover intrinsic admission, ordinary source ownership
--- and explicit cleanup without inferring provider or custom-model retirement.
--- ==============================================================================

local M = {}
local Codec = require("toml_codec.codec")
local LeafRows = require("toml_codec.leaf_rows")
local Models = require("config_user_models")
local Records = require("toml_codec.record_list")
local Unused = require("config_unused_keys")

local bad = "[[llm.models.user_models]]\nbackend = 'future-backend' # preserve bad row\nname = ''\nfuture = { empty = [], map = {}, stamp = 2026-10-05T10:20:30Z } # opaque\n"
local good = "[[llm.models.user_models]]\nbackend = 'mlx' # valid neighbor\nname = 'custom-model'\nfuture = 0.12345678901234566\nlarge = 9223372036854775807\n"
local tail = "[future]\ntext = 'unrelated'\nempty = []\n"
local source = "[_meta]\nschema_version = 11\n" .. bad .. good .. tail

local function collector(document, mark, shapes)
	Models.partition(document.llm.models.user_models, shapes, mark)
	mark("future")
end

local function replace_once(content, before, after)
	local first = assert(content:find(before, 1, true), "hand image does not contain the expected unique token")
	assert(not content:find(before, first + #before, true), "hand image token is not unique")
	return content:sub(1, first - 1) .. after .. content:sub(first + #before)
end

local function fresh_rows(content)
	local capture = assert(Records.capture(content))
	local rows = {}
	for index, element in ipairs(capture.elements) do
		if element.valid then rows[#rows + 1] = LeafRows.clone_value(capture.rows[index]) end
	end
	return rows
end

--- Registers shared pure controls runnable under both actual Lua runtimes.
--- @param helpers table Existing registered test helper.
function M.register_pure(helpers)
	helpers.describe("intrinsic saved-model source ownership", function()
		local valid = { { backend = "future-provider", name = "custom/private:model" }, { backend = " ", name = " " } }
		for index, row in ipairs(valid) do
			helpers.it("admits plain nonempty custom identity " .. index, function()
				helpers.assert_eq(Models.fits(row), true)
			end)
		end
		local invalid = { false, 0, "model", {}, { backend = "", name = "valid" }, { backend = "mlx", name = "" },
			{ backend = false, name = "valid" }, { backend = "mlx", name = {} }, { backend = {}, name = "valid" } }
		for index, row in ipairs(invalid) do
			helpers.it("rejects an intrinsically malformed record " .. index, function()
				helpers.assert_eq(Models.fits(row), false)
			end)
		end
		helpers.it("rejects TOML dates as names or backend strings without changing the source", function()
			local content = '[llm.models]\nuser_models=[{backend=2026-10-05,name="good"},{backend="future",name=2026-10-05}]\n'
			local capture = Records.capture(content)
			helpers.assert_eq(capture.elements[1].valid, false)
			helpers.assert_eq(capture.elements[2].valid, false)
			local operation = Records.prepare(content, {}, "date-control")
			helpers.assert_eq(Records.apply(operation, content, content), content)
		end)
		local forms = {
			'[llm.models]\nuser_models = [{backend="future",name="",opaque=[1,2]}, {backend="mlx",name="good",future=9223372036854775807}] # keep\n',
			'llm.models.user_models = [{backend="future",name="",opaque=[]},{backend="mlx",name="good",future=0.12345678901234566}]\n',
			'llm = { models = { user_models = [{backend="future",name=""},{backend="mlx",name="good",future={a=[],b={}}}], other="keep" }, future=[] }\n',
			'["llm"."models"]\n"user_models" = [\n# bad comma, bracket ]\n{backend="future",name=""},\n# neighbor\n{backend="mlx",name="good",future=2026-10-05T10:20:30Z},\n] # after\n',
			'[["llm"."models"."user_models"]]\nbackend="future"\nname=""\n[["llm"."models"."user_models"]]\nbackend="mlx"\nname="good" # old\n[llm.models.user_models.future]\nempty=[]\nmap={}\n',
			'[[llm.models.user_models]]\nbackend="future"\nname=""\n[foreign]\nkeep=3\n[[llm.models.user_models]]\nbackend="mlx"\nname="""good"""\nfuture=nan\n',
		}
		for index, content in ipairs(forms) do
			helpers.it("edits only an owned name token in canonical source form " .. index, function()
				local capture = Records.capture(content)
				local desired = fresh_rows(content)
				helpers.assert_eq(#desired, 1)
				desired[1].name = "changed"
				local operation = Records.prepare(content, desired, "form-" .. index)
				local encoded = Records.apply(operation, content, content)
				local old_token = index == 6 and 'name="""good"""' or 'name="good"'
				local expected = replace_once(content, old_token, 'name="changed"')
				helpers.assert_eq(encoded, expected, "independent full-image single-token replacement")
				helpers.assert_eq(Records.capture(encoded).elements[1].raw, capture.elements[1].raw, "bad fragment exact")
				helpers.assert_eq(LeafRows.value_literal(Records.capture(encoded).rows[2].future), LeafRows.value_literal(capture.rows[2].future))
			end)
		end
		helpers.it("keeps the entire malformed block through clear, add and repeated rename", function()
			local desired = fresh_rows(source)
			local operation = Records.prepare(source, desired, "repeat-control")
			local encoded = Records.apply(operation, source, source)
			helpers.assert_eq(encoded, source, "unchanged save is byte-identical")
			Records.acknowledge(operation, encoded)
			desired[1].name = "first"
			operation = Records.prepare(encoded, desired, "repeat-control")
			encoded = Records.apply(operation, encoded, encoded)
			Records.acknowledge(operation, encoded)
			desired[1].name = "second"
			operation = Records.prepare(encoded, desired, "repeat-control")
			encoded = Records.apply(operation, encoded, encoded)
			Records.acknowledge(operation, encoded)
			helpers.assert_eq(encoded, source:gsub("name = 'custom%-model'", 'name = "second"'))
			operation = Records.prepare(encoded, {}, "repeat-control")
			local cleared = Records.apply(operation, encoded, encoded)
			helpers.assert_eq(cleared, "[_meta]\nschema_version = 11\n" .. bad .. tail)
			Records.acknowledge(operation, cleared)
			operation = Records.prepare(cleared, { { backend = "future-native", name = "new/custom" } }, "repeat-control")
			helpers.assert_eq(Records.apply(operation, cleared, cleared), "[_meta]\nschema_version = 11\n" .. bad
				.. '[[llm.models.user_models]]\nbackend = "future-native"\nname = "new/custom"\n' .. tail)
		end)
		helpers.it("restores exact removed records and refuses withdrawn or reordered inverses", function()
			local content = '[llm.models]\nuser_models = [{backend="a",name="first",future=[]},{backend="b",name="second",future={}},false]\n'
			local desired = fresh_rows(content)
			local operation = Records.prepare(content, {}, "array-inverse")
			local cleared = Records.apply(operation, content, content)
			helpers.assert_eq(cleared, '[llm.models]\nuser_models = [false]\n')
			Records.acknowledge(operation, cleared)
			helpers.assert_throws(function() Records.prepare(cleared, { desired[2], desired[1] }, "array-inverse") end)
			helpers.assert_throws(function() Records.prepare(cleared, { desired[1], desired[1] }, "array-inverse") end)
			local changed = LeafRows.clone_value(desired); changed[1].future = { forged = true }
			helpers.assert_throws(function() Records.prepare(cleared, changed, "array-inverse") end)
			helpers.assert_throws(function() Records.prepare(cleared .. "# external\n", desired, "array-inverse") end)
			operation = Records.prepare(cleared, desired, "array-inverse")
			helpers.assert_eq(Records.apply(operation, cleared, cleared), content)
		end)
		helpers.it("restores an acknowledged all-valid AOT removal without manufacturing new future fields", function()
			local content = "[_meta]\nschema_version = 11\n" .. good .. tail
			local desired = fresh_rows(content)
			local operation = Records.prepare(content, {}, "absent-inverse")
			local cleared = Records.apply(operation, content, content)
			helpers.assert_eq(cleared, "[_meta]\nschema_version = 11\n" .. tail)
			Records.acknowledge(operation, cleared)
			operation = Records.prepare(cleared, desired, "absent-inverse")
			helpers.assert_eq(Records.apply(operation, cleared, cleared), content)
		end)
		helpers.it("withdraws retry permission when an external writer changes any physical model row", function()
			local desired = fresh_rows(source); desired[1].name = "wanted"
			for _, changed in ipairs({ replace_once(source, "future = 0.12345678901234566", "future = 2"),
				replace_once(source, "name = 'custom-model'", "name = 'external'"),
				replace_once(source, "# preserve bad row", "# changed bad row") }) do
				helpers.assert_throws(function() Records.prepare(changed, desired, "retry-withdrawal") end)
			end
		end)
		local mutations = { "copied", "token", "name", "field", "delete", "section", "future", "reordered", "duplicate", "stale", "source" }
		for _, kind in ipairs(mutations) do
			helpers.it("refuses changed ordinary row authority " .. kind, function()
				local desired = fresh_rows(source)
				if kind == "future" then desired[1].future = 9 end
				if kind == "reordered" or kind == "duplicate" then
					desired[2] = LeafRows.clone_value(desired[1])
				end
				if kind == "stale" then
					helpers.assert_throws(function() Records.prepare(source:gsub("'custom%-model'", "'changed'"), desired, "stale-control") end)
					return
				end
				if kind == "future" or kind == "reordered" or kind == "duplicate" then
					helpers.assert_throws(function() Records.prepare(source, desired, "mutation") end)
					return
				end
				local operation = Records.prepare(source, desired, "mutation")
				if kind == "copied" then local copied = {}; for key, value in pairs(operation) do copied[key] = value end; operation = copied
				elseif kind == "token" then operation.record_list = {}
				elseif kind == "name" then desired[1].name = "after"
				elseif kind == "field" then operation.key = "different"
				elseif kind == "delete" then operation.delete = true
				elseif kind == "section" then operation.section = "llm"
				end
				helpers.assert_throws(function() Records.apply(operation, kind == "source" and source .. "# later\n" or source, source) end)
			end)
		end
		for _, kind in ipairs({ "substituted token", "token metatable" }) do
			helpers.it("requires raw ordinary token identity without equality effects: " .. kind, function()
				local desired = fresh_rows(source); desired[1].name = "changed"
				local operation = Records.prepare(source, desired, "pure-token-identity")
				local original, effects = operation.record_list, 0
				local meta = { __eq = function() effects = effects + 1; return true end }
				setmetatable(original, meta)
				if kind == "substituted token" then operation.record_list = setmetatable({}, meta) end
				local okay = pcall(Records.apply, operation, source, source)
				helpers.assert_eq(okay, false)
				helpers.assert_eq(effects, 0)
				setmetatable(original, nil); operation.record_list = original
				helpers.assert_eq(Records.apply(operation, source, source), replace_once(source, "name = 'custom-model'", 'name = "changed"'))
			end)
		end
		for _, kind in ipairs({ "substituted token", "token metatable", "path metatable" }) do
			helpers.it("requires plain exact cleanup identity without equality effects: " .. kind, function()
				local scan = Unused.find_in_source(source, collector)
				local entry, effects = scan.keys[1], 0
				local original = entry.source_record
				local meta = { __eq = function() effects = effects + 1; return true end,
					__len = function() effects = effects + 1; return 4 end }
				if kind == "path metatable" then setmetatable(entry.path, meta)
				else setmetatable(original, meta); if kind == "substituted token" then entry.source_record = setmetatable({}, meta) end end
				local encoded = Unused.remove_from_source(source, scan.keys)
				helpers.assert_nil(encoded)
				helpers.assert_eq(effects, 0)
				setmetatable(original, nil); setmetatable(entry.path, nil); entry.source_record = original
				local repaired, count = Unused.remove_from_source(source, scan.keys)
				helpers.assert_eq(repaired, "[_meta]\nschema_version = 11\n" .. good .. tail)
				helpers.assert_eq(count, 1)
			end)
		end
		helpers.it("refuses a borrowed ordinary destination before reading its source", function()
			local operation = Records.prepare(source, fresh_rows(source), "actual-model-owner")
			local reads = 0
			local okay = require("toml_codec.writer").prepare_batch("borrowed-model-owner", { operation }, {
				read_file = function() reads = reads + 1; return source, "ok" end,
			})
			helpers.assert_eq(okay, false)
			helpers.assert_eq(reads, 0)
		end)
		helpers.it("refuses collisions from another candidate but permits unrelated byte changes", function()
			local desired = fresh_rows(source); desired[1].name = "changed"
			local operation = Records.prepare(source, desired, "other-owner")
			helpers.assert_throws(function() Records.apply(operation, source, source:gsub("opaque", "changed opaque")) end)
			local external = source:gsub("'unrelated'", "'another ordinary choice'")
			helpers.assert_eq(Records.apply(operation, source, external), external:gsub("name = 'custom%-model'", 'name = "changed"'))
		end)
		helpers.it("ordinary empty list retains scalar invalid rows and empty-array identity", function()
			local content = '[llm.models]\nuser_models = [false, [], {backend="future",name=""}] # retain\n'
			local operation = Records.prepare(content, {}, "mixed-invalid")
			helpers.assert_eq(Records.apply(operation, content, content), content)
			local empty = '[llm.models]\nuser_models = [ # exact empty array\n]\n'
			operation = Records.prepare(empty, {}, "empty-array")
			helpers.assert_eq(Records.apply(operation, empty, empty), empty)
		end)
		helpers.it("preserves stream BOM while explicit cleanup removes its first invalid array record", function()
			local bom = string.char(0xEF, 0xBB, 0xBF)
			local content = bom .. bad .. good .. tail
			local scan = Unused.find_in_source(content, collector)
			local encoded, count = Unused.remove_from_source(content, scan.keys)
			helpers.assert_eq(encoded, bom .. good .. tail)
			helpers.assert_eq(count, 1)
		end)
		helpers.it("offers and cuts exactly the reported intrinsically invalid physical row", function()
			local scan = Unused.find_in_source(source, collector)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].kind, "saved_model_record")
			helpers.assert_eq(scan.keys[1].path, { "llm", "models", "user_models", "1" })
			local encoded, count = Unused.remove_from_source(source, scan.keys)
			helpers.assert_eq(count, 1)
			helpers.assert_eq(encoded, "[_meta]\nschema_version = 11\n" .. good .. tail)
		end)
		helpers.it("keeps foreign unavailable feature cleanup with its existing reader instead of claiming native model ownership", function()
			local content = '[llm.models]\nuser_models=[{backend="future",name=""}]\n'
			local scan = Unused.find_in_source(content, function() end)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].kind, "section", "foreign list follows historical whole-leaf cleanup")
			local encoded, count = Unused.remove_from_source(content, scan.keys)
			helpers.assert_eq(encoded, "")
			helpers.assert_eq(count, 1)
		end)
		helpers.it("requires the actual reader report and preserves duplicate bad rows as distinct identities", function()
			local content = "[_meta]\nschema_version = 11\n" .. bad .. bad .. good .. tail
			local unreported = Unused.find_in_source(content, function(_, mark) mark("llm"); mark("future") end)
			helpers.assert_eq(unreported.keys, {})
			local scan = Unused.find_in_source(content, collector)
			helpers.assert_eq(#scan.keys, 2)
			helpers.assert_eq(scan.keys[1].key, "1")
			helpers.assert_eq(scan.keys[2].key, "2")
			local encoded, count = Unused.remove_from_source(content, { scan.keys[2] })
			helpers.assert_eq(encoded, source)
			helpers.assert_eq(count, 1)
		end)
		for _, kind in ipairs({ "copied", "changed-kind", "changed-path", "changed-value", "changed-token", "duplicate", "repaired", "stale", "ancestor", "valid" }) do
			helpers.it("refuses cleanup selection " .. kind, function()
				local scan = Unused.find_in_source(source, collector)
				local entries, content = scan.keys, source
				if kind == "copied" then local copy = {}; for key, value in pairs(entries[1]) do copy[key] = value end; entries = { copy }
				elseif kind == "changed-kind" then entries[1].kind = "leaf"
				elseif kind == "changed-path" then entries[1].path[4] = "2"
				elseif kind == "changed-value" then entries[1].value = "changed"
				elseif kind == "changed-token" then entries[1].source_record = {}
				elseif kind == "duplicate" then entries[2] = entries[1]
				elseif kind == "repaired" then content = source:gsub("name = ''", "name = 'repaired'")
				elseif kind == "stale" then content = source .. "# later\n"
				elseif kind == "ancestor" then entries[2] = { section = "llm.models", key = "user_models", kind = "leaf", path = Models.PATH }
				elseif kind == "valid" then entries = { { section = "llm.models.user_models", key = "2", kind = "saved_model_record", path = { "llm", "models", "user_models", "2" } } }
				end
				local encoded, reason = Unused.remove_from_source(content, entries)
				helpers.assert_nil(encoded)
				helpers.assert_eq(type(reason), "string")
			end)
		end
	end)
end

local function with_native(helpers, content, body)
	helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
		local warnings, errors = {}, {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, format, ...) warnings[#warnings + 1] = string.format(format, ...) end
		logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
		package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
		package.loaded["adapters.file_system"] = nil
		require("config_outdated").reset_for_tests()
		local preferences = helpers.load_with_stubs("infra.preferences")
		local path = os.tmpname()
		local backups = {}
		local function write(bytes)
			local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
		end
		local function read()
			local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
		end
		write(content)
		local okay, detail = xpcall(function() body(preferences, path, read, write, warnings, errors, backups) end, debug.traceback)
		os.remove(path)
		for _, backup in ipairs(backups) do os.remove(backup) end
		if not okay then error(detail, 0) end
	end)
end

--- Registers actual Mac Preferences, writer, native files and cleanup paths.
--- @param helpers table Existing native test helper.
function M.register_native(helpers)
	helpers.describe("native saved-model row ownership", function()
		helpers.it("projects valid rows, warns once and marks only consumed records without source writes", function()
			with_native(helpers, source, function(preferences, path, read, _, warnings)
				local state, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(#state.llm_user_models, 1)
				helpers.assert_eq(state.llm_user_models[1].name, "custom-model")
				helpers.assert_eq(read(), source)
				helpers.assert_eq(#warnings, 1)
				helpers.assert_contains(warnings[1], "llm.models.user_models.1")
				preferences.load(path)
				helpers.assert_eq(#warnings, 1)
				local document, shapes = Codec.decode_with_shapes(source)
				local marks = {}
				preferences.mark_config_reads(document, function(...) marks[table.concat({ ... }, ".")] = true end, shapes)
				helpers.assert_nil(marks["llm.models.user_models"])
				helpers.assert_nil(marks["llm.models.user_models.1"])
				helpers.assert_eq(marks["llm.models.user_models.2"], true)
			end)
		end)
		helpers.it("acknowledges neighbor edits with full bad-row and future source preservation", function()
			with_native(helpers, source, function(preferences, path, read)
				local state = preferences.load(path)
				helpers.assert_eq(preferences.save(path, state, {}, {}), true)
				local neutral = read()
				helpers.assert_contains(neutral, bad)
				helpers.assert_contains(neutral, good)
				state.llm_user_models[1].name = "changed"
				helpers.assert_eq(preferences.save(path, state, {}, {}), true)
				local expected = neutral:gsub("name = 'custom%-model'", 'name = "changed"')
				helpers.assert_eq(read(), expected)
				local fresh = preferences.load(path)
				helpers.assert_eq(#fresh.llm_user_models, 1)
				helpers.assert_eq(fresh.llm_user_models[1].name, "changed")
				helpers.assert_eq(LeafRows.value_literal(fresh.llm_user_models[1].future), "0.12345678901234566")
			end)
		end)
		helpers.it("ordinary clear keeps bad row whereas explicit cleanup backs up and removes it", function()
			with_native(helpers, source, function(preferences, path, read, _, _, _, backups)
				local state = preferences.load(path)
				state.llm_user_models = {}
				helpers.assert_eq(preferences.save(path, state, {}, {}), true)
				local before = read()
				helpers.assert_contains(before, bad)
				helpers.assert_eq(before:find(good, 1, true), nil)
				local scan = Unused.find({ path = path, collect = function(document, mark, shapes)
					preferences.mark_config_reads(document, mark, shapes); mark("future")
				end })
				local entries = {}; for _, entry in ipairs(scan.keys) do if entry.kind == "saved_model_record" then entries[#entries + 1] = entry end end
				helpers.assert_eq(#entries, 1)
				local result = Unused.remove({ path = path, keys = entries, expected_source = before, stamp = "models-native" })
				backups[#backups + 1] = result.backup
				helpers.assert_eq(result.status, "removed")
				helpers.assert_eq(result.removed, 1)
				helpers.assert_eq(result.previous, before)
				helpers.assert_eq(read(), before:gsub(bad:gsub("([^%w])", "%%%1"), "", 1))
				local backup_file = assert(io.open(result.backup, "rb")); local copy = backup_file:read("*a"); assert(backup_file:close())
				helpers.assert_eq(copy, before, "actual physical backup exact")
				local fresh = preferences.load(path)
				helpers.assert_eq(fresh.llm_user_models, nil, "no bad rows acquire runtime ownership after cleanup")
				local repeated = Unused.remove({ path = path, keys = entries, stamp = "consumed-row" })
				helpers.assert_eq(repeated.status, "write_failed")
				backups[#backups + 1] = repeated.backup
			end)
		end)
		for index, content in ipairs({
			'[llm.models]\nuser_models=[false, {backend="future",name="",opaque=[]}, {backend="mlx",name="good",future=0.12345678901234566}] # tail\n',
			'llm.models.user_models=[{backend="future",name=""}, {backend="mlx",name="good",future=9223372036854775807}]\n',
			'llm={models={user_models=[{backend="future",name=""},{backend="mlx",name="good",future={a=[],b={}}}],active_backend="mlx"},future=[]}\n',
		}) do
			helpers.it("uses actual native read and writer for physical array form " .. index, function()
				with_native(helpers, content, function(preferences, path, read)
					local state = preferences.load(path)
					helpers.assert_eq(#state.llm_user_models, 1)
					helpers.assert_eq(preferences.save(path, state, {}, {}), true)
					local neutral = read()
					state.llm_user_models[1].name = "changed"
					helpers.assert_eq(preferences.save(path, state, {}, {}), true)
					helpers.assert_eq(read(), replace_once(neutral, 'name="good"', 'name="changed"'))
					helpers.assert_eq(preferences.load(path).llm_user_models[1].name, "changed")
				end)
			end)
		end
		for _, failure in ipairs({ "backup-false", "backup-nil", "backup-throw", "backup-mismatch", "publish-false", "publish-nil", "publish-throw", "selection-withdrawal", "preview-drift" }) do
			helpers.it("preserves actual source on cleanup failure " .. failure, function()
				with_native(helpers, source, function(preferences, path, read, write)
					preferences.load(path)
					local scan = Unused.find({ path = path, collect = collector })
					local copies, calls = {}, { backup = 0, publish = 0 }
					local result = Unused.remove({ path = path, keys = scan.keys, expected_source = source,
						read = function(target)
							if target == path then return read(), "ok" end
							return copies[target], copies[target] and "ok" or "absent"
						end,
						create_backup = function(target, bytes)
							calls.backup = calls.backup + 1
							if failure == "backup-false" then return false end
							if failure == "backup-nil" then return nil end
							if failure == "backup-throw" then error("backup refused") end
							copies[target] = failure == "backup-mismatch" and "different" or bytes
							if failure == "selection-withdrawal" then scan.keys[1].key = "2" end
							if failure == "preview-drift" then write(source .. "# external after backup\n") end
							return true
						end,
						publish = function(target, bytes, expected)
							calls.publish = calls.publish + 1
							helpers.assert_eq(target, path)
							helpers.assert_eq(expected, { status = "ok", content = source })
							helpers.assert_eq(bytes, "[_meta]\nschema_version = 11\n" .. good .. tail)
							if failure == "publish-throw" then error("publish refused") end
							if failure == "publish-nil" then return nil end
							return false
						end })
					local expected_status = failure:sub(1, 6) == "backup" and "backup_failed" or "write_failed"
					helpers.assert_eq(result.status, expected_status)
					helpers.assert_eq(result.removed, 0)
					helpers.assert_eq(read(), failure == "preview-drift" and source .. "# external after backup\n" or source)
					helpers.assert_eq(calls.backup, 1)
					if failure:sub(1, 6) == "backup" or failure == "selection-withdrawal" then helpers.assert_eq(calls.publish, 0)
					else helpers.assert_eq(calls.publish, 1) end
				end)
			end)
		end
		helpers.it("uses actual CAS after an external edit during the verified backup and repairs by fresh preview", function()
			with_native(helpers, source, function(preferences, path, read, write, _, _, backups)
				preferences.load(path)
				local scan = Unused.find({ path = path, collect = collector })
				local writer = require("toml_codec.writer")
				local later = source .. "# after backup\n"
				local result = Unused.remove({ path = path, keys = scan.keys, stamp = "model-drift",
					create_backup = function(target, bytes)
						local acknowledged = writer.publish_if_unchanged(target, bytes, nil, { status = "absent" })
						if acknowledged then write(later) end
						return acknowledged
					end })
				backups[#backups + 1] = result.backup
				helpers.assert_eq(result.status, "write_failed")
				helpers.assert_eq(read(), later, "actual publication source recheck keeps external image")
				local backup_file = assert(io.open(result.backup, "rb")); local bytes = backup_file:read("*a"); assert(backup_file:close())
				helpers.assert_eq(bytes, source)
				local current = Unused.find({ path = path, collect = collector })
				local repaired = Unused.remove({ path = path, keys = current.keys, stamp = "model-repaired" })
				backups[#backups + 1] = repaired.backup
				helpers.assert_eq(repaired.status, "removed")
				helpers.assert_eq(repaired.removed, 1)
				helpers.assert_eq(read(), "[_meta]\nschema_version = 11\n" .. good .. tail .. "# after backup\n")
			end)
		end)
		for _, kind in ipairs({ "substituted token", "token metatable" }) do
			helpers.it("refuses native ordinary token mutation before source acquisition: " .. kind, function()
				with_native(helpers, source, function(preferences, path, read)
					local state = preferences.load(path)
					state.llm_user_models[1].name = "changed"
					local operation = Records.prepare(source, state.llm_user_models, path)
					local original, effects = operation.record_list, 0
					local meta = { __eq = function() effects = effects + 1; return true end }
					setmetatable(original, meta)
					if kind == "substituted token" then operation.record_list = setmetatable({}, meta) end
					local writer, adapter = require("toml_codec.writer"), require("adapters.file_system")
					local reader, publisher = adapter.read_with_status, adapter.write_if_unchanged
					local reads, writes = 0, 0
					adapter.read_with_status = function(...) reads = reads + 1; return reader(...) end
					adapter.write_if_unchanged = function(...) writes = writes + 1; return publisher(...) end
					local called, ack = pcall(writer.batch_write, path, { operation }, adapter)
					adapter.read_with_status, adapter.write_if_unchanged = reader, publisher
					helpers.assert_eq(called, true)
					helpers.assert_eq(ack, false)
					helpers.assert_eq(effects, 0)
					helpers.assert_eq(reads, 0)
					helpers.assert_eq(writes, 0)
					helpers.assert_eq(read(), source)
					setmetatable(original, nil); operation.record_list = original
					helpers.assert_eq(writer.batch_write(path, { operation }, adapter), true)
					helpers.assert_eq(read(), replace_once(source, "name = 'custom-model'", 'name = "changed"'))
					helpers.assert_eq(preferences.load(path).llm_user_models[1].name, "changed")
				end)
			end)
		end
		for _, kind in ipairs({ "substituted token", "token metatable", "path metatable" }) do
			helpers.it("refuses native cleanup identity mutation before backup: " .. kind, function()
				with_native(helpers, source, function(preferences, path, read, _, _, _, backups)
					preferences.load(path)
					local scan = Unused.find({ path = path, collect = function(document, mark, shapes)
						preferences.mark_config_reads(document, mark, shapes); mark("future")
					end })
					helpers.assert_eq(#scan.keys, 1)
					local entry, effects = scan.keys[1], 0
					local original = entry.source_record
					local meta = { __eq = function() effects = effects + 1; return true end,
						__len = function() effects = effects + 1; return 4 end }
					if kind == "path metatable" then setmetatable(entry.path, meta)
					else setmetatable(original, meta); if kind == "substituted token" then entry.source_record = setmetatable({}, meta) end end
					local backup_calls, publish_calls = 0, 0
					local writer, adapter = require("toml_codec.writer"), require("adapters.file_system")
					local called, refused = pcall(Unused.remove, { path = path, keys = scan.keys, file_adapter = adapter,
						create_backup = function(target, content)
							backup_calls = backup_calls + 1; backups[#backups + 1] = target
							return writer.publish_if_unchanged(target, content, adapter, { status = "absent" })
						end,
						publish = function(target, content, expected)
							publish_calls = publish_calls + 1; return writer.publish_if_unchanged(target, content, adapter, expected)
						end })
					helpers.assert_eq(called, true)
					helpers.assert_eq(refused.status, "write_failed")
					helpers.assert_eq(effects, 0)
					helpers.assert_eq(backup_calls, 0)
					helpers.assert_eq(publish_calls, 0)
					helpers.assert_eq(read(), source)
					setmetatable(original, nil); setmetatable(entry.path, nil); entry.source_record = original
					local result = Unused.remove({ path = path, keys = scan.keys, stamp = "identity-repair" })
					backups[#backups + 1] = result.backup
					helpers.assert_eq(result.status, "removed")
					helpers.assert_eq(result.removed, 1)
					helpers.assert_eq(read(), "[_meta]\nschema_version = 11\n" .. good .. tail)
					helpers.assert_eq(preferences.load(path).llm_user_models[1].name, "custom-model")
				end)
			end)
		end
		helpers.it("refuses pure or foreign-destination cleanup receipts before backup", function()
			with_native(helpers, source, function(_, path, read)
				for _, scan in ipairs({ Unused.find_in_source(source, collector), Unused.find({ path = path .. "-other", collect = collector,
					read = function() return source, "ok" end }) }) do
					local backups, publications = 0, 0
					local result = Unused.remove({ path = path, keys = scan.keys,
						create_backup = function() backups = backups + 1; return true end,
						publish = function() publications = publications + 1; return true end })
					helpers.assert_eq(result.status, "write_failed")
					helpers.assert_eq(backups, 0)
					helpers.assert_eq(publications, 0)
					helpers.assert_eq(read(), source)
				end
			end)
		end)
		helpers.it("restores the exact previously acknowledged valid record after ordinary removal", function()
			local complete = source .. "\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n"
			with_native(helpers, complete, function(preferences, path, read)
				local state = preferences.load(path)
				local previous = LeafRows.clone_value(state.llm_user_models)
				state.llm_user_models = {}
				helpers.assert_eq(preferences.save(path, state, {}, {}), true)
				helpers.assert_eq(read(), replace_once(complete, good, ""))
				state.llm_user_models = previous
				helpers.assert_eq(preferences.save(path, state, {}, {}), true, "acknowledged removal retains exact inverse ownership")
				helpers.assert_eq(read(), complete, "exact complete physical inverse")
				helpers.assert_eq(preferences.load(path).llm_user_models[1].name, "custom-model")
			end)
		end)
		helpers.it("retains the exact prior native rows after refused ordinary removal and explicit retry", function()
			with_native(helpers, source, function(preferences, path, read)
				local state = preferences.load(path)
				local previous = LeafRows.clone_value(state.llm_user_models)
				local adapter = require("adapters.file_system")
				local write = adapter.write_if_unchanged
				local publications = 0
				adapter.write_if_unchanged = function() publications = publications + 1; return false, "native refusal" end
				state.llm_user_models = {}
				local okay, detail = xpcall(function()
					helpers.assert_eq(preferences.save(path, state, {}, {}), false)
					helpers.assert_eq(read(), source)
					helpers.assert_eq(publications, 1)
				end, debug.traceback)
				adapter.write_if_unchanged = write
				if not okay then error(detail, 0) end
				state.llm_user_models = previous
				helpers.assert_eq(preferences.save(path, state, {}, {}), true)
				local expected = source .. "\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n"
				helpers.assert_eq(read(), expected)
				helpers.assert_eq(preferences.load(path).llm_user_models[1].name, "custom-model")
			end)
		end)
		helpers.it("permits an explicit retry after unrelated external source drift", function()
			local complete = source .. "\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n"
			with_native(helpers, complete, function(preferences, path, read, write)
				local state = preferences.load(path)
				state.llm_user_models[1].name = "wanted"
				local later = complete .. "# unrelated external comment\n"
				write(later)
				helpers.assert_eq(preferences.save(path, state, {}, {}), false, "first stale candidate refused")
				helpers.assert_eq(read(), later)
				helpers.assert_eq(preferences.save(path, state, {}, {}), true, "existing explicit retry remains supported")
				helpers.assert_eq(read(), replace_once(later, "name = 'custom-model'", 'name = "wanted"'))
				helpers.assert_eq(preferences.load(path).llm_user_models[1].name, "wanted")
			end)
		end)
		helpers.it("refuses future-field replacement, external drift and changed receipts before publication", function()
			with_native(helpers, source, function(preferences, path, read, write)
				local state = preferences.load(path)
				state.llm_user_models[1].future = 2
				helpers.assert_eq(preferences.save(path, state, {}, {}), false)
				helpers.assert_eq(read(), source)
				state = preferences.load(path)
				state.llm_user_models[1].name = "wanted"
				local later = source .. "# external\n"; write(later)
				helpers.assert_eq(preferences.save(path, state, {}, {}), false)
				helpers.assert_eq(read(), later)
				local scan = Unused.find({ path = path, collect = collector })
				local backup_calls, publish_calls = 0, 0
				scan.keys[1].value = "edited"
				local refused = Unused.remove({ path = path, keys = { scan.keys[1] }, read = function() return later, "ok" end,
					create_backup = function() backup_calls = backup_calls + 1; return true end,
					publish = function() publish_calls = publish_calls + 1; return true end })
				helpers.assert_eq(refused.status, "write_failed")
				helpers.assert_eq(backup_calls, 0)
				helpers.assert_eq(publish_calls, 0)
				helpers.assert_eq(read(), later)
			end)
		end)
	end)
end

return M
