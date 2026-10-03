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
local KeyPath = require("toml_codec.key_path")
local Codec = require("toml_codec.codec")





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

--- Publishes complete content through a same-directory staging file.
--- A protected call only proves that Lua did not raise; file methods also
--- return nil/false for ordinary I/O failures, so every terminal result is
--- checked before the live path can be replaced.
--- @param path string Destination path.
--- @param content string Complete serialized content.
--- @param expected_source table|nil Optional `{ status, content }` precondition.
--- @return boolean committed
--- @return string|nil error_message
local function publish(path, content, expected_source)
	-- A synchronous fallback can acknowledge the current image after its exact
	-- source recheck. Explicit adapters retain their own serialization boundary.
	if type(expected_source) == "table" and expected_source.status == "ok"
		and expected_source.content == content then
		local current, detail, status = read_batch_source(path)
		if status ~= "ok" or current ~= content then
			return false, "source changed before unchanged acknowledgement: " .. tostring(detail or status)
		end
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

	local rename_ok, renamed, rename_err = pcall(os.rename, tmp_path, path)
	-- POSIX replaces an existing destination atomically. Windows' C runtime does
	-- not, so keep the old file recoverable while replacing it on test/Linux
	-- hosts running under Windows.
	if (not rename_ok or renamed ~= true) and package.config:sub(1, 1) == "\\" then
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
local function publish_content(path, content, file_adapter, expected_source)
	local refusal = _refused_writes[refusal_key(path)]
	if refusal then
		return false, "writes to this file are refused for the session: " .. refusal
	end
	if type(file_adapter) == "table" then
		if type(expected_source) == "table" then
			local current, current_status, current_detail = read_existing(path, file_adapter)
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
		local publisher = type(expected_source) == "table"
			and type(file_adapter.write_if_unchanged) == "function"
			and file_adapter.write_if_unchanged
			or file_adapter.write
		if type(publisher) ~= "function" then
			return false, "explicit file adapter has no compatible publication method"
		end
		local call_ok, written, write_detail = pcall(publisher, path, content, expected_source)
		if call_ok and written == true then return true end
		return false, tostring((call_ok and write_detail) or written or "adapter write failed")
	end

	return publish(path, content, expected_source)
end

