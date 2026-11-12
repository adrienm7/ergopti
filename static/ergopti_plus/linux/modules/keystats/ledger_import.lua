--- modules/keystats/ledger_import.lua

--- ==============================================================================
--- MODULE: Foreign Metrics Ledger Import (Linux)
--- DESCRIPTION:
--- Imports the other devices' append-only ledgers
--- (<config>/metrics/by_device/<id>/data.sql, keystats_spec.md §15.5) into
--- metrics.sqlite and rebuilds their aggregates, so a Linux device shows the
--- metrics of the Macs and PCs that sync the same metrics folder, as macOS
--- (export.lua sync_foreign_data_sql) and Windows (ledger catalogue) do.
---
--- FEATURES & RATIONALE:
--- 1. A foreign data.sql runs in the local store, so its text is never
---    executed. Each statement is parsed: only comments, the framing
---    (BEGIN TRANSACTION, COMMIT, PRAGMA foreign_keys = OFF) and
---    `INSERT OR IGNORE INTO events_* (columns) VALUES (literals);` are
---    admitted, every column must be one of the shared schema's for that
---    table, every value a literal (string, number, NULL, blob, or the
---    CAST(X'..' AS TEXT) a NUL-carrying text exports as) and the device_id the
---    folder's own. No subquery, ATTACH or function call can pass, and the
---    admitted rows are re-rendered from their parsed literals.
--- 2. The macOS watermark contract: devices.imported_data_sql_size is the byte
---    offset already applied, always a batch boundary, and
---    imported_data_sql_sha256 the SHA-256 of exactly that prefix. A prefix
---    whose digest no longer matches (a replaced generation, a truncation, a
---    legacy row without a digest) is replayed from byte 0; INSERT OR IGNORE
---    makes the replay idempotent.
--- 3. Raw and derived land together. The raw slice, its watermark and a pending
---    mark commit in one transaction; once the device is caught up, the
---    derived rebuild (ledger_rebuild) and the mark's removal commit in a
---    second one. A crash between the two leaves the mark, so the rebuild runs
---    at the next catch-up: a dashboard never shows raw rows without their
---    aggregates for longer than one catch-up.
--- 4. Bounded work per tick. The daemon's loop also reads the keyboard, so a
---    step hashes and admits at most a few hundred kilobytes; the digest stream
---    of a verified prefix is kept while the file's identity (inode, size,
---    modification time) is unchanged, so a large first import hashes each
---    byte once. A changed file is re-verified from byte 0, as macOS does.
--- ==============================================================================

local M = {}

local Json = require("core.text.engine.json")
local Queries = require("metrics.engine.queries")
local SqliteCommand = require("modules.keystats.sqlite_command")
local MetricsLedger = require("modules.keystats.metrics_ledger")

local LOG = "keystats.ledger_import"





-- ===============================
-- ===============================
-- ======= 1/ Constants ==========
-- ===============================
-- ===============================

--- Bytes hashed per step while a prefix is being verified.
M.VERIFY_BYTES_PER_STEP = 512 * 1024

--- Bytes of new ledger text read per step; a batch larger than this is read
--- whole, since a step that applies nothing makes no progress.
M.IMPORT_BYTES_PER_STEP = 256 * 1024

--- Meta key marking a device whose raw rows are ahead of its aggregates.
M.PENDING_PREFIX = "linux_ledger_import_pending:"

local DIGEST_PATTERN = "^" .. string.rep("%x", 64) .. "$"

--- The OS names the shared devices table admits.
local KNOWN_OS = { darwin = true, windows = true, linux = true }





-- ===============================
-- ===============================
-- ======= 2/ Pure Helpers =======
-- ===============================
-- ===============================

--- Whether a folder name can be another device's id: one path component of
--- the characters every driver mints its ids from.
--- @param name any Candidate.
--- @return boolean
function M.is_foreign_device_id(name)
	return type(name) == "string" and #name >= 1 and #name <= 255 and name ~= "." and name ~= ".."
		and not name:find("[^%w%.%-_]")
end

--- The columns of every raw events_* table of the shared schema.
--- @param schema string Text of _shared/metrics/data/db/schema.sql.
--- @return table columns { [table] = { [column] = true } }
function M.raw_columns(schema)
	local out = {}
	for name, body in schema:gmatch("CREATE TABLE IF NOT EXISTS (events_[%w_]+) %((.-)\n%);") do
		local columns = {}
		for line in (body .. "\n"):gmatch("([^\n]*)\n") do
			local column = line:match("^%s*([%a_][%w_]*)%s+%u")
			if column and column ~= "PRIMARY" and column ~= "UNIQUE" and column ~= "CHECK" and column ~= "FOREIGN" then
				columns[column] = true
			end
		end
		assert(columns.device_id and columns.id, "a raw table without device_id and id: " .. name)
		out[name] = columns
	end
	assert(next(out) ~= nil, "the shared schema names no raw table")
	return out
