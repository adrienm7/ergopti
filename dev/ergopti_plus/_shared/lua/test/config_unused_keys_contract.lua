--- _shared/lua/test/config_unused_keys_contract.lua

--- ==============================================================================
--- MODULE: Unused Configuration Keys Contract
--- DESCRIPTION:
--- The behaviour every Lua driver's "Clean up unused settings…" row must keep,
--- registered once per driver suite so the macOS runner (Lua 5.4) and the
--- Linux runner (LuaJIT in CI) both prove it: detection by the driver's own
--- rule, a verified byte-exact backup before any change, a refusal that leaves
--- the file untouched on every failure, byte-preserving removal, and the menu
--- flow's dialogs.
---
--- USAGE (one call per driver suite):
---   require("test.config_unused_keys_contract").register(helpers, {
---       driver   = "macos",
---       collect  = Cleanup.collect,       -- the driver's readers
---       fixture  = "...",                 -- a config.toml for that driver
---       expected = { "metrics.metrics_encrypt=leaf", ... },
---       survivors = { { { "metrics", "enabled" }, true }, ... },
---   })
--- ==============================================================================

local M = {}

local Engine    = require("config_unused_keys")
local TomlCodec = require("toml_codec")

local STAMP = "20990101-000000"
local _sequence = 0





-- ===============================
-- ===============================
-- ======= 1/ File Sandbox =======
-- ===============================
-- ===============================

