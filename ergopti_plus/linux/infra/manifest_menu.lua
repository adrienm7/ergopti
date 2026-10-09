--- infra/manifest_menu.lua

--- ==============================================================================
--- MODULE: Manifest Menu Renderer (Linux binding)
--- DESCRIPTION:
--- Binds the shared manifest menu renderer to this driver: the pure-Lua JSON
--- decoder, this driver's manifest path and i18n catalogue, and the platform
--- token "linux".
---
--- WHY THIS DRIVER HAD NONE UNTIL NOW:
--- the renderer lived inside the macOS driver, 561 lines that read as Hammerspoon
--- code and were not — one `hs.json.decode` and a platform token were the whole
--- of it. Linux built its tray menu by hand instead, and the top-level parity
--- gate had to read `menu_builder.lua`'s real `_build_*` calls to compare the two
--- at all. Three rows only became visible that way: `kanata`, `updates` and
--- `apps`, all built here and none of them described by the manifest.
---
--- THE PLATFORM TOKEN IS WHY THIS IS A BINDING AND NOT A COPY. The renderer's
--- filter used to be hardcoded to "hs". Passing "linux" is what makes those same
--- three rows visible to this driver and hides the macOS-only ones — a copy that
--- kept the constant would have rendered the macOS menu on Linux.
---
--- WHAT THIS DOES NOT YET DO: the renderer only DISPATCHES. Every `action`,
--- `dynamic`, `toggle` and `feature` row still needs a handler in this driver
--- before a single manifest row reaches the tray. This module is what makes that
--- work possible, not what completes it.
--- ==============================================================================

local Logger = require("logger.shim")
local Paths  = require("infra.paths")
local i18n   = require("infra.i18n")
local json   = require("json")
local Renderer = require("menu.renderer")

local LOG = "manifest_menu"

local instance, err = Renderer.new({
	platform      = "linux",
	-- Resolved on every read rather than once here, matching the macOS binding:
	-- Paths.shared probes for the shared root and can answer differently before
	-- and after the daemon has settled its install layout.
	manifest_path = function() return Paths.shared("modules/menu/menu_manifest.json") end,
	-- Pure Lua, deliberately. macOS injects hs.json.decode because it has a C
	-- decoder on its boot path; this driver has none and must not pretend to.
	json_decode   = json.decode,
	i18n          = i18n,
	logger        = Logger,
})

if not instance then
	Logger.error(LOG, "Could not bind the shared menu renderer (%s) — manifest rows will not render.",
		tostring(err))
end

return instance
