--- _shared/lua/tray/protocol.lua

--- ==============================================================================
--- MODULE: Tray Asset Resolution
--- DESCRIPTION:
--- Finds the icon file a tray backend should display.
---
--- WHAT THIS MODULE USED TO BE:
--- A serialiser for com.canonical.dbusmenu XML plus a set of `gdbus` command
--- builders. All of it was deleted with the tray that used it, and the deletion
--- is worth recording rather than hiding: the XML was correct, well tested, and
--- written to a temp file that nothing read — a panel calls GetLayout over
--- D-Bus, it does not open a file. The `gdbus call … RequestName` builder
--- acquired a bus name in a process that then exited, releasing it. SNI is an
--- object a process HOSTS, not a call it makes, so none of it could ever have
--- produced a tray icon. The hosting now happens through
--- linux/platform/tray/appindicator.lua, and nothing needs a serialiser.
---
--- What remains is the one question that outlived the transport: which file is
--- the icon.
--- ==============================================================================

local M = {}




-- =======================================
-- =======================================
-- ======= 1/ Icon resolution ============
-- =======================================
-- =======================================

--- The bundled icons, relative to the shared tree. Byte copies of
--- static/img/logo/logo_simple{,_disabled}.png — the logo macOS draws in its
--- menu bar and Windows in its tray — held in _shared because every Linux
--- package format ships that tree and none ships static/img. The copies are
--- pinned to their originals by tools/test/test-linux-tray-icon-assets.cjs.
local ICONS = {
	active = "/assets/ergopti_tray.png",
	paused = "/assets/ergopti_tray_paused.png",
}

--- Finds the bundled tray icon.
---
--- Returns "" when there is none, and the CALLER must treat that as "use a
--- themed name" rather than as an icon. An empty icon name produces a blank,
--- unclickable space in the panel.
---
--- Resolved from the SHARED root, not from the driver root. The candidates used
--- to be "<driver root>/../_shared/assets/…", which is wrong on the system
--- packages (the shared tree is a CHILD of /usr/lib/ergopti there), and the
--- assets directory did not exist anyway: every Linux user saw a generic
--- keyboard glyph instead of the logo the other two drivers show.
--- @param shared_root string|nil Absolute path to the shared tree.
--- @param paused boolean|nil True for the greyed logo shown while paused.
--- @return string Absolute path to an existing icon file, or "".
function M.resolve_tray_icon(shared_root, paused)
	if type(shared_root) ~= "string" or shared_root == "" then return "" end
	local sep = package.config:sub(1, 1)
	local order = paused and { ICONS.paused, ICONS.active } or { ICONS.active }
	for _, suffix in ipairs(order) do
		local path = shared_root .. suffix
		if sep == "\\" then path = path:gsub("/", "\\") end
		local fh = io.open(path, "r")
		if fh then
			fh:close()
			return path
		end
	end
	return ""
end

return M
