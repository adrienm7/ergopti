--- modules/keystats/metrics_ledger.lua

--- ==============================================================================
--- MODULE: Per-Device Metrics Ledger (Linux)
--- DESCRIPTION:
--- Publishes this device's raw metrics events as the append-only SQL ledger
--- macOS and Windows write and import: <config>/metrics/by_device/<id>/ holds
--- device.json and data.sql, in the canonical format of keystats_spec.md §15.5.
--- A Mac or a PC that syncs the metrics folder replays it like any other
--- device's ledger and rebuilds its aggregates from the raw rows.
---
--- FEATURES & RATIONALE:
--- 1. The SQLite store stays the authority. Linux keeps metrics.sqlite in the
---    XDG data folder, which no OS purges, so the ledger is a projection of its
---    committed local rows rather than a second journal: every row with an id
---    above the exported cursor is rendered and appended. One exporter covers
---    the history recorded before the ledger existed and every later flush.
--- 2. Ids order the export. Every raw family takes its id from one reservation
---    counter and a single flush owner commits them in order, so "id above the
---    cursor" never skips a committed row.
--- 3. A divergence rebuilds instead of guessing. When data.sql is missing or
---    its size is not the one recorded with the cursor (a crash between the
---    append and the cursor commit, a sync tool restoring an older copy, a hand
---    edit), the whole file is regenerated beside it and renamed over it. The
---    importers on macOS and Windows verify a prefix digest, so a replaced
---    generation is replayed rather than misread. The at-rest text migration
---    rewrites stored rows, so it requests the same rebuild when it finishes.
--- 4. Canonical framing. One INSERT OR IGNORE per line, device_id and id first,
---    each batch under an « ingest batch » header inside BEGIN/COMMIT, and a
---    « day rollover » marker between batches when the exported date advances:
---    the exact shapes the macOS scanner and the Windows frame index admit.
--- 5. Identity as on the other drivers: the folder whose device.json carries
---    this host's signature (/etc/machine-id) is this device; an unreadable
---    identity refuses the ledger rather than minting a second one. A store
---    recorded before the ledger keeps its "linux-<hostname>" id, so its history
---    stays one device; a new store gets a UUID v4 as on macOS and Windows.
--- ==============================================================================

local M = {}

local Json = require("json")
local Queries = require("keystats.queries")
local SqliteCommand = require("modules.keystats.sqlite_command")

local LOG = "keystats.metrics_ledger"





-- ===============================
-- ===============================
-- ======= 1/ Constants ==========
-- ===============================
-- ===============================

--- Ledger format version, as written by macOS and Windows.
M.SCHEMA_VERSION = 1

--- Rows rendered per export query. One query is one sqlite3 spawn; at a few
--- kilobytes per typing row a batch stays well under a megabyte of SQL text.
M.ROWS_PER_STEP = 500

--- The raw event statements of the shared catalogue, which are the ledger's
--- vocabulary: every driver's cache accepts exactly these tables and columns.
M.RAW_STATEMENTS = {
	"events.typing", "events.app_switch", "events.window_switch", "events.shortcut",
	"events.system", "events.hotstring", "events.session", "events.llm", "events.network",
}

--- Meta keys holding the export state, committed together.
M.META = {
	device = "linux_ledger_device",
	cursor = "linux_ledger_cursor",
	date = "linux_ledger_date",
	size = "linux_ledger_size",
}

local LEGACY_PREFIX = "linux-"
local DATE_PATTERN = "^%d%d%d%d%-%d%d%-%d%d$"
local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"





-- ===============================
-- ===============================
-- ======= 2/ Pure Helpers =======
-- ===============================
-- ===============================

--- Formats 16 random bytes as a version-4 UUID.
--- @param bytes string Exactly 16 bytes.
--- @return string uuid
function M.format_uuid(bytes)
	assert(type(bytes) == "string" and #bytes == 16, "a UUID needs 16 random bytes")
	local b = { bytes:byte(1, 16) }
	b[7] = (b[7] % 16) + 64
	b[9] = (b[9] % 64) + 128
	return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16])
end