--- Reads existing content through a classified platform adapter when supplied.
--- @param path string Source path.
--- @param file_adapter table|nil Platform file adapter.
--- @return string|nil content
--- @return string status `ok`, `absent`, or `error`.
--- @return string|nil detail
read_existing = function(path, file_adapter)
	if type(file_adapter) == "table" and type(file_adapter.read_with_status) == "function" then
		local call_ok, content, status, detail = pcall(file_adapter.read_with_status, path)
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
--- inside an inline table or a root-level entry is refused with its path.
--- @param path    string Absolute path to the config.toml to write.
--- @param updates table  Array of `{section=string, key=string, value=any}` tables.
--- @param file_adapter table|nil Classified platform file adapter.
--- @param expected_source table|nil Exact source precondition.
--- @return boolean prepared
--- @return string|nil detail
--- @return string|nil content Candidate bytes.
--- @return table|nil source Exact publication precondition.
function M.prepare_batch(path, updates, file_adapter, expected_source)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "batch_write: invalid path.")
		return false, "Invalid path."
	end
	if type(updates) ~= "table" then
		Logger.error(LOG, "batch_write: updates must be a table.")
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
		Logger.error(LOG, "batch_write: %s.", detail)
		return false, detail
	end
	for index, u in ipairs(updates) do
		if type(u) ~= "table" then return reject_row(index, "row must be a table") end
		if type(u.section) ~= "string" or u.section == "" then
			return reject_row(index, "section must be a non-empty string")
		end
		if type(u.key) ~= "string" or u.key == "" then
			return reject_row(index, "key must be a non-empty string")
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
		local manifest_path = table.concat(segments, ".") .. "." .. u.key
		for _, segment in ipairs(segments) do
			if segment:find(".", 1, true) then manifest_path = nil; break end
		end
		local intent_ok, intentional = pcall(require("shortcuts.assignment").is_intentional, u)
		if not intent_ok then return reject_row(index, tostring(intentional)) end
		if defaults and manifest_path and not u.delete and not intentional and defaults.has_default(manifest_path) then
			u = defaults.sparse_operation(manifest_path, u.value)
		end
		u = { section = KeyPath.render(segments), segments = segments, key = u.key, value = u.value, delete = u.delete }
		normalized[#normalized + 1] = u

		local sl = u.section:lower()
		local kl = u.key:lower()
		if not lookup[sl] then lookup[sl] = {} end
		if lookup[sl][kl] then return reject_row(index, "logical key is duplicated") end
		lookup[sl][kl] = u
	end
	updates = normalized

	-- Serialise a Lua value to a TOML literal
	local to_toml_value = Codec.encode_value

	-- Read existing lines (empty table only when absence is proven).
	local lines = {}
	local source, read_status, read_detail = read_existing(path, file_adapter)
	if read_status == "error" then
		Logger.error(LOG, "batch_write: refusing unreadable destination '%s' — %s.", path, tostring(read_detail))
		return false, tostring(read_detail)
	end
	if expected_source ~= nil then
		if type(expected_source) ~= "table" or expected_source.status ~= read_status
			or (read_status == "ok" and expected_source.content ~= source) then
			return false, "source changed before preparing the batch"
		end
	end
	local decoded_ok, decoded = pcall(Codec.decode, source or "")
	if not decoded_ok or type(decoded) ~= "table" then
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
	-- A key outside the bare and dotted alphabet, such as an extension pack's
	-- `ext:pack:stem`, is written quoted so it stays one key a reader can parse.
	local function key_text(key)
		if key:match("^[A-Za-z0-9_%-%.]+$") then return key end
		return KeyPath.render({ key })
	end
	local applied, replacements, removed = {}, {}, {}
	for _, record in ipairs(scanned.records) do
		local section, key = record.section, record.key
		if not record.addressable and record.quoted then section, key = record.quoted.section, record.quoted.key end
		if record.addressable or record.quoted then
			local sl, kl = section:lower(), key:lower()
			local u = lookup[sl] and lookup[sl][kl]
			if u then
				if applied[sl .. "\0" .. kl] then return false, "ambiguous batch key identity" end
				applied[sl .. "\0" .. kl] = true
				for index = record.first, record.last do removed[index] = true end
				if not u.delete then
					replacements[record.first] = key_text(u.key) .. " = " .. to_toml_value(u.value)
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
			if existing ~= nil and not u.delete and same_value(existing, u.value) then
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
				lines[#lines + 1] = key_text(u.key) .. " = " .. to_toml_value(u.value) .. "\n"
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
			lines[#lines + 1] = key_text(u.key) .. " = " .. to_toml_value(u.value) .. "\n"
		end
	end

	local content = table.concat(lines)
	local content_ok, content_value = pcall(Codec.decode, content)
	if not content_ok or type(content_value) ~= "table" then
		return false, "the batch cannot address the destination without ambiguous TOML keys"
	end
	return true, nil, content, {
		status = read_status,
		content = source,
	}
end

--- Prepares and atomically publishes one explicit set/delete batch.
--- @param path string Destination path.
--- @param updates table Explicit set/delete operations.
--- @param file_adapter table|nil Platform file adapter.
--- @param expected_source table|nil Exact source precondition.
--- @return boolean committed
--- @return string|nil detail
--- @return string|nil content Committed bytes.
function M.batch_write(path, updates, file_adapter, expected_source)
	local prepared, detail, content, source = M.prepare_batch(path, updates, file_adapter, expected_source)
	if not prepared then return false, detail end
	local published, publish_err = publish_content(path, content, file_adapter, source)
	if not published then
		Logger.error(LOG, "batch_write: publication to '%s' failed — %s.", path, tostring(publish_err))
		return false, tostring(publish_err)
	end
	Logger.info(LOG, "batch_write: committed %d operation(s) to '%s'.", #updates, path)
	return true, nil, content
end



-- ========================================
-- ===== 3.3) Exact Byte Transactions =====
-- ========================================

--- Reads a file and classifies the outcome without confusing an I/O failure
--- with absence, through the platform adapter when one is supplied.
--- @param path string Source path.
--- @param file_adapter table|nil Platform file adapter.
--- @return string|nil content Exact bytes when the status is `ok`.
--- @return string status `ok`, `absent`, or `error`.
--- @return string|nil detail Failure detail.
function M.read_classified(path, file_adapter)
	return read_existing(path, file_adapter)
end

--- Publishes exact bytes only while the destination still matches
--- expected_source. `{ status = "absent" }` creates a file that must not exist,
--- and `{ status = "ok", content = … }` replaces exactly the bytes a caller read.
--- @param path string Destination path.
--- @param content string Complete payload.
--- @param file_adapter table|nil Platform file adapter.
--- @param expected_source table `{ status, content }` precondition.
--- @return boolean committed
--- @return string|nil error_message
function M.publish_if_unchanged(path, content, file_adapter, expected_source)
	if type(path) ~= "string" or path == "" or type(content) ~= "string"
		or type(expected_source) ~= "table" then
		return false, "publish_if_unchanged needs a path, a string payload and a source precondition"
	end
	return publish_content(path, content, file_adapter, expected_source)
end

--- Removes a file only while it still holds exactly the bytes a caller published.
--- This restores a proven absence: a created file that was edited since is kept.
--- The macOS adapter exposes `remove_exact`, the Linux one `delete`; an explicit
--- adapter with neither is refused instead of reaching around it.
--- @param path string File to remove.
--- @param file_adapter table|nil Platform file adapter.
--- @param expected_source table `{ status = "ok", content = string }` precondition.
--- @return boolean removed
--- @return string|nil error_message
function M.remove_if_unchanged(path, file_adapter, expected_source)
	if type(path) ~= "string" or path == "" or type(expected_source) ~= "table"
		or expected_source.status ~= "ok" or type(expected_source.content) ~= "string" then
		return false, "remove_if_unchanged needs a path and the exact bytes it must still hold"
	end
	local refusal = _refused_writes[refusal_key(path)]
	if refusal then
		return false, "writes to this file are refused for the session: " .. refusal
	end
	local current, status, detail = read_existing(path, file_adapter)
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
