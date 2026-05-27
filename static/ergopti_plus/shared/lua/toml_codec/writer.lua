--- shared/lua/toml_codec/writer.lua

--- ==============================================================================
--- MODULE: TOML Writer (shared)
--- DESCRIPTION:
--- Serializes a hotstrings data structure back to the TOML format used by
--- the application. Canonical source shared by all Lua-based drivers
--- (Hammerspoon, future Linux driver). Previously lived at
--- hammerspoon/lib/toml_writer.lua; moved here so both drivers share one
--- implementation without duplication.
---
--- FEATURES & RATIONALE:
--- 1. Python formatter integration: after writing, automatically calls the
---    centralized format_toml.py script to ensure consistent styling and
---    organization across all TOML files (sorts sections/keys, adds headers).
--- 2. Token alias normalization: {Esc} → {Escape}, {return} → {Enter}, etc.,
---    so the on-disk format never mixes raw \n / \t with {Enter} / {Tab}.
--- 3. Batch write: a separate batch_write() method updates key/value pairs
---    in INI-style TOML files (driver config.toml) without rewriting the whole
---    file — existing lines are updated in-place, new entries are appended.
--- ==============================================================================

local M = {}
local Logger = require("lib.logger")
local i18n   = require("lib.i18n")
local LOG    = "toml_writer"




-- ===================================
-- ====================================
-- ======= 0/ Python Formatter =======
-- ====================================
-- ===================================

-- Locate the format_toml.py script at repo root/tools/
local function get_format_script_path()
	local _src = debug.getinfo(1, "S").source:sub(2)
	local _script_dir = _src:match("^(.*[/\\])")
	-- Walk up from static/ergopti_plus/shared/lua/toml_codec/ to repo root
	local _repo_root = _script_dir
		:gsub("static[/\\]drivers[/\\].*$", "")
		:gsub("[/\\]$", "")
	return _repo_root .. "/tools/format_toml.py"
end

--- Reformat a TOML file using the centralized Python formatter.
--- Ensures consistent headers, sorted sections/keys across all TOML files.
--- Called automatically after M.write() to guarantee consistent formatting.
local function format_toml_via_python(path)
	if type(path) ~= "string" or path == "" then return end

	local script_path = get_format_script_path()
	local cmd = string.format("python3 '%s' '%s' 2>&1", script_path, path)

	local ok, output = pcall(os.execute, cmd)
	if not ok then
		Logger.warn(LOG, "Python formatter call failed: %s", tostring(output))
		return
	end

	Logger.trace(LOG, "Reformatted TOML: %s", path)
end




-- ====================================
-- =====================================
-- ======= 1/ Constants & State =======
-- =====================================
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
-- ====================================
-- ======= 2/ String Utilities =======
-- ====================================
-- ===================================

--- Escapes a value for TOML double-quoted strings.
--- Also normalizes literal newlines to {Enter} and token aliases.
--- @param s string The input string to escape.
--- @return string The escaped and normalized string.
local function esc(s)
	if type(s) ~= "string" then s = tostring(s or "") end

	s = s:gsub("\\", "\\\\")
	s = s:gsub("\"",  "\\\"")

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

	return s
end




-- =============================
-- ==============================
-- ======= 3/ Public API =======
-- ==============================
-- =============================

--- Writes a TOML file from a hotstrings data structure.
--- @param path string Destination file path.
--- @param data table  The configuration dictionary.
--- @return boolean, string|nil True on success, or false and error string.
function M.write(path, data)
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
		meta_desc = raw_desc[code] or raw_desc["fr"] or "Hotstrings personnels"
	elseif type(raw_desc) == "string" then
		meta_desc = raw_desc
	else
		meta_desc = "Hotstrings personnels"
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
						w(string.format(
							"\"%s\" = { output = \"%s\", is_word = %s, auto_expand = %s, is_case_sensitive = %s, final_result = %s }",
							esc(e.trigger),
							esc(e.output),
							e.is_word           and "true" or "false",
							e.auto_expand       and "true" or "false",
							e.is_case_sensitive and "true" or "false",
							e.final_result      and "true" or "false"
						))
					end
				end
			end
		end
	end

	local ok, fh = pcall(io.open, path, "w")
	if not ok or not fh then
		Logger.error(LOG, "Failed to open file for writing.")
		-- UI error message kept in French
		return false, "Impossible d'ouvrir le fichier en écriture : " .. tostring(path)
	end

	local write_ok, write_err = pcall(function()
		fh:write(table.concat(L, "\n"))
	end)

	pcall(function() fh:close() end)

	if not write_ok then
		Logger.error(LOG, string.format("Error during TOML write: %s.", tostring(write_err)))
		return false, "Erreur lors de l'écriture : " .. tostring(write_err)
	end

	Logger.info(LOG, "TOML configuration saved successfully.")
	-- Reformat using centralized Python script for consistent styling
	format_toml_via_python(path)
	return true
end


--- ===================================
-- ===== 3.2) Batch Write Method =====
--- ===================================

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
function M.batch_write(path, updates)
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
		return "\"" .. tostring(v):gsub("\\", "\\\\"):gsub("\"", "\\\"") .. "\""
	end

	-- Read existing lines (empty table if file absent)
	local lines = {}
	local fh_r = io.open(path, "r")
	if fh_r then
		for line in fh_r:lines() do lines[#lines + 1] = line end
		fh_r:close()
	end

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

	local fh_w, err_w = io.open(path, "w")
	if not fh_w then
		Logger.error(LOG, "batch_write: cannot open '%s' for writing — %s.", path, tostring(err_w))
		return false, tostring(err_w)
	end
	local content = table.concat(lines, "\n")
	local ok_w, err2 = pcall(function() fh_w:write(content) end)
	pcall(function() fh_w:close() end)
	if not ok_w then
		Logger.error(LOG, "batch_write: write failed — %s.", tostring(err2))
		return false, tostring(err2)
	end
	Logger.info(LOG, "batch_write: wrote %d line(s) to '%s'.", #lines, path)
	return true
end

return M
