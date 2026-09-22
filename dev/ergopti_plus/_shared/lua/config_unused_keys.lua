--- _shared/lua/config_unused_keys.lua

--- ==============================================================================
--- MODULE: Unused Configuration Keys (shared Lua engine)
--- DESCRIPTION:
--- Lists the keys of a driver's config.toml that none of that driver's readers
--- consumes and, on request, removes them after writing a byte-exact backup
--- next to the file. The Lua counterpart of windows/infra/config_unused_keys.ahk,
--- shared by the macOS and Linux drivers.
---
--- FEATURES & RATIONALE:
--- 1. The driver's own rule. This module holds no schema. Each driver passes a
---    collector that runs its real config readers over the decoded file and
---    marks every path they consume, through the same code the readers apply
---    at load. A key is unused exactly when no mark covers its path, so the
---    list can never disagree with what the driver actually reads.
--- 2. Backup before change. The exact current bytes go to a new, never
---    overwritten ``<name>.backup-<timestamp>.<ext>`` file, which is read back
---    and compared before the configuration file is touched. Any failure stops
---    the cleanup with the file unchanged.
--- 3. Byte-preserving removal. Only the confirmed records are cut, plus the
---    header of an unknown section they leave empty; every other byte, comment
---    and line ending survives. The rewrite is published only while the file
---    still holds the bytes that were backed up.
--- 4. Conservative addressing. Keys outside any table, quoted keys, and
---    array-of-tables records are never offered: removing them by text alone
---    cannot be proven exact.
--- ==============================================================================

local M = {}

-- Resolved softly, like toml_codec.writer: macOS has its ring-buffer logger,
-- the Linux daemon and the LuaJIT runners use the shim.
local _ok_log, Logger = pcall(require, "infra.logger")
if not _ok_log or type(Logger) ~= "table" then
	Logger = require("logger.shim")
end
local TomlCodec     = require("toml_codec")
local TomlWriter    = require("toml_codec.writer")
local RecordScanner = require("toml_codec.record_scanner")
local Bom           = require("toml_codec.bom")
local LOG           = "config_unused_keys"

--- The confirmation dialog lists at most this many keys; the rest are counted.
--- Pinned to CONFIG_UNUSED_KEYS_DISPLAY_LIMIT of the Windows driver by test.
M.DISPLAY_LIMIT = 30

--- os.date format of the backup timestamp, the Windows driver's
--- "yyyyMMdd-HHmmss" spelled for Lua.
M.STAMP_FORMAT = "%Y%m%d-%H%M%S"





-- ====================================
-- ====================================
-- ======= 1/ Consumption Marks =======
-- ====================================
-- ====================================

--- Creates the set of config paths a driver's readers consume.
---
--- A mark on a path covers its whole subtree: a reader that takes a table as a
--- unit (a map of gesture slots, a list of hotstring groups) consumes every key
--- inside it. A record is also kept when a mark lies BELOW it, because an
--- inline table holding one consumed field cannot be cut by halves.
--- @return table consumption `{ mark(...), touches(segments) }`.
function M.new_consumption()
	local root = { children = {}, marked = false, below = false }
	local consumption = {}

	--- Marks one consumed path, given as its segments.
	--- @param ... string Path segments, e.g. "gestures", "tap_3".
	function consumption.mark(...)
		local count = select("#", ...)
		if count == 0 then error("config_unused_keys: a mark needs at least one segment", 2) end
		local node = root
		for index = 1, count do
			local segment = select(index, ...)
			if type(segment) ~= "string" or segment == "" then
				error("config_unused_keys: mark segments must be non-empty strings", 2)
			end
			node.below = true
			local child = node.children[segment]
			if not child then
				child = { children = {}, marked = false, below = false }
				node.children[segment] = child
			end
			node = child
		end
		node.marked = true
	end

	--- Whether a mark covers the path or lies anywhere below it.
	--- @param segments table Path segments.
	--- @return boolean
	function consumption.touches(segments)
		local node = root
		for _, segment in ipairs(segments) do
			node = node.children[segment]
			if not node then return false end
			if node.marked then return true end
		end
		return node.below
	end

	return consumption
end





-- =================================
-- =================================
-- ======= 2/ Record Scanner =======
-- =================================
-- =================================

