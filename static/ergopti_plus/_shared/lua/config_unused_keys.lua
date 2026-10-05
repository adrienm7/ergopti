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
---    cannot be proven exact. Metadata tables ([_meta] and any other [_*]) are
---    never offered either, as on Windows.
--- 5. Outdated members of an inline table. An owner can report one member of
---    `keys = { at_hash = true, ctrl_s = true }` as outdated while another is
---    live. That member is offered on its own, and its removal rewrites only
---    that record, without the member, so what is warned is what is offered.
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
local ConfigOutdated = require("config_outdated")
local LOG           = "config_unused_keys"
local BOM           = string.char(0xEF, 0xBB, 0xBF)

local RootCleanup = require("toml_codec.cleanup_roots")
local root_receipts = setmetatable({}, { __mode = "k" })

local function protected_root(root)
	return root:sub(1, 1) == "_" or root == "updater"
end

local function root_fields_match(entry, receipt, source)
	if receipt.consumed or receipt.source ~= source or getmetatable(entry) ~= nil then return false end
	local allowed = { section = true, key = true, kind = true, value = true, path = true }
	local count = 0
	for key in pairs(entry) do if not allowed[key] then return false end; count = count + 1 end
	if count ~= 5 or entry.section ~= receipt.root or entry.key ~= "" or entry.kind ~= "section"
		or entry.value ~= receipt.value or entry.path ~= receipt.path or getmetatable(entry.path) ~= nil then return false end
	count = 0
	for key in pairs(entry.path) do if key ~= 1 then return false end; count = count + 1 end
	return count == 1 and entry.path[1] == receipt.root
end

local function still_unread(receipt, source)
	local ok, decoded, shapes = pcall(TomlCodec.decode_with_shapes, source)
	if not ok or type(decoded) ~= "table" or protected_root(receipt.root) then return false end
	local consumption = M.new_consumption()
	local admitted = pcall(function()
		ConfigOutdated.collect_reports(function() receipt.collect(decoded, consumption.mark, shapes) end)
	end)
	return admitted and not consumption.touches({ receipt.root })
end

