--- ui/window_toggle.lua

--- ==============================================================================
--- MODULE: Web-View Window Toggle (macOS)
--- DESCRIPTION:
--- The one three-state rule behind the shared `open_*` window actions
--- (_shared/modules/actions/actions.toml, group "UI"), so a single shortcut
--- both shows and dismisses an Ergopti page.
---
--- FEATURES & RATIONALE:
--- 1. Closed: the page's own opener runs, which opens and focuses it.
--- 2. Open but hidden or behind another window: ui_builder.force_focus
---    presents it. It is never closed, because the user may not see it; a
---    failed focus lookup therefore reads as "covered".
--- 3. Open and focused: the page's own close() runs, the same transaction as
---    its close button.
--- 4. No window state lives here. Each page module answers window() (its
---    current hs.webview or nil) and close(); this table only names them.
--- 5. Four openers need what only the menu session holds (the remap facade,
---    the update channel owner, the menu state, the AI menu's model context):
---    their owner registers them with set_opener(). A toggle that finds no
---    opener refuses loudly instead of opening a window without its context.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "window_toggle"

--- Every toggleable page: its module, the method that opens it when it needs
--- no session context, and the hook names when they differ from the default
--- window() / close().
local PAGES = {
	metrics_typing           = { module = "ui.metrics_typing", open = "show" },
	metrics_apps             = { module = "ui.metrics_apps", open = "show" },
	hotstring_editor         = { module = "ui.hotstring_editor", open = "open" },
	paths_editor             = { module = "ui.menu.menu_paths", open = "open_editor",
		window = "editor_window", close = "close_editor" },
	hotstrings_config_window = { module = "ui.hotstrings_config_window", open = "open" },
	layout_manager           = { module = "ui.layout_manager", open = "open" },
	layer_editor             = { module = "ui.layer_editor" },
	model_browser            = { module = "ui.model_browser" },
	changelog                = { module = "ui.changelog" },
	healthcheck              = { module = "ui.healthcheck", close = "close_window" },
}
M.PAGES = PAGES

-- Openers registered by the owner of their session context, by page id.
local _openers = {}

-- The presentation port, replaced only by tests.
local function default_ui_builder() return require("ui.ui_builder") end
local _ui_builder = default_ui_builder





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Registers the opener of a page that needs session context.
--- @param page string A PAGES id.
--- @param open_fn function Opens and focuses the page; returns true on success.
function M.set_opener(page, open_fn)
	if PAGES[page] == nil then error("window_toggle.set_opener: unknown page '" .. tostring(page) .. "'", 2) end
	if type(open_fn) ~= "function" then error("window_toggle.set_opener: opener must be a function", 2) end
	_openers[page] = open_fn
	Logger.debug(LOG, "Opener registered for page '%s'.", page)
end

--- Calls one named hook of a page module.
--- @param page string Page id, for diagnostics.
--- @param mod table The page module.
--- @param name string The hook name.
--- @return boolean called, any result
local function call_hook(page, mod, name)
	if type(mod[name]) ~= "function" then
		Logger.error(LOG, "Page '%s' exposes no %s() hook; the toggle cannot run.", page, name)
		return false, nil
	end
	local ok, result = xpcall(mod[name], debug.traceback)
	if not ok then
		Logger.error(LOG, "Page '%s' %s() raised: %s.", page, name, tostring(result))
		return false, nil
	end
	return true, result
end

--- Opens a closed page through its opener.
--- @param page string Page id.
--- @param spec table PAGES entry.
--- @param mod table The page module.
--- @return boolean opened
local function open_page(page, spec, mod)
	local opener = _openers[page]
	if opener == nil and spec.open ~= nil then
		local called, result = call_hook(page, mod, spec.open)
		return called and result ~= false
	end
	if opener == nil then
		Logger.error(LOG, "Page '%s' has no registered opener yet; nothing was opened.", page)
		return false
	end
	local ok, result = xpcall(opener, debug.traceback)
	if not ok then
		Logger.error(LOG, "Page '%s' opener raised: %s.", page, tostring(result))
		return false
	end
	return result ~= false
end

--- Toggles one page: closed opens it, hidden or covered presents it,
--- focused closes it.
--- @param page string A PAGES id.
--- @return boolean committed The requested transition was accepted.
function M.toggle(page)
	local spec = PAGES[page]
	if spec == nil then
		Logger.error(LOG, "Toggle refused: unknown page '%s'.", tostring(page))
		return false
	end
	local ok_mod, mod = pcall(require, spec.module)
	if not ok_mod or type(mod) ~= "table" then
		Logger.error(LOG, "Page '%s' module '%s' could not be required: %s.", page, spec.module, tostring(mod))
		return false
	end
	local called, view = call_hook(page, mod, spec.window or "window")
	if not called then return false end
	if view == nil then
		Logger.debug(LOG, "Toggle '%s': closed, opening.", page)
		return open_page(page, spec, mod)
	end
	local UiBuilder = _ui_builder()
	if not UiBuilder.is_window_focused(view) then
		Logger.debug(LOG, "Toggle '%s': open but not focused, bringing to front.", page)
		return UiBuilder.force_focus(view, false) ~= false
	end
	Logger.debug(LOG, "Toggle '%s': focused, closing.", page)
	local closed, result = call_hook(page, mod, spec.close or "close")
	return closed and result ~= false
end

--- Replaces the presentation port (tests only).
--- @param provider function|nil Returns a ui_builder-shaped table; nil restores it.
function M._set_ui_builder(provider)
	_ui_builder = provider or default_ui_builder
end

--- Forgets every registered opener (tests only).
function M._reset_openers()
	_openers = {}
end

return M
