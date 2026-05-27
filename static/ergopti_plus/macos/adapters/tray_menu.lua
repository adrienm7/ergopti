--- adapters/tray_menu.lua

--- ==============================================================================
--- MODULE: TrayMenu Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TrayMenu port contract defined in
--- static/ergopti_plus/shared/ports/TrayMenu.spec.js. Wraps hs.menubar to expose
--- a platform-agnostic interface (setIcon, setMenu, setTooltip, destroy) that
--- domain modules can call without a direct dependency on the hs.menubar API.
---
--- FEATURES & RATIONALE:
--- 1. Lazy creation: the menubar item is created on first use (first call to any
---    setter) rather than at module load time, so modules that do not ultimately
---    need a tray icon do not allocate one.
--- 2. Structural menu items: setMenu() accepts a plain Lua table of
---    { title, fn, checked?, disabled? } entries, mirroring hs.menubar's format
---    exactly so no translation layer is needed.
--- 3. Defensive pcall: all hs.menubar calls are wrapped in pcall because a
---    menubar item can become stale after a Hammerspoon reload.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.tray_menu"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Lazily-created hs.menubar item. Nil until the first setter is called.
local _menubar = nil

local function _ensure_menubar()
	if _menubar then return _menubar end
	local ok, mb = pcall(hs.menubar.new)
	if not ok or not mb then
		Logger.error(LOG, "_ensure_menubar(): hs.menubar.new failed — %s", tostring(mb))
		return nil
	end
	_menubar = mb
	return _menubar
end


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Sets the tray icon.
--- @param opts table { image?, title?, imageData? }
---              image     string   Path to an image file (hs.image.imageFromPath).
---              title     string   Text label shown beside or instead of the icon.
---              imageData userdata Pre-built hs.image object (takes priority).
function M.setIcon(opts)
	local mb = _ensure_menubar()
	if not mb then return end

	local options = type(opts) == "table" and opts or {}

	if options.imageData then
		pcall(function() mb:setIcon(options.imageData) end)
	elseif type(options.image) == "string" then
		pcall(function()
			local img = hs.image.imageFromPath(options.image)
			if img then mb:setIcon(img) end
		end)
	end

	if type(options.title) == "string" then
		pcall(function() mb:setTitle(options.title) end)
	end
end

--- Replaces the drop-down menu items.
--- @param items table Array of { title, fn, checked?, disabled? } entries,
---               or a function that returns such an array (dynamic menu).
function M.setMenu(items)
	local mb = _ensure_menubar()
	if not mb then return end
	pcall(function() mb:setMenu(items) end)
end

--- Sets the tooltip shown on hover.
--- @param text string Tooltip text.
function M.setTooltip(text)
	local mb = _ensure_menubar()
	if not mb then return end
	pcall(function() mb:setTooltip(text) end)
end

--- Removes and destroys the tray icon. Safe to call multiple times.
function M.destroy()
	if not _menubar then return end
	pcall(function() _menubar:delete() end)
	_menubar = nil
end

return M
