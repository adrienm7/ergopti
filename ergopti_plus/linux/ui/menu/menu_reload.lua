--- ui/menu/menu_reload.lua

--- ==============================================================================
--- MODULE: Linux Menu Reload Row
--- DESCRIPTION:
--- Builds the tray's Reload row. The daemon owns the reload; the row asks it to
--- through ctx.on_reload, exactly as Quit asks through ctx.on_quit.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local LOG = "ui.menu.menu_reload"

--- Builds the reload item.
---
--- This used to run `kill -HUP $$` through os.execute. Two things were wrong
--- with that, and together they made the item a no-op that logged success:
--- `os.getpid` does not exist in Lua, so the expression always fell through to
--- the literal `"$$"`; and os.execute runs its string in a NEW /bin/sh, where
--- `$$` is that shell's own PID. The daemon therefore told a throwaway shell to
--- reload, and the shell obligingly killed itself.
---
--- The daemon owns the reload; the menu asks it to, exactly as the quit item
--- asks via on_quit. No signal, no subprocess, no PID to get wrong.
local function _build_reload(ctx)
	local row = ManifestMenu.command_row("top_level", "reload", {
		reload = function()
			if type(ctx.on_reload) ~= "function" then
				-- Loudly, not silently: a Reload item that cannot reload is the
				-- exact failure this replaced.
				Logger.error(LOG, "Reload requested but ctx.on_reload is absent — the menu cannot reload the daemon.")
				return
			end
			Logger.info(LOG, "Reload requested from the tray menu…")
			local ok, err = pcall(ctx.on_reload)
			if not ok then
				Logger.error(LOG, "Reload callback raised: %s.", tostring(err))
			end
		end,
	})
	-- Read by ui/menu/rebuild_owner: a click on a stale Reload row joins the
	-- reload that already ran instead of replaying a second one.
	if type(row) == "table" then row.joins_reload = true end
	return row
end

M.build = _build_reload

return M
