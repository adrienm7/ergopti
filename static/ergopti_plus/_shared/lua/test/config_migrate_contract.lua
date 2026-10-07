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
end


-- Keep the existing registration body and every prior contract unchanged.
local register_without_variant = M.register
function M.register(h, opts)
	register_without_variant(h, opts)
	h.describe("Internal helper-variant record migration (" .. opts.driver .. ")", function()
		local operation = { op = "move_ergopti_variant", section = "layout", key = "ergopti_plus",
			to_key = "ergopti_variant", base_key = "ergopti_base", alt_gr_key = "ergopti_alt_gr",
			source_key = "emulated_layout", false_variant = "ergopti", true_variant = "ergopti_plus" }
		h.it("transfers recognized three-key-only intent without changing metadata or independent layers", function()
			local source = '[_meta]\nschema_version = 7\n[layout]\nergopti_plus = true\nergopti_base = false\nergopti_alt_gr = false\nemulated_layout = ""\n[private]\nopaque = "retain" # independent source\n'
			local plan = Engine.plan_operations(source, { operation })
			h.assert_eq(plan.outcome, "migrated", plan.detail)
			h.assert_eq(Engine.plain(plan.model), { _meta = { schema_version = 7 },
				layout = { ergopti_variant = "ergopti_plus", ergopti_base = false, ergopti_alt_gr = false, emulated_layout = "" },
				private = { opaque = "retain" } })
			h.assert_true(plan.candidate:find('[private]\nopaque = "retain" # independent source\n', 1, true) ~= nil)
			local replay = Engine.plan_operations(plan.candidate, { operation })
			h.assert_eq(replay.outcome, "current")
			h.assert_eq(replay.candidate, plan.candidate)
		end)
		h.it("unknown absent-source and conflicting current choices return typed refusals without candidates", function()
			for _, source in ipairs({ '[layout]\nergopti_variant = "future"\n',
				'[layout]\nergopti_variant = "ERGOPTI_PLUS"\n',
				'[layout]\nergopti_plus = true\nergopti_variant = "ergopti"\n' }) do
				local accepted, plan = pcall(Engine.plan_operations, source, { operation })
				h.assert_true(accepted, "the new typed refusal remains an outcome instead of an unhandled exception")
				h.assert_eq(plan.outcome, "invalid")
				h.assert_nil(plan.candidate)
				h.assert_true(plan.detail:find("Ergopti variant migration refused:", 1, true) == 1)
			end
		end)
		h.it("the actual mutable step refuses before consuming old or conflicting ownership", function()
			local registry = assert(Engine.load_registry(shared_root() .. "/tests/corpus/config_migrations/joint_variant_true_overlay/migrations.toml"))
			for _, source in ipairs({ '[_meta]\nschema_version = 1\n[layout]\nergopti_plus = 1\n',
				'[_meta]\nschema_version = 1\n[layout]\nergopti_plus = true\nergopti_base = 0\n',
				'[_meta]\nschema_version = 1\n[layout]\nergopti_plus = true\nergopti_alt_gr = "false"\n',
				'[_meta]\nschema_version = 1\n[layout]\nergopti_plus = true\nemulated_layout = false\n',
				'[_meta]\nschema_version = 1\n[layout]\nergopti_plus = true\nergopti_variant = "ergopti"\n',
				'[_meta]\nschema_version = 1\n[layout]\nergopti_variant = "future"\n' }) do
				local model = assert(Engine.model_from_source(source))
				local before = Engine.plain(model)
				local accepted, refusal = pcall(Engine.apply_steps, model, registry, opts.driver, 1)
				h.assert_true(not accepted, "the real mutable operation must refuse each malformed participant")
				h.assert_true(tostring(refusal):find("Ergopti variant migration refused:", 1, true) == 1)
				h.assert_eq(Engine.plain(model), before, "every old/current/independent typed value survives direct refusal")
			end
		end)
		h.it("malformed legacy and retained layer/source participants cannot reach a record candidate", function()
			for _, source in ipairs({ '[layout]\nergopti_plus = 1\n',
				'[layout]\nergopti_plus = true\nergopti_base = 0\n',
				'[layout]\nergopti_plus = true\nergopti_alt_gr = "false"\n',
				'[layout]\nergopti_plus = true\nemulated_layout = false\n' }) do
				local plan = Engine.plan_operations(source, { operation })
				h.assert_eq(plan.outcome, "invalid")
				h.assert_nil(plan.candidate)
				h.assert_true(plan.detail:find("Ergopti variant migration refused:", 1, true) == 1)
			end
		end)
	end)
end

local register_without_neutral = M.register
function M.register(h, opts)
	register_without_neutral(h, opts)
	h.describe("Neutral internal helper intent (" .. opts.driver .. ")", function()
		local operation = { op = "move_ergopti_variant", section = "layout", key = "ergopti_plus",
			to_key = "ergopti_variant", base_key = "ergopti_base", alt_gr_key = "ergopti_alt_gr",
			source_key = "emulated_layout", false_variant = "ergopti", true_variant = "ergopti_plus", neutral_variant = "none" }
		h.it("registry admission requires a typed neutral choice distinct from both legacy choices", function()
			local decoded = { registry = { current_version = 2, unstamped_version = 1 },
				steps = { v1_to_v2 = { from = 1, to = 2, drivers = { "ahk", "hs", "linux" },
					reason = "Independent neutral admission.", ops = { operation } } } }
			h.assert_true(Engine.validate_registry(decoded) ~= nil)
			for _, bad in ipairs({ false, 1, "ergopti", "ergopti_plus" }) do
				operation.neutral_variant = bad
				local registry, detail = Engine.validate_registry(decoded)
				h.assert_nil(registry)
				h.assert_true(detail:find("neutral variant", 1, true) ~= nil)
			end
			operation.neutral_variant = "none"
		end)
		h.it("admits current neutral intent without enabling or rewriting independent layers", function()
			local source = '[layout]\nergopti_variant = "none"\nergopti_base = true\nergopti_alt_gr = false\nemulated_layout = ""\n'
			local plan = Engine.plan_operations(source, { operation })
			h.assert_eq(plan.outcome, "current", plan.detail)
			h.assert_eq(plan.candidate, source)
			h.assert_eq(Engine.plain(plan.model).layout, { ergopti_variant = "none", ergopti_base = true, ergopti_alt_gr = false, emulated_layout = "" })
		end)
		h.it("refuses neutral conflict and occupied ownership before consuming any source", function()
			for _, source in ipairs({ '[layout]\nergopti_plus = false\nergopti_variant = "none"\n',
				'[layout]\nergopti_variant = { value = "none" }\n', '[layout]\nergopti_variant = "NONE"\n' }) do
				local plan = Engine.plan_operations(source, { operation })
				h.assert_eq(plan.outcome, "invalid")
				h.assert_nil(plan.candidate)
			end
		end)
	end)
end

return M
