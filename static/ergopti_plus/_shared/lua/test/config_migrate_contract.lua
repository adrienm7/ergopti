--- _shared/lua/test/config_migrate_contract.lua

--- ==============================================================================
--- MODULE: Config Migration Contract
--- DESCRIPTION:
--- The behaviour every Lua driver's boot migration must keep, registered once
--- per driver suite so the macOS runner (Lua 5.4) and the Linux runner
--- (LuaJIT in CI) both prove it: the shared corpus replayed through the engine
--- with the driver's own id, byte preservation of everything no op touches,
--- replay idempotence, and the boot run's backup, publication and refusal
--- outcomes, including the read-only session a newer file starts.
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
					local plan = Engine.plan(input, registry, driver)
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

					local replay = Engine.apply_steps(Engine.model_from_source(plan.candidate), registry,
						driver, spec.from_version)
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

		h.it("rejects a gap, an unknown op, an unknown driver and a misnamed step", function()
			local base = table.concat({
				"[registry]", "current_version = 3", "unstamped_version = 1", "",
				"[steps.v1_to_v2]", "from = 1", "to = 2", "drivers = [\"hs\"]", "reason = \"r\"",
				"ops = [{ op = \"delete\", section = \"a\", key = \"b\" }]", "",
			}, "\n")
			local cases = {
				{ "gap", base },
				{ "unknown op", (base:gsub("\"delete\"", "\"explode\"")) .. "\n[steps.v2_to_v3]\nfrom = 2\nto = 3\ndrivers = [\"hs\"]\nreason = \"r\"\nops = []\n" },
				{ "unknown driver", (base:gsub("%[\"hs\"%]", "[\"amiga\"]", 1)) .. "\n[steps.v2_to_v3]\nfrom = 2\nto = 3\ndrivers = [\"hs\"]\nreason = \"r\"\nops = []\n" },
				{ "misnamed", base .. "\n[steps.second]\nfrom = 2\nto = 3\ndrivers = [\"hs\"]\nreason = \"r\"\nops = []\n" },
				{ "unknown field", (base:gsub("key = \"b\"", "key = \"b\", extra = 1")) .. "\n[steps.v2_to_v3]\nfrom = 2\nto = 3\ndrivers = [\"hs\"]\nreason = \"r\"\nops = []\n" },
			}
			for _, case in ipairs(cases) do
				local registry, err = Engine.validate_registry(TomlCodec.decode(case[2]))
				h.assert_nil(registry, case[1] .. " must be rejected")
				h.assert_true(type(err) == "string" and err ~= "", case[1] .. " must explain the refusal")
			end
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

--- Registers the whole contract for one driver.
--- @param h table Driver test helpers (describe, it, assert_*).
--- @param opts table `{ driver = "hs" | "linux" }`.
function M.register(h, opts)
	if type(opts) ~= "table" or not Engine.DRIVERS[opts.driver] then
		error("config_migrate_contract.register needs a known driver id", 2)
	end
	register_corpus(h, opts.driver)
	register_registry(h, opts.driver)
	register_boot(h, opts.driver)
end

return M
