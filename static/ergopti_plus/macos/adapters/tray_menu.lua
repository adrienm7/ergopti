--- adapters/tray_menu.lua

--- ==============================================================================
--- MODULE: TrayMenu Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TrayMenu port contract defined in
--- static/ergopti_plus/_shared/core/ports/TrayMenu.spec.js. Wraps hs.menubar to expose
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
---    menubar item can become stale after a Hammerspoon reload. Each setter
---    also checks the returned capability and reports an explicit boolean.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

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

--- Executes one native mutation and verifies the menubar capability returned.
--- @param operation string Stable native method name for diagnostics.
--- @param callback function One-arity function receiving the live menubar.
--- @return boolean accepted True only when the native method returns that menubar.
local function _mutate(operation, callback)
	local mb = _ensure_menubar()
	if not mb then return false end
	local ok, result_or_err = xpcall(function()
		return callback(mb)
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s(): hs.menubar failed: %s.", operation, tostring(result_or_err))
		return false
	end
	if result_or_err ~= mb then
		Logger.error(LOG, "%s(): hs.menubar refused the mutation.", operation)
		return false
	end
	return true
end

--- Adopts the application's existing menubar object instead of creating a second icon.
--- @param menubar userdata|table A live hs.menubar object.
--- @return boolean True when the object is retained by this adapter.
function M.adopt(menubar)
	if not menubar then return false end
	_menubar = menubar
	return true
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
--- @return boolean accepted True only when every requested native mutation commits.
function M.setIcon(opts)
	local options = type(opts) == "table" and opts or {}

	if options.imageData then
		if not _mutate("setIcon", function(mb) return mb:setIcon(options.imageData) end) then
			return false
		end
	elseif type(options.image) == "string" then
		local loaded, image_or_err = xpcall(function()
			return hs.image.imageFromPath(options.image)
		end, debug.traceback)
		if not loaded or not image_or_err then
			Logger.error(LOG, "setIcon(): image load failed: %s.", tostring(image_or_err))
			return false
		end
		if not _mutate("setIcon", function(mb) return mb:setIcon(image_or_err) end) then
			return false
		end
	end

	if type(options.title) == "string" then
		return _mutate("setTitle", function(mb) return mb:setTitle(options.title) end)
	end
	return true
end

--- Replaces the drop-down menu items.
--- @param items table Array of { title, fn, checked?, disabled? } entries,
---               or a function that returns such an array (dynamic menu).
--- @return boolean accepted True only when the native menu is replaced.
function M.setMenu(items)
	return _mutate("setMenu", function(mb) return mb:setMenu(items) end)
end

--- Sets the tooltip shown on hover.
--- @param text string Tooltip text.
--- @return boolean accepted True only when the native tooltip is replaced.
function M.setTooltip(text)
	return _mutate("setTooltip", function(mb) return mb:setTooltip(text) end)
end

--- Removes and destroys the tray icon. Safe to call multiple times.
--- @return boolean committed True only when no native menubar remains owned.
function M.destroy()
	if not _menubar then return true end
	local owned = _menubar
	if type(owned.delete) ~= "function" then
		Logger.error(LOG, "destroy(): owned hs.menubar has no delete method.")
		return false
	end
	local ok, err = xpcall(function() owned:delete() end, debug.traceback)
	if not ok then
		Logger.error(LOG, "destroy(): hs.menubar delete failed; exact owner retained: %s.", tostring(err))
		return false
	end
	if _menubar == owned then _menubar = nil end
	return true
end

return M