--- Splits source bytes into physical lines, each keeping its exact terminator.
--- @param source string Complete file content.
--- @return table lines Array of `{ text, eol }`.
local function split_lines(source)
	local lines = {}
	local cursor = 1
	while cursor <= #source do
		local cr_at = source:find("\r", cursor, true)
		local lf_at = source:find("\n", cursor, true)
		local eol_at = (cr_at and lf_at) and math.min(cr_at, lf_at) or cr_at or lf_at
		if not eol_at then
			lines[#lines + 1] = { text = source:sub(cursor), eol = "" }
			break
		end
		local eol = source:sub(eol_at, eol_at)
		local eol_last = eol_at
		if eol == "\r" and source:sub(eol_at + 1, eol_at + 1) == "\n" then
			eol = "\r\n"
			eol_last = eol_at + 1
		end
		lines[#lines + 1] = { text = source:sub(cursor, eol_at - 1), eol = eol }
		cursor = eol_last + 1
	end
	return lines
end

local function trim(value)
	return (value:match("^%s*(.-)%s*$")) or ""
end

--- Splits a dotted bare-key path. Returns nil for anything that is not a plain
--- run of bare segments (quotes, empty segments), which is never offered.
--- @param text string Key or header body.
--- @return table|nil segments
local function bare_segments(text)
	if text:find("[\"']") then return nil end
	local segments = {}
	for part in (text .. "."):gmatch("([^%.]*)%.") do
		local segment = trim(part)
		if not segment:match("^[%w_%-]+$") then return nil end
		segments[#segments + 1] = segment
	end
	return #segments > 0 and segments or nil
end

--- Parses a table header line.
--- @param trimmed string The trimmed physical line, starting with "[".
--- @return table header `{ array, segments|nil }`; segments is nil when unaddressable.
local function parse_header(trimmed)
	local array = trimmed:sub(1, 2) == "[["
	local body, rest
	if array then
		body, rest = trimmed:match("^%[%[([^%]]*)%]%](.*)$")
	else
		body, rest = trimmed:match("^%[([^%]]*)%](.*)$")
	end
	local header = { array = array, segments = nil }
	if body and (trim(rest) == "" or trim(rest):sub(1, 1) == "#") then
		header.segments = bare_segments(body)
	end
	return header
end

--- Whether prefix is a leading run of segments.
--- @param segments table
--- @param prefix table
--- @return boolean
local function starts_with(segments, prefix)
	if #prefix > #segments then return false end
	for index = 1, #prefix do
		if segments[index] ~= prefix[index] then return false end
	end
	return true
end

--- Finds every assignment record of a TOML document with its exact line span.
---
--- Continuation lines of arrays, inline tables and multiline strings belong to
--- the record that opened them (the shared record scanner decides), so a line
--- that merely looks like a header inside a value is data.
--- @param source string Complete file content.
--- @return table|nil scan `{ lines, headers, records }`, nil when a value never closes.
--- @return string|nil error_detail
function M.scan_records(source)
	local lines = split_lines(source)
	local headers, records = {}, {}
	local current = nil
	local open = nil
	local depth, multiline_quote = 0, nil
	for index, line in ipairs(lines) do
		local raw = index == 1 and Bom.strip_prefix(line.text) or line.text
		if depth > 0 or multiline_quote ~= nil then
			depth, multiline_quote = RecordScanner.advance(raw, depth, multiline_quote)
			open.last = index
			open.value_parts[#open.value_parts + 1] = trim(raw)
		else
			local trimmed = trim(raw)
			if trimmed == "" or trimmed:sub(1, 1) == "#" then
				open = nil
			elseif trimmed:sub(1, 1) == "[" then
				current = parse_header(trimmed)
				current.index = index
				current.section = current.segments and table.concat(current.segments, ".") or nil
				headers[#headers + 1] = current
				open = nil
			else
				local key_text, value_text = trimmed:match("^([^=]-)%s*=%s*(.*)$")
				open = {
					first = index,
					last = index,
					header = current,
					key_segments = key_text and bare_segments(key_text) or nil,
					value_parts = { value_text or "" },
				}
				records[#records + 1] = open
				depth, multiline_quote = RecordScanner.advance(raw, 0, nil)
			end
		end
	end
	if depth > 0 or multiline_quote ~= nil then
		return nil, "unterminated TOML assignment"
	end

	-- Anything under an array of tables attaches to its latest element; the
	-- text alone cannot name that element, so none of it is addressable.
	local array_prefixes = {}
	for _, header in ipairs(headers) do
		if header.array and header.segments then array_prefixes[#array_prefixes + 1] = header.segments end
	end
	for _, record in ipairs(records) do
		local header = record.header
		local addressable = header ~= nil and header.segments ~= nil and not header.array
			and record.key_segments ~= nil
		if addressable then
			for _, prefix in ipairs(array_prefixes) do
				if starts_with(header.segments, prefix) then
					addressable = false
					break
				end
			end
		end
		record.addressable = addressable
		if addressable then
			record.section = header.section
			record.key = table.concat(record.key_segments, ".")
			record.path = {}
			for _, segment in ipairs(header.segments) do record.path[#record.path + 1] = segment end
			for _, segment in ipairs(record.key_segments) do record.path[#record.path + 1] = segment end
			record.value = table.concat(record.value_parts, " ")
		end
	end
	return { lines = lines, headers = headers, records = records }
end





-- ============================
-- ============================
-- ======= 3/ Detection =======
-- ============================
-- ============================

--- Reads through the injected reader, or the shared classified reader.
--- @param opts table Options carrying `read` or `file_adapter`.
--- @param path string
--- @return string|nil content
--- @return string status `ok`, `absent` or `error`.
--- @return string|nil detail
local function read_file(opts, path)
	if type(opts.read) == "function" then return opts.read(path) end
	return TomlWriter.read_classified(path, opts.file_adapter)
end

--- Lists the unused keys of already-read content.
--- @param source string Exact file content.
--- @param collect function `collect(decoded, mark)`: the driver's readers.
--- @return table scan `{ status = "ok"|"malformed", keys }`.
function M.find_in_source(source, collect)
	if type(collect) ~= "function" then
		error("config_unused_keys: a collector of the driver's readers is required", 2)
	end
	local decoded_ok, decoded = pcall(TomlCodec.decode, source)
	if not decoded_ok or type(decoded) ~= "table" then
		return { status = "malformed", keys = {} }
	end
	local scan = M.scan_records(source)
	if not scan then return { status = "malformed", keys = {} } end

	local consumption = M.new_consumption()
	collect(decoded, consumption.mark)

	local keys = {}
	for _, record in ipairs(scan.records) do
		if record.addressable and not consumption.touches(record.path) then
			keys[#keys + 1] = {
				section = record.section,
				key     = record.key,
				value   = record.value,
				-- "section" when nothing the driver reads lives at, above or
				-- below the section path: the whole table is foreign to it.
				kind    = consumption.touches(record.header.segments) and "leaf" or "section",
				path    = record.path,
			}
		end
	end
	return { status = "ok", keys = keys }
end

--- Lists the unused keys of a config file. A missing file is "ok" with no
--- keys: there is nothing to clean.
--- @param opts table `{ path, collect, file_adapter?, read? }`.
--- @return table scan `{ status = "ok"|"unreadable"|"malformed", keys }`.
function M.find(opts)
	if type(opts) ~= "table" or type(opts.path) ~= "string" or opts.path == "" then
		error("config_unused_keys.find needs a path", 2)
	end
	local content, status = read_file(opts, opts.path)
	if status == "absent" then return { status = "ok", keys = {} } end
	if status ~= "ok" or type(content) ~= "string" then
		return { status = "unreadable", keys = {} }
	end
	return M.find_in_source(content, opts.collect)
end

--- Substitutes {1}, {2}, … in a localized template without pattern magic, so
--- a path or value holding "%" stays literal.
--- @param template string
--- @param ... any Values in placeholder order.
--- @return string
function M.fill(template, ...)
	local text = tostring(template)
	for index = 1, select("#", ...) do
		local placeholder = "{" .. index .. "}"
		local value = tostring((select(index, ...)))
		local out, cursor = {}, 1
		while true do
			local at = text:find(placeholder, cursor, true)
			if not at then break end
			out[#out + 1] = text:sub(cursor, at - 1)
			out[#out + 1] = value
			cursor = at + #placeholder
		end
		out[#out + 1] = text:sub(cursor)
		text = table.concat(out)
	end
	return text
end

--- One "[section] key = value" line per key, capped at DISPLAY_LIMIT with a
--- localized count of the remainder.
--- @param keys table Keys from find().
--- @param get_text function Localized string lookup.
--- @return string
function M.describe(keys, get_text)
	local lines = {}
	for index, entry in ipairs(keys) do
		if index > M.DISPLAY_LIMIT then
			lines[#lines + 1] = M.fill(get_text("dialog.unused_keys.more"), #keys - M.DISPLAY_LIMIT)
			break
		end
		lines[#lines + 1] = "[" .. entry.section .. "] " .. entry.key .. " = " .. entry.value
	end
	return table.concat(lines, "\n")
end





-- ==========================
-- ==========================
-- ======= 4/ Removal =======
-- ==========================
-- ==========================

--- ``config.toml`` + "20260922-041500" -> ``config.backup-20260922-041500.toml``
--- in the same directory, so the copy sits next to the file it protects.
--- @param path string
--- @param stamp string
--- @return string
function M.backup_path(path, stamp)
	local dir, name = path:match("^(.*[/\\])([^/\\]+)$")
	if not dir then dir, name = "", path end
	local stem, ext = name:match("^(.+)(%.[^%.]+)$")
	if not stem then stem, ext = name, "" end
	return dir .. stem .. ".backup-" .. stamp .. ext
end

--- Cuts the listed keys out of source, byte for byte.
---
--- A listed key that is no longer in the file is simply absent from the count,
--- and a key added after the scan is never touched because only listed
--- identities are cut. An unknown section loses its header only when the
--- cleanup removed at least one of its keys and none remain.
--- @param source string Exact file content.
--- @param keys table Keys from find().
--- @return string|nil candidate Cleaned content.
--- @return number|string removed_or_error Number of records cut, or a failure detail.
function M.remove_from_source(source, keys)
	local scan, scan_err = M.scan_records(source)
	if not scan then return nil, scan_err end
	local listed, unknown_sections = {}, {}
	for _, entry in ipairs(keys) do
		listed[entry.section .. "\n" .. entry.key] = true
		if entry.kind == "section" then unknown_sections[entry.section] = true end
	end

	local dropped, touched = {}, {}
	local removed = 0
	for _, record in ipairs(scan.records) do
		if record.addressable and listed[record.section .. "\n" .. record.key] then
			for index = record.first, record.last do dropped[index] = true end
			removed = removed + 1
			touched[record.header] = true
		end
	end
	for _, header in ipairs(scan.headers) do
		if touched[header] and unknown_sections[header.section] then
			local remaining = false
			for _, record in ipairs(scan.records) do
				if record.header == header and not dropped[record.first] then
					remaining = true
					break
				end
			end
			if not remaining then dropped[header.index] = true end
		end
	end

	local lines = scan.lines
	local bom = lines[1] and lines[1].text:sub(1, 3) == string.char(0xEF, 0xBB, 0xBF)
	local chunks, bom_pending = {}, bom and dropped[1]
	for index, line in ipairs(lines) do
		if not dropped[index] then
			if bom_pending then
				-- The first line went; the file keeps its byte-order mark.
				chunks[#chunks + 1] = string.char(0xEF, 0xBB, 0xBF)
				bom_pending = false
			end
			chunks[#chunks + 1] = line.text
			chunks[#chunks + 1] = line.eol
		end
	end
	local candidate = table.concat(chunks)
	local decoded_ok, decoded = pcall(TomlCodec.decode, candidate)
	if not decoded_ok or type(decoded) ~= "table" then
		return nil, "the cleaned content would not parse"
	end
	return candidate, removed
end

--- Removes keys (as returned by find) from a config file after a verified
--- backup. Only status "removed" changes the file.
---
--- Seams: `read(path) -> content, status, detail`, `create_backup(path,
--- content) -> true | false, detail` (must refuse an existing path) and
--- `publish(path, content, expected_source) -> true | false, detail`. By
--- default all three go through toml_codec.writer with `file_adapter`.
--- @param opts table `{ path, keys, stamp?, file_adapter?, read?, create_backup?, publish? }`.
--- @return table result `{ status, backup, removed, previous?, content? }`.
function M.remove(opts)
	if type(opts) ~= "table" or type(opts.path) ~= "string" or opts.path == "" then
		error("config_unused_keys.remove needs a path", 2)
	end
	if type(opts.keys) ~= "table" or #opts.keys == 0 then
		error("config_unused_keys.remove needs at least one key to remove", 2)
	end
	local path = opts.path
	local stamp = opts.stamp or os.date(M.STAMP_FORMAT)
	local backup = M.backup_path(path, stamp)
	local create_backup = opts.create_backup or function(target, content)
		return TomlWriter.publish_if_unchanged(target, content, opts.file_adapter, { status = "absent" })
	end
	local publish = opts.publish or function(target, content, expected_source)
		return TomlWriter.publish_if_unchanged(target, content, opts.file_adapter, expected_source)
	end
	local result = { status = "write_failed", backup = backup, removed = 0 }

	Logger.start(LOG, "Removing %d unused key(s) from '%s'…", #opts.keys, path)
	local function refuse(status, detail)
		result.status = status
		Logger.error(LOG, "Unused-key cleanup of '%s' refused (%s: %s); the file was not changed.",
			path, status, tostring(detail))
		return result
	end

	local read_ok, source, read_status, read_detail = pcall(read_file, opts, path)
	if not read_ok then return refuse("unreadable", source) end
	if read_status ~= "ok" or type(source) ~= "string" then
		return refuse("unreadable", read_detail or read_status)
	end

	-- The copy is created where nothing exists yet and read back before any
	-- byte of the configuration can change.
	local create_ok, created, create_detail = pcall(create_backup, backup, source)
	if not create_ok or created ~= true then
		return refuse("backup_failed", create_ok and create_detail or created)
	end
	local copy_ok, copy, copy_status = pcall(read_file, opts, backup)
	if not copy_ok or copy_status ~= "ok" or copy ~= source then
		return refuse("backup_failed", "the backup '" .. backup .. "' does not hold the exact bytes")
	end

	local candidate, removed_or_err = M.remove_from_source(source, opts.keys)
	if not candidate then return refuse("write_failed", removed_or_err) end
	if candidate ~= source then
		local publish_ok, published, publish_detail = pcall(publish, path, candidate,
			{ status = "ok", content = source })
		if not publish_ok or published ~= true then
			return refuse("write_failed", publish_ok and publish_detail or published)
		end
	end

	result.status = "removed"
	result.removed = removed_or_err
	result.previous = source
	result.content = candidate
	Logger.success(LOG, "Removed %d unused key(s) from '%s'; backup at '%s'.",
		removed_or_err, path, backup)
	return result
end





-- ==============================
-- ==============================
-- ======= 5/ Menu Action =======
-- ==============================
-- ==============================

--- The tray action: lists the unused keys, asks before removing them, and
--- reports the backup path or the reason nothing changed. Dialogs belong to the
--- driver: `confirm(title, text)` returns true, false, or nil when nobody could
--- be asked; `inform(title, text)` and `fail(title, text)` only show.
--- @param opts table `{ path, collect, get_text, confirm, inform, fail,
---   on_removed?, stamp?, file_adapter?, read?, create_backup?, publish? }`.
--- @return boolean completed False when the check or the removal failed.
function M.run(opts)
	for _, name in ipairs({ "collect", "get_text", "confirm", "inform", "fail" }) do
		if type(opts[name]) ~= "function" then
			error("config_unused_keys.run needs a '" .. name .. "' function", 2)
		end
	end
	local path = opts.path
	local get_text = opts.get_text
	local title = get_text("dialog.unused_keys.title")

	Logger.start(LOG, "Checking '%s' for unused keys…", tostring(path))
	local find_ok, scan = pcall(M.find, opts)
	if not find_ok or scan.status ~= "ok" then
		Logger.error(LOG, "Unused-key check of '%s' aborted: %s.", tostring(path),
			find_ok and ("the file is " .. scan.status) or tostring(scan))
		opts.fail(title, M.fill(get_text("dialog.unused_keys.failed"),
			get_text("dialog.unused_keys.reason.unreadable")))
		return false
	end

	local keys = scan.keys
	if #keys == 0 then
		Logger.success(LOG, "No unused keys in '%s'.", path)
		opts.inform(title, M.fill(get_text("dialog.unused_keys.none"), path))
		return true
	end

	local answer = opts.confirm(title, M.fill(get_text("dialog.unused_keys.confirm"),
		#keys, path, M.describe(keys, get_text)))
	if answer == nil then
		Logger.error(LOG, "Found %d unused key(s) in '%s', but the confirmation could not be shown; "
			.. "nothing was removed.", #keys, path)
		return false
	end
	Logger.success(LOG, "Found %d unused key(s) in '%s'; removal %s.", #keys, path,
		answer == true and "confirmed" or "declined")
	if answer ~= true then return true end

	local result = M.remove({
		path = path,
		keys = keys,
		stamp = opts.stamp,
		file_adapter = opts.file_adapter,
		read = opts.read,
		create_backup = opts.create_backup,
		publish = opts.publish,
	})
	if result.status == "removed" then
		if type(opts.on_removed) == "function" then opts.on_removed(result) end
		opts.inform(title, M.fill(get_text("dialog.unused_keys.done"), result.removed, result.backup))
		return true
	end
	local reason_key = "dialog.unused_keys.reason.write"
	if result.status == "backup_failed" then
		reason_key = "dialog.unused_keys.reason.backup"
	elseif result.status == "unreadable" then
		reason_key = "dialog.unused_keys.reason.unreadable"
	end
	opts.fail(title, M.fill(get_text("dialog.unused_keys.failed"), get_text(reason_key)))
	return false
end

return M