end

--- The offset just past the last "COMMIT;\n" that sits outside a string
--- literal and a comment: the export.lua _last_complete_batch_offset rule.
--- @param chunk string Bytes starting at a batch boundary.
--- @return integer offset 0 when no batch is complete.
function M.last_complete_batch(chunk)
	local find, sub = string.find, string.sub
	local last_commit, i = 0, 1
	while true do
		local at = find(chunk, "[-'\n]", i)
		if not at then return last_commit end
		local ch = sub(chunk, at, at)
		if ch == "-" then
			if sub(chunk, at + 1, at + 1) == "-" then
				local ending = find(chunk, "\n", at + 2, true)
				if not ending then return last_commit end
				i = ending + 1
			else
				i = at + 1
			end
		elseif ch == "'" then
			local close = at
			repeat
				close = find(chunk, "'", close + 1, true)
				if not close then return last_commit end
				local doubled = sub(chunk, close + 1, close + 1) == "'"
				if doubled then close = close + 1 end
			until not doubled
			i = close + 1
		elseif sub(chunk, at + 1, at + 8) == "COMMIT;\n" then
			last_commit, i = at + 8, at + 9
		else
			i = at + 1
		end
	end
end

--- Reads one single-quoted SQL string at `pos`, doubled quotes included.
--- @return string|nil quoted Its exact text, quotes included.
--- @return integer|nil next Position after it.
local function read_quoted(chunk, pos)
	local close = pos
	repeat
		close = chunk:find("'", close + 1, true)
		if not close then return nil end
		local doubled = chunk:sub(close + 1, close + 1) == "'"
		if doubled then close = close + 1 end
	until not doubled
	return chunk:sub(pos, close), close + 1
end

