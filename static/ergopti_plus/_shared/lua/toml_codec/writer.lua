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





-- ====================================
-- ====================================
-- ======= 0/ File Transactions =======
-- ====================================
-- ====================================

local read_batch_source

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
		return "{" .. (canon or (name:sub(1,1):upper() .. name:sub(2):lower())) .. "}"
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
	if type(file_adapter) == "table" and type(file_adapter.write) == "function" then
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

--- Writes or updates a set of key/value pairs in a simple INI-style TOML file
--- (the driver config.toml used by config_overrides and the onboarding wizard).
--- Each entry in `updates` is a table `{section, key, value}` where:
---   - `section` is the TOML section header without brackets, e.g. `"Script"`.
---   - `key`     is the bare key name, e.g. `"Locale"`.
---   - `value`   is a Lua string, boolean, or number — serialised to TOML.
---
--- Existing keys in the file are updated in-place; new sections and keys are
--- appended. Lines not matching any update are preserved verbatim.
--- @param path    string Absolute path to the config.toml to write.
--- @param updates table  Array of `{section=string, key=string, value=any}` tables.
--- @return boolean, string|nil True on success, or false and an error string.
function M.batch_write(path, updates, file_adapter)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "batch_write: invalid path.")
		return false, "Invalid path."
	end
	if type(updates) ~= "table" then
		Logger.error(LOG, "batch_write: updates must be a table.")
		return false, "updates must be a table."
	end

	-- Build a lookup: section_lower → key_lower → update entry
	local lookup = {}
	for _, u in ipairs(updates) do
		if type(u.section) == "string" and type(u.key) == "string" then
			local sl = u.section:lower()
			if not lookup[sl] then lookup[sl] = {} end
			lookup[sl][u.key:lower()] = u
		end
	end

	-- Serialise a Lua value to a TOML literal
	local function to_toml_value(v)
		if type(v) == "boolean" then return v and "true" or "false" end
		if type(v) == "number"  then return tostring(v) end
		-- String: quote and escape
		return "\"" .. BasicString.escape_body(tostring(v)) .. "\""
	end

	-- Read existing lines (empty table only when absence is proven).
	local lines = {}
	local source, read_status, read_detail = read_existing(path, file_adapter)
	if read_status == "error" then
		Logger.error(LOG, "batch_write: refusing unreadable destination '%s' — %s.", path, tostring(read_detail))
		return false, tostring(read_detail)
	end
	if read_status == "absent" then source = "" end
	for line in (source .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
	if #lines == 1 and lines[1] == "" then lines = {} end

	-- Walk existing lines, replacing matching key lines in-place
	local current_section = ""
	local applied = {}   -- Tracks which updates were already applied
	for idx, line in ipairs(lines) do
		local trimmed = line:match("^%s*(.-)%s*$") or ""
		-- Section header
		local hdr = trimmed:match("^%[([^%[%]]+)%]$")
		if hdr then
			current_section = hdr:lower()
		else
			local key = trimmed:match("^([%w_]+)%s*=")
			if key then
				local kl = key:lower()
				local bucket = lookup[current_section]
				if bucket and bucket[kl] then
					local u = bucket[kl]
					lines[idx] = u.key .. " = " .. to_toml_value(u.value)
					applied[current_section .. "\0" .. kl] = true
				end
			end
		end
	end

	-- Append any updates that were not found in the existing file.
	-- Group by section so we don't emit duplicate section headers
	local pending = {}   -- section_original → list of update entries
	for _, u in ipairs(updates) do
		local sl = u.section:lower()
		local kl = u.key:lower()
		if not applied[sl .. "\0" .. kl] then
			if not pending[u.section] then pending[u.section] = {} end
			pending[u.section][#pending[u.section] + 1] = u
		end
	end

	for section, entries in pairs(pending) do
		-- Check whether the section header already exists anywhere in lines
		local section_exists = false
		for _, line in ipairs(lines) do
			if (line:match("^%s*%[([^%[%]]+)%]%s*$") or ""):lower() == section:lower() then
				section_exists = true
				break
			end
		end
		if not section_exists then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "[" .. section .. "]"
		end
		for _, u in ipairs(entries) do
			lines[#lines + 1] = u.key .. " = " .. to_toml_value(u.value)
		end
	end

	local content = table.concat(lines, "\n")
	local published, publish_err = publish_content(path, content, file_adapter, {
		status = read_status,
		content = source,
	})
	if not published then
		Logger.error(LOG, "batch_write: publication to '%s' failed — %s.", path, tostring(publish_err))
		return false, tostring(publish_err)
	end
	Logger.info(LOG, "batch_write: wrote %d line(s) to '%s'.", #lines, path)
	return true
end

return M
