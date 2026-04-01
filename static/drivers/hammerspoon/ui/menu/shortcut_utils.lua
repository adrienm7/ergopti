--- ui/menu/shortcut_utils.lua

--- ==============================================================================
--- MODULE: Menu Shortcut Utils
--- DESCRIPTION:
--- Provides shared helpers to parse, normalize, display, and prompt keyboard
--- shortcuts from menu modules.
--- ============================================================================== 

local M = {}
local hs = hs




-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local VALID_MODS = {
	cmd = true,
	alt = true,
	ctrl = true,
	shift = true,
}




-- =======================================
-- =======================================
-- ======= 2/ Parsing & Formatting =======
-- =======================================
-- =======================================

--- Normalizes a shortcut definition into a validated table.
--- @param mods table|nil Modifier keys.
--- @param key string|nil Trigger key.
--- @param default_mods table|nil Default modifiers if none are provided.
--- @return table|nil Normalized shortcut table or nil when invalid.
function M.normalize_shortcut(mods, key, default_mods)
	if type(key) ~= "string" then return nil end
	local clean_key = key:match("^%s*(.-)%s*$")
	if clean_key == "" then return nil end

	local seen = {}
	local out_mods = {}
	for _, m in ipairs(type(mods) == "table" and mods or {}) do
		local mod = tostring(m):lower():match("^%s*(.-)%s*$")
		if mod == "option" then mod = "alt" end
		if mod == "control" then mod = "ctrl" end
		if VALID_MODS[mod] and not seen[mod] then
			seen[mod] = true
			table.insert(out_mods, mod)
		end
	end

	if #out_mods == 0 and type(default_mods) == "table" then
		for _, dm in ipairs(default_mods) do
			local m = tostring(dm):lower()
			if VALID_MODS[m] and not seen[m] then
				seen[m] = true
				table.insert(out_mods, m)
			end
		end
	end

	if #out_mods == 0 then return nil end
	return { mods = out_mods, key = clean_key:lower() }
end

--- Parses a raw input string to a normalized shortcut definition.
--- @param raw string Raw value from text prompt.
--- @param default_mods table|nil Default modifiers if none are provided.
--- @return table|nil Parsed shortcut.
function M.parse_shortcut_input(raw, default_mods)
	if type(raw) ~= "string" then return nil end
	local normalized = raw:match("^%s*(.-)%s*$"):lower()
	if normalized == "" then return nil end

	local parts = {}
	for part in normalized:gmatch("[^+]+") do
		table.insert(parts, part)
	end
	if #parts < 1 then return nil end

	local key = parts[#parts]
	local mods = {}
	for i = 1, #parts - 1 do table.insert(mods, parts[i]) end
	return M.normalize_shortcut(mods, key, default_mods)
end

--- Converts a shortcut table to a config-friendly string.
--- @param sc table|nil Shortcut definition.
--- @return string String representation for input fields.
function M.shortcut_to_config_string(sc)
	if type(sc) ~= "table" then return "" end
	local mods = type(sc.mods) == "table" and table.concat(sc.mods, "+") or ""
	local key = type(sc.key) == "string" and sc.key or ""
	if mods ~= "" and key ~= "" then return mods .. "+" .. key end
	if key ~= "" then return key end
	return ""
end

--- Converts a shortcut table to a readable label for menu entries.
--- @param sc table|nil Shortcut definition.
--- @param none_label string|nil Label when shortcut is disabled.
--- @return string Display label.
function M.shortcut_to_label(sc, none_label)
	if type(sc) ~= "table" then return none_label or "Aucun" end

	local mods_cap = {}
	for _, m in ipairs(sc.mods or {}) do
		table.insert(mods_cap, m:sub(1, 1):upper() .. m:sub(2))
	end

	local mods_str = table.concat(mods_cap, "+")
	local key_str = string.upper(sc.key or "")
	if key_str == "" then return none_label or "Aucun" end
	return (mods_str ~= "" and (mods_str .. " + ") or "") .. key_str
end




-- ====================================
-- ====================================
-- ======= 3/ Prompt Helpers ==========
-- ====================================
-- ====================================

--- Opens a standard shortcut prompt and returns parsed output via callback.
--- @param opts table Prompt options.
--- @return boolean True when an update callback was executed.
function M.prompt_shortcut(opts)
	if type(opts) ~= "table" or type(opts.on_apply) ~= "function" then return false end

	local title = type(opts.title) == "string" and opts.title or "Raccourci"
	local message = type(opts.message) == "string"
		and opts.message
		or "Format : mods+touche (ex : cmd+alt+p)\nMods disponibles : cmd, alt, ctrl, shift\nLaisser vide pour désactiver"

	local current = M.shortcut_to_config_string(opts.current_shortcut)
	local ok_prompt, button, raw = pcall(hs.dialog.textPrompt, title, message, current, "OK", "Annuler")
	if not ok_prompt or button ~= "OK" or type(raw) ~= "string" then return false end

	local cleaned = raw:match("^%s*(.-)%s*$")
	if cleaned == "" then
		opts.on_apply(nil, nil)
		return true
	end

	local parsed = M.parse_shortcut_input(cleaned, opts.default_mods)
	if parsed then
		opts.on_apply(parsed.mods, parsed.key)
		return true
	end

	pcall(hs.dialog.alert, "Format invalide", "Utilisez le format mods+touche, par exemple cmd+shift+b")
	return false
end

return M