--- Whether a name can be a device folder and a device id.
--- @param id any Candidate.
--- @return boolean
function M.is_device_id(id)
	return type(id) == "string" and (id:match(UUID_PATTERN) ~= nil
		or (id:sub(1, #LEGACY_PREFIX) == LEGACY_PREFIX and #id > #LEGACY_PREFIX and #id <= 255
			and not id:find("[^%w%.%-_]")))
end

--- The first lines of a new ledger, byte for byte the macOS header.
--- @param device_id string Device id.
--- @return string header
function M.header(device_id)
	return string.format("-- ergopti metrics — device %s — schema_version %d\n"
		.. "-- This file is APPEND-ONLY. Do not edit by hand.\n"
		.. "-- The keystats replays its content into db.sqlite at startup.\n"
		.. "PRAGMA foreign_keys = OFF;\n", device_id, M.SCHEMA_VERSION)
end

--- The metrics folder's Git exclusion, as macOS writes it.
M.GITIGNORE = "# Local hot-path log — never commit, never sync. One writer per device.\ntoday.log\n"

--- One SQL value as a literal: quote() stops at a NUL, so a text holding one
--- travels as its exact bytes.
--- @param column string Column name.
--- @return string expression
local function literal_expression(column)
	return string.format("CASE WHEN typeof(%s)='text' AND instr(%s,char(0))>0 THEN 'CAST(X''' || hex(%s) || ''' AS TEXT)' ELSE quote(%s) END",
		column, column, column, column)
end

--- The table a raw catalogue statement inserts into.
--- @param name string Catalogue name such as "events.typing".
--- @return string table_name
local function table_of(name)
	return (name:gsub("^events%.", "events_"))
end

--- Builds the query that renders this device's next rows as ledger statements.
--- Each output line is "<id> <hex date> <hex statement>": the statement can
--- hold a newline inside a literal, which no line framing could carry.
--- @param device_id string Local device id.
--- @param cursor integer Last exported id.
--- @param limit integer Maximum rows.
--- @return string sql
function M.export_query(device_id, cursor, limit)
	assert(M.is_device_id(device_id), "invalid ledger device id")
	assert(type(cursor) == "number" and cursor >= 0 and cursor % 1 == 0, "invalid ledger cursor")
	assert(type(limit) == "number" and limit >= 1 and limit % 1 == 0, "invalid ledger limit")
	local device = "'" .. SqliteCommand.escape_literal(device_id) .. "'"
	local parts = {}
	for _, name in ipairs(M.RAW_STATEMENTS) do
		local columns = Queries.params(name)
		assert(columns[1] == "device_id" and columns[2] == "id", "a ledger statement starts with device_id, id")
		local values = {}
		for index, column in ipairs(columns) do values[index] = literal_expression(column) end
		parts[#parts + 1] = string.format(
			"SELECT id, date, 'INSERT OR IGNORE INTO %s (%s) VALUES (' || %s || ');' AS stmt FROM %s WHERE device_id=%s AND id>%.0f",
			table_of(name), table.concat(columns, ", "), table.concat(values, " || ', ' || "),
			table_of(name), device, cursor)
	end
	return "SELECT id || ' ' || hex(coalesce(date,'')) || ' ' || hex(stmt) FROM ("
		.. table.concat(parts, " UNION ALL ") .. string.format(") ORDER BY id LIMIT %d;", limit)
end

local function unhex(text)
	if #text % 2 ~= 0 or text:find("[^%x]") then return nil end
	return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

--- Decodes the export query's output lines.
--- @param lines table Output lines.
--- @return table|nil rows Array of { id, date, sql }; nil when a line is malformed.
function M.decode_rows(lines)
	local rows = {}
	for _, line in ipairs(lines) do
		local id, date_hex, sql_hex = line:match("^(%d+) (%x*) (%x+)$")
		local date, sql = date_hex and unhex(date_hex), sql_hex and unhex(sql_hex)
		if not id or not date or not sql or sql:find("%z") then return nil end
		rows[#rows + 1] = { id = tonumber(id), date = date, sql = sql }
	end
	return rows
end

--- Frames exported rows as ledger text: one batch per run of rows, a rollover
--- marker between batches whenever the date moves forward.
--- @param rows table Decoded rows in id order.
--- @param state table { cursor, date } Export position before these rows.
--- @param now_ts string Batch header timestamp.
--- @return string text
--- @return integer cursor Last id framed.
--- @return string date Last exported date.
function M.frame(rows, state, now_ts)
	local out, batch = {}, {}
	local cursor, date = state.cursor, state.date
	local batch_from = cursor
	local function close()
		if #batch == 0 then return end
		out[#out + 1] = string.format("\n-- === ingest batch %s (offset %.0f -> %.0f, %d entry(ies)) ===\nBEGIN TRANSACTION;\n%s\nCOMMIT;\n",
			now_ts, batch_from, cursor, #batch, table.concat(batch, "\n"))
		batch, batch_from = {}, cursor
	end
	for _, row in ipairs(rows) do
		assert(row.id > cursor, "ledger rows must follow the cursor in id order")
		local row_date = row.date:match(DATE_PATTERN) and row.date or nil
		if row_date and (date == "" or row_date > date) then
			if date ~= "" then
				close()
				out[#out + 1] = string.format("\n-- === day rollover %s -> %s ===\n", date, row_date)
			end
			date = row_date
		end
		batch[#batch + 1] = row.sql
		cursor = row.id
	end
	close()
	return table.concat(out), cursor, date
end





-- ===================================
-- ===================================
-- ======= 3/ Device Identity ========
-- ===================================
-- ===================================

--- Resolves this device's identity under the metrics folder.
--- @param opts table {
---   metrics_dir string, host_signature string, hostname string, os_version string,
---   legacy_registered fun(id:string):boolean|nil, random_bytes fun(n):string|nil,
---   now_ts string, list fun(path):table|nil,string, read fun(path):string|nil,string }
--- @return table|nil identity { device_id, name, os, os_version, host_signature, created_at, schema_version }
--- @return boolean|string created_or_reason True when this identity is new; the refusal otherwise.
function M.resolve_identity(opts)
	if type(opts.host_signature) ~= "string" or opts.host_signature == "" then
		return nil, "the host signature (/etc/machine-id) is unreadable"
	end
	local by_root = opts.metrics_dir .. "/by_device"
	local entries, list_error = opts.list(by_root)
	if entries == nil then return nil, "cannot list " .. by_root .. ": " .. tostring(list_error) end
	local names = {}
	for _, entry in ipairs(entries) do
		if entry.kind == "directory" then
			names[entry.name] = true
			local raw, status = opts.read(by_root .. "/" .. entry.name .. "/device.json")
			if status ~= "absent" then
				if status ~= "ok" then return nil, "a device identity is unreadable: " .. entry.name end
				local ok, obj = pcall(Json.decode, raw)
				if not ok or type(obj) ~= "table" or type(obj.device_id) ~= "string" or obj.device_id == ""
					or type(obj.host_signature) ~= "string" or obj.host_signature == "" then
					return nil, "a device identity is malformed: " .. entry.name
				end
				if obj.host_signature == opts.host_signature then
					if obj.device_id ~= entry.name or not M.is_device_id(obj.device_id) then
						return nil, "this host's device identity does not match its folder: " .. entry.name
					end
					return obj, false
				end
			end
		end
	end
	local legacy = LEGACY_PREFIX .. opts.hostname
	local device_id
	if M.is_device_id(legacy) and not names[legacy] and opts.legacy_registered(legacy) == true then
		device_id = legacy
	else
		local bytes = opts.random_bytes(16)
		if type(bytes) ~= "string" or #bytes ~= 16 then return nil, "no random bytes for a device id" end
		device_id = M.format_uuid(bytes)
	end
	return {
		device_id = device_id, name = opts.hostname, os = "linux", os_version = opts.os_version or "",
		host_signature = opts.host_signature, created_at = opts.now_ts, schema_version = M.SCHEMA_VERSION,
	}, true
end





-- ===================================
-- ===================================
-- ======= 4/ Ledger Exporter ========
-- ===================================
-- ===================================

--- Creates the exporter of one identified device.
--- @param opts table {
---   metrics_dir string, identity table, store { query_rows, get_meta, exec_sql },
---   fs { read_with_status, write, write_new, append, mkdir, size, rename },
---   now_ts fun():string, logger table }
--- @return table ledger
function M.new(opts)
	assert(type(opts) == "table" and type(opts.identity) == "table", "the ledger needs an identity")
	local identity = opts.identity
	assert(M.is_device_id(identity.device_id), "the ledger needs a safe device id")
	local store, fs, logger = opts.store, opts.fs, opts.logger
	local folder = opts.metrics_dir .. "/by_device/" .. identity.device_id
	local self = {
		path = folder .. "/data.sql",
		rebuild_path = folder .. "/data.sql.rebuild",
		device_json_path = folder .. "/device.json",
		device_id = identity.device_id,
	}
	-- rebuilding: nil (appending) or { cursor, date, size } of the file being regenerated.
	local state, rebuilding, prepared, failed = nil, nil, false, nil

	local function persist(cursor, date, size)
		local statements = { "BEGIN IMMEDIATE;" }
		for key, value in pairs({ device = self.device_id, cursor = string.format("%.0f", cursor), date = date,
			size = string.format("%.0f", size) }) do
			statements[#statements + 1] = Queries.render("meta.set", "cli_json", { key = M.META[key], value = value })
		end
		statements[#statements + 1] = "COMMIT;"
		return store.exec_sql(table.concat(statements, "\n")) == true
	end

	local function start_rebuild(reason)
		logger.info(LOG, "Regenerating the metrics ledger of this device (%s).", reason)
		if not fs.write(self.rebuild_path, M.header(self.device_id)) then
			return false, "cannot start the ledger regeneration"
		end
		rebuilding = { cursor = 0, date = "", size = #M.header(self.device_id) }
		return true
	end

	--- Creates the folder, the identity and the Git exclusion, then decides
	--- whether data.sql can be extended or must be regenerated.
	--- @return boolean ok
	--- @return string|nil reason
	function self:prepare()
		if not fs.mkdir(folder) then return false, "cannot create " .. folder end
		local _, gitignore_status = fs.read_with_status(opts.metrics_dir .. "/.gitignore")
		if gitignore_status == "absent" and not fs.write_new(opts.metrics_dir .. "/.gitignore", M.GITIGNORE) then
			logger.warn(LOG, "The metrics folder's Git exclusion could not be written.")
		end
		local _, json_status = fs.read_with_status(self.device_json_path)
		if json_status == "absent" then
			local encoded = Json.encode(identity)
			if not fs.write_new(self.device_json_path, encoded .. "\n") then
				return false, "cannot publish device.json"
			end
		elseif json_status ~= "ok" then
			return false, "device.json is unreadable"
		end
		local recorded = {}
		for key, meta_key in pairs(M.META) do recorded[key] = store.get_meta(meta_key) end
		local size = fs.size(self.path)
		local cursor, recorded_size = tonumber(recorded.cursor), tonumber(recorded.size)
		prepared = true
		if recorded.device == self.device_id and cursor and recorded_size and size == recorded_size
			and type(recorded.date) == "string" then
			state = { cursor = cursor, date = recorded.date, size = size }
			return true
		end
		local ok, reason = start_rebuild(size == nil and "no ledger yet" or "its recorded size does not match")
		if not ok then prepared = false end
		return ok, reason
	end

	--- Discards the current file at the next step and regenerates it from the store.
	function self:request_rebuild()
		if prepared then
			local ok, reason = start_rebuild("stored rows were rewritten")
			if not ok then failed = reason end
		end
	end

	--- Exports the next bounded slice of rows.
	--- @return string status "idle", "more" or "failed".
	--- @return string|nil reason
	function self:step()
		if failed then return "failed", failed end
		if not prepared then return "failed", "the ledger was not prepared" end
		local position = rebuilding or state
		local lines = store.query_rows(M.export_query(self.device_id, position.cursor, M.ROWS_PER_STEP))
		if lines == nil then return "failed", "the export query was refused" end
		local rows = M.decode_rows(lines)
		if rows == nil then
			failed = "the export query returned a malformed row"
			return "failed", failed
		end
		if #rows > 0 then
			local text, cursor, date = M.frame(rows, position, opts.now_ts())
			local target = rebuilding and self.rebuild_path or self.path
			if fs.size(target) ~= position.size then
				if rebuilding then
					failed = "the ledger regeneration file changed under the exporter"
					return "failed", failed
				end
				local ok, reason = start_rebuild("data.sql changed outside the exporter")
				if not ok then failed = reason; return "failed", reason end
				return "more"
			end
			if not fs.append(target, text) then return "failed", "cannot append to " .. target end
			local size = position.size + #text
			if fs.size(target) ~= size then
				failed = "the ledger append was not completely written"
				return "failed", failed
			end
			if rebuilding then
				rebuilding = { cursor = cursor, date = date, size = size }
			elseif not persist(cursor, date, size) then
				-- The bytes are in data.sql but the cursor is not: the next prepare
				-- sees the size mismatch and regenerates.
				failed = "the ledger cursor could not be committed"
				return "failed", failed
			else
				state = { cursor = cursor, date = date, size = size }
			end
			if #rows >= M.ROWS_PER_STEP then return "more" end
		end
		if rebuilding then
			local done = rebuilding
			if not fs.rename(self.rebuild_path, self.path) then
				failed = "cannot publish the regenerated ledger"
				return "failed", failed
			end
			rebuilding = nil
			if not persist(done.cursor, done.date, done.size) then
				failed = "the ledger cursor could not be committed"
				return "failed", failed
			end
			state = done
			logger.info(LOG, "Metrics ledger regenerated (%d byte(s)).", done.size)
		end
		return "idle"
	end

	--- Diagnostic snapshot.
	function self:status()
		return {
			path = self.path, device_id = self.device_id, failed = failed,
			rebuilding = rebuilding ~= nil, cursor = (rebuilding or state or {}).cursor,
		}
	end

	return self
end





-- ===================================
-- ===================================
-- ======= 5/ Native Ports ===========
-- ===================================
-- ===================================

--- The file ports the daemon gives the exporter and the identity resolver.
--- @return table ports { read_with_status, write, write_new, append, mkdir, size, rename, list, read }
function M.native_ports()
	local FileSystem = require("adapters.file_system")
	local NativeDirectory = require("infra.native_directory")
	local uv = require("luv")
	local shell_quote = require("text_utils").shell_quote
	local ports = { write = FileSystem.write, write_new = FileSystem.write_new, append = FileSystem.append }
	local function lstat(path)
		local called, stat, _, code = pcall(uv.fs_lstat, path)
		if not called then return nil, "error" end
		if type(stat) ~= "table" then return nil, code == "ENOENT" and "absent" or "error" end
		return stat
	end
	--- Exact bytes of a regular file, telling absence from a failed read.
	function ports.read_with_status(path)
		local stat, status = lstat(path)
		if not stat then return nil, status end
		if stat.type ~= "file" then return nil, "error" end
		local handle = io.open(path, "rb")
		if not handle then return nil, "error" end
		local content = handle:read("*a")
		handle:close()
		if type(content) ~= "string" then return nil, "error" end
		return content, "ok"
	end
	function ports.mkdir(path)
		local status = os.execute("mkdir -p " .. shell_quote(path) .. " 2>/dev/null")
		return (status == true or status == 0) and NativeDirectory.kind(path) == "directory"
	end
	function ports.size(path)
		local stat = lstat(path)
		return stat and stat.type == "file" and tonumber(stat.size) or nil
	end
	function ports.rename(source, destination)
		local called, renamed = pcall(os.rename, source, destination)
		return called and renamed == true
	end
	function ports.list(path)
		local entries, message, code = NativeDirectory.entries(path)
		if entries == nil and code == "ENOENT" then return {} end
		return entries, message
	end
	ports.read = ports.read_with_status
	return ports
end

return M
