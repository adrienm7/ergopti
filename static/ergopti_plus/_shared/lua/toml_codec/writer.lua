--- _shared/lua/toml_codec/writer.lua

--- ==============================================================================
--- MODULE: TOML Writer (shared)
--- DESCRIPTION:
--- Serializes a hotstrings data structure back to the TOML format used by
--- the application. Canonical source shared by all Lua-based drivers
--- (Hammerspoon, future Linux driver). Previously lived at
--- hammerspoon/infra/toml_writer.lua; moved here so both drivers share one
--- implementation without duplication.
---
--- FEATURES & RATIONALE:
--- 1. Token alias normalization: {Esc} → {Escape}, {return} → {Enter}, etc.,
---    so the on-disk format never mixes raw \n / \t with {Enter} / {Tab}.
--- 2. Batch write: a separate batch_write() method updates key/value pairs
---    in INI-style TOML files (driver config.toml) without rewriting the whole
---    file — existing lines are updated in-place, new entries are appended.
--- 3. Transactional publication: both writers require exact read/write/close/
---    rename acknowledgement before they report success or replace live data.
--- 4. Session registries owned by the config migration: a path whose writes
---    are refused (a config.toml this build cannot version) and the rows a
---    writer adds when it creates a path (the schema stamp).
--- ==============================================================================

local M = {}
-- Logger / i18n are resolved SOFTLY so this shared module genuinely loads on every
-- Lua runtime (the Linux daemon, LuaJIT test runners, build scripts), not only the
-- macOS driver. macOS still gets its real ring-buffer logger and localised section
-- descriptions; elsewhere a print shim + key-passthrough i18n take over. Hard
-- requires on lib.logger / lib.i18n here were the impurity that forced the Linux
-- driver to fork its own TOML parser (audit SS-2).
local _ok_log, Logger = pcall(require, "infra.logger")
if not _ok_log or type(Logger) ~= "table" then
	Logger = require("logger.shim")
end
local _ok_i18n, i18n = pcall(require, "infra.i18n")
if not _ok_i18n or type(i18n) ~= "table" then
	i18n = { get = function(k) return k end, get_locale = function() return "fr" end }
end
local LOG    = "toml_writer"
local ENOENT_ERROR_CODE = 2
local BasicString = require("toml_codec.basic_string")
local RecordScanner = require("toml_codec.record_scanner")
local Bom = require("toml_codec.bom")
local KeyPath = require("toml_codec.key_path")
local Codec = require("toml_codec.codec")
local inline_member_spans = Codec.inline_member_spans
local math_type = math.type
local OperationReporter = require("diagnostics.operation_reporter")





-- ====================================
-- ====================================
-- ======= 0/ File Transactions =======
-- ====================================
-- ====================================

local read_batch_source

-- Paths this session must not write, with the reason. The config migration
-- registers a config.toml it could not version (a newer schema, a failed
-- migration): every publication below refuses it, so no writer can replace a
-- file this build does not understand.
local _refused_writes = {}

-- Rows a writer adds when it creates a path from absence. The config migration
-- registers the schema stamp here, so a config.toml this build creates carries
-- this build's version and a later boot never mistakes it for an unstamped,
-- older file.
local _create_rows = {}
local _sparse_defaults = {}

--- The refusal registry key: one spelling per path, whatever the separators.
--- @param path string
--- @return string
local function refusal_key(path)
	return (tostring(path):gsub("\\", "/"):gsub("/+", "/"))
end

--- Runs the captured final admission without treating exceptions as permission.
--- @param admission function|nil
--- @return boolean admitted
local function publication_admitted(admission)
	if admission == nil then return true end
	if type(admission) ~= "function" then return false end
	local called, admitted = pcall(admission)
	return called and admitted == true
end

--- Publishes complete content through a same-directory staging file.
--- A protected call only proves that Lua did not raise; file methods also
--- return nil/false for ordinary I/O failures, so every terminal result is
--- checked before the live path can be replaced.
--- @param path string Destination path.
--- @param content string Complete serialized content.
--- @param expected_source table|nil Optional `{ status, content }` precondition.
--- @return boolean committed
--- @return string|nil error_message
local function publish(path, content, expected_source, admission)
	-- A synchronous fallback can acknowledge the current image after its exact
	-- source recheck. Explicit adapters retain their own serialization boundary.
	if type(expected_source) == "table" and expected_source.status == "ok"
		and expected_source.content == content then
		local current, detail, status = read_batch_source(path)
		if status ~= "ok" or current ~= content then
			return false, "source changed before unchanged acknowledgement: " .. tostring(detail or status)
		end
		if not publication_admitted(admission) then return false, "publication admission refused" end
		return true
	end
	local tmp_path = path .. ".tmp"
	local open_ok, fh, open_err = pcall(io.open, tmp_path, "w")
	if not open_ok or not fh then
		return false, "cannot open staging file: " .. tostring(open_ok and open_err or fh)
	end

	local write_ok, wrote, write_err = pcall(fh.write, fh, content)
	local close_ok, closed, close_err = pcall(fh.close, fh)
	if not write_ok or wrote == nil or wrote == false then
		pcall(os.remove, tmp_path)
		return false, "write failed: " .. tostring(write_ok and write_err or wrote)
	end
	if not close_ok or closed == nil or closed == false then
		pcall(os.remove, tmp_path)
		return false, "close failed: " .. tostring(close_ok and close_err or closed)
	end
	if type(expected_source) == "table" then
		local current, current_err, current_status = read_batch_source(path)
		if current_status ~= expected_source.status
			or (current_status == "ok" and current ~= expected_source.content) then
			pcall(os.remove, tmp_path)
			return false, "source changed before publication: " .. tostring(current_err or current_status)
		end
	end

	-- The last classified source read has completed. No logical reader or
	-- observer runs between this captured admission and native publication.
	if not publication_admitted(admission) then
		pcall(os.remove, tmp_path)
		return false, "publication admission refused"
	end
	local rename_ok, renamed, rename_err = pcall(os.rename, tmp_path, path)
	-- POSIX replaces an existing destination atomically. Windows' C runtime does
	-- not, so keep the old file recoverable while replacing it on test/Linux
	-- hosts running under Windows.
	if admission == nil and (not rename_ok or renamed ~= true) and package.config:sub(1, 1) == "\\" then
		local backup = path .. ".bak"
		pcall(os.remove, backup)
		local backup_ok, backed_up = pcall(os.rename, path, backup)
		if backup_ok and backed_up == true then
			rename_ok, renamed, rename_err = pcall(os.rename, tmp_path, path)
			if rename_ok and renamed == true then
				pcall(os.remove, backup)
			else
				pcall(os.rename, backup, path)
			end
		end
	end
	if not rename_ok or renamed ~= true then
		pcall(os.remove, tmp_path)
		return false, "rename failed: " .. tostring(rename_ok and rename_err or renamed)
	end
	return true
end

--- Reads an existing batch-write source without confusing an I/O failure with
--- a fresh file. The caller may create only after an exact ENOENT result.
--- @param path string Source path.
--- @return string|nil content Empty string for a proven absent source.
--- @return string|nil error_message
--- @return string status "ok" | "absent" | "error"
read_batch_source = function(path)
	local open_ok, fh, open_err, open_code = pcall(io.open, path, "r")
	if not open_ok then return nil, "source open raised: " .. tostring(fh), "error" end
	if not fh then
		if open_code == ENOENT_ERROR_CODE then return "", nil, "absent" end
		return nil, "source open failed: " .. tostring(open_err), "error"
	end
	local read_ok, content, read_err = pcall(fh.read, fh, "*a")
	local close_ok, closed, close_err = pcall(fh.close, fh)
	if not read_ok or type(content) ~= "string" then
		return nil, "source read failed: " .. tostring(read_ok and read_err or content), "error"
	end
	if not close_ok or closed ~= true then
		return nil, "source close failed: " .. tostring(close_ok and close_err or closed), "error"
	end
	return content, nil, "ok"
