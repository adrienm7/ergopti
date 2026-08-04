--- infra/manifest_menu.lua

--- ==============================================================================
--- MODULE: Manifest Menu Renderer (Hammerspoon binding)
--- DESCRIPTION:
--- Binds the shared manifest menu renderer to this driver: its JSON decoder, its
--- manifest path, its i18n catalogue, and the platform token "hs".
---
--- WHY THIS IS A BINDING AND NOT THE RENDERER:
--- the renderer was 561 lines here and made exactly ONE Hammerspoon call. The
--- "hs.menubar item table" its docstrings talk about is a plain Lua table, and
--- the tree walk that produces it is not macOS's — it is the same walk Linux
--- needs, and the same one AutoHotkey re-implements in its own language because
--- it cannot require Lua. What was genuinely per-driver is exactly what this file
--- now supplies: the decoder, the path, the catalogue, and the platform token
--- that decides which manifest rows this driver may see.
---
--- The public surface is unchanged — every consumer under ui/menu/ calls the same
--- nine functions on the value returned here.
--- ==============================================================================

local hs     = hs
local Logger = require("infra.logger")
local Paths  = require("infra.paths")
local i18n   = require("infra.i18n")
local Renderer = require("menu.renderer")

local LOG = "manifest_menu"

local instance, err = Renderer.new({
	platform      = "hs",
	-- Resolved on every read, not once here: Paths.shared is what the renderer's
	-- unit files redirect to a throwaway fixture directory, per case.
	manifest_path = function() return Paths.shared("modules/menu/menu_manifest.json") end,
	-- Injected rather than replaced: this is a boot-path parse of an 11.9 KB
	-- file and hs.json.decode is C. Linux passes the pure-Lua decoder instead.
	json_decode   = hs.json.decode,
	i18n          = i18n,
	-- This driver's logger, not the shared shim: the renderer's warnings belong
	-- in this driver's log, at this driver's levels.
	logger        = Logger,
})

if not instance then
	-- Returning nil here would make every `require("infra.manifest_menu")` in
	-- ui/menu/ fail at its first field access, several frames from the cause.
	Logger.error(LOG, "Could not bind the shared menu renderer (%s) — the menu will not build.",
		tostring(err))
end

return instance
