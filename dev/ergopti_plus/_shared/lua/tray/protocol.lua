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

--- Candidate icon locations, in preference order: the shared asset tree first,
--- then a driver-local override.
local CANDIDATES = {
	"/../_shared/assets/ergopti_tray.png",
	"/../_shared/assets/ergopti_tray.svg",
	"/assets/tray_icon.png",
}

--- Finds the bundled tray icon.
---
--- Returns "" when there is none, and the CALLER must treat that as "use a
--- themed name" rather than as an icon. An empty icon name produces a blank,
--- unclickable space in the panel — which is what shipped, because the assets
--- directory does not exist and the result was assigned to a local nothing read.
--- @param driver_root string|nil Absolute path to the driver root.
--- @return string Absolute path to an existing icon file, or "".
function M.resolve_tray_icon(driver_root)
	driver_root = driver_root or "."
	local sep = package.config:sub(1, 1)

	for _, suffix in ipairs(CANDIDATES) do
		local path = driver_root .. suffix
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
