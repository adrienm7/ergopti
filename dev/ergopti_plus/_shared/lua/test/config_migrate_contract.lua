--- _shared/lua/test/config_migrate_contract.lua

--- ==============================================================================
--- MODULE: Config Migration Contract
--- DESCRIPTION:
--- The behaviour every Lua driver's boot migration must keep, registered once
--- per driver suite so the macOS runner (Lua 5.4) and the Linux runner
--- (LuaJIT in CI) both prove it: the shared corpus replayed through the engine
--- with the driver's own id, the shared registry-defect corpus every loader
--- must reject, byte preservation of everything no op touches, replay
--- idempotence, and the boot run's backup, publication and refusal outcomes,
--- including the read-only session a newer file starts.
---
--- USAGE (one call per driver suite):
---   require("test.config_migrate_contract").register(helpers, { driver = "hs" })
--- ==============================================================================

local M = {}

local Engine     = require("config_migrate")
local TomlCodec  = require("toml_codec")
local TomlWriter = require("toml_codec.writer")

local STAMP = "20990101-000000"
local MIN_CASES_PER_DRIVER = 10
local MIN_REGISTRY_DEFECTS = 20
local _sequence = 0





-- ===============================
-- ===============================
-- ======= 1/ File Sandbox =======
-- ===============================
-- ===============================

--- The _shared/ tree, from this file's own location.
--- @return string
local function shared_root()
	local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	local root = source:match("^(.*)/lua/test/config_migrate_contract%.lua$")
	if not root then error("config_migrate_contract: cannot locate _shared/ from " .. source) end
	return root
end

--- A fresh absolute config path inside the host's scratch directory.
--- @return string
local function new_config_path()
	local base = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
	base = base:gsub("\\", "/"):gsub("/+$", "")
	_sequence = _sequence + 1
	return string.format("%s/ergopti_config_migrate_%d_%d_%d.toml", base, os.time(),
		math.random(100000, 999999), _sequence)
end

local function write_bytes(path, content)
	local fh = assert(io.open(path, "w"))
	assert(fh:write(content))
	assert(fh:close())
end

