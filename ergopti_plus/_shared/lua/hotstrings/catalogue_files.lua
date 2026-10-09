--- _shared/lua/hotstrings/catalogue_files.lua

--- ==============================================================================
--- MODULE: Hotstring Catalogue Files (Shared)
--- DESCRIPTION:
--- The one rule that tells a hotstring category file from the metadata stored
--- beside it in _shared/modules/hotstrings/.
---
--- WHY THIS IS SHARED:
--- Both Lua drivers discover categories by listing that directory. Two files in
--- it are not categories: _index.toml (the menu index) and defaults.toml (the
--- resolver's fallback delays and colours). Linux excluded both; macOS excluded
--- only the underscore-prefixed one, so it loaded defaults.toml as a hotstring
--- group and the common hotstrings menu showed an empty « defaults (0) » row.
--- One predicate, used by both scans, is what keeps the two lists equal.
--- ==============================================================================

local M = {}





-- =====================================
-- =====================================
-- ======= 1/ Category predicate =======
-- =====================================
-- =====================================

--- Metadata files that sit among the category files without an underscore.
local METADATA_FILES = {
	["defaults.toml"] = true,
}

--- Files of other features that live in the configuration folder, which macOS
--- reads as its hotstrings folder (HotstringsDirPath): the navigation layer,
--- which the recommended import writes there, and the wrap symbols an older
--- release left. Read as a category, either one made that folder look like a
--- copy of the catalogue, so the boot loaded it instead of the bundled
--- categories and lost every shipped hotstring (hardening-a-startup-zero-error).
local CONFIGURATION_FILES = {
	["layers.toml"] = true,
	["wrap_symbols.toml"] = true,
}

--- Whether a file found in a hotstrings directory is a category to load.
---
--- Underscore-prefixed files are metadata by convention; defaults.toml predates
--- that convention and is named explicitly, as are the configuration files
--- that share the folder.
--- @param path string A file name or path.
--- @return boolean
function M.is_category_file(path)
	if type(path) ~= "string" or path == "" then return false end
	local name = path:match("([^/\\]+)$")
	if not name or not name:match("%.toml$") then return false end
	return name:sub(1, 1) ~= "_" and not METADATA_FILES[name] and not CONFIGURATION_FILES[name]
end

return M