end





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Token alias normalization map.
local TOKEN_CANONICAL = {
	esc = "Escape", escape = "Escape",
	bs  = "BackSpace", backspace = "BackSpace",
	del = "Delete", delete = "Delete",
	["return"] = "Enter", enter = "Enter",
	left = "Left", right = "Right", up = "Up", down = "Down",
	home = "Home", ["end"] = "End", tab = "Tab",
}





-- ===================================
-- ===================================
-- ======= 2/ String Utilities =======
-- ===================================
-- ===================================

--- Escapes a value for TOML double-quoted strings.
--- Also normalizes literal newlines to {Enter} and token aliases.
--- @param s string The input string to escape.
--- @return string The escaped and normalized string.
local function esc(s)
	if type(s) ~= "string" then s = tostring(s or "") end

	-- Normalize literal newlines → {Enter} and tabs → {Tab} so the on-disk
	-- format never mixes raw \n / \t with {Enter} / {Tab} for the same kind
	-- of payload (matches the AHK side's EscapeTomlValue behaviour)
	s = s:gsub("\r\n", "{Enter}")
	s = s:gsub("\r",   "{Enter}")
	s = s:gsub("\n",   "{Enter}")
	s = s:gsub("\t",   "{Tab}")

	-- Normalize token aliases e.g. {Esc} → {Escape}, {return} → {Enter}
	s = s:gsub("{([^}]+)}", function(name)
		local canon = TOKEN_CANONICAL[name:lower()]
		return "{" .. (canon or name) .. "}"
	end)

	return BasicString.escape_body(s)
end

-- Forward declaration: publish_content() revalidates through this helper.
-- Declaring it first is required for Lua to capture the local rather than bind
-- an unrelated `_G.read_existing`.
local read_existing

--- Publishes complete content through a platform adapter when one is supplied.
--- The shared fallback remains for drivers that have not injected an adapter.
--- When a caller edited an existing snapshot, it is re-read immediately before
--- publication so a sibling writer cannot silently replace changes observed
--- during serialization.
--- @param path string Destination path.
--- @param content string Complete TOML payload.
--- @param file_adapter table|nil Platform file adapter.
--- @param expected_source table|nil Optional `{ status, content }` precondition.
--- @return boolean written
--- @return string|nil error_message
local function publish_content(path, content, file_adapter, expected_source, on_error, admission)
	if admission ~= nil and type(admission) ~= "function" then
		return false, "publication admission must be a function"
	end
	local admitted_publisher
	if admission ~= nil and type(file_adapter) == "table" then
		-- Capture the advertised owner before its classified reader can reenter.
		admitted_publisher = type(expected_source) == "table" and file_adapter.write_if_unchanged_admitted
		if type(admitted_publisher) ~= "function" then
			return false, "explicit file adapter has no final publication admission"
		end
	end
	local refusal = _refused_writes[refusal_key(path)]
	if refusal then
		return false, "writes to this file are refused for the session: " .. refusal
	end
	if type(file_adapter) == "table" then
		if type(expected_source) == "table" then
			local current, current_status, current_detail = read_existing(path, file_adapter, on_error)
			if current_status ~= expected_source.status
				or (current_status == "ok" and current ~= expected_source.content) then
				return false, "source changed before publication: "
					.. tostring(current_detail or current_status)
			end
		end
		-- A classified source precondition is useful only if it crosses the same
		-- serialization boundary as publication. macOS exposes that stronger
		-- optional capability because its ordinary FileSystem.write contract is
		-- deliberately two-argument; passing a third Lua argument to write() merely
		-- discards it and leaves a race between this precheck and lock acquisition.
		local publisher
		if admission ~= nil then
			publisher = admitted_publisher
		else
			publisher = type(expected_source) == "table"
				and type(file_adapter.write_if_unchanged) == "function"
				and file_adapter.write_if_unchanged
				or file_adapter.write
		end
		if type(publisher) ~= "function" then
			return false, "explicit file adapter has no compatible publication method"
		end
		local call_ok, written, write_detail, receipt
		if admission ~= nil then
			call_ok, written, write_detail, receipt = pcall(publisher, path, content, expected_source, on_error, admission)
		elseif publisher == file_adapter.write_if_unchanged then
			call_ok, written, write_detail, receipt = pcall(publisher, path, content, expected_source, on_error)
		else
			call_ok, written, write_detail, receipt = pcall(publisher, path, content)
		end
		if type(on_error) ~= "function" and type(receipt) ~= "function" then receipt = nil end
		if call_ok and written == true then
			if receipt ~= nil and type(receipt) ~= "function" then return true, nil, receipt end
			return true
		end
		local detail = tostring((call_ok and write_detail) or written or "adapter write failed")
		if call_ok and receipt ~= nil then return false, detail, receipt end
		return false, detail
	end

	return publish(path, content, expected_source, admission)
end

--- Reads existing content through a classified platform adapter when supplied.
--- @param path string Source path.
--- @param file_adapter table|nil Platform file adapter.
--- @return string|nil content
--- @return string status `ok`, `absent`, or `error`.
--- @return string|nil detail
read_existing = function(path, file_adapter, on_error)
	if type(file_adapter) == "table" and type(file_adapter.read_with_status) == "function" then
		local call_ok, content, status, detail = pcall(file_adapter.read_with_status, path, on_error)
		if not call_ok then return nil, "error", tostring(content) end
		if status == "ok" and type(content) == "string" then return content, "ok" end
		if status == "absent" then return nil, "absent", detail end
		return nil, "error", detail or "classified read failed"
	end

	local content, detail, status = read_batch_source(path)
	if status == "absent" then return nil, "absent", detail end
	if status ~= "ok" then return nil, "error", detail end
	return content, "ok"
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Writes a TOML file from a hotstrings data structure.
--- @param path string Destination file path.
--- @param data table  The configuration dictionary.
--- @param expected_source table|nil Optional exact source precondition.
--- @return boolean, string|nil, string|nil Commit, error, and committed payload.
function M.write(path, data, file_adapter, create_only, expected_source)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "Invalid path provided for TOML write.")
		return false, "Invalid path provided."
	end

	Logger.debug(LOG, "Writing TOML configuration to disk…")
	data = type(data) == "table" and data or {}

	local order     = type(data.sections_order) == "table" and data.sections_order or {}
	local sections  = type(data.sections) == "table" and data.sections or {}
	local raw_desc  = type(data.meta) == "table" and data.meta.description or nil
	local meta_desc
	if type(raw_desc) == "table" then
		local code = i18n.get_locale()
		meta_desc = raw_desc[code] or raw_desc["fr"] or i18n.get("menu.hotstrings.personal_header")
	elseif type(raw_desc) == "string" then
		meta_desc = raw_desc
	else
		meta_desc = i18n.get("menu.hotstrings.personal_header")
	end

	local L = {}
	local function w(line) table.insert(L, line) end

	-- [_meta]
	w("[_meta]")
	w(string.format("description = \"%s\"", esc(meta_desc)))

	-- File-level tuning the loader consumes (delay, color, show_tooltip,
	-- priority). Emitted only when the caller carries it, so writers that
	-- never set tuning get byte-identical output to before.
	local meta_tuning = type(data.meta) == "table" and data.meta or nil
	if meta_tuning then
		if type(meta_tuning.delay) == "number" then
			w("delay = " .. tostring(meta_tuning.delay))
		end
		if type(meta_tuning.color) == "string" then
			w(string.format("color = \"%s\"", esc(meta_tuning.color)))
		end
		if type(meta_tuning.show_tooltip) == "boolean" then
			w("show_tooltip = " .. (meta_tuning.show_tooltip and "true" or "false"))
		end
		if type(meta_tuning.priority) == "number" then
			w("priority = " .. tostring(math.floor(meta_tuning.priority)))
		end
	end

	if #order > 0 then
		local parts = {}
		for _, name in ipairs(order) do
			if type(name) == "string" then
				table.insert(parts, "\"" .. esc(name) .. "\"")
			end
		end
		w("sections_order = [" .. table.concat(parts, ", ") .. "]")
	else
		w("sections_order = []")
	end

	-- [_meta.sections]
	local has_sections = false
	for _, name in ipairs(order) do
		if name ~= "-" and type(sections[name]) == "table" then
			has_sections = true
			break
		end
	end

	if has_sections then
		w("[_meta.sections]")
		for _, name in ipairs(order) do
			if name ~= "-" and type(sections[name]) == "table" then
				local desc = type(sections[name].description) == "string" and sections[name].description or name
				w(string.format("%s = \"%s\"", name, esc(desc)))
			end
		end
	end

	-- [_meta.section_delays]: per-section delay overrides the reader parses
	-- and the loader resolves. Sorted for a deterministic file; emitted only
	-- when at least one numeric override is present.
	if meta_tuning and type(meta_tuning.section_delays) == "table" then
		local delay_names = {}
		for name, value in pairs(meta_tuning.section_delays) do
			if type(name) == "string" and type(value) == "number" then
				delay_names[#delay_names + 1] = name
			end
		end
		table.sort(delay_names)
		if #delay_names > 0 then
			w("[_meta.section_delays]")
			for _, name in ipairs(delay_names) do
				w(name .. " = " .. tostring(meta_tuning.section_delays[name]))
			end
		end
	end

	-- [[section]] blocks
	for _, name in ipairs(order) do
		if name ~= "-" and type(sections[name]) == "table" then
			local sec = sections[name]
			w(string.format("[[%s]]", name))

			if type(sec.entries) == "table" then
				for _, e in ipairs(sec.entries) do
					if type(e) == "table" and type(e.trigger) == "string" and type(e.output) == "string" then
						local line = string.format(
							"\"%s\" = { output = \"%s\", is_word = %s, auto_expand = %s, is_case_sensitive = %s, final_result = %s",
							esc(e.trigger),
							esc(e.output),
							e.is_word           and "true" or "false",
							e.auto_expand       and "true" or "false",
							e.is_case_sensitive and "true" or "false",
							e.final_result      and "true" or "false"
						)
						if e.is_case_sensitive_strict == true then
							line = line .. ", is_case_sensitive_strict = true"
						end
						-- Individual collision-priority override — written only when
						-- set so entries that inherit the source default stay free
						-- of the key (matches the AHK editor's on-disk format).
						local prio = tonumber(e.priority)
						if prio then
							line = line .. ", priority = " .. tostring(math.floor(prio))
						end
						w(line .. " }")
					end
				end
			end
		end
	end

	local payload = table.concat(L, "\n")
	local published, publish_err
	local committed_payload = nil
	if create_only == true and type(file_adapter) == "table"
			and type(file_adapter.create_if_absent) == "function" then
		local call_ok, created, create_status, create_detail = pcall(
			file_adapter.create_if_absent,
			path,
			payload
		)
		published = call_ok and (created == true or create_status == "exists")
		publish_err = create_detail or create_status
		if call_ok and created == true then committed_payload = payload end
	else
		published, publish_err = publish_content(path, payload, file_adapter, expected_source)
		if published then committed_payload = payload end
	end
	if not published then
		Logger.error(LOG, "Failed to publish TOML file: %s.", tostring(publish_err))
		return false, "Erreur lors de la publication : " .. tostring(publish_err)
	end

	Logger.info(LOG, "TOML configuration saved successfully.")
	return true, nil, committed_payload
end



-- ===================================
-- ===== 3.2) Batch Write Method =====
-- ===================================

--- Whether two decoded TOML values are equal, tables compared by content.
--- @param left any
--- @param right any
--- @return boolean
local function same_value(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not same_value(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

--- Proves an integer token against an explicit native numeric intent.
--- The canonical decoder already validated the token grammar. Above the exact
--- double integer range, decoded equality cannot prove source integer identity.
--- This comparison grants no source, row, or native publication authority.
local function numeric_source_matches(document, shapes, path, value)
	if type(value) ~= "number" then return true end
	local parent = document
	for index = 1, #path - 1 do
		if type(parent) ~= "table" then return false end
		parent = parent[path[index]]
	end
	local saved = shapes.numbers[parent]
	saved = saved and saved[path[#path]]
	if not saved then return false end
	if saved.value > -9007199254740992 and saved.value < 9007199254740992 then return true end
	local token = saved.token
	local based = token:sub(1, 2):match("^0[box]$") ~= nil
	if not based and token:find("[%.eE]") then return true end
	-- Authenticated scalar literal precedence cannot replace proof of the
	-- explicit native numeric intent. Carried whole models keep their receipts.
	local desired = math_type and math_type(value) == "integer" and tostring(value)
		or string.format("%.0f", value)
	-- Rendering normalization is applied only to an already parsed decimal
	-- integer. Base-prefixed large integers require a real owned replacement.
	return not based and token:gsub("_", ""):gsub("^%+", "") == desired
end

--- The decoded key path a normalized batch row addresses.
--- @param row table Row with `segments` and `key`.
--- @return table path Table segments followed by the key.
local function row_path(row)
	local path = {}
	for index, segment in ipairs(row.segments) do path[index] = segment end
	path[#path + 1] = row.key
	return path
end

--- Whether prefix is a leading run of segments.
--- @param segments table
--- @param prefix table
--- @param fold boolean Compare without regard to letter case, as batch identities do.
--- @return boolean
local function has_prefix(segments, prefix, fold)
	if #prefix > #segments then return false end
	for index, segment in ipairs(prefix) do
		local left, right = segments[index], segment
		if fold then left, right = left:lower(), right:lower() end
		if left ~= right then return false end
	end
	return true
end

--- Classifies an existing scalar, absent deletion or direct scalar insertion.
--- This is descriptive source evidence; publication still owns every fence.
local function inline_scalar_state(document, path, row, shapes, allow_absent)
	if row.key == "" or row.key:find(".", 1, true) then return nil end
	local value = document
	for index, segment in ipairs(path) do
		if type(value) ~= "table" or shapes and shapes.arrays[value] then return nil end
		local matches = 0
		for key in pairs(value) do
			if type(key) == "string" and key:lower() == segment:lower() then matches = matches + 1 end
		end
		local child = value[segment]
		if child == nil then
			if allow_absent and matches == 0 then
				if row.delete then return "absent" end
				local desired, kind = row.value, type(row.value)
				if index == #path and (kind == "string" or kind == "boolean"
					or kind == "number" and desired == desired and math.abs(desired) ~= math.huge) then
					return "insert"
				end
			end
			return nil
		end
		if matches ~= 1 then return nil, nil, "ambiguous inline scalar case identity" end
		value = child
	end
	local kind, desired = type(value), row.value
	local scalar = kind == "string" or kind == "boolean"
		or kind == "number" and value == value and math.abs(value) ~= math.huge
	local desired_kind = type(desired)
	local desired_scalar = desired_kind == "string" or desired_kind == "boolean"
		or desired_kind == "number" and desired == desired and math.abs(desired) ~= math.huge
	if scalar and (row.delete or desired_scalar and desired_kind == kind) then return "scalar", value end
	return nil
end

--- Whether canonical fragments actually name one selected inline scalar.
local function inline_has_leaf(raw, path)
	local spans = inline_member_spans(raw)
	if not spans then return false end
	for _, member in ipairs(spans.members) do
		if has_prefix(path, member.segments, false) then
			if #path == #member.segments then return true end
			local remaining = {}
			for index = #member.segments + 1, #path do remaining[#remaining + 1] = path[index] end
			return inline_has_leaf(member.value_source, remaining)
		end
	end
	return false
end

--- Whether existing canonical inline parents own a proven absent final member.
--- Missing intermediate namespaces, dotted aliases and case twins are refused.
local function inline_can_insert(raw, path)
	local spans = inline_member_spans(raw)
	if not spans or #path == 0 then return false end
	for _, member in ipairs(spans.members) do
		if has_prefix(path, member.segments, true) or has_prefix(member.segments, path, true) then
			if not has_prefix(path, member.segments, false) or #path <= #member.segments then return false end
			local remaining = {}
			for index = #member.segments + 1, #path do remaining[#remaining + 1] = path[index] end
			return inline_can_insert(member.value_source, remaining)
		end
	end
	return #path == 1
end

--- Describes inline parents whose whole intersecting batch can retain leaves.
--- A returned path is a forwarding hint, never file or publication authority.
--- Unsupported groups retain their existing native whole-parent policy.
--- @param content string Complete exact TOML source.
--- @param updates table Explicit writer row array.
--- @return table|nil parents Detached canonical parent path set.
--- @return string|nil detail Invalid source or row description.
function M.source_inline_scalar_parents(content, updates)
	if type(content) ~= "string" or type(updates) ~= "table" then return nil, "inline source and rows are required" end
	local rows, identities, count = {}, {}, 0
	for key in pairs(updates) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil, "inline rows must be a dense array" end
		count = count + 1
	end
	for index = 1, count do
		local row = updates[index]
		if type(row) ~= "table" or type(row.section) ~= "string" or row.section == ""
			or type(row.key) ~= "string"
			or row.delete ~= nil and row.delete ~= true
			or row.delete and row.value ~= nil or not row.delete and row.value == nil then
			return nil, "invalid inline row at " .. index
		end
		local segments = KeyPath.parse(row.section, true)
		if not segments then return nil, "invalid inline row section" end
		local path = {}
		for part, segment in ipairs(segments) do path[part] = segment end
		path[#path + 1] = row.key
		local identity = KeyPath.render(segments):lower() .. "\0" .. row.key:lower()
		if identities[identity] then return nil, "duplicate inline row identity" end
		identities[identity] = true
		rows[#rows + 1] = { path = path, row = row }
	end
	local overlapping = {}
	for index, request in ipairs(rows) do
		for other_index = index + 1, #rows do
			local other = rows[other_index]
			if has_prefix(request.path, other.path, true) or has_prefix(other.path, request.path, true) then
				overlapping[index], overlapping[other_index] = true, true
			end
		end
	end
	local decoded, shapes = require("toml_codec.leaf_rows").decode_source(content)
	if type(decoded) ~= "table" or type(shapes) ~= "table" or type(shapes.arrays) ~= "table" then
		return nil, "inline source has no canonical shape evidence"
	end
	local scanned, detail = RecordScanner.scan_records(content, { quoted_headers = true })
	if not scanned then return nil, detail end
	local parents = {}
	for _, record in ipairs(scanned.records) do
		if record.addressable and #record.key_segments == 1 and record.first == record.last then
			local _, _, raw = RecordScanner.split_assignment(Bom.strip_prefix(scanned.lines[record.first].text))
			if raw and inline_member_spans(raw) then
				local parent_path = record.path
				local admitted, intersected = true, false
				for index, request in ipairs(rows) do
					local path, row = request.path, request.row
					if has_prefix(path, parent_path, true) or has_prefix(parent_path, path, true) then
						intersected = true
						if overlapping[index] or #path <= #parent_path or not has_prefix(path, parent_path, false) then admitted = false
						else
							local state = inline_scalar_state(decoded, path, row, shapes, true)
							local remaining = {}
							for index = #parent_path + 1, #path do remaining[#remaining + 1] = path[index] end
							if not state or state == "scalar" and not inline_has_leaf(raw, remaining)
								or state == "insert" and not inline_can_insert(raw, remaining) then admitted = false end
						end
					end
				end
				if admitted and intersected then parents[KeyPath.render(parent_path)] = true end
			end
		end
	end
	return parents
end

--- Prepares updates to a simple INI-style TOML file without publishing it
--- (the driver config.toml used by config_overrides and the onboarding wizard).
--- Each entry in `updates` is a table `{section, key, value}` where:
---   - `section` is a table path without brackets; owner-provided colon segments
---     are literal identities and are quoted when rendered, e.g. `ext:pack:group`.
---   - `key`     is the bare key name, e.g. `"Locale"`.
---   - `value`   is a Lua string, boolean, or number — serialised to TOML.
---   - `delete = true` removes the complete assignment instead of setting it.
---
--- Existing keys in the file are updated in-place; new sections and keys are
--- appended. Lines not matching any update are preserved verbatim. A key held
--- by table headers (`[t.key]`, `[t.key.sub]`, `[[t.key]]`) is replaced as one
--- value: those header lines and their assignments go, comments stay. A value
--- the file already holds in any spelling is left untouched, and a changed key
--- inside an unsupported container is refused with its path. Existing root inline
--- scalar tokens have canonical source spans; unrelated members stay exact. Strict
--- root dotted scalar records are replaced or removed through their own span.
--- @param path    string Absolute path to the config.toml to write.
--- @param updates table  Array of `{section=string, key=string, value=any}` tables.
--- @param file_adapter table|nil Classified platform file adapter.
--- @param expected_source table|nil Exact source precondition.
--- @param on_error function|nil Receives only fixed failure categories.
--- @return boolean prepared
--- @return string|nil detail
--- @return string|nil content Candidate bytes.
--- @return table|nil source Exact publication precondition.
function M.prepare_batch(path, updates, file_adapter, expected_source, on_error)
	local report = OperationReporter.new(on_error, Logger, LOG)
	if type(path) ~= "string" or path == "" then
		report("validation", "error", "batch_write: invalid path.")
		return false, "Invalid path."
	end
	if type(updates) ~= "table" then
		report("validation", "error", "batch_write: updates must be a table.")
		return false, "updates must be a table."
	end

	-- Validate the complete batch before acquiring the source snapshot. A bad
	-- row must be a typed refusal with zero filesystem side effects, and two
	-- rows must never compete for the same logical TOML key.
	local lookup, normalized = {}, {}
	local defaults = _sparse_defaults[refusal_key(path)]
	local function valid_value(value, visiting)
		local kind = type(value)
		if kind == "string" or kind == "boolean" or kind == "number" then return true end
		if kind ~= "table" or visiting[value] then return false end
		visiting[value] = true
		local count, numeric = 0, false
		for key, child in pairs(value) do
			count = count + 1
			if type(key) == "number" then
				if key < 1 or key % 1 ~= 0 then return false end
				numeric = true
			elseif type(key) ~= "string" then return false end
			if not valid_value(child, visiting) then return false end
		end
		if numeric then
			for index = 1, count do if value[index] == nil then return false end end
		end
		visiting[value] = nil
		return true
	end
	local function reject_row(index, reason)
		local detail = "Invalid update row at index " .. tostring(index) .. ": " .. reason
		report("preparation", "error", "batch_write: %s.", detail)
		return false, detail
	end
	for index, u in ipairs(updates) do
		local source_row = u
		if type(u) ~= "table" then return reject_row(index, "row must be a table") end
		if type(u.section) ~= "string" or u.section == "" then
			return reject_row(index, "section must be a non-empty string")
		end
		if type(u.key) ~= "string" or u.key == "" then
			return reject_row(index, "key must be a non-empty string")
		end
		if u.literal_key ~= nil and type(u.literal_key) ~= "boolean" then
			return reject_row(index, "literal_key capability must be Boolean")
		end
		if u.delete ~= nil and u.delete ~= true then
			return reject_row(index, "delete must be true when present")
		end
		if u.delete == true and u.value ~= nil then
			return reject_row(index, "delete and value are mutually exclusive")
		end
		if not u.delete and not valid_value(u.value, {}) then
			return reject_row(index, "value must contain only TOML scalars, dense arrays, or dictionaries")
		end
		local segments = KeyPath.parse(u.section, true)
		if not segments then return reject_row(index, "section is not a valid table path") end
		-- Manifest paths use semantic dots; a quoted literal dot must never inherit
		-- the neutral value of a different, nested configuration key.
		local literal_key = source_row.literal_key == true or source_row.source_shape ~= nil
		local manifest_path = table.concat(segments, ".") .. "." .. u.key
		if literal_key and u.key:find(".", 1, true) then manifest_path = nil end
		for _, segment in ipairs(segments) do
			if segment:find(".", 1, true) then manifest_path = nil; break end
		end
		local intent_ok, intentional = pcall(require("shortcuts.assignment").is_intentional, u)
		if not intent_ok then return reject_row(index, tostring(intentional)) end
		local personal_ok, personal_intent = pcall(require("hotstrings.personal_adoption").is_preference_intent, u)
		if not personal_ok then return reject_row(index, tostring(personal_intent)) end
		intentional = intentional or personal_intent
		if defaults and manifest_path and not u.delete and not intentional and defaults.has_default(manifest_path) then
			u = defaults.sparse_operation(manifest_path, u.value)
		end
		u = { section = KeyPath.render(segments), segments = segments, key = u.key, value = u.value, delete = u.delete,
			literal_key = literal_key, source_row = source_row }
		normalized[#normalized + 1] = u

		local sl = u.section:lower()
		local kl = u.key:lower()
		if not lookup[sl] then lookup[sl] = {} end
		if lookup[sl][kl] then return reject_row(index, "logical key is duplicated") end
		lookup[sl][kl] = u
	end
	updates = normalized

	-- Serialise a Lua value to a TOML literal
	local function to_toml_value(row)
		return row.source_literal or row.precise_literal or Codec.encode_value(row.value)
	end

	-- Read existing lines (empty table only when absence is proven).
	local lines = {}
	local source, read_status, read_detail = read_existing(path, file_adapter, on_error)
	if read_status == "error" then
		report("read", "error", "batch_write: refusing unreadable destination '%s' — %s.", path, tostring(read_detail))
		return false, tostring(read_detail)
	end
	if expected_source ~= nil then
		if type(expected_source) ~= "table" or expected_source.status ~= read_status
			or (read_status == "ok" and expected_source.content ~= source) then
			return false, "source changed before preparing the batch"
		end
	end
	for _, row in ipairs(updates) do
		local called, literal = pcall(require("toml_codec.leaf_rows").publication_literal, row.source_row, source or "")
		if not called then return false, tostring(literal) end
		row.source_literal = literal
		if require("toml_codec.leaf_rows").publication_capability(row.source_row) then row.literal_key = true end
	end
	local decoded_ok, decoded, source_shapes = pcall(require("toml_codec.leaf_rows").decode_source, source or "")
	if not decoded_ok or type(decoded) ~= "table" or type(source_shapes) ~= "table"
		or type(source_shapes.numbers) ~= "table" then
		return false, "the existing destination is not valid TOML"
	end
	if read_status == "absent" then
		source = ""
		local seeds = {}
		for _, seed in ipairs(_create_rows[refusal_key(path)] or {}) do
			local segments = KeyPath.parse(seed.section, true)
			if not segments then return false, "invalid creation seed section" end
			local row = { section = KeyPath.render(segments), segments = segments, key = seed.key, value = seed.value }
			local sl, kl = row.section:lower(), row.key:lower()
			if not (lookup[sl] and lookup[sl][kl]) then
				if not lookup[sl] then lookup[sl] = {} end
				lookup[sl][kl] = row
				seeds[#seeds + 1] = row
			end
		end
		if #seeds > 0 then
			for _, u in ipairs(updates) do seeds[#seeds + 1] = u end
			updates = seeds
		end
	end
	-- Finite scalar publication must retain the requested native numeric value.
	-- Reuse the optional codec; authentic source literals retain precedence and
	-- default encoding of every other value remains unchanged.
	local finite_owned = {}
	for _, row in ipairs(updates) do
		local value = row.value
		if not row.delete and type(value) == "number" and value == value and math.abs(value) ~= math.huge then
			local called, literal = pcall(require("toml_codec.leaf_rows").value_literal, value)
			if not called or type(literal) ~= "string" then return false, "the numeric scalar cannot be encoded exactly" end
			row.precise_literal = literal
			finite_owned[#finite_owned + 1] = { path = row_path(row), value = value }
		end
	end
	local scanned, scan_error = RecordScanner.scan_records(source, { quoted_headers = true })
	if not scanned then return false, scan_error end
	-- A case-insensitive batch cannot choose between two distinct source tables.
	-- Arrays of tables additionally need an element owner that this API lacks.
	local seen_headers = {}
	for _, header in ipairs(scanned.headers) do
		if header.segments then
			local identity = header.section:lower()
			if lookup[identity] and seen_headers[identity] then return false, "ambiguous batch table identity" end
			seen_headers[identity] = true
			if header.array then
				for _, row in ipairs(updates) do
					local inside = #row.segments >= #header.segments
					for index, segment in ipairs(header.segments) do
						if not row.segments[index] or row.segments[index]:lower() ~= segment:lower() then inside = false end
					end
					if inside then return false, "the batch cannot address an array-of-table element" end
				end
			end
		end
	end
	-- A key outside the bare alphabet, such as an extension pack's
	-- `ext:pack:stem`, is written quoted so it stays one key a reader can parse.
	local function key_text(key, literal)
		if key:match(literal and "^[A-Za-z0-9_%-]+$" or "^[A-Za-z0-9_%-%.]+$") then return key end
		return KeyPath.render({ key })
	end
	--- Edits only selected scalar tokens inside one authentic inline value.
	--- Canonical member spans retain all surviving fragments and delimiters;
	--- deleting a leaf never prunes or serializes its explicit parent value.
	local function edit_inline(raw, requests)
		local spans = inline_member_spans(raw)
		if not spans then return nil, "the inline scalar has no canonical source spans" end
		local fragments, claimed = {}, {}
		for _, member in ipairs(spans.members) do
			local direct, nested = nil, {}
			for index, request in ipairs(requests) do
				if has_prefix(request.path, member.segments, false) then
					if claimed[index] then return nil, "ambiguous inline scalar identity" end
					claimed[index] = true
					if #request.path == #member.segments then direct = request.row
					else
						local remaining = {}
						for part = #member.segments + 1, #request.path do remaining[#remaining + 1] = request.path[part] end
						nested[#nested + 1] = { path = remaining, row = request.row }
					end
				end
			end
			if direct and #nested > 0 then return nil, "the batch replaces an inline parent and its child" end
			local fragment = raw:sub(member.first, member.last)
			local replacement
			if direct and not direct.delete and not direct.inline_unchanged then replacement = to_toml_value(direct) end
			if #nested > 0 then
				local detail
				replacement, detail = edit_inline(member.value_source, nested)
				if not replacement then return nil, detail end
			end
			if replacement then
				fragment = raw:sub(member.first, member.value_first - 1) .. replacement
					.. raw:sub(member.value_last + 1, member.last)
			end
			if not direct or not direct.delete then fragments[#fragments + 1] = fragment end
		end
		local additions = {}
		for index, request in ipairs(requests) do
			if not claimed[index] then
				if request.row.delete or #request.path ~= 1 or not inline_can_insert(raw, request.path) then
					return nil, "the inline scalar has no exact existing parent"
				end
				additions[#additions + 1] = request
			end
		end
		table.sort(additions, function(left, right) return left.path[1] < right.path[1] end)
		local interior = #spans.members == 0 and raw:sub(spans.first + 1, spans.last - 1) or ""
		for _, request in ipairs(additions) do
			fragments[#fragments + 1] = key_text(request.path[1], true) .. " = " .. to_toml_value(request.row)
		end
		return raw:sub(1, spans.first) .. interior .. table.concat(fragments, ",") .. raw:sub(spans.last)
	end

	local applied, replacements, removed = {}, {}, {}
	local root_owned = {}
	for _, record in ipairs(scanned.records) do
		-- A strict root dotted assignment names one scalar leaf without a header.
		-- Its physical record owns only that leaf; inline scalar members use the
		-- canonical span capability below, and array elements remain unsupported.
		local root_path = record.header == nil and record.key_text and KeyPath.parse(record.key_text) or nil
		local inline_path, relative_inline = root_path, false
		if record.addressable and #record.key_segments == 1 then
			inline_path, relative_inline = record.path, true
		end
		if inline_path and (relative_inline or #inline_path == 1) and record.first == record.last then
			local first_text = scanned.lines[record.first].text
			local _, _, rhs = RecordScanner.split_assignment(Bom.strip_prefix(first_text))
			local spans = rhs and inline_member_spans(rhs)
			if spans then
				local requests = {}
				for _, u in ipairs(updates) do
					local path = row_path(u)
					if relative_inline and has_prefix(path, inline_path, true) and not has_prefix(path, inline_path, false) then
						return false, "the section inline scalar has no exact case identity"
					end
					if #path > #inline_path and has_prefix(path, inline_path, false) and not u.key:find(".", 1, true) then
						local state, existing, state_detail = inline_scalar_state(decoded, path, u, source_shapes, true)
						if state_detail then return false, state_detail end
						local kind, desired = type(existing), u.value
						local remaining = {}
						for index = #inline_path + 1, #path do remaining[#remaining + 1] = path[index] end
						if state == "insert" and not inline_can_insert(rhs, remaining) then
							return false, "the inline scalar has no exact existing parent"
						end
						if state == "scalar" or state == "insert" then
							for _, other in ipairs(updates) do
								local other_path = row_path(other)
								if other ~= u and (has_prefix(path, other_path, true) or has_prefix(other_path, path, true)) then
									return false, "the batch replaces an inline parent and its child"
								end
							end
							local identity = u.section:lower() .. "\0" .. u.key:lower()
							if applied[identity] then return false, "ambiguous batch key identity" end
							applied[identity] = true
							root_owned[#root_owned + 1] = { path = path, row = u }
							u.inline_unchanged = not u.delete and same_value(existing, desired)
								and (kind ~= "number" or existing ~= 0 or 1 / existing == 1 / desired)
								and (not u.source_literal or require("toml_codec.leaf_rows").value_literal(existing) == u.source_literal)
								and numeric_source_matches(decoded, source_shapes, path, desired)
							requests[#requests + 1] = { path = remaining, row = u }
						end
					end
				end
				if #requests > 0 then
					local called, patched, detail = pcall(edit_inline, rhs, requests)
					if not called then return false, "the inline scalar cannot be encoded exactly" end
					if not patched then return false, detail end
					replacements[record.first] = first_text:sub(1, #first_text - #rhs) .. patched
						.. scanned.lines[record.first].eol
				end
			end
		end
		-- A section-relative dotted record has the same physical scalar owner:
		-- its authentic, non-array header contributes the leading path segments.
		-- Keep single keys, literal dotted leaves, and unaddressable records on
		-- their existing paths rather than inferring a new table or parent.
		local scalar_path, relative_scalar = root_path, false
		if record.addressable and #record.key_segments > 1 then
			local relative = KeyPath.parse(record.key_text)
			if relative then
				scalar_path, relative_scalar = {}, true
				for _, segment in ipairs(record.header.segments) do scalar_path[#scalar_path + 1] = segment end
				for _, segment in ipairs(relative) do scalar_path[#scalar_path + 1] = segment end
			end
		end
		if scalar_path and #scalar_path > 1 and not scalar_path[#scalar_path]:find(".", 1, true) then
			local parents = {}
			for index = 1, #scalar_path - 1 do parents[index] = scalar_path[index] end
			local sl, kl = KeyPath.render(parents):lower(), scalar_path[#scalar_path]:lower()
			local u = lookup[sl] and lookup[sl][kl]
			local exact = u ~= nil and u.key == scalar_path[#scalar_path] and #u.segments == #parents
			for index, segment in ipairs(parents) do
				if not u or u.segments[index] ~= segment then exact = false end
			end
			if relative_scalar and u and not exact then return false, "the section scalar has no exact case identity" end
			local existing = decoded
			for _, segment in ipairs(scalar_path) do
				if type(existing) ~= "table" then existing = nil; break end
				existing = existing[segment]
			end
			local kind = type(existing)
			local scalar = kind == "string" or kind == "boolean"
				or (kind == "number" and existing == existing and math.abs(existing) ~= math.huge)
			local desired = u and u.value
			local desired_kind = type(desired)
			local desired_scalar = desired_kind == "string" or desired_kind == "boolean"
				or (desired_kind == "number" and desired == desired and math.abs(desired) ~= math.huge)
			if exact and scalar and (u.delete or desired_scalar and (not relative_scalar or desired_kind == kind)) then
				if relative_scalar then
					local parent = decoded
					for _, segment in ipairs(scalar_path) do
						local matches = 0
						for key in pairs(parent) do
							if type(key) == "string" and key:lower() == segment:lower() then matches = matches + 1 end
						end
						if matches ~= 1 then return false, "ambiguous section scalar case identity" end
						parent = parent[segment]
					end
				end
				local identity = sl .. "\0" .. kl
				if applied[identity] then return false, "ambiguous batch key identity" end
				applied[identity] = true
				root_owned[#root_owned + 1] = { path = scalar_path, row = u }
				local unchanged = not u.delete and same_value(existing, u.value)
					and (kind ~= "number" or existing ~= 0 or 1 / existing == 1 / u.value)
					and (not u.source_literal or require("toml_codec.leaf_rows").value_literal(existing) == u.source_literal)
					and numeric_source_matches(decoded, source_shapes, scalar_path, u.value)
				if not unchanged then
					for _, other in ipairs(updates) do
						local inner = row_path(other)
						if other ~= u and #inner > #scalar_path and has_prefix(inner, scalar_path, true) then
							return false, "the batch replaces " .. KeyPath.render(scalar_path)
								.. " and also writes " .. KeyPath.render(inner) .. " inside it"
						end
					end
					for index = record.first, record.last do removed[index] = true end
					local first_text = scanned.lines[record.first].text
					local prefix = record.first == 1 and first_text:sub(1, #first_text - #Bom.strip_prefix(first_text)) or ""
					if u.delete and prefix ~= "" then replacements[record.first] = prefix end
					if not u.delete then
						-- This new scalar capability uses the existing optional precise codec;
						-- default encoding of other value kinds remains unchanged.
						local literal_ok, literal = pcall(function()
							return u.source_literal or require("toml_codec.leaf_rows").value_literal(u.value)
						end)
						if not literal_ok then return false, "the root scalar cannot be encoded exactly" end
						replacements[record.first] = prefix .. record.key_text .. " = " .. literal
							.. scanned.lines[record.last].eol
					end
				end
			end
		end
		local section, key = record.section, record.key
		if not record.addressable and record.quoted then section, key = record.quoted.section, record.quoted.key end
		if record.quoted or (record.addressable and #record.key_segments == 1) then
			local sl, kl = section:lower(), key:lower()
			local u = lookup[sl] and lookup[sl][kl]
			if u and (not record.quoted or not key:find(".", 1, true) or u.literal_key) then
				if applied[sl .. "\0" .. kl] then return false, "ambiguous batch key identity" end
				applied[sl .. "\0" .. kl] = true
				for index = record.first, record.last do removed[index] = true end
				if not u.delete then
					replacements[record.first] = key_text(u.key, u.literal_key) .. " = " .. to_toml_value(u)
						.. scanned.lines[record.last].eol
				end
			end
		end
	end

	-- A key no `key = value` line holds may still exist in another spelling.
	-- Older macOS builds wrote every empty map as its own header, and structured
	-- values (a shortcut's mods and key) or a hand-written [[list]] are table
	-- headers too: the ordinary save addresses those keys as whole values. The
	-- same value needs no change; otherwise the header lines and their
	-- assignments go (comments and blank lines stay) and the new value is one
	-- line. An inline table or a root-level entry cannot be patched by line.
	local pending = {}   -- section_original → list of update entries
	for _, u in ipairs(updates) do
		local sl = u.section:lower()
		local kl = u.key:lower()
		local identity = sl .. "\0" .. kl
		if not applied[identity] then
			local node = decoded
			for _, segment in ipairs(u.segments) do
				node = type(node) == "table" and node[segment] or nil
			end
			local existing = nil
			if type(node) == "table" then existing = node[u.key] end
			if existing ~= nil and not u.delete and same_value(existing, u.value)
				and (not u.source_literal or require("toml_codec.leaf_rows").value_literal(existing) == u.source_literal)
				and numeric_source_matches(decoded, source_shapes, row_path(u), u.value) then
				applied[identity] = true
			elseif existing ~= nil then
				local path = row_path(u)
				local owned = {}
				for _, header in ipairs(scanned.headers) do
					if header.segments and has_prefix(header.segments, path, false) then owned[header] = true end
				end
				if next(owned) == nil then
					return false, "the batch cannot address " .. KeyPath.render(path)
						.. ": an inline table or a root-level entry holds it; write it under a ["
						.. u.section .. "] header"
				end
				for _, other in ipairs(updates) do
					local inner = row_path(other)
					if other ~= u and #inner > #path and has_prefix(inner, path, true) then
						return false, "the batch replaces " .. KeyPath.render(path)
							.. " and also writes " .. KeyPath.render(inner) .. " inside it"
					end
				end
				for header in pairs(owned) do removed[header.index] = true end
				for _, record in ipairs(scanned.records) do
					if record.header and owned[record.header] then
						for index = record.first, record.last do removed[index] = true end
					end
				end
			end
		end
		if not u.delete and not applied[identity] then
			if not pending[u.section] then pending[u.section] = {} end
			pending[u.section][#pending[u.section] + 1] = u
		end
	end

	local insertions = {}
	for _, header in ipairs(scanned.headers) do
		if header.section and not header.array and not removed[header.index] then
			for section, entries in pairs(pending) do
				if section:lower() == header.section:lower() then
					insertions[header.index] = entries
					pending[section] = nil
				end
			end
		end
	end
	for index, line in ipairs(scanned.lines) do
		if replacements[index] then lines[#lines + 1] = replacements[index]
		elseif not removed[index] then lines[#lines + 1] = line.text .. line.eol end
		if insertions[index] then
			if line.eol == "" then lines[#lines + 1] = "\n" end
			for _, u in ipairs(insertions[index]) do
				lines[#lines + 1] = key_text(u.key, u.literal_key) .. " = " .. to_toml_value(u) .. "\n"
			end
		end
	end

	local pending_sections = {}
	for section in pairs(pending) do pending_sections[#pending_sections + 1] = section end
	table.sort(pending_sections)
	for _, section in ipairs(pending_sections) do
		local entries = pending[section]
		lines[#lines + 1] = "\n[" .. section .. "]\n"
		for _, u in ipairs(entries) do
			lines[#lines + 1] = key_text(u.key, u.literal_key) .. " = " .. to_toml_value(u) .. "\n"
		end
	end

	local content = table.concat(lines)
	local content_ok, content_value, candidate_shapes = pcall(require("toml_codec.leaf_rows").decode_source, content)
	if not content_ok or type(content_value) ~= "table" or type(candidate_shapes) ~= "table"
		or type(candidate_shapes.numbers) ~= "table" then
		return false, "the batch cannot address the destination without ambiguous TOML keys"
	end
	-- Parsing proves syntax; this capability additionally proves the requested
	-- owned scalar before a native publisher can acknowledge the candidate.
	for _, owned in ipairs(root_owned) do
		local actual = content_value
		for _, segment in ipairs(owned.path) do
			if type(actual) ~= "table" then actual = nil; break end
			actual = actual[segment]
		end
		local wanted = owned.row.value
		local exact = owned.row.delete and actual == nil or not owned.row.delete
			and type(actual) == type(wanted) and actual == wanted
			and (type(wanted) ~= "number" or wanted ~= 0 or 1 / actual == 1 / wanted)
		if not exact then return false, "the root scalar candidate differs from the requested value" end
	end
	for _, owned in ipairs(finite_owned) do
		local actual = content_value
		for _, segment in ipairs(owned.path) do
			if type(actual) ~= "table" then actual = nil; break end
			actual = actual[segment]
		end
		if type(actual) ~= "number" or actual ~= owned.value
			or owned.value == 0 and 1 / actual ~= 1 / owned.value
			or not numeric_source_matches(content_value, candidate_shapes, owned.path, owned.value) then
			return false, "the numeric scalar candidate differs from the requested value"
		end
	end
	return true, nil, content, {
		status = read_status,
		content = source,
	}
end

--- Prepares and atomically publishes one explicit set/delete batch.
--- @param admission function|nil Captured final logical admission.
--- @param path string Destination path.
--- @param updates table Explicit set/delete operations.
--- @param file_adapter table|nil Platform file adapter.
--- @param expected_source table|nil Exact source precondition.
--- @param on_error function|nil Receives only fixed failure categories.
--- @return boolean committed
--- @return string|nil detail
--- @return string|nil content Committed bytes.
--- @return table|nil receipt Optional private native publication/release capability.
--- @return string|nil candidate Prepared bytes only when a native receipt is returned.
function M.batch_write(path, updates, file_adapter, expected_source, on_error, admission)
	if admission ~= nil and type(admission) ~= "function" then return false, "publication admission must be a function" end
	local report = OperationReporter.new(on_error, Logger, LOG)
	local prepared, detail, content, source = M.prepare_batch(path, updates, file_adapter, expected_source, on_error)
	if not prepared then return false, detail end
	local published, publish_err, receipt = publish_content(path, content, file_adapter, source, on_error, admission)
	if not published then
		report("publication", "error", "batch_write: publication to '%s' failed — %s.", path, tostring(publish_err))
		if receipt ~= nil then return false, tostring(publish_err), nil, receipt, content end
		return false, tostring(publish_err)
	end
	Logger.info(LOG, "batch_write: committed %d operation(s) to '%s'.", #updates, path)
	if receipt ~= nil then return true, nil, content, receipt, content end
	return true, nil, content
end



-- ========================================
-- ===== 3.3) Exact Byte Transactions =====
-- ========================================

--- Reads a file and classifies the outcome without confusing an I/O failure
--- with absence, through the platform adapter when one is supplied.
--- @param path string Source path.
--- @param file_adapter table|nil Platform file adapter.
--- @param on_error function|nil Receives only fixed failure categories.
--- @return string|nil content Exact bytes when the status is `ok`.
--- @return string status `ok`, `absent`, or `error`.
--- @return string|nil detail Failure detail.
function M.read_classified(path, file_adapter, on_error)
	return read_existing(path, file_adapter, on_error)
end

--- @param admission function|nil Captured final logical admission.
--- Publishes exact bytes only while the destination still matches
--- expected_source. `{ status = "absent" }` creates a file that must not exist,
--- and `{ status = "ok", content = … }` replaces exactly the bytes a caller read.
--- @param path string Destination path.
--- @param content string Complete payload.
--- @param file_adapter table|nil Platform file adapter.
--- @param expected_source table `{ status, content }` precondition.
--- @param on_error function|nil Receives only fixed failure categories.
--- @return boolean committed
--- @return string|nil error_message
--- @return function|table|nil receipt Ordinary cleanup callback or opaque private native receipt.
function M.publish_if_unchanged(path, content, file_adapter, expected_source, on_error, admission)
	if type(path) ~= "string" or path == "" or type(content) ~= "string"
		or type(expected_source) ~= "table" then
		return false, "publish_if_unchanged needs a path, a string payload and a source precondition"
	end
	return publish_content(path, content, file_adapter, expected_source, on_error, admission)
end

--- Settles one private native publication cleanup receipt without writing a file.
--- The owner retains a refused or malformed terminal; only literal settlement
--- and effect flags can acknowledge its exact publication boundary.
--- @param record table Owner's private publication_cleanup and effect state.
--- @return boolean settled
--- @return string|nil detail
--- @return boolean|nil published Effect receipt, nil when no cleanup was owed.
function M.retry_publication_cleanup(record)
	if record.publication_cleanup == nil then return true, nil, record.publication_effect end
	local called, settled, detail, published = pcall(record.publication_cleanup)
	if not called or settled ~= true or type(published) ~= "boolean" then
		return false, tostring(called and detail or settled or "publication cleanup remains pending")
	end
	record.publication_cleanup, record.publication_effect = nil, published
	return true, nil, published
end

--- Removes a file only while it still holds exactly the bytes a caller published.
--- This restores a proven absence: a created file that was edited since is kept.
--- Uses an optional adapter-owned conditional mutex transaction when available.
--- Legacy callers retain the compare-before-unlink fallback; owners requiring
--- the stronger capability refuse adapters which cannot provide it.
--- @param path string File to remove.
--- @param file_adapter table|nil Platform file adapter.
--- @param expected_source table `{ status = "ok", content = string }` precondition.
--- @param operation_policy table|nil `{ require_conditional, on_error }`.
--- @return boolean removed
--- @return string|nil error_message
--- @return table|function|nil receipt Private physical inverse or ordinary release-only owner.
function M.remove_if_unchanged(path, file_adapter, expected_source, operation_policy)
	if type(path) ~= "string" or path == "" or type(expected_source) ~= "table"
		or expected_source.status ~= "ok" or type(expected_source.content) ~= "string" then
		return false, "remove_if_unchanged needs a path and the exact bytes it must still hold"
	end
	local refusal = _refused_writes[refusal_key(path)]
	if refusal then
		return false, "writes to this file are refused for the session: " .. refusal
	end
	local on_error = operation_policy and operation_policy.on_error
	if type(file_adapter) == "table" and type(file_adapter.remove_if_unchanged) == "function" then
		local called, removed, detail, receipt, retry_cleanup = pcall(file_adapter.remove_if_unchanged, path, expected_source, on_error)
		if not called then return false, tostring(removed) end
		if operation_policy and operation_policy.require_conditional == true then
			return removed == true, detail, receipt
		end
		-- Ordinary inverse owners keep their exact release-only capability. A
		-- private program inverse separately requires the guarded rich receipt.
		if removed == true then return true end
		local refusal_detail = tostring(detail or "conditional removal refused")
		if type(receipt) == "function" then return false, refusal_detail, receipt end
		if type(receipt) == "table" and receipt.path == path
			and type(receipt.expected) == "table" and receipt.expected.status == expected_source.status
			and receipt.expected.content == expected_source.content and type(retry_cleanup) == "function" then
			return false, refusal_detail, retry_cleanup
		end
		return false, refusal_detail
	end
	if operation_policy and operation_policy.require_conditional == true then
		return false, "conditional removal capability is unavailable"
	end
	local current, status, detail = read_existing(path, file_adapter, on_error)
	if status ~= "ok" or current ~= expected_source.content then
		return false, "source changed before removal: " .. tostring(detail or status)
	end
	local remover = os.remove
	if type(file_adapter) == "table" then
		remover = file_adapter.remove_exact or file_adapter.delete
		if type(remover) ~= "function" then
			return false, "explicit file adapter has no removal method"
		end
	end
	local call_ok, removed, remove_detail = pcall(remover, path)
	if call_ok and removed == true then return true end
	return false, tostring((call_ok and remove_detail) or removed or "removal failed")
end

--- Refuses every later publication to path for the rest of the session. There
--- is deliberately no way to lift it: the file stays untouched until a restart
--- re-evaluates it.
--- @param path string Destination path.
--- @param reason string Why the file must not be written (logged by callers).
function M.refuse_writes(path, reason)
	if type(path) ~= "string" or path == "" or type(reason) ~= "string" or reason == "" then
		error("refuse_writes needs a path and a reason", 2)
	end
	_refused_writes[refusal_key(path)] = reason
end

--- Why writes to path are refused this session, or nil.
--- @param path string Destination path.
--- @return string|nil reason
function M.write_refusal(path)
	if type(path) ~= "string" then return nil end
	return _refused_writes[refusal_key(path)]
end

--- Registers the rows batch_write adds whenever it creates path from absence,
--- replacing any earlier registration. A whole-file writer that creates the
--- file reads them through M.create_rows.
--- @param path string Destination path.
--- @param rows table Array of `{ section, key, value }` with scalar values.
function M.set_create_rows(path, rows)
	if type(path) ~= "string" or path == "" or type(rows) ~= "table" then
		error("set_create_rows needs a path and an array of rows", 2)
	end
	local copy = {}
	for index, row in ipairs(rows) do
		local value_type = type(row) == "table" and type(row.value) or nil
		if type(row) ~= "table" or type(row.section) ~= "string" or row.section == ""
			or type(row.key) ~= "string" or row.key == ""
			or (value_type ~= "string" and value_type ~= "number" and value_type ~= "boolean") then
			error("set_create_rows: row " .. index .. " must be { section, key, scalar value }", 2)
		end
		copy[index] = { section = row.section, key = row.key, value = row.value }
	end
	_create_rows[refusal_key(path)] = copy
end

--- Registers the neutral-value contract for one configuration destination.
--- Data files stay outside this registry so their false values remain explicit.
--- @param path string Configuration file path.
--- @param defaults table Manifest reader with sparse operation methods.
function M.set_sparse_defaults(path, defaults)
	assert(type(path) == "string" and path ~= "" and type(defaults) == "table"
		and type(defaults.has_default) == "function" and type(defaults.sparse_operation) == "function",
		"sparse defaults require a configuration path and a complete manifest reader")
	local key = refusal_key(path)
	assert(_sparse_defaults[key] == nil or _sparse_defaults[key] == defaults,
		"configuration sparse-default owner cannot be replaced")
	_sparse_defaults[key] = defaults
end

--- The rows a writer creating path must add, as a fresh copy, or nil.
--- @param path string Destination path.
--- @return table|nil rows
function M.create_rows(path)
	if type(path) ~= "string" then return nil end
	local rows = _create_rows[refusal_key(path)]
	if not rows then return nil end
	local copy = {}
	for index, row in ipairs(rows) do
		copy[index] = { section = row.section, key = row.key, value = row.value }
	end
	return copy
end

return M