local function read_bytes(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Runs body with a fresh config file holding content, then removes every file
--- the scenario may have created.
--- @param content string|nil Initial bytes; nil leaves the file absent.
--- @param body function body(path).
local function with_config(content, body)
	local path = new_config_path()
	if content then write_bytes(path, content) end
	local ok, err = pcall(body, path)
	for _, version in ipairs({ 2, 3 }) do
		os.remove(Engine.backup_path(path, version, STAMP))
		os.remove(Engine.backup_path(path, version, STAMP) .. ".tmp")
	end
	os.remove(path)
	os.remove(path .. ".tmp")
	if not ok then error(err, 0) end
end

--- A logger double recording every line by level.
--- @return table logger, table lines
local function recording_logger()
	local lines = {}
	local logger = {}
	for _, level in ipairs({ "debug", "trace", "done", "info", "start", "success", "warn", "error" }) do
		logger[level] = function(_module, fmt, ...)
			lines[#lines + 1] = { level = level, text = string.format(fmt, ...) }
		end
	end
	return logger, lines
end

local function count_level(lines, level)
	local count = 0
	for _, line in ipairs(lines) do
		if line.level == level then count = count + 1 end
	end
	return count
end

local function contains(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then return true end
	end
	return false
end

--- Decodes a corpus file, failing loudly when it is missing or malformed.
--- @return table decoded, string content
local function read_corpus_file(path)
	local fh = io.open(path, "rb")
	if not fh then error("config migration corpus file is missing: " .. path) end
	local content = fh:read("*a")
	fh:close()
	local ok, decoded = pcall(TomlCodec.decode, content)
	if not ok or type(decoded) ~= "table" then error("config migration corpus file does not parse: " .. path) end
	return decoded, content
end

--- Actual generated macOS identities and shared physical aliases, injected
--- explicitly into every interpreter replay, including the Linux suite.
local function migration_context()
	local root = shared_root()
	local catalogue = dofile(root .. "/../macos/_generated/action_catalogue.lua")
	local context, detail = Engine.load_context(root .. "/modules/actions/modifier_chords.json", catalogue)
	if not context then error("migration context rejected: " .. tostring(detail)) end
	return context
end

--- A validated registry from TOML text, for scenarios independent of the
--- shipped one.
local function registry_from(text)
	local registry, err = Engine.validate_registry(TomlCodec.decode(text))
	if not registry then error("test registry rejected: " .. tostring(err)) end
	return registry
end

-- Two steps: v1 renames, v2 deletes gestures.space_wrap on every driver.
local SCENARIO_REGISTRY = table.concat({
	"[registry]",
	"current_version = 3",
	"unstamped_version = 1",
	"",
	"[steps.v1_to_v2]",
	"from = 1",
	"to = 2",
	"drivers = [\"ahk\", \"hs\", \"linux\"]",
	"reason = \"Contract: rename.\"",
	"ops = [{ op = \"rename\", section = \"hotstrings.dynamic\", key = \"datefr\", to_key = \"date_fr\" }]",
	"",
	"[steps.v2_to_v3]",
	"from = 2",
	"to = 3",
	"drivers = [\"ahk\", \"hs\", \"linux\"]",
	"reason = \"Contract: delete.\"",
	"ops = [{ op = \"delete\", section = \"gestures\", key = \"space_wrap\" }]",
	"",
}, "\n")

local SCENARIO_SOURCE = table.concat({
	"# My settings — edited by hand.",
	"[gestures]",
	"enabled = true # keep this comment",
	"space_wrap = false",
	"",
	"[hotstrings.dynamic]",
	"datefr = true",
	"time = false",
	"",
}, "\n")

-- Exactly what the scenario must publish: the stamp before the first table,
-- the deleted record cut, the renamed one appended to its section, every
-- other byte kept.
local SCENARIO_CANDIDATE = table.concat({
	"# My settings — edited by hand.",
	"[_meta]",
	"schema_version = 3",
	"",
	"[gestures]",
	"enabled = true # keep this comment",
	"",
	"[hotstrings.dynamic]",
	"time = false",
	"date_fr = true",
	"",
}, "\n")





-- ================================
-- ================================
-- ======= 2/ Corpus Replay =======
-- ================================
-- ================================

--- Registers one test per corpus case listed for the driver.
--- @param h table Driver test helpers.
--- @param driver string
local function register_corpus(h, driver)
	local root = shared_root()
	local corpus = root .. "/tests/corpus/config_migrations"
	local shipped = root .. "/" .. Engine.REGISTRY_PATH
	local index = read_corpus_file(corpus .. "/cases.toml")
	local cases = index.corpus and index.corpus.cases or {}

	h.describe("config migration corpus (" .. driver .. ")", function()
		local listed = 0
		for _, name in ipairs(cases) do
			local dir = corpus .. "/" .. name
			local spec = read_corpus_file(dir .. "/case.toml").case
			if contains(spec.drivers, driver) then
				listed = listed + 1
				h.it(name, function()
					local own = io.open(dir .. "/migrations.toml", "rb")
					local registry_path = shipped
					if own then own:close() registry_path = dir .. "/migrations.toml" end
					local registry, registry_err = Engine.load_registry(registry_path)
					h.assert_true(registry ~= nil, "the case registry must load: " .. tostring(registry_err))

					local _, input = read_corpus_file(dir .. "/input.toml")
					local context = migration_context()
					local plan = Engine.plan(input, registry, driver, context)
					h.assert_eq(plan.outcome, spec.outcome, "outcome (" .. tostring(plan.detail) .. ")")
					if spec.outcome ~= "migrated" then
						h.assert_nil(plan.candidate, "a refused or current file has no candidate")
						return
					end
					h.assert_eq(plan.version, spec.from_version, "the version the migration starts from")
					h.assert_eq(registry.current, spec.to_version, "the version the migration reaches")

					local _, expected_source = read_corpus_file(dir .. "/expected.toml")
					local migrated = Engine.model_from_source(plan.candidate)
					h.assert_eq(Engine.plain(migrated), Engine.plain(Engine.model_from_source(expected_source)),
						"the migrated file must read as expected.toml")

					for line in (input .. "\n"):gmatch("([^\n]*)\n") do
						if line:match("^%s*#") then
							h.assert_true(plan.candidate:find(line, 1, true) ~= nil,
								"a comment no op touches must survive: " .. line)
						end
					end

					if spec.preserve_source == true then
						local stripped, count = plan.candidate:gsub("%[_meta%]\nschema_version = 2\n\n", "", 1)
						h.assert_eq(count, 1, "only the schema stamp is added to unsupported handoffs")
						h.assert_eq(stripped, input, "every source and occupied destination byte survives")
					end

					local replay = Engine.apply_steps(Engine.model_from_source(plan.candidate), registry,
						driver, spec.from_version, context)
					h.assert_eq(Engine.plain(replay), Engine.plain(migrated),
						"replaying the steps on their own output must change nothing")
				end)
			end
		end

		h.it("replays enough cases for this driver", function()
			h.assert_true(listed >= MIN_CASES_PER_DRIVER, string.format(
				"expected at least %d corpus cases for %s, found %d", MIN_CASES_PER_DRIVER, driver, listed))
		end)
	end)
end





-- ======================================
-- ======================================
-- ======= 3/ Registry and Render =======
-- ======================================
-- ======================================

local function register_registry(h, driver)
	h.describe("config migration registry (" .. driver .. ")", function()
		h.it("the shipped registry loads as a gap-free chain", function()
			local registry, err = Engine.load_registry(shared_root() .. "/" .. Engine.REGISTRY_PATH)
			h.assert_true(registry ~= nil, tostring(err))
			h.assert_true(#registry.steps == registry.current - registry.unstamped,
				"one step per version between unstamped and current")
			h.assert_true(#registry.steps >= 1, "the registry ships at least one step")
		end)

		h.it("accepts the control and rejects every registry of the shared defect corpus", function()
			local corpus = shared_root() .. "/tests/corpus/config_migration_registries"
			local index = read_corpus_file(corpus .. "/cases.toml").corpus or {}
			local control, control_err = Engine.load_registry(corpus .. "/" .. tostring(index.control) .. ".toml")
			h.assert_true(control ~= nil, "the control registry must be accepted: " .. tostring(control_err))
			local rejected = 0
			for _, name in ipairs(index.rejected or {}) do
				local path = corpus .. "/" .. name .. ".toml"
				read_corpus_file(path)
				local registry, err = Engine.load_registry(path)
				h.assert_nil(registry, name .. " must be rejected")
				h.assert_true(type(err) == "string" and err ~= "", name .. " must explain the refusal")
				rejected = rejected + 1
			end
			h.assert_true(rejected >= MIN_REGISTRY_DEFECTS, string.format(
				"expected at least %d rejected registries, found %d", MIN_REGISTRY_DEFECTS, rejected))
		end)

		h.it("touches only the records the steps change", function()
			local plan = Engine.plan(SCENARIO_SOURCE, registry_from(SCENARIO_REGISTRY), driver)
			h.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
			h.assert_eq(plan.candidate, SCENARIO_CANDIDATE)
		end)

		h.it("keeps CRLF line endings and a byte-order mark", function()
			local source = "\239\187\191" .. SCENARIO_SOURCE:gsub("\n", "\r\n")
			local plan = Engine.plan(source, registry_from(SCENARIO_REGISTRY), driver)
			h.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
			h.assert_eq(plan.candidate, "\239\187\191" .. SCENARIO_CANDIDATE:gsub("\n", "\r\n"))
		end)

		h.it("refuses to drop a section holding entries it cannot address", function()
			local registry = registry_from(SCENARIO_REGISTRY:gsub(
				"{ op = \"delete\", section = \"gestures\", key = \"space_wrap\" }",
				"{ op = \"delete\", section = \"gestures\" }"))
			local plan = Engine.plan("[gestures]\n\"quoted.key\" = 1\nenabled = true\n", registry, driver)
			h.assert_eq(plan.outcome, "failed")
			h.assert_nil(plan.candidate)
		end)
	end)
end





-- ===========================
-- ===========================
-- ======= 4/ Boot Run =======
-- ===========================
-- ===========================

local function register_boot(h, driver)
	h.describe("config migration at boot (" .. driver .. ")", function()
		h.it("migrates after a byte-exact backup, then leaves a current file alone", function()
			with_config(SCENARIO_SOURCE, function(path)
				local logger, lines = recording_logger()
				local registry = registry_from(SCENARIO_REGISTRY)
				local result = Engine.run({ path = path, driver = driver, registry = registry,
					stamp = STAMP, logger = logger })
				h.assert_eq(result.status, "migrated", tostring(result.detail))
				h.assert_eq(result.read_only, false)
				h.assert_eq(result.backup, Engine.backup_path(path, 3, STAMP))
				h.assert_eq(result.backup, path:sub(1, -#".toml" - 1) .. ".pre-v3-" .. STAMP .. ".toml",
					"the backup is <name>.pre-v<N>-<stamp>.toml next to the file")
				h.assert_eq(read_bytes(result.backup), SCENARIO_SOURCE, "the backup holds the exact old bytes")
				h.assert_eq(read_bytes(path), SCENARIO_CANDIDATE)
				h.assert_eq(count_level(lines, "start"), 1)
				h.assert_eq(count_level(lines, "success"), 1, "START is paired with SUCCESS")

				local again = Engine.run({ path = path, driver = driver, registry = registry,
					stamp = "20990101-000001", logger = logger })
				h.assert_eq(again.status, "current")
				h.assert_eq(read_bytes(path), SCENARIO_CANDIDATE, "a current file is not rewritten")
				h.assert_nil(read_bytes(Engine.backup_path(path, 3, "20990101-000001")),
					"a current file is not backed up")
			end)
		end)

		h.it("never writes a newer file and refuses every later write this session", function()
			local newer = "[_meta]\nschema_version = 999\n\n[gestures]\nenabled = true\n"
			with_config(newer, function(path)
				local logger, lines = recording_logger()
				local result = Engine.run({ path = path, driver = driver,
					registry = registry_from(SCENARIO_REGISTRY), stamp = STAMP, logger = logger })
				h.assert_eq(result.status, "newer")
				h.assert_eq(result.read_only, true)
				h.assert_eq(read_bytes(path), newer, "the newer file keeps its exact bytes")
				h.assert_nil(read_bytes(Engine.backup_path(path, 3, STAMP)), "nothing is backed up")
				h.assert_eq(count_level(lines, "error"), 1, "the refusal is logged as ERROR")
				h.assert_true(type(Engine.read_only_reason(path)) == "string", "the session is read-only")

				local wrote = TomlWriter.batch_write(path, { { section = "gestures", key = "enabled", value = false } })
				h.assert_true(wrote ~= true, "a later write through the shared writer is refused")
				h.assert_eq(read_bytes(path), newer, "the refused write changed nothing")
			end)
		end)


		for _, stamp_value in ipairs({ '"3"', "false", "0", "-1", "1.5", "[]" }) do
			h.it("refuses an invalid schema stamp " .. stamp_value .. " at boot and on later writes", function()
				local source = "# keep the invalid stamp for manual repair\n[_meta]\nschema_version = "
					.. stamp_value .. "\n\n[gestures]\nenabled = true\n"
				with_config(source, function(path)
					local logger, lines = recording_logger()
					local backups, publications = 0, 0
					local result = Engine.boot({ path = path, driver = driver,
						registry = registry_from(SCENARIO_REGISTRY), stamp = STAMP, logger = logger,
						create_backup = function()
							backups = backups + 1
							return true
						end,
						publish = function()
							publications = publications + 1
							return true
						end })
					h.assert_eq(result.status, "invalid")
					h.assert_eq(result.read_only, true)
					h.assert_eq(backups, 0, "invalid stamps never reach backup creation")
					h.assert_eq(publications, 0, "invalid stamps never reach publication")
					h.assert_eq(read_bytes(path), source, "the invalid file keeps every source byte")
					h.assert_nil(read_bytes(Engine.backup_path(path, 3, STAMP)))
					h.assert_eq(count_level(lines, "error"), 1, "the strict refusal is logged once")
					h.assert_true(type(Engine.read_only_reason(path)) == "string")
					local wrote = TomlWriter.batch_write(path,
						{ { section = "gestures", key = "enabled", value = false } })
					h.assert_true(wrote ~= true, "later ordinary saves remain refused for the session")
					h.assert_eq(read_bytes(path), source, "a later save cannot repair or erase the stamp")
				end)
			end)
		end

		h.it("has nothing to do when the file is absent", function()
			with_config(nil, function(path)
				local result = Engine.run({ path = path, driver = driver,
					registry = registry_from(SCENARIO_REGISTRY), stamp = STAMP, logger = (recording_logger()) })
				h.assert_eq(result.status, "absent")
				h.assert_eq(result.read_only, false)
				h.assert_nil(read_bytes(path), "no file is created")
			end)
		end)

		h.it("stamps the current version into a file a writer creates later", function()
			with_config(nil, function(path)
				local result = Engine.run({ path = path, driver = driver,
					registry = registry_from(SCENARIO_REGISTRY), stamp = STAMP, logger = (recording_logger()) })
				h.assert_eq(result.status, "absent")
				local wrote = TomlWriter.batch_write(path, { { section = "gestures", key = "enabled", value = true } })
				h.assert_eq(wrote, true)
				local decoded = TomlCodec.decode(read_bytes(path))
				h.assert_eq(decoded._meta and decoded._meta.schema_version, 3,
					"a file this build creates is at this build's version, never read later as unstamped")
				h.assert_eq(decoded.gestures and decoded.gestures.enabled, true)
				h.assert_eq(TomlWriter.create_rows(path),
					{ { section = Engine.META_SECTION, key = Engine.VERSION_KEY, value = 3 } },
					"whole-file writers read the same rows")
			end)
		end)

		h.it("leaves the file untouched and read-only when the backup fails", function()
			with_config(SCENARIO_SOURCE, function(path)
				local result = Engine.run({ path = path, driver = driver,
					registry = registry_from(SCENARIO_REGISTRY), stamp = STAMP, logger = (recording_logger()),
					create_backup = function() return false, "disk full" end })
				h.assert_eq(result.status, "failed")
				h.assert_eq(result.read_only, true)
				h.assert_eq(read_bytes(path), SCENARIO_SOURCE)
			end)
		end)

		h.it("does not overwrite an edit made after the file was read", function()
			with_config(SCENARIO_SOURCE, function(path)
				local edited = SCENARIO_SOURCE .. "\n[layout]\nedited = true\n"
				local result = Engine.run({ path = path, driver = driver,
					registry = registry_from(SCENARIO_REGISTRY), stamp = STAMP, logger = (recording_logger()),
					create_backup = function(target, content)
						write_bytes(target, content)
						write_bytes(path, edited)
						return true
					end })
				h.assert_eq(result.status, "failed")
				h.assert_eq(read_bytes(path), edited, "the concurrent edit survives")
			end)
		end)

		h.it("refuses a file it cannot parse", function()
			local broken = "[gestures\nenabled = true\n"
			with_config(broken, function(path)
				local result = Engine.run({ path = path, driver = driver,
					registry = registry_from(SCENARIO_REGISTRY), stamp = STAMP, logger = (recording_logger()) })
				h.assert_eq(result.status, "failed")
				h.assert_eq(result.read_only, true)
				h.assert_eq(read_bytes(path), broken)
			end)
		end)

		h.it("turns a raise inside the engine into the same read-only refusal", function()
			with_config(SCENARIO_SOURCE, function(path)
				local logger, lines = recording_logger()
				local broken = { current = 3, unstamped = 1, steps = { true } }
				local result = Engine.boot({ path = path, driver = driver, registry = broken,
					stamp = STAMP, logger = logger })
				h.assert_eq(result.status, "failed")
				h.assert_eq(result.read_only, true)
				h.assert_eq(read_bytes(path), SCENARIO_SOURCE)
				h.assert_true(type(Engine.read_only_reason(path)) == "string", "later writes are refused")
				h.assert_eq(count_level(lines, "error"), 1, "the raise is logged as ERROR")
			end)
		end)

		h.it("refuses to run without a loadable registry", function()
			with_config(SCENARIO_SOURCE, function(path)
				local result = Engine.run({ path = path, driver = driver,
					registry_path = path .. ".missing-registry.toml", stamp = STAMP, logger = (recording_logger()) })
				h.assert_eq(result.status, "failed")
				h.assert_eq(result.read_only, true)
				h.assert_eq(read_bytes(path), SCENARIO_SOURCE)
			end)
		end)
	end)
end





-- ===============================
-- ===============================
-- ======= 5/ Registration =======
-- ===============================
-- ===============================

--- Registers mutation probes that semantic TOML replay alone cannot expose.
local function register_copy_ownership(h, driver)
	h.describe("config migration conditional copies (" .. driver .. ")", function()
		h.it("retains every occupied namespace byte, including empty table headers", function()
			local dir = shared_root() .. "/tests/corpus/config_migrations/copy_preserves_occupied_namespaces"
			local _, input = read_corpus_file(dir .. "/input.toml")
			local registry = assert(Engine.load_registry(dir .. "/migrations.toml"))
			local plan = Engine.plan(input, registry, driver)
			h.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
			local without_stamp, removed = plan.candidate:gsub("%[_meta%]\nschema_version = 2\n\n", "", 1)
			h.assert_eq(removed, 1, "only the new schema stamp may be added")
			h.assert_eq(without_stamp, input, "conditional copies retain the complete original file")
		end)

		h.it("owns each copied nested value independently of its source and sibling", function()
			local dir = shared_root() .. "/tests/corpus/config_migrations/op_copy_if_absent"
			local _, input = read_corpus_file(dir .. "/input.toml")
			local expected = read_corpus_file(dir .. "/expected.toml")
			local registry = assert(Engine.load_registry(dir .. "/migrations.toml"))
			local model = assert(Engine.model_from_source(input))
			Engine.apply_steps(model, registry, driver, 1)
			local source = model.sections.source.records.value
			local copied = model.sections.destination.records.value
			local sibling = model.sections.sibling.records.value
			h.assert_eq(copied, expected.destination.records, "the whole copied value matches independent expectations")
			h.assert_eq(sibling, expected.sibling.records, "the second copy matches independent expectations")
			source[1].palette[1].Key = "edited source"
			source[#source + 1] = { future = "source only" }
			h.assert_eq(copied, expected.destination.records, "source edits cannot change the copied value")
			h.assert_eq(sibling, expected.sibling.records, "source edits cannot change the sibling copy")
			copied[1].palette[1].key = "edited copy"
			copied[1].visible = true
			h.assert_eq(source[1].palette[1].key, "lower", "copy edits cannot change the source's nested map")
			h.assert_eq(source[1].visible, false, "copy edits cannot change the source's Boolean")
			h.assert_eq(sibling, expected.sibling.records, "copy edits cannot change another destination")
			model.sections.source.rows.value[1][1] = 99
			h.assert_eq(model.sections.destination.rows.value, expected.destination.rows, "nested copied arrays own every child")
		end)

		h.it("preserves the exact inline ancestor bytes and the complete source choice", function()
			local dir = shared_root() .. "/tests/corpus/config_migrations/copy_preserves_occupied_namespaces"
			local _, input = read_corpus_file(dir .. "/inline_ancestor.toml")
			local registry = registry_from(table.concat({
				"[registry]", "current_version = 2", "unstamped_version = 1",
				"[steps.v1_to_v2]", "from = 1", "to = 2", 'drivers = ["ahk", "hs", "linux"]',
				'reason = "Contract: preserve occupied inline namespaces."',
				'ops = [{ op = "copy_if_absent", section = "source", key = "choice", to_section = "settings.inline.deep", to_key = "child" },',
				'{ op = "copy_if_absent", section = "source", key = "choice", to_section = "settings", to_key = "inline" }]',
			}, "\n"))
			local plan = Engine.plan(input, registry, driver)
			h.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
			local expected = assert(Engine.model_from_source(input))
			expected.sections._meta = { schema_version = { value = 2 } }
			h.assert_eq(Engine.plain(plan.model), Engine.plain(expected), "every original source and inline choice remains intact")
			local without_stamp, removed = plan.candidate:gsub("%[_meta%]\nschema_version = 2\n\n", "", 1)
			h.assert_eq(removed, 1, "only the new schema stamp may be added")
			h.assert_eq(without_stamp, input, "all original bytes survive the conditional no-ops")
		end)
	end)
end

local function register_chord_handoff(h, driver)
	h.describe("config chord action ownership (" .. driver .. ")", function()
		h.it("builds real assignability without changing ordered native catalogue data", function()
			local context = migration_context()
			local actions = context.assignable_actions
			h.assert_true(actions.none == true, "NONE is an actual offered action")
			h.assert_true(actions.open_hotstrings_editor == true, "the editor is an actual offered action")
			h.assert_true(actions.cmd_ctrl_option_shift_comma == true, "the canonical modifier subset matrix is complete")
			h.assert_nil(actions.future_action, "unknown strings are not assignable")
			h.assert_nil(actions.alt_d, "native aliases are not persisted action identities")
			h.assert_nil(actions._modifier_chords_placeholder, "picker metadata is not an action")
			local catalogue = dofile(shared_root() .. "/../macos/_generated/action_catalogue.lua")
			local before = require("toml_codec.leaf_rows").clone_value(catalogue)
			require("actions.assignable").build(catalogue, context.modifier_chords, "macos")
			h.assert_eq(catalogue, before, "array order, labels and generated native fields are untouched")
		end)

		h.it("backs up exact legacy data before publishing the represented chord handoff", function()
			local dir = shared_root() .. "/tests/corpus/config_migrations/op_move_chord_ctrl_letter"
			local _, source = read_corpus_file(dir .. "/input.toml")
			local _, wanted = read_corpus_file(dir .. "/expected.toml")
			local registry = assert(Engine.load_registry(dir .. "/migrations.toml"))
			with_config(source, function(path)
				local result = Engine.run({ path = path, driver = driver, registry = registry,
					stamp = STAMP, context = migration_context() })
				h.assert_eq(result.status, "migrated", tostring(result.detail))
				h.assert_eq(read_bytes(result.backup), source, "backup precedes source cleanup")
				h.assert_eq(Engine.plain(assert(Engine.model_from_source(read_bytes(path)))),
					Engine.plain(assert(Engine.model_from_source(wanted))), "publication carries the exact expected choices")
			end)
		end)

		h.it("retains exact inline ancestor namespaces without a partial handoff", function()
			local dir = shared_root() .. "/tests/corpus/config_migrations/op_move_chord_scalar_ancestor"
			local _, source = read_corpus_file(dir .. "/inline_ancestor.toml")
			local registry = assert(Engine.load_registry(dir .. "/migrations.toml"))
			local plan = Engine.plan(source, registry, driver, migration_context())
			h.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
			local without_stamp, count = plan.candidate:gsub("%[_meta%]\nschema_version = 2\n\n", "", 1)
			h.assert_eq(count, 1)
			h.assert_eq(without_stamp, source, "both complete inline records and comments remain byte exact")
		end)

		h.it("refused handoff publication preserves the legacy file and prevents future writes", function()
			local dir = shared_root() .. "/tests/corpus/config_migrations/op_move_chord_ctrl_letter"
			local _, source = read_corpus_file(dir .. "/input.toml")
			with_config(source, function(path)
				local result = Engine.run({ path = path, driver = driver,
					registry = assert(Engine.load_registry(dir .. "/migrations.toml")), stamp = STAMP,
					context = migration_context(), publish = function() return false, "native lease refused" end })
				h.assert_eq(result.status, "failed")
				h.assert_true(result.read_only, "the old native owner remains backed by an unwritable source")
				h.assert_eq(read_bytes(path), source, "no cleanup or conditional choice reaches the file")
			end)
		end)

		h.it("missing catalogue data uses the existing read-only boot refusal", function()
			local context, detail = Engine.load_context("", {})
			h.assert_nil(context)
			h.assert_true(type(detail) == "string")
			local bad, bad_detail = Engine.load_context("unreadable-catalogue.json", {}, { read = function() return nil end })
			h.assert_nil(bad)
			local source = '[hotstrings.editor]\nshortcut = false\n'
			with_config(source, function(path)
				local result = Engine.boot({ path = path, driver = driver,
					registry = assert(Engine.load_registry(shared_root() .. "/tests/corpus/config_migrations/op_move_chord_false/migrations.toml")),
					context_error = bad_detail, stamp = STAMP })
				h.assert_eq(result.status, "failed")
				h.assert_true(result.read_only)
				h.assert_eq(read_bytes(path), source, "missing context never deletes the legacy owner")
			end)
		end)
		h.it("rejects actual malformed and scalar JSON without publishing a legacy handoff", function()
			for _, raw in ipairs({ "{ malformed", "false", '{"keys": [], "platforms": {"macos": false}}' }) do
				with_config(raw, function(catalogue_path)
					local context, detail = Engine.load_context(catalogue_path,
						dofile(shared_root() .. "/../macos/_generated/action_catalogue.lua"))
					h.assert_nil(context, "malformed or untyped catalogue data cannot authorize cleanup")
					h.assert_true(type(detail) == "string", "the failure reaches boot's refusal path")
					h.assert_eq(read_bytes(catalogue_path), raw, "validation never changes its data source")
				end)
			end
		end)

		h.it("an absent engine context cannot consume the explicit legacy disable record", function()
			local source = '[hotstrings.editor]\nshortcut = false\n'
			with_config(source, function(path)
				local result = Engine.boot({ path = path, driver = driver,
					registry = assert(Engine.load_registry(shared_root() .. "/tests/corpus/config_migrations/op_move_chord_false/migrations.toml")),
					stamp = STAMP })
				h.assert_eq(result.status, "failed")
				h.assert_true(result.read_only)
				h.assert_eq(read_bytes(path), source, "the old native owner survives context refusal")
			end)
		end)

		h.it("missing assignability owner becomes a context refusal receipt before boot", function()
			local previous_loaded = package.loaded["actions.assignable"]
			local previous_preload = package.preload["actions.assignable"]
			package.loaded["actions.assignable"] = nil
			package.preload["actions.assignable"] = function() error("fixture missing assignability owner") end
			local ok, context, detail = pcall(function()
				return Engine.load_context(shared_root() .. "/modules/actions/modifier_chords.json",
					dofile(shared_root() .. "/../macos/_generated/action_catalogue.lua"))
			end)
			package.loaded["actions.assignable"] = previous_loaded
			package.preload["actions.assignable"] = previous_preload
			h.assert_true(ok, "module acquisition errors must not escape the pre-boot seam")
			h.assert_nil(context)
			h.assert_true(type(detail) == "string" and detail:find("fixture missing assignability owner", 1, true) ~= nil)
		end)

		h.it("a decoder exception becomes a receipt and leaves the legacy file read-only", function()
			local previous_json = package.loaded["json"]
			package.loaded["json"] = { decode_lossless = function() error("fixture decoder exception") end }
			local ok, context, detail = pcall(function()
				return Engine.load_context(shared_root() .. "/modules/actions/modifier_chords.json",
					dofile(shared_root() .. "/../macos/_generated/action_catalogue.lua"))
			end)
			package.loaded["json"] = previous_json
			h.assert_true(ok, "decode errors must not escape the pre-boot seam")
			h.assert_nil(context)
			h.assert_true(type(detail) == "string" and detail:find("fixture decoder exception", 1, true) ~= nil)
			local source = '[hotstrings.editor]\nshortcut = false\n'
			with_config(source, function(path)
				local result = Engine.boot({ path = path, driver = driver,
					registry = assert(Engine.load_registry(shared_root() .. "/tests/corpus/config_migrations/op_move_chord_false/migrations.toml")),
					context_error = detail, stamp = STAMP })
				h.assert_eq(result.status, "failed")
				h.assert_true(result.read_only)
				h.assert_eq(read_bytes(path), source, "decoder failure cannot clean the legacy source")
			end)
		end)

	end)
end


-- Fresh schema admission is exercised through real file publication; the
-- source/read callback controls below keep their assertions outside owners.
local function register_schema_admission(h, driver)
	local function current(enabled)
		return '# keep foreign bytes\n[_meta]\nschema_version = 3\n[llm]\nenabled = '
			.. tostring(enabled) .. '\n[future]\nprecise = 0.1234567890123456789\nmax = 9223372036854775807\nempty = [] # exact\n'
	end
	local function admitted(path, logger)
		return Engine.boot({ path = path, driver = driver, registry = registry_from(SCENARIO_REGISTRY),
			stamp = STAMP, logger = logger or (recording_logger()) })
	end
	h.describe('fresh closed configuration schema admission (' .. driver .. ')', function()
		h.it('rejects copied or callback native ports before invoking them', function()
			with_config(current(false), function(path)
				h.assert_eq(admitted(path).status, 'current')
				local calls = 0
				local function fake() calls = calls + 1; return true end
				local adapter = setmetatable({ read_with_status = fake, write_if_unchanged_admitted = fake,
					write_if_unchanged = fake, remove_if_unchanged_admitted = fake,
					remove_if_unchanged = fake, delete = fake }, { __eq = function() return true end })
				h.assert_eq(TomlWriter.prepare_batch(path, { { section = 'llm', key = 'enabled', value = true } }, adapter), false)
				h.assert_eq(TomlWriter.publish_if_unchanged(path, current(true), adapter, { status = 'ok', content = current(false) }), false)
				h.assert_eq(TomlWriter.remove_if_unchanged(path, adapter, { status = 'ok', content = current(false) }), false)
				local bytes, status = TomlWriter.read_classified(path, adapter)
				h.assert_nil(bytes); h.assert_eq(status, 'error')
				h.assert_eq(calls, 0, 'a fake native acknowledgement never invokes a port')
				h.assert_eq(read_bytes(path), current(false))
			end)
		end)
		for _, operation in ipairs({ false, true }) do
			for _, kind in ipairs({ 'copied adapter', 'withdrawn actual reader' }) do
				h.it('refuses ' .. kind .. ' before whole-write reader invocation: create_only=' .. tostring(operation), function()
					with_config(current(false), function(path)
						local adapter = require('adapters.file_system')
						h.assert_eq(admitted(path).status, 'current')
						local reader = rawget(adapter, 'read_with_status')
						local calls = 0
						local function fake() calls = calls + 1; return current(false), 'ok' end
						local supplied = adapter
						if kind == 'copied adapter' then supplied = { read_with_status = fake }
						else rawset(adapter, 'read_with_status', fake) end
						local called, accepted = pcall(TomlWriter.write, path, {}, supplied, operation)
						rawset(adapter, 'read_with_status', reader)
						h.assert_true(called)
						h.assert_eq(accepted, false)
						h.assert_eq(calls, 0, 'read refusal precedes an unissued callback')
						h.assert_eq(read_bytes(path), current(false))
					end)
				end)
			end
		end

		for _, field in ipairs({ 'remove_if_unchanged_admitted', 'remove_exact', 'delete' }) do
			for _, timing in ipairs({ 'before boot', 'after boot' }) do
				h.it('refuses replacement native removal identity ' .. field .. ' ' .. timing, function()
					with_config(current(false), function(path)
						local adapter = require('adapters.file_system')
						local original, calls = rawget(adapter, field), 0
						local function fake() calls = calls + 1; return true end
						if timing == 'before boot' then rawset(adapter, field, fake) end
						local boot_called, boot = pcall(admitted, path)
						if timing == 'after boot' then rawset(adapter, field, fake) end
						local called, accepted = pcall(TomlWriter.remove_if_unchanged,
							path, adapter, { status = 'ok', content = current(false) })
						rawset(adapter, field, original)
						h.assert_true(boot_called)
						if timing == 'after boot' then h.assert_eq(boot.status, 'current')
						else h.assert_true(boot.read_only) end
						h.assert_true(called)
						h.assert_eq(accepted, false)
						h.assert_eq(calls, 0, 'invented or replaced native remover is never invoked')
						h.assert_eq(read_bytes(path), current(false))
					end)
				end)
			end
		end
		h.it('refuses a genuine same-file native method aliased as delete before boot', function()
			with_config(current(false), function(path)
				local adapter = require('adapters.file_system')
				local original = rawget(adapter, 'delete')
				rawset(adapter, 'delete', assert(rawget(adapter, 'exists')))
				local boot_called, boot = pcall(admitted, path)
				local called, accepted = pcall(TomlWriter.remove_if_unchanged,
					path, adapter, { status = 'ok', content = current(false) })
				rawset(adapter, 'delete', original)
				h.assert_true(boot_called); h.assert_true(boot.read_only)
				h.assert_true(called); h.assert_eq(accepted, false)
				h.assert_eq(read_bytes(path), current(false), 'a filename match is not a native removal identity')
			end)
		end)
		h.it('refuses raw native issuer withdrawal before publication without invoking its accessor', function()
			with_config(current(false), function(path)
				local adapter = require('adapters.file_system')
				h.assert_eq(admitted(path).status, 'current')
				local issuer, meta = rawget(adapter, 'configuration_ports'), getmetatable(adapter)
				local reached = 0
				rawset(adapter, 'configuration_ports', nil)
				setmetatable(adapter, { __index = function(_, key)
					if key == 'configuration_ports' then reached = reached + 1; return issuer end
				end })
				local called, accepted = pcall(TomlWriter.batch_write, path,
					{ { section = 'llm', key = 'enabled', value = true } }, adapter)
				setmetatable(adapter, meta); rawset(adapter, 'configuration_ports', issuer)
				h.assert_true(called); h.assert_eq(accepted, false)
				h.assert_eq(reached, 0)
				h.assert_eq(read_bytes(path), current(false))
				h.assert_true(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }, adapter))
			end)
		end)

		h.it('refuses a replacement native identity getter before invoking it at boot', function()
			with_config(current(false), function(path)
				local adapter = require('adapters.file_system')
				local issuer, calls = rawget(adapter, 'configuration_ports'), 0
				rawset(adapter, 'configuration_ports', function() calls = calls + 1; return adapter end)
				local called, boot = pcall(admitted, path)
				rawset(adapter, 'configuration_ports', issuer)
				h.assert_true(called); h.assert_true(boot.read_only)
				h.assert_eq(calls, 0, 'a replacement identity callback cannot issue native admission')
				h.assert_eq(read_bytes(path), current(false))
			end)
		end)
		h.it('refuses a copied native module borrowing the actual initializer getter', function()
			with_config(current(false), function(path)
				local adapter = require('adapters.file_system')
				local copy, calls = {}, 0
				for key, value in pairs(adapter) do copy[key] = value end
				copy.read_with_status = function() calls = calls + 1; return current(false), 'ok' end
				rawset(package.loaded, 'adapters.file_system', copy)
				local called, boot = pcall(admitted, path)
				rawset(package.loaded, 'adapters.file_system', adapter)
				h.assert_true(called); h.assert_true(boot.read_only)
				h.assert_eq(calls, 0, 'the borrowed getter returns its real owner, never the copied module')
				h.assert_eq(read_bytes(path), current(false))
			end)
		end)

		for _, timing in ipairs({ 'before boot', 'during start callback' }) do
			h.it('refuses a replaced native registry reader ' .. timing .. ' before invoking it', function()
				with_config(current(false), function(path)
					local adapter = require('adapters.file_system')
					local reader, calls = rawget(adapter, 'read_with_status'), 0
					local function replaced(...) calls = calls + 1; return reader(...) end
					local logger = recording_logger()
					if timing == 'before boot' then rawset(adapter, 'read_with_status', replaced)
					else
						local start = logger.start
						logger.start = function(...)
							start(...); rawset(adapter, 'read_with_status', replaced)
						end
					end
					local called, boot = pcall(Engine.boot, { path = path, driver = driver,
						registry_path = shared_root() .. '/' .. Engine.REGISTRY_PATH,
						file_adapter = adapter, logger = logger })
					rawset(adapter, 'read_with_status', reader)
					h.assert_true(called); h.assert_true(boot.read_only)
					h.assert_eq(calls, 0, 'registry loading never invokes an unissued native reader')
					h.assert_eq(read_bytes(path), current(false))
				end)
			end)
		end

		h.it('refuses a withdrawn actual admitted native export even with accessor fallback', function()
			with_config(current(false), function(path)
				local adapter = require('adapters.file_system')
				h.assert_eq(admitted(path).status, 'current')
				local publisher, previous = rawget(adapter, 'write_if_unchanged_admitted'), getmetatable(adapter)
				local reached = 0
				rawset(adapter, 'write_if_unchanged_admitted', nil)
				setmetatable(adapter, { __index = function(_, key)
					if key == 'write_if_unchanged_admitted' then reached = reached + 1; return publisher end
				end })
				local called, accepted = pcall(TomlWriter.batch_write, path, { { section = 'llm', key = 'enabled', value = true } }, adapter)
				setmetatable(adapter, previous); rawset(adapter, 'write_if_unchanged_admitted', publisher)
				h.assert_eq(called, true); h.assert_eq(accepted, false)
				h.assert_eq(reached, 0, 'withdrawn methods are not manufactured through __index')
				h.assert_eq(read_bytes(path), current(false))
				h.assert_true(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }))
			end)
		end)
		for _, token in ipairs({ '4', 'true', '"3"', '3.5', '[]' }) do
			h.it('refuses newly unsupported source before preparation, publication, read and removal: ' .. token, function()
				with_config(current(false), function(path)
					h.assert_eq(admitted(path).status, 'current')
					local source = current(false):gsub('schema_version = 3', 'schema_version = ' .. token)
					write_bytes(path, source)
					h.assert_eq(TomlWriter.prepare_batch(path, { { section = 'llm', key = 'enabled', value = true } }), false)
					h.assert_eq(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }), false)
					h.assert_eq(TomlWriter.publish_if_unchanged(path, source, nil, { status = 'ok', content = source }), false,
						'a byte-identical no-op cannot acknowledge an unsupported configuration')
					h.assert_eq(TomlWriter.remove_if_unchanged(path, nil, { status = 'ok', content = source }), false)
					local bytes, status = TomlWriter.read_classified(path)
					h.assert_nil(bytes)
					h.assert_eq(status, 'error', 'runtime readers receive failure, never absence/defaults')
					h.assert_eq(read_bytes(path), source)
					write_bytes(path, current(false))
					h.assert_true(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }),
						'a fresh explicit intent after manual current repair is eligible')
					h.assert_eq(read_bytes(path), current(true))
				end)
			end)
		end
		for _, metadata in ipairs({ '_meta = {schema_version = 3}', '_meta.schema_version = 3', '["_meta"]\n"schema_version" = 3' }) do
			h.it('authenticates canonical current metadata: ' .. metadata, function()
				local source = metadata .. '\n[llm]\nenabled = false\n'
				with_config(source, function(path)
					h.assert_eq(admitted(path).status, 'current')
					h.assert_true(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }))
					h.assert_eq(read_bytes(path), metadata .. '\n[llm]\nenabled = true\n')
				end)
			end)
		end
		for _, metadata in ipairs({ '_meta = true', '[["_meta"]]\nschema_version = 3', '_meta = {schema_version = 4}', '_meta.schema_version = true' }) do
			h.it('refuses non-current canonical metadata at initial boot: ' .. metadata, function()
				local source = metadata .. '\n[llm]\nenabled = false\n'
				with_config(source, function(path)
					h.assert_true(admitted(path).read_only)
					h.assert_eq(read_bytes(path), source)
					h.assert_nil(read_bytes(Engine.backup_path(path, 3, STAMP)))
				end)
			end)
		end
		h.it('admits actual absent/current creation but does not grant READY through public row/default setters', function()
			with_config(nil, function(path)
				h.assert_eq(admitted(path).status, 'absent')
				h.assert_true(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }))
				h.assert_eq(TomlCodec.decode(read_bytes(path))._meta.schema_version, 3)
				h.assert_eq(TomlCodec.decode(read_bytes(path)).llm.enabled, true)
			end)
			with_config(current(false), function(path)
				h.assert_eq(admitted(path).status, 'current')
				local future = current(false):gsub('schema_version = 3', 'schema_version = 4')
				write_bytes(path, future)
				TomlWriter.set_create_rows(path, { { section = '_meta', key = 'schema_version', value = 4 } })
				h.assert_eq(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }), false)
				h.assert_eq(read_bytes(path), future)
			end)
		end)
		h.it('does not lift an initial refused session when the physical source is manually current again', function()
			with_config(current(false):gsub('schema_version = 3', 'schema_version = 4'), function(path)
				h.assert_true(admitted(path).read_only)
				write_bytes(path, current(false))
				admitted(path)
				h.assert_eq(TomlWriter.prepare_batch(path, { { section = 'llm', key = 'enabled', value = true } }), false)
				h.assert_eq(read_bytes(path), current(false))
			end)
		end)
		h.it('starts PREPARING before the real logger can reenter ordinary publication', function()
			with_config(current(false), function(path)
				local logger = recording_logger()
				local wrote
				logger.start = function() wrote = TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }) end
				local result = admitted(path, logger)
				h.assert_eq(result.status, 'current')
				h.assert_eq(wrote, false)
				h.assert_eq(read_bytes(path), current(false))
			end)
		end)
		h.it('keeps the issued registry copy private before callbacks mutate the public object', function()
			with_config(current(false), function(path)
				local registry = registry_from(SCENARIO_REGISTRY)
				local logger = recording_logger()
				logger.start = function() registry.current = 999; registry.steps = {} end
				local result = Engine.boot({ path = path, driver = driver, registry = registry, logger = logger })
				h.assert_eq(result.status, 'current')
				h.assert_eq(result.to, 3)
				h.assert_true(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }))
				h.assert_eq(read_bytes(path), current(true))
			end)
		end)
		h.it('rejects a cloned current-looking registry rather than issuing native readiness', function()
			with_config(current(false), function(path)
				local registry = registry_from(SCENARIO_REGISTRY)
				local clone = { current = registry.current, unstamped = registry.unstamped, steps = registry.steps }
				h.assert_true(Engine.boot({ path = path, driver = driver, registry = clone, logger = recording_logger() }).read_only)
				h.assert_eq(read_bytes(path), current(false))
			end)
		end)
		h.it('refuses a borrowed constructor factory call from an arbitrary consumer', function()
			local callbacks = 0
			local called = pcall(Engine.writer_admission_factory, TomlWriter, function()
				callbacks = callbacks + 1
				return TomlWriter, function() return current(false), 'ok' end, function() return true end
			end)
			h.assert_eq(called, false)
			h.assert_eq(callbacks, 0)
		end)
		h.it('does not accept raw factory withdrawal through an __index fallback', function()
			with_config(current(false), function(path)
				h.assert_eq(admitted(path).status, 'current')
				local factory, meta = rawget(Engine, 'writer_admission_factory'), getmetatable(Engine)
				rawset(Engine, 'writer_admission_factory', nil)
				setmetatable(Engine, { __index = function(_, key) if key == 'writer_admission_factory' then return factory end end })
				local called, wrote = pcall(TomlWriter.batch_write, path, { { section = 'llm', key = 'enabled', value = true } })
				setmetatable(Engine, meta)
				rawset(Engine, 'writer_admission_factory', factory)
				h.assert_true(called)
				h.assert_eq(wrote, false)
				h.assert_eq(read_bytes(path), current(false))
				h.assert_true(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }))
			end)
		end)
		h.it('refuses ambiguous dot-segment spellings without rewriting the native route', function()
			with_config(current(false), function(path)
				h.assert_eq(admitted(path).status, 'current')
				local alias = path:gsub('([^/]+)$', './%1')
				h.assert_eq(TomlWriter.batch_write(alias, { { section = 'llm', key = 'enabled', value = true } }), false)
				h.assert_eq(read_bytes(path), current(false))
			end)
		end)
		h.it('refuses future whole-write/create-only exists acknowledgement before adapter effects', function()
			with_config(current(false), function(path)
				h.assert_eq(admitted(path).status, 'current')
				local future = current(false):gsub('schema_version = 3', 'schema_version = 4')
				write_bytes(path, future)
				local calls = 0
				local adapter = { read_with_status = function() return read_bytes(path), 'ok' end,
					create_if_absent = function() calls = calls + 1; return false, 'exists' end,
					write = function() calls = calls + 1; return true end }
				h.assert_eq(TomlWriter.write(path, {}, adapter, true), false)
				h.assert_eq(TomlWriter.write(path, {}, adapter, false), false)
				h.assert_eq(calls, 0)
				h.assert_eq(read_bytes(path), future)
			end)
		end)
		h.it('reacquires initial legacy source before backup when its first actual native read triggers drift', function()
			with_config(SCENARIO_SOURCE, function(path)
				local future = '[_meta]\nschema_version = 4\n[future]\nvalue = "keep"\n'
				local open, injected = io.open, false
				io.open = function(target, mode)
					local file, detail, code = open(target, mode)
					if file and target == path and mode == 'r' and not injected then
						return { read = function(_, format)
							local bytes = file:read(format)
							if not injected then injected = true; write_bytes(path, future) end
							return bytes
						end, close = function() return file:close() end }
					end
					return file, detail, code
				end
				local called, result = pcall(admitted, path)
				io.open = open
				h.assert_true(called)
				h.assert_true(injected)
				h.assert_true(result.read_only)
				h.assert_eq(read_bytes(path), future)
				h.assert_nil(read_bytes(Engine.backup_path(path, 3, STAMP)), 'no backup effect may precede fresh drift refusal')
			end)
		end)
		h.it('retires an acquired publication epoch if actual final native read reenters boot', function()
			with_config(current(false), function(path)
				h.assert_eq(admitted(path).status, 'current')
				local open, injected, nested = io.open, false, nil
				io.open = function(target, mode)
					local file, detail, code = open(target, mode)
					if file and target == path and mode == 'r' and not injected then
						return { read = function(_, format)
							local bytes = file:read(format)
							if not injected then injected = true; nested = admitted(path) end
							return bytes
						end, close = function() return file:close() end }
					end
					return file, detail, code
				end
				local called, wrote = pcall(TomlWriter.publish_if_unchanged, path, current(true), nil,
					{ status = 'ok', content = current(false) })
				io.open = open
				h.assert_true(called)
				h.assert_true(injected)
				h.assert_eq(nested.status, 'current')
				h.assert_eq(wrote, false)
				h.assert_eq(read_bytes(path), current(false))
				h.assert_true(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }))
			end)
		end)
	end)
