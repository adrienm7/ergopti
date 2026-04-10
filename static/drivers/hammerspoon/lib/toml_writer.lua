--- lib/toml_writer.lua

--- ==============================================================================
--- MODULE: TOML Writer
--- DESCRIPTION:
--- Serializes a hotstrings data structure back to the TOML format used by
--- the application.
--- ==============================================================================

local M = {}
local Logger = require("lib.logger")
local LOG    = "toml_writer"





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
--- @param s string The input string to escape.
--- @return string The escaped and normalized string.
local function esc(s)
	if type(s) ~= "string" then s = tostring(s or "") end
	
	s = s:gsub("\\", "\\\\")
	s = s:gsub("\"",  "\\\"")
	
	s = s:gsub("\r\n", "{Enter}")
	s = s:gsub("\r",   "{Enter}")
	s = s:gsub("\n",   "{Enter}")
	s = s:gsub("\t", "\\t")
	
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

	w("# custom.toml — Hotstrings personnels")
	w("# Géré automatiquement par l’éditeur de hotstrings personnels.")
	w("# Ne pas modifier manuellement sauf si vous savez ce que vous faites.")
	w("")

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
	w("")

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
		w("")
	end

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
			w("")
		end
	end

	local ok, fh = pcall(io.open, path, "w")
	if not ok or not fh then
		Logger.error(LOG, "Failed to open file for writing.")
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
	return true
end

return M
