--- modules/updater/install_origin.lua

--- ==============================================================================
--- MODULE: Installation Origin Update Policy (Linux)
--- DESCRIPTION:
--- The one answer to « may this installation replace itself, and if not, what
--- does the user read? » for each installation kind
--- modules/updater/installer.resolve() returns. The About menu, the update
--- check window and the Versions window all show this reason.
---
--- FEATURES & RATIONALE:
--- 1. Only the self-update is refused. A system package, an AppImage and a
---    Flatpak each restart through their own launcher (installer.resolve names
---    it), so a Reload never asks this module.
--- 2. Each origin names its own updater: an AppImage greyed as « installé par
---    un paquet système » sent the user to a package manager that never
---    installed it (field report of 2026-11-25).
--- ==============================================================================

local M = {}

-- The locale key that names why each installation kind cannot replace itself.
-- A kind absent here (standalone, unmanaged) is not refused for its origin.
local UPDATE_BLOCKED_KEYS = {
	package  = "changelog_window.install_blocked_package",
	appimage = "changelog_window.install_blocked_appimage",
	flatpak  = "changelog_window.install_blocked_flatpak",
}

--- Why an installation of this kind never replaces itself, as a locale key.
--- @param kind string|nil An installation kind installer.resolve() returned.
--- @return string|nil key nil when the kind's origin does not forbid it.
function M.update_blocked_key(kind)
	return UPDATE_BLOCKED_KEYS[kind]
end

return M