end

-- A refused initial version remains readable only through the captured native
-- destination and byte image; refusal never becomes a publication capability.
local function register_version_refused_reads(h, driver)
	local function boot(path, options)
		options = options or {}
		options.path, options.driver = path, driver
		options.registry = registry_from(SCENARIO_REGISTRY)
		options.stamp, options.logger = STAMP, recording_logger()
		return Engine.boot(options)
	end
	local function source(token)
		return '# retained read-only source\n[_meta]\nschema_version = ' .. token
			.. '\n[llm]\nenabled = false\n[future]\nvalue = "preserved"\n'
	end
	h.describe('captured initial version-refused reads (' .. driver .. ')', function()
		for _, case in ipairs({ { 'true', 'invalid' }, { 'false', 'invalid' }, { '4', 'newer' } }) do
			h.it('reads initial ' .. case[2] .. ' bytes without granting a write or scope effect', function()
				with_config(source(case[1]), function(path)
					local original = read_bytes(path)
					local result = boot(path)
					h.assert_eq(result.status, case[2]); h.assert_true(result.read_only)
					local bytes, status = TomlWriter.read_classified(path)
					h.assert_eq(status, 'ok'); h.assert_eq(bytes, original)
					h.assert_eq(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }), false)
					h.assert_eq(TomlWriter.publish_if_unchanged(path, original, nil, { status = 'ok', content = original }), false)
					h.assert_eq(TomlWriter.remove_if_unchanged(path, nil, { status = 'ok', content = original }), false)
					local effects = 0
					local scope = require('config_scope_transaction').new({ path = path, backup_path = path .. '.scope-backup',
						manifest = require('infra.manifest_reader'), files = require('adapters.file_system'),
						capture = function() effects = effects + 1; return {} end,
						apply = function() effects = effects + 1; return true end,
						restore = function() effects = effects + 1; return true end })
					h.assert_eq(scope.apply('llm', 'clear'), false)
					h.assert_eq(effects, 0); h.assert_nil(read_bytes(path .. '.scope-backup'))
					h.assert_eq(read_bytes(path), original)
					h.assert_nil(read_bytes(Engine.backup_path(path, 3, STAMP)))
				end)
			end)
		end
		h.it('refuses a changed image or absence without lifting the initial write latch', function()
			with_config(source('4'), function(path)
				local original = read_bytes(path)
				h.assert_true(boot(path).read_only)
				for _, replacement in ipairs({ original .. '# external successor\n', source('3') }) do
					write_bytes(path, replacement)
					local bytes, status = TomlWriter.read_classified(path)
					h.assert_nil(bytes); h.assert_eq(status, 'error')
					h.assert_eq(TomlWriter.batch_write(path, { { section = 'llm', key = 'enabled', value = true } }), false)
					h.assert_eq(read_bytes(path), replacement)
				end
				os.remove(path)
				local bytes, status = TomlWriter.read_classified(path)
				h.assert_nil(bytes); h.assert_eq(status, 'error')
				write_bytes(path, original)
				h.assert_eq(TomlWriter.read_classified(path), original)
			end)
		end)
		h.it('refuses a withdrawn raw native issuer without invoking its replacement', function()
			with_config(source('true'), function(path)
				h.assert_true(boot(path).read_only)
				local adapter = require('adapters.file_system')
				local issuer, calls = rawget(adapter, 'configuration_ports'), 0
				rawset(adapter, 'configuration_ports', function() calls = calls + 1; return issuer() end)
				local called, bytes, status = pcall(TomlWriter.read_classified, path)
				rawset(adapter, 'configuration_ports', issuer)
				h.assert_true(called); h.assert_nil(bytes); h.assert_eq(status, 'error'); h.assert_eq(calls, 0)
				h.assert_eq(TomlWriter.read_classified(path), source('true'))
			end)
		end)
		h.it('refuses a raw native owner replacement rather than lending its readable image', function()
			with_config(source('4'), function(path)
				h.assert_true(boot(path).read_only)
				local adapter = rawget(package.loaded, 'adapters.file_system')
				local calls = 0
				package.loaded['adapters.file_system'] = { read_with_status = function()
					calls = calls + 1; return source('4'), 'ok'
				end }
				local called, bytes, status = pcall(TomlWriter.read_classified, path)
				package.loaded['adapters.file_system'] = adapter
				h.assert_true(called); h.assert_nil(bytes); h.assert_eq(status, 'error'); h.assert_eq(calls, 0)
				h.assert_eq(TomlWriter.read_classified(path), source('4'))
			end)
		end)
		h.it('retires a captured read closure when a new boot journal replaces its epoch', function()
			with_config(source('4'), function(path)
				h.assert_true(boot(path).read_only)
				local _, _, read_check = Engine.writer_admission_factory()
				local check = read_check(path)
				h.assert_eq(type(check), 'function'); h.assert_true(check(source('4'), 'ok'))
				h.assert_true(boot(path).read_only)
				h.assert_eq(check(source('4'), 'ok'), false)
				h.assert_eq(TomlWriter.read_classified(path), source('4'))
			end)
		end)
		for _, invalid in ipairs({ '_meta = true\n', '[["_meta"]]\nschema_version = true\n', 'broken = [\n' }) do
			h.it('does not grant a readable image for malformed document or metadata: ' .. invalid, function()
				with_config(invalid, function(path)
					h.assert_true(boot(path).read_only)
					local bytes, status = TomlWriter.read_classified(path)
					h.assert_nil(bytes); h.assert_eq(status, 'error'); h.assert_eq(read_bytes(path), invalid)
				end)
			end)
		end
		h.it('grants no initial reader image to a custom read seam or failed context', function()
			for _, options in ipairs({ { read = function() return source('4'), 'ok' end }, { context_error = 'unavailable catalogue' } }) do
				with_config(source('4'), function(path)
					h.assert_true(boot(path, options).read_only)
					local bytes, status = TomlWriter.read_classified(path)
					h.assert_nil(bytes); h.assert_eq(status, 'error'); h.assert_eq(read_bytes(path), source('4'))
				end)
			end
		end)
	end)
end

--- Registers the whole contract for one driver.
--- @param h table Driver test helpers (describe, it, assert_*).
--- @param opts table `{ driver = "hs" | "linux" }`.
function M.register(h, opts)
	if type(opts) ~= "table" or not Engine.DRIVERS[opts.driver] then
		error("config_migrate_contract.register needs a known driver id", 2)
	end
	register_corpus(h, opts.driver)
	register_registry(h, opts.driver)
	register_copy_ownership(h, opts.driver)
	register_chord_handoff(h, opts.driver)
	register_boot(h, opts.driver)
	register_schema_admission(h, opts.driver)
	register_version_refused_reads(h, opts.driver)
end

return M