--- Reads one SQL literal at `pos`.
--- @return string|nil literal Its exact text.
--- @return integer|nil next Position after it.
local function read_literal(chunk, pos)
	local first = chunk:sub(pos, pos)
	if first == "'" then
		local quoted, after = read_quoted(chunk, pos)
		if not quoted then return nil end
		-- Every driver writes a CR or a NUL as a char() concatenation
		-- (core/fs/engine/sqlite/literal.lua, Windows SQLite_Q): only that form joins literals,
		-- re-rendered as the exact bytes it stores.
		if chunk:sub(after, after + 1) ~= "||" then return quoted, after end
		local parts = { (quoted:sub(2, -2):gsub("''", "'")) }
		while chunk:sub(after, after + 1) == "||" do
			local code = chunk:match("^||char%((%d+)%)", after)
			if code == "0" or code == "13" then
				parts[#parts + 1] = string.char(tonumber(code))
				after = after + #"||char()" + #code
			elseif chunk:sub(after + 2, after + 2) == "'" then
				local next_quoted, next_after = read_quoted(chunk, after + 2)
				if not next_quoted then return nil end
				parts[#parts + 1] = (next_quoted:sub(2, -2):gsub("''", "'"))
				after = next_after
			else
				return nil
			end
		end
		local bytes = table.concat(parts)
		return "CAST(X'" .. (bytes:gsub(".", function(c) return string.format("%02X", c:byte()) end)) .. "' AS TEXT)", after
	end
	for _, pattern in ipairs({
		"^NULL", "^[xX]'%x*'", "^CAST%(X'%x*' AS TEXT%)",
		"^%-?%d+%.%d+[eE][%+%-]?%d+", "^%-?%d+[eE][%+%-]?%d+", "^%-?%d+%.%d+", "^%-?%d+",
	}) do
		local literal = chunk:match(pattern, pos)
		if literal then
			local hex = literal:match("'(%x*)'")
			if hex and #hex % 2 ~= 0 then return nil end
			return literal, pos + #literal
		end
	end
	return nil
end

--- Admits a run of complete ledger batches.
--- @param chunk string Ledger text ending at a batch boundary.
--- @param device_id string The folder's device id.
--- @param columns table M.raw_columns() of the shared schema.
--- @return table|nil statements Re-rendered INSERT statements.
--- @return string|nil reason Why the text was refused, with its byte.
function M.admit(chunk, device_id, columns)
	local own = "'" .. SqliteCommand.escape_literal(device_id) .. "'"
	local statements, pos, n = {}, 1, #chunk
	local function refuse(why) return nil, string.format("%s at byte %d", why, pos - 1) end
	while true do
		pos = chunk:find("[^ \t\r\n]", pos) or (n + 1)
		if pos > n then break end
		if chunk:sub(pos, pos + 1) == "--" then
			local ending = chunk:find("\n", pos, true)
			if not ending then return refuse("unterminated comment") end
			pos = ending + 1
		else
			local framing = chunk:match("^BEGIN TRANSACTION;", pos) or chunk:match("^COMMIT;", pos)
				or chunk:match("^PRAGMA foreign_keys = OFF;", pos)
			if framing then
				pos = pos + #framing
			else
				local table_name, list, after = chunk:match("^INSERT OR IGNORE INTO (events_[%w_]+) %(([%w_, ]+)%) VALUES %(()", pos)
				if not table_name then return refuse("statement outside the ledger grammar") end
				local allowed = columns[table_name]
				if not allowed then return refuse("unknown raw table " .. table_name) end
				local names, seen = {}, {}
				for name in (list .. ","):gmatch("%s*([^,]-)%s*,") do
					if not allowed[name] or seen[name] then return refuse("column refused: " .. name) end
					seen[name] = true
					names[#names + 1] = name
				end
				if names[1] ~= "device_id" or names[2] ~= "id" then return refuse("a row must start with device_id, id") end
				local values = {}
				pos = after
				while true do
					local literal, next_pos = read_literal(chunk, pos)
					if not literal then return refuse("value is not a literal") end
					values[#values + 1] = literal
					local comma = chunk:match("^%s*,%s*", next_pos)
					if comma then
						pos = next_pos + #comma
					else
						local close = chunk:match("^%s*%);", next_pos)
						if not close then return refuse("value is not followed by a separator") end
						pos = next_pos + #close
						break
					end
				end
				if #values ~= #names then return refuse("column and value counts differ") end
				if values[1] ~= own then return refuse("a row of another device") end
				if not values[2]:match("^%d+$") then return refuse("an event id is not an integer") end
				statements[#statements + 1] = string.format("INSERT OR IGNORE INTO %s (%s) VALUES (%s);",
					table_name, table.concat(names, ", "), table.concat(values, ", "))
			end
		end
	end
	return statements
end





-- ===================================
-- ===================================
-- ======= 3/ Importer ===============
-- ===================================
-- ===================================

--- Creates the importer of the foreign ledgers under one metrics folder.
--- @param opts table {
---   metrics_dir string, local_device_id string, schema string,
---   store { query_rows, exec_sql },
---   fs { list(path), read(path) -> content, status, stat(path) -> { size, ino, mtime }|nil,
---        read_range(path, offset, length) -> string|nil },
---   digest_stream fun():table|nil, rebuild fun(device_id):string|nil,string|nil,
---   now_ts fun():string, logger table }
--- @return table importer
function M.new(opts)
	assert(type(opts) == "table" and type(opts.metrics_dir) == "string", "the importer needs a metrics folder")
	local store, fs, logger = opts.store, opts.fs, opts.logger
	local columns = M.raw_columns(opts.schema)
	local by_root = opts.metrics_dir .. "/by_device"
	local self = {}
	-- Per device: the verified prefix { identity, offset, stream } and the
	-- verification in progress { identity, offset, stream, target, digest }.
	local verified, verifying, refused = {}, {}, {}

	local function identity_of(stat)
		return string.format("%s:%s:%s", tostring(stat.ino), tostring(stat.size), tostring(stat.mtime))
	end

	local function warn_once(device_id, reason)
		if refused[device_id] ~= reason then
			refused[device_id] = reason
			logger.warn(LOG, "Foreign ledger %s not imported: %s.", device_id, reason)
		end
	end

	--- The committed watermark of a device: offset, digest, whether a row exists.
	local function watermark(device_id)
		local lines = store.query_rows(string.format(
			"SELECT imported_data_sql_size || ' ' || hex(coalesce(imported_data_sql_sha256,'')) FROM devices WHERE device_id='%s';",
			SqliteCommand.escape_literal(device_id)))
		if lines == nil then return nil end
		if #lines == 0 then return 0, nil, false end
		local size, hex = lines[1]:match("^(%d+) (%x*)$")
		if not size then return nil end
		local digest = (hex:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
		return tonumber(size), digest ~= "" and digest or nil, true
	end

	local function pending(device_id)
		local lines = store.query_rows(Queries.render("meta.get", "cli_json", { key = M.PENDING_PREFIX .. device_id }))
		return lines ~= nil and #lines > 0, lines ~= nil
	end

	--- Proves the committed prefix, a bounded slice per call.
	--- @return string state "proved", "more", "replay" (from byte 0) or "failed".
	local function prove(device_id, path, stat, offset, digest)
		local identity = identity_of(stat)
		local known = verified[device_id]
		if known and known.identity == identity and known.offset == offset then return "proved" end
		if offset == 0 then
			local stream = opts.digest_stream()
			if not stream then return "failed" end
			verified[device_id] = { identity = identity, offset = 0, stream = stream }
			return "proved"
		end
		if offset > stat.size or type(digest) ~= "string" or not digest:match(DIGEST_PATTERN) then return "replay" end
		local job = verifying[device_id]
		if not job or job.identity ~= identity or job.target ~= offset or job.digest ~= digest then
			local stream = opts.digest_stream()
			if not stream then return "failed" end
			job = { identity = identity, target = offset, digest = digest, offset = 0, stream = stream }
			verifying[device_id] = job
		end
		local length = math.min(M.VERIFY_BYTES_PER_STEP, job.target - job.offset)
		local bytes = fs.read_range(path, job.offset, length)
		if type(bytes) ~= "string" or #bytes ~= length or not job.stream.update(bytes) then
			verifying[device_id] = nil
			return "failed"
		end
		job.offset = job.offset + length
		if job.offset < job.target then return "more" end
		verifying[device_id] = nil
		if job.stream.digest() ~= digest:lower() then return "replay" end
		verified[device_id] = { identity = identity, offset = offset, stream = job.stream }
		return "proved"
	end

	--- Registers the device and applies one slice of its ledger.
	--- @return string state "idle", "more" or "failed".
	local function import_slice(device_id, path, stat, offset, descriptor)
		local known = verified[device_id]
		if offset >= stat.size then return "idle" end
		local length = math.min(M.IMPORT_BYTES_PER_STEP, stat.size - offset)
		local chunk, boundary = "", 0
		while true do
			local bytes = fs.read_range(path, offset + #chunk, length)
			if type(bytes) ~= "string" or #bytes ~= length then return "failed" end
			chunk = chunk .. bytes
			boundary = M.last_complete_batch(chunk)
			if boundary > 0 or offset + #chunk >= stat.size then break end
			length = math.min(#chunk, stat.size - offset - #chunk)
		end
		if boundary == 0 then return "idle" end
		chunk = chunk:sub(1, boundary)
		local statements, reason = M.admit(chunk, device_id, columns)
		if not statements then
			warn_once(device_id, "its ledger holds " .. tostring(reason))
			return "failed"
		end
		local stream = known.stream.copy()
		if not stream.update(chunk) then return "failed" end
		local digest = stream.digest()
		if not digest then return "failed" end
		local applied = offset + boundary
		local q = SqliteCommand.escape_literal
		local now_ts = opts.now_ts()
		local now = q(now_ts)
		local script = {
			"BEGIN IMMEDIATE;",
			string.format("INSERT OR IGNORE INTO devices (device_id, name, os, os_version, host_signature, created_at, updated_at) "
				.. "VALUES ('%s','%s','%s','%s','%s','%s','%s');", q(device_id), q(descriptor.name), q(descriptor.os),
				q(descriptor.os_version), q(descriptor.host_signature), q(descriptor.created_at), now),
			table.concat(statements, "\n"),
			Queries.render("devices.import_watermark", "cli_json", {
				size = applied, digest = digest, updated_at = now_ts, device_id = device_id }),
			Queries.render("meta.set", "cli_json", { key = M.PENDING_PREFIX .. device_id, value = "1" }),
			"COMMIT;",
		}
		if store.exec_sql(table.concat(script, "\n")) ~= true then
			warn_once(device_id, "the store refused its rows")
			return "failed"
		end
		verified[device_id] = { identity = identity_of(stat), offset = applied, stream = stream }
		logger.debug(LOG, "Foreign ledger %s: %d statement(s) applied up to byte %.0f.", device_id, #statements, applied)
		if applied < stat.size then return "more" end
		return "idle"
	end

	--- Rebuilds the aggregates of a caught-up device whose raw rows moved.
	local function rebuild(device_id)
		local is_pending, readable = pending(device_id)
		if not readable then return "failed" end
		if not is_pending then return "idle" end
		local ok, sql, reason = pcall(opts.rebuild, device_id)
		if not ok or type(sql) ~= "string" then
			warn_once(device_id, "its aggregates cannot be rebuilt (" .. tostring(ok and reason or sql) .. ")")
			return "failed"
		end
		local script = "BEGIN IMMEDIATE;\n" .. sql .. "\n"
			.. string.format("DELETE FROM meta WHERE key='%s';\n", SqliteCommand.escape_literal(M.PENDING_PREFIX .. device_id))
			.. Queries.render("meta.rev_bump", "cli_json") .. "\nCOMMIT;"
		if store.exec_sql(script) ~= true then
			warn_once(device_id, "the store refused its rebuilt aggregates")
			return "failed"
		end
		refused[device_id] = nil
		logger.info(LOG, "Imported the metrics of device %s.", device_id)
		return "rebuilt"
	end

	--- Reads a folder's device.json; nil when it does not name this folder.
	local function descriptor_of(device_id)
		local raw, status = fs.read(by_root .. "/" .. device_id .. "/device.json")
		if status ~= "ok" then return nil, "its device.json is unreadable" end
		local ok, obj = pcall(Json.decode, raw)
		if not ok or type(obj) ~= "table" or obj.device_id ~= device_id then
			return nil, "its device.json does not identify the folder"
		end
		local function text(value) return type(value) == "string" and value or "" end
		-- The devices table admits only these (schema CHECK); INSERT OR IGNORE
		-- would drop another value silently and leave no watermark to advance.
		if not KNOWN_OS[obj.os] then return nil, "its device.json names no known OS" end
		return { name = obj.name == nil and "?" or text(obj.name), os = obj.os,
			os_version = text(obj.os_version), host_signature = text(obj.host_signature),
			created_at = type(obj.created_at) == "string" and obj.created_at or opts.now_ts() }
	end

	--- Advances every foreign device by one bounded slice.
	--- @return string status "idle" (every device caught up) or "more".
	--- @return table rebuilt Device ids whose aggregates were rebuilt.
	function self:step()
		local entries = fs.list(by_root)
		if entries == nil then return "idle", {} end
		table.sort(entries, function(a, b) return a.name < b.name end)
		local status, rebuilt = "idle", {}
		for _, entry in ipairs(entries) do
			local device_id = entry.name
			if entry.kind == "directory" and device_id ~= opts.local_device_id and M.is_foreign_device_id(device_id) then
				local path = by_root .. "/" .. device_id .. "/data.sql"
				local stat = fs.stat(path)
				local descriptor, unidentified
				if stat and stat.size > 0 then descriptor, unidentified = descriptor_of(device_id) end
				if unidentified then
					warn_once(device_id, unidentified)
				elseif descriptor then
					local offset, digest = watermark(device_id)
					local state = offset ~= nil and prove(device_id, path, stat, offset, digest) or "failed"
					if state == "replay" then
						logger.info(LOG, "Foreign ledger %s: the imported prefix is not proved; replaying from byte 0.", device_id)
						verified[device_id], verifying[device_id] = nil, nil
						state = prove(device_id, path, stat, 0, nil)
						offset = 0
					end
					if state == "more" then
						status = "more"
					elseif state == "proved" then
						local slice = import_slice(device_id, path, stat, offset, descriptor)
						if slice == "more" then
							status = "more"
						elseif slice == "idle" and rebuild(device_id) == "rebuilt" then
							rebuilt[#rebuilt + 1] = device_id
						end
					end
				end
			end
		end
		return status, rebuilt
	end

	return self
end





-- ===================================
-- ===================================
-- ======= 4/ Native Ports ===========
-- ===================================
-- ===================================

--- The file ports of the daemon: the ledger exporter's, plus stat and ranged reads.
--- @return table ports
function M.native_ports()
	local uv = require("luv")
	local ports = MetricsLedger.native_ports()
	function ports.stat(path)
		local called, stat = pcall(uv.fs_stat, path)
		if not called or type(stat) ~= "table" or stat.type ~= "file" then return nil end
		local mtime = type(stat.mtime) == "table" and string.format("%d.%09d", stat.mtime.sec, stat.mtime.nsec) or ""
		return { size = tonumber(stat.size), ino = stat.ino, mtime = mtime }
	end
	function ports.read_range(path, offset, length)
		local handle = io.open(path, "rb")
		if not handle then return nil end
		local positioned = handle:seek("set", offset)
		local bytes = positioned == offset and handle:read(length) or nil
		handle:close()
		if length == 0 then return "" end
		return bytes
	end
	return ports
end

return M