--- A fresh absolute config path inside the host's scratch directory. The
--- backup lands next to it, so no directory has to be created.
--- @return string
local function new_config_path()
	local base = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
	base = base:gsub("\\", "/"):gsub("/+$", "")
	_sequence = _sequence + 1
	return string.format("%s/ergopti_unused_keys_%d_%d_%d.toml", base, os.time(),
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
--- @param content string|nil Initial config bytes; nil leaves the file absent.
--- @param body function body(path).
local function with_config(content, body)
	local path = new_config_path()
	if content then write_bytes(path, content) end
	local ok, err = pcall(body, path)
	os.remove(path)
	os.remove(path .. ".tmp")
	os.remove(Engine.backup_path(path, STAMP))
	os.remove(Engine.backup_path(path, STAMP) .. ".tmp")
	if not ok then error(err, 0) end
end

--- "section.key=kind" for each key, in file order.
--- @param keys table
--- @return table
local function ids(keys)
	local out = {}
	for _, entry in ipairs(keys) do out[#out + 1] = entry.section .. "." .. entry.key .. "=" .. entry.kind end
	return out
end

--- Reads a decoded value at a segment path.
--- @param decoded table
--- @param path table
--- @return any
local function value_at(decoded, path)
	local node = decoded
	for _, segment in ipairs(path) do
		if type(node) ~= "table" then return nil end
		node = node[segment]
	end
	return node
end

--- A collector that marks exactly the listed paths, for driver-independent
--- engine cases.
--- @param paths table Array of segment arrays.
--- @return function
local function marking(paths)
	local unpack_segments = table.unpack or unpack
	return function(_decoded, mark)
		for _, path in ipairs(paths) do mark(unpack_segments(path)) end
	end
end





-- ========================================
-- ========================================
-- ======= 2/ Driver Rule Scenarios =======
-- ========================================
-- ========================================

--- Registers the scenarios that run the driver's own collector.
--- @param h table Driver test helpers.
--- @param opts table Registration options (see USAGE).
local function register_driver_rule(h, opts)
	local label = "config unused keys (" .. opts.driver .. ")"

	h.describe(label .. ": detection follows the driver's readers", function()
		h.it("lists exactly the keys no reader of this driver consumes", function()
			with_config(opts.fixture, function(path)
				local scan = Engine.find({ path = path, collect = opts.collect })
				h.assert_eq(scan.status, "ok")
				h.assert_eq(ids(scan.keys), opts.expected,
					"only keys the driver's readers never take may be offered")
			end)
		end)

		h.it("a missing config has nothing to clean", function()
			with_config(nil, function(path)
				local scan = Engine.find({ path = path, collect = opts.collect })
				h.assert_eq(scan.status, "ok")
				h.assert_eq(#scan.keys, 0)
			end)
		end)

		h.it("a malformed config is reported, never cleaned", function()
			with_config("[metrics\nenabled = true\n", function(path)
				h.assert_eq(Engine.find({ path = path, collect = opts.collect }).status, "malformed")
			end)
		end)
	end)

	h.describe(label .. ": removal", function()
		h.it("removes exactly the unused keys after a byte-exact backup", function()
			with_config(opts.fixture, function(path)
				local keys = Engine.find({ path = path, collect = opts.collect }).keys
				local result = Engine.remove({ path = path, keys = keys, stamp = STAMP })
				h.assert_eq(result.status, "removed")
				h.assert_eq(result.removed, #opts.expected)
				h.assert_eq(result.backup, Engine.backup_path(path, STAMP))
				local suffix = ".backup-" .. STAMP .. ".toml"
				h.assert_eq(result.backup, path:sub(1, -#".toml" - 1) .. suffix,
					"the backup is <name>.backup-<timestamp>.toml next to the file")
				h.assert_eq(read_bytes(result.backup), opts.fixture,
					"the backup must hold the exact pre-cleanup bytes")

				local after = read_bytes(path)
				local decoded = TomlCodec.decode(after)
				h.assert_true(type(decoded) == "table", "the cleaned file must still parse")
				for _, survivor in ipairs(opts.survivors) do
					h.assert_eq(value_at(decoded, survivor[1]), survivor[2],
						"a used key must keep its value: " .. table.concat(survivor[1], "."))
				end
				h.assert_true(after:find("[stale.section]", 1, true) == nil,
					"an unknown section emptied by the cleanup loses its header")
				h.assert_eq(#Engine.find({ path = path, collect = opts.collect }).keys, 0,
					"a second check finds nothing left to clean")
			end)
		end)

		h.it("never removes a key the user was not shown", function()
			with_config(opts.fixture, function(path)
				local keys = Engine.find({ path = path, collect = opts.collect }).keys
				-- A key written into the unknown section after the scan.
				write_bytes(path, (opts.fixture:gsub("%[stale%.section%]\n",
					"[stale.section]\nlate = 1\n", 1)))
				local result = Engine.remove({ path = path, keys = keys, stamp = STAMP })
				h.assert_eq(result.status, "removed")
				local after = read_bytes(path)
				local decoded = TomlCodec.decode(after)
				h.assert_eq(value_at(decoded, { "stale", "section", "late" }), 1,
					"only keys the user confirmed may be removed")
				h.assert_true(after:find("[stale.section]", 1, true) ~= nil,
					"a section still holding an unlisted key keeps its header")
				h.assert_eq(value_at(decoded, { "stale", "section", "label" }), nil)
			end)
		end)

		h.it("a refused backup aborts before the writer, file byte-identical", function()
			with_config(opts.fixture, function(path)
				local keys = Engine.find({ path = path, collect = opts.collect }).keys
				local published = 0
				local result = Engine.remove({
					path = path, keys = keys, stamp = STAMP,
					create_backup = function() return false, "refused" end,
					publish = function() published = published + 1; return true end,
				})
				h.assert_eq(result.status, "backup_failed")
				h.assert_eq(result.removed, 0)
				h.assert_eq(published, 0, "no change may be published without a backup")
				h.assert_eq(read_bytes(path), opts.fixture)
			end)
		end)

		h.it("an occupied backup path is never overwritten and aborts the cleanup", function()
			with_config(opts.fixture, function(path)
				local keys = Engine.find({ path = path, collect = opts.collect }).keys
				write_bytes(Engine.backup_path(path, STAMP), "occupied")
				local result = Engine.remove({ path = path, keys = keys, stamp = STAMP })
				h.assert_eq(result.status, "backup_failed")
				h.assert_eq(read_bytes(result.backup), "occupied")
				h.assert_eq(read_bytes(path), opts.fixture)
			end)
		end)

		h.it("a backup that does not read back exactly aborts before the writer", function()
			with_config(opts.fixture, function(path)
				local keys = Engine.find({ path = path, collect = opts.collect }).keys
				local published = 0
				local result = Engine.remove({
					path = path, keys = keys, stamp = STAMP,
					create_backup = function(target) write_bytes(target, "torn"); return true end,
					publish = function() published = published + 1; return true end,
				})
				h.assert_eq(result.status, "backup_failed")
				h.assert_eq(published, 0)
				h.assert_eq(read_bytes(path), opts.fixture)
			end)
		end)

		h.it("an unreadable file is refused before any backup", function()
			with_config(opts.fixture, function(path)
				local keys = Engine.find({ path = path, collect = opts.collect }).keys
				local backups = 0
				local result = Engine.remove({
					path = path, keys = keys, stamp = STAMP,
					read = function() return nil, "error", "denied" end,
					create_backup = function() backups = backups + 1; return true end,
				})
				h.assert_eq(result.status, "unreadable")
				h.assert_eq(backups, 0)
				h.assert_eq(read_bytes(path), opts.fixture)
			end)
		end)

		h.it("a refused write keeps the config and the exact backup", function()
			with_config(opts.fixture, function(path)
				local keys = Engine.find({ path = path, collect = opts.collect }).keys
				local result = Engine.remove({
					path = path, keys = keys, stamp = STAMP,
					publish = function() return false, "disk full" end,
				})
				h.assert_eq(result.status, "write_failed")
				h.assert_eq(read_bytes(path), opts.fixture)
				h.assert_eq(read_bytes(result.backup), opts.fixture)
			end)
		end)

		h.it("an edit landing after the backup wins: the stale rewrite is refused", function()
			with_config(opts.fixture, function(path)
				local keys = Engine.find({ path = path, collect = opts.collect }).keys
				local external = opts.fixture .. "\n# edited elsewhere\n"
				local result = Engine.remove({
					path = path, keys = keys, stamp = STAMP,
					create_backup = function(target, content)
						write_bytes(target, content)
						write_bytes(path, external)
						return true
					end,
				})
				h.assert_eq(result.status, "write_failed")
				h.assert_eq(read_bytes(path), external,
					"the cleanup may only replace the bytes it backed up")
			end)
		end)
	end)

	h.describe(label .. ": menu flow", function()
		local function texts(key) return "<" .. key .. ">" end

		h.it("reports a clean file without asking anything", function()
			with_config("[stale.section]\n", function(path)
				local shown, asked = {}, 0
				local completed = Engine.run({
					path = path, collect = opts.collect, get_text = texts,
					confirm = function() asked = asked + 1; return true end,
					inform = function(_, text) shown[#shown + 1] = text end,
					fail = function() error("no failure expected") end,
				})
				h.assert_true(completed)
				h.assert_eq(asked, 0)
				h.assert_eq(shown, { "<dialog.unused_keys.none>" })
			end)
		end)

		h.it("a declined confirmation changes nothing", function()
			with_config(opts.fixture, function(path)
				local prompt
				local completed = Engine.run({
					path = path, collect = opts.collect, get_text = texts, stamp = STAMP,
					confirm = function(title, text) prompt = { title, text }; return false end,
					inform = function() error("nothing to report") end,
					fail = function() error("no failure expected") end,
				})
				h.assert_true(completed)
				h.assert_eq(prompt[1], "<dialog.unused_keys.title>")
				h.assert_eq(read_bytes(path), opts.fixture)
				h.assert_nil(read_bytes(Engine.backup_path(path, STAMP)),
					"a declined cleanup writes no backup")
			end)
		end)

		h.it("no dialog to confirm with means nothing is removed", function()
			with_config(opts.fixture, function(path)
				local completed = Engine.run({
					path = path, collect = opts.collect, get_text = texts, stamp = STAMP,
					confirm = function() return nil end,
					inform = function() error("nothing to report") end,
					fail = function() end,
				})
				h.assert_eq(completed, false)
				h.assert_eq(read_bytes(path), opts.fixture)
			end)
		end)

		h.it("a confirmed cleanup reports the backup it wrote", function()
			with_config(opts.fixture, function(path)
				local shown, removed = {}, nil
				local completed = Engine.run({
					path = path, collect = opts.collect, get_text = texts, stamp = STAMP,
					confirm = function() return true end,
					inform = function(_, text) shown[#shown + 1] = text end,
					fail = function() error("no failure expected") end,
					on_removed = function(result) removed = result end,
				})
				h.assert_true(completed)
				h.assert_eq(shown, { "<dialog.unused_keys.done>" })
				h.assert_eq(removed.previous, opts.fixture)
				h.assert_eq(removed.content, read_bytes(path))
			end)
		end)

		h.it("a failed backup is reported with its reason and the file kept", function()
			with_config(opts.fixture, function(path)
				local failure
				local completed = Engine.run({
					path = path, collect = opts.collect, get_text = texts, stamp = STAMP,
					confirm = function() return true end,
					inform = function() error("nothing succeeded") end,
					fail = function(_, text) failure = text end,
					create_backup = function() return false, "refused" end,
				})
				h.assert_eq(completed, false)
				h.assert_eq(failure, "<dialog.unused_keys.failed>")
				h.assert_eq(read_bytes(path), opts.fixture)
			end)
		end)

		h.it("an unreadable file is reported without asking", function()
			with_config(opts.fixture, function(path)
				local failure, asked = nil, 0
				local completed = Engine.run({
					path = path, collect = opts.collect, get_text = texts,
					read = function() return nil, "error", "denied" end,
					confirm = function() asked = asked + 1 end,
					inform = function() error("nothing to report") end,
					fail = function(_, text) failure = text end,
				})
				h.assert_eq(completed, false)
				h.assert_eq(asked, 0)
				h.assert_eq(failure, "<dialog.unused_keys.failed>")
			end)
		end)
	end)
end





-- ===================================
-- ===================================
-- ======= 3/ Engine Scenarios =======
-- ===================================
-- ===================================

--- Registers driver-independent engine scenarios with synthetic collectors.
--- @param h table Driver test helpers.
--- @param driver string Driver name for the suite labels.
local function register_engine(h, driver)
	local label = "config unused keys engine (" .. driver .. ")"

	h.describe(label .. ": byte-preserving removal", function()
		h.it("keeps CRLF, comments, a BOM and every unlisted byte", function()
			local bom = string.char(0xEF, 0xBB, 0xBF)
			local source = bom .. "[old]\r\nx = 1\r\n# keep me\r\n[kept]\r\ny = 2 # note\r\nz = [\r\n  1,\r\n]\r\n"
			local scan = Engine.find_in_source(source, marking({ { "kept", "y" } }))
			h.assert_eq(ids(scan.keys), { "old.x=section", "kept.z=leaf" })
			local cleaned, removed = Engine.remove_from_source(source, scan.keys)
			h.assert_eq(removed, 2)
			h.assert_eq(cleaned, bom .. "# keep me\r\n[kept]\r\ny = 2 # note\r\n",
				"only the listed records and the emptied unknown header may go")
		end)

		h.it("a header-looking line inside a multiline value is data", function()
			local source = "[a]\nnote = \"\"\"\n[b]\nk = 1\n\"\"\"\n[c]\nk = 2\n"
			local scan = Engine.find_in_source(source, marking({ { "c", "k" } }))
			h.assert_eq(ids(scan.keys), { "a.note=section" })
			h.assert_eq(scan.keys[1].value, "\"\"\" [b] k = 1 \"\"\"")
			h.assert_eq((Engine.remove_from_source(source, scan.keys)), "[c]\nk = 2\n")
		end)

		h.it("a mark on a table consumes every key inside it", function()
			local source = "[hotstrings.groups]\nfoo = true\nbar = false\n"
			local scan = Engine.find_in_source(source, marking({ { "hotstrings", "groups" } }))
			h.assert_eq(#scan.keys, 0)
		end)

		h.it("an inline table holding one consumed field is kept whole", function()
			local source = "[llm]\ntrigger = { shortcut = \"x\", stale = 1 }\n"
			local scan = Engine.find_in_source(source, marking({ { "llm", "trigger", "shortcut" } }))
			h.assert_eq(#scan.keys, 0, "an inline table cannot be cut by halves")
		end)

		h.it("dotted keys are addressed by their full path", function()
			local source = "[llm]\ntrigger.debounce = 1\ntrigger.gone = 2\n"
			local scan = Engine.find_in_source(source, marking({ { "llm", "trigger", "debounce" } }))
			h.assert_eq(ids(scan.keys), { "llm.trigger.gone=leaf" })
			h.assert_eq((Engine.remove_from_source(source, scan.keys)), "[llm]\ntrigger.debounce = 1\n")
		end)

		h.it("a known section left empty keeps its header", function()
			local source = "[metrics]\nstale = 1\n"
			local scan = Engine.find_in_source(source, marking({ { "metrics", "enabled" } }))
			h.assert_eq(ids(scan.keys), { "metrics.stale=leaf" })
			h.assert_eq((Engine.remove_from_source(source, scan.keys)), "[metrics]\n")
		end)
	end)

	h.describe(label .. ": never offered", function()
		h.it("root keys, quoted keys and arrays of tables are left alone", function()
			local source = "root = 1\n[t]\n\"quoted key\" = 1\n[[list]]\nk = 1\n[list.sub]\nj = 2\n"
			local scan = Engine.find_in_source(source, marking({}))
			h.assert_eq(scan.status, "ok")
			h.assert_eq(#scan.keys, 0,
				"only records whose exact removal can be proven by text are offered")
		end)

		h.it("an unterminated value is malformed, not cleanable", function()
			h.assert_eq(Engine.find_in_source("[a]\nx = [\n1,\n", marking({})).status, "malformed")
		end)
	end)

	h.describe(label .. ": dialog text", function()
		h.it("caps the list at DISPLAY_LIMIT and counts the rest", function()
			local keys = {}
			for index = 1, Engine.DISPLAY_LIMIT + 3 do
				keys[index] = { section = "s", key = "k" .. index, value = tostring(index) }
			end
			local lines = {}
			for line in (Engine.describe(keys, function() return "+{1}" end) .. "\n"):gmatch("(.-)\n") do
				lines[#lines + 1] = line
			end
			h.assert_eq(#lines, Engine.DISPLAY_LIMIT + 1)
			h.assert_eq(lines[1], "[s] k1 = 1")
			h.assert_eq(lines[#lines], "+3")
		end)

		h.it("fills placeholders literally, even with a percent sign", function()
			h.assert_eq(Engine.fill("{1} in {2} ({1})", "50%", "a%b"), "50% in a%b (50%)")
		end)

		h.it("names the backup next to the file", function()
			h.assert_eq(Engine.backup_path("/x/y/config.toml", "20260922-041500"),
				"/x/y/config.backup-20260922-041500.toml")
			h.assert_eq(Engine.backup_path("C:\\cfg\\config.toml", "1"), "C:\\cfg\\config.backup-1.toml")
		end)
	end)
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- The file sandbox, for a driver suite's own scenarios.
M.sandbox = {
	STAMP = STAMP,
	with_config = with_config,
	read_bytes = read_bytes,
	write_bytes = write_bytes,
}

--- Registers the whole contract in the calling driver suite.
--- @param h table Driver test helpers (describe, it, assert_*).
--- @param opts table `{ driver, collect, fixture, expected, survivors }`.
function M.register(h, opts)
	for _, field in ipairs({ "driver", "collect", "fixture", "expected", "survivors" }) do
		if opts[field] == nil then error("config_unused_keys_contract: missing '" .. field .. "'", 2) end
	end
	-- Every case name carries one prefix so `--only "unused keys"` re-runs the
	-- whole contract in either suite.
	local prefixed = setmetatable({
		it = function(name, fn) return h.it("unused keys: " .. name, fn) end,
	}, { __index = h })
	register_engine(prefixed, opts.driver)
	register_driver_rule(prefixed, opts)
end

return M