local function root_selection(source, keys, native_path)
	local roots, selected = {}, {}
	for _, entry in ipairs(keys) do
		local receipt = root_receipts[entry]
		if receipt then
			if not root_fields_match(entry, receipt, source) or selected[receipt.root]
				or (native_path ~= nil and (receipt.file_path ~= native_path or not still_unread(receipt, source))) then
				return nil, "the whole-root preview lost its exact source, record or unread ownership"
			end
			selected[receipt.root] = true; roots[#roots + 1] = receipt.root
		elseif entry.key == "" or (type(entry.path) == "table" and #entry.path < 2) then
			return nil, "a whole-root request needs its private native preview"
		end
	end
	return roots
end

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

--- Shared document scanner used by cleanup and sparse configuration writes.
M.scan_records = RecordScanner.scan_records





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

--- Reads the value at a path of a decoded document.
--- @param document table
--- @param segments table
--- @return any
local function lookup(document, segments)
	local value = document
	for _, segment in ipairs(segments) do
		if type(value) ~= "table" then return nil end
		value = value[segment]
	end
	return value
end

--- The bare-key segments of a dotted outdated path, nil for a path holding a
--- quoted segment (never offered: config_outdated says so in its warning).
--- @param path string
--- @return table|nil segments
local function bare_path(path)
	local segments = {}
	for segment in (path .. "."):gmatch("([^.]*)%.") do
		if not segment:match("^[A-Za-z0-9_%-]+$") then return nil end
		segments[#segments + 1] = segment
	end
	return segments
end

--- The outdated members strictly below one inline-table record, as offered
--- entries sorted by path.
--- @param record table Addressable record whose value is an inline table.
--- @param outdated table Set of dotted outdated paths.
--- @param decoded table Decoded document.
--- @return table entries
local function inline_members(record, outdated, decoded)
	local prefix = table.concat(record.path, ".") .. "."
	local paths = {}
	for path in pairs(outdated) do
		if path:sub(1, #prefix) == prefix then paths[#paths + 1] = path end
	end
	table.sort(paths)
	local entries = {}
	for _, path in ipairs(paths) do
		local segments = bare_path(path)
		local value = segments and lookup(decoded, segments)
		if value ~= nil then
			local section = {}
			for index = 1, #segments - 1 do section[index] = segments[index] end
			entries[#entries + 1] = {
				section = table.concat(section, "."),
				key     = segments[#segments],
				value   = TomlCodec.encode_value(value),
				kind    = "leaf",
				path    = segments,
				-- The record whose inline value the removal rewrites.
				inline  = { section = record.section, key = record.key },
			}
		end
	end
	return entries
end

--- Lists the unused keys of already-read content.
--- @param source string Exact file content.
--- @param collect function `collect(decoded, mark, shapes)`: the driver's readers; receipt is optional for old consumers.
--- @return table scan `{ status = "ok"|"malformed", keys }`.
local function find_in_source(source, collect, whole_unread_roots)
	if type(collect) ~= "function" then
		error("config_unused_keys: a collector of the driver's readers is required", 2)
	end
	local decoded_ok, decoded, shapes = pcall(TomlCodec.decode_with_shapes, source)
	if not decoded_ok or type(decoded) ~= "table" then
		return { status = "malformed", keys = {} }
	end
	local scan = M.scan_records(source)
	if not scan then return { status = "malformed", keys = {} } end

	local consumption = M.new_consumption()
	-- An entry its owner reports as outdated is offered even when another
	-- reader also reads it: warned and offered are one set.
	local outdated = ConfigOutdated.collect_reports(function() collect(decoded, consumption.mark, shapes) end)

	local keys, whole_roots = {}, {}
	local projection = whole_unread_roots and RootCleanup.scan(source)
	if projection then
		for _, root in ipairs(projection.order) do
			if root ~= "" and not protected_root(root) and not consumption.touches({ root }) then
				local value = TomlCodec.encode_value_with_shapes(projection.document[root], projection.shapes, projection.document, root)
				local entry = { section = root, key = "", kind = "section", value = value, path = { root } }
				root_receipts[entry] = { source = source, root = root, value = value, path = entry.path,
					collect = collect, consumed = false }
				keys[#keys + 1] = entry; whole_roots[root] = true
			end
		end
	end
	for _, record in ipairs(scan.records) do
		-- A [_*] table is metadata no reader marks: [_meta] holds the schema
		-- stamp the boot migration reads before any reader runs. The Windows
		-- loader skips the same tables.
		local metadata = record.addressable and record.path[1]:sub(1, 1) == "_"
		local stale = record.addressable and outdated[table.concat(record.path, ".")] == true
		if record.addressable and not whole_roots[record.path[1]] and not metadata and (stale or not consumption.touches(record.path)) then
			keys[#keys + 1] = {
				section = record.section,
				key     = record.key,
				value   = record.value,
				-- "section" when nothing the driver reads lives at, above or
				-- below the section path: the whole table is foreign to it.
				kind    = consumption.touches(record.header.segments) and "leaf" or "section",
				path    = record.path,
			}
		elseif record.addressable and not whole_roots[record.path[1]] and not metadata and type(lookup(decoded, record.path)) == "table" then
			for _, entry in ipairs(inline_members(record, outdated, decoded)) do keys[#keys + 1] = entry end
		end
	end
	return { status = "ok", keys = keys }
end

--- Retains the conservative addressing of the historical source-only API.
function M.find_in_source(source, collect)
	return find_in_source(source, collect, false)
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
	if opts.whole_unread_roots ~= nil and type(opts.whole_unread_roots) ~= "boolean" then
		error("whole unread roots need explicit native Boolean intent", 2)
	end
	local scan = find_in_source(content, opts.collect, opts.whole_unread_roots == true)
	for _, entry in ipairs(scan.keys) do
		if root_receipts[entry] then root_receipts[entry].file_path = opts.path end
	end
	scan.source = content
	return scan
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
	local roots, root_error = root_selection(source, keys)
	if not roots then return nil, root_error end
	if #roots > 0 then
		local remaining = {}
		for _, entry in ipairs(keys) do if not root_receipts[entry] then remaining[#remaining + 1] = entry end end
		local candidate, count = RootCleanup.render(source, roots)
		if not candidate then return nil, count end
		if #remaining > 0 then
			local remainder, removed = M.remove_from_source(candidate, remaining)
			if not remainder then return nil, removed end
			candidate, count = remainder, count + removed
		end
		return candidate, count
	end
	local scan, scan_err = M.scan_records(source)
	if not scan then return nil, scan_err end
	local listed, unknown_sections, members = {}, {}, {}
	for _, entry in ipairs(keys) do
		if type(entry.inline) == "table" then
			-- An inline-table member: its record is rewritten, never cut.
			local id = entry.inline.section .. "\n" .. entry.inline.key
			members[id] = members[id] or {}
			members[id][#members[id] + 1] = entry.path
		else
			listed[entry.section .. "\n" .. entry.key] = true
			if entry.kind == "section" then unknown_sections[entry.section] = true end
		end
	end

	local dropped, touched, replaced = {}, {}, {}
	local removed = 0
	local decoded = nil
	for _, record in ipairs(scan.records) do
		local id = record.addressable and (record.section .. "\n" .. record.key) or nil
		if id and listed[id] then
			for index = record.first, record.last do dropped[index] = true end
			removed = removed + 1
			touched[record.header] = true
		elseif id and members[id] then
			if decoded == nil then
				local decoded_ok, value = pcall(require("toml_codec.leaf_rows").decode_source, source)
				if not decoded_ok or type(value) ~= "table" then return nil, "the source would not parse" end
				decoded = value
			end
			local reduced, cut = M.without_members(lookup(decoded, record.path), record.path, members[id])
			if cut > 0 then
				removed = removed + cut
				for index = record.first, record.last do dropped[index] = true end
				if next(reduced) ~= nil then
					-- The rewritten record takes the place of its first line.
					local text = scan.lines[record.first].text
					local lead = text:sub(1, 3) == BOM and BOM or ""
					local indent = text:sub(#lead + 1):match("^[ \t]*")
					replaced[record.first] = {
						text = lead .. indent .. record.key .. " = " .. require("toml_codec.leaf_rows").value_literal(reduced),
						eol = scan.lines[record.last].eol,
					}
				end
			end
		end
	end
	for _, header in ipairs(scan.headers) do
		if touched[header] and unknown_sections[header.section] then
			local remaining = false
			for _, record in ipairs(scan.records) do
				if record.header == header and (not dropped[record.first] or replaced[record.first]) then
					remaining = true
					break
				end
			end
			if not remaining then dropped[header.index] = true end
		end
	end

	local lines = scan.lines
	local bom = lines[1] and lines[1].text:sub(1, 3) == BOM
	local chunks, bom_pending = {}, bom and dropped[1] and not replaced[1]
	for index, line in ipairs(lines) do
		local kept = replaced[index] or (not dropped[index] and line) or nil
		if kept then
			if bom_pending then
				-- The first line went; the file keeps its byte-order mark.
				chunks[#chunks + 1] = BOM
				bom_pending = false
			end
			chunks[#chunks + 1] = kept.text
			chunks[#chunks + 1] = kept.eol
		end
	end
	local candidate = table.concat(chunks)
	local decoded_ok, decoded = pcall(TomlCodec.decode, candidate)
	if not decoded_ok or type(decoded) ~= "table" then
		return nil, "the cleaned content would not parse"
	end
	return candidate, removed
end

--- Copies an inline table without the listed member paths, pruning tables
--- the removal leaves empty.
--- @param value table Decoded inline table.
--- @param prefix table Path segments of its record.
--- @param paths table Member paths (full segments) to remove.
--- @return table reduced
--- @return number cut Members actually removed.
function M.without_members(value, prefix, paths)
	local reduced, cut = require("toml_codec.leaf_rows").clone_value(value), 0
	for _, path in ipairs(paths) do
		local parents, node = {}, reduced
		for index = #prefix + 1, #path - 1 do
			if type(node) ~= "table" then node = nil; break end
			parents[#parents + 1] = { node = node, key = path[index] }
			node = node[path[index]]
		end
		if type(node) == "table" and node[path[#path]] ~= nil then
			node[path[#path]] = nil
			cut = cut + 1
			for index = #parents, 1, -1 do
				local parent = parents[index]
				if next(parent.node[parent.key]) ~= nil then break end
				parent.node[parent.key] = nil
			end
		end
	end
	return reduced, cut
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
	local captured_keys = {}
	for index, entry in ipairs(opts.keys) do captured_keys[index] = entry end
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
	if opts.expected_source ~= nil and source ~= opts.expected_source then
		result.status = "changed"
		Logger.warn(LOG, "Cleanup deferred: '%s' changed after the preview was opened.", path)
		return result
	end

	local function validate_roots()
		local roots, detail = root_selection(source, captured_keys, path)
		if not roots then return false, detail end
		if #roots > 0 then
			if getmetatable(opts.keys) ~= nil or #opts.keys ~= #captured_keys then
				return false, "the native root selection changed"
			end
			for index, entry in ipairs(captured_keys) do
				if not rawequal(opts.keys[index], entry) then return false, "the captured native root row changed" end
			end
		end
		return true
	end
	local admitted, admission_error = validate_roots()
	if not admitted then return refuse("write_failed", admission_error) end

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

	admitted, admission_error = validate_roots()
	if not admitted then return refuse("write_failed", admission_error) end
	local candidate, removed_or_err = M.remove_from_source(source, captured_keys)
	if not candidate then return refuse("write_failed", removed_or_err) end
	if candidate ~= source then
		admitted, admission_error = validate_roots()
		if not admitted then return refuse("write_failed", admission_error) end
		local publish_ok, published, publish_detail = pcall(publish, path, candidate,
			{ status = "ok", content = source })
		if not publish_ok or published ~= true then
			return refuse("write_failed", publish_ok and publish_detail or published)
		end
	end

	for _, entry in ipairs(captured_keys) do
		if root_receipts[entry] then root_receipts[entry].consumed = true end
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
