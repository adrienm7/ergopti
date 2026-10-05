--- infra/common_hotstrings_boot.lua

--- ==============================================================================
--- MODULE: Cold TOML Hotstring Registration Receipts
--- DESCRIPTION:
--- Records only groups acknowledged by the actual native registry. A refused
--- optional common source stays unavailable while unrelated boot groups continue.
--- ==============================================================================

local Logger = require("infra.logger")
local M = {}

--- Loads one cold-boot group and records only an acknowledged native image.
--- @param keymap table Native registry owner.
--- @param name string Category identity.
--- @param path string Source path.
--- @param section_sources table|nil Extension-bound section sources.
--- @param hotfiles table Acknowledged boot category identities.
--- @param hotfile_paths table Acknowledged boot source routes.
--- @return table receipt Classified native publication result.
function M.load(keymap, name, path, section_sources, hotfiles, hotfile_paths)
	local ok, committed = pcall(keymap.load_toml, name, path, section_sources)
	if not ok or committed ~= true then
		Logger.warn("HotstringsBoot", "Hotstring category '%s' is unavailable; its native source was not admitted.", name)
		return { committed = false, complete = false, unavailable = { name } }
	end
	hotfiles[#hotfiles + 1] = name
	hotfile_paths[name] = path
	return { committed = true, complete = true, unavailable = {} }
end

return M
