--- lib/toml_writer.lua

--- ==============================================================================
--- MODULE: TOML Writer
--- DESCRIPTION:
--- Serializes a hotstrings data structure back to the TOML format used by
--- the application. After writing, automatically calls the centralized Python
--- formatter (format_toml.py) to ensure consistent styling and organization
--- across all TOML files (sorts sections/keys, adds headers, etc.).
--- ==============================================================================

local M = {}
local Logger = require("lib.logger")
local LOG    = "toml_writer"


-- ===================================
-- ===================================
-- ======= 0/ Python Formatter =======
-- ===================================
-- ===================================

-- Locate the format_toml.py script at repo root/tools/
local function get_format_script_path()
	local _src = debug.getinfo(1, "S").source:sub(2)
	local _script_dir = _src:match("^(.*[/\\])")
	-- Walk up from static/drivers/hammerspoon/lib/ to repo root
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
	
	s = s:gsub("\\", "\\\\")
	s = s:gsub("\"",  "\\\"")
	
    -- Normalize literal newlines → {Enter} and tabs → {Tab} so the on-disk
    -- format never mixes raw \n / \t with {Enter} / {Tab} for the same kind
    -- of payload (matches the AHK side's EscapeTomlValue behaviour).
	s = s:gsub("\r\n", "{Enter}")
	s = s:gsub("\r",   "{Enter}")
	s = s:gsub("\n",   "{Enter}")
	s = s:gsub("\t",   "{Tab}")
	
    -- Normalize token aliases  e.g. {Esc} → {Escape}, {return} → {Enter}
	s = s:gsub("{([^}]+)}", function(name)
		local canon = TOKEN_CANONICAL[name:lower()]
		return "{" .. (canon or (name:sub(1,1):upper() .. name:sub(2):lower())) .. "}"
	end)
	
	return s
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Writes a TOML file from a hotstrings data structure.
--- @param path string Destination file path.
--- @param data table The configuration dictionary.
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
	local meta_desc = (type(data.meta) == "table" and type(data.meta.description) == "string") 
					  and data.meta.description or "Hotstrings personnels"

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
        -- UI Error message kept in French
		return false, "Impossible d’ouvrir le fichier en écriture : " .. tostring(path)
	end
	
	local write_ok, write_err = pcall(function()
		fh:write(table.concat(L, "\n"))
	end)
	
	pcall(function() fh:close() end)
	
	if not write_ok then
		Logger.error(LOG, string.format("Error during TOML write: %s.", tostring(write_err)))
		return false, "Erreur lors de l’écriture : " .. tostring(write_err)
	end
	
	Logger.info(LOG, "TOML configuration saved successfully.")	
	-- Reformat using centralized Python script for consistent styling
	format_toml_via_python(path)
		return true
end

return M
