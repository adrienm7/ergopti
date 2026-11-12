--- ui/layout_manager/init.lua

--- ==============================================================================
--- MODULE: Layout Manager Window (macOS host)
--- DESCRIPTION:
--- Hosts the shared layout manager page (_shared/ui/layout_manager) in a
--- WKWebView: the "Manage layouts…" row of the keyboard-layout submenu opens
--- it, and it lists, installs, updates, uninstalls and selects the layouts of
--- the registry through modules/keymap/layout_registry.lua.
---
--- FEATURES & RATIONALE:
--- 1. The message rules and the page state are shared with Linux
---    (_shared/lua/layouts/manager_bridge.lua): an allowlist of actions, each
---    checked against the catalogue or the installed layouts before it runs.
--- 2. Singleton: a second open focuses the existing window. Only the exact
---    window this module created may receive pushes or close, so a late
---    callback of a closed window never writes into its successor.
--- 3. Nothing here runs on the typing path; every operation is asynchronous.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("infra.logger")
local DeferredWork  = require("infra.deferred_work")
local i18n          = require("infra.i18n")
local Paths         = require("infra.paths")
local FileSystem    = require("adapters.file_system")
local Json          = require("json")
local ManagerBridge = require("layouts.manager_bridge")
local ControllerPool = require("ui.webview_controller_pool").new(function(name)
	return hs.webview.usercontent.new(name)
end, Logger)

local LOG = "layout_manager"

-- Every string the page shows, declared next to it.
local STRINGS_FILE = "ui/layout_manager/strings.json"

-- The exact window this module created, and its message channel.
local _webview = nil
local _usercontent = nil
local _controller_lease = nil
local _controller = nil
local _retiring_window = nil
local _retiring_window_has_metadata = false
local _retiring_usercontent = nil
local _retiring_lease = nil
local _settling_retired_window = false
local _opening_window = false

-- Applies a layers.toml the layout editor built from a source's navigation
-- layer: the navigation layer editor's own save, bound to the remap facade by
-- the menu (M.set_nav_applier); nil until then, and nav_save is refused.
local _nav_applier = nil

-- « Emulate without installing »: makes the composed layout the emulated one and
-- reloads the layout emulation, bound to the preferences by the menu
-- (M.set_emulation_applier); nil until then, and composer_emulate is refused.
local _emulation_applier = nil

-- Reloads the layout emulation and the menu after a layout changed, when it is
-- the emulated one (LMH-001, LMH-002), bound by the menu
-- (M.set_layout_change_handler); nil until then.
local _layout_change_handler = nil

-- Reports whether the driver is paused, bound by the menu (M.set_pause_query):
-- a paused driver admits only the page's ready signal, as on Windows (LMH-003).
-- nil until then, and every command is admitted.
local _pause_query = nil

--- Settles exact window and callback owners before admitting another window.
--- @return boolean settled Native cleanup committed or already consumed the window.
local function settle_retired_window()
	if _settling_retired_window then return false end
	_settling_retired_window = true
	local view = _retiring_window
	if view ~= nil then
		local metadata = _retiring_window_has_metadata
		local ok, result = pcall(function()
			if not metadata or getmetatable(view) ~= nil then return view:delete() end
		end)
		local settled = (ok and result ~= false) or (metadata and getmetatable(view) == nil)
		if not settled then
			pcall(Logger.error, LOG, "The layout manager candidate cleanup remains pending: %s.", tostring(result))
			_settling_retired_window = false
			return false
		end
		if _retiring_window == view then _retiring_window = nil end
	end
	local bridge = _retiring_usercontent
	if bridge ~= nil then
		local released, result = ControllerPool.release(_retiring_lease)
		if not released then
			pcall(Logger.error, LOG, "The layout manager callback cleanup remains pending: %s.", tostring(result))
			_settling_retired_window = false
			return false
		end
		if _retiring_usercontent == bridge then _retiring_usercontent, _retiring_lease = nil, nil end
	end
	_settling_retired_window = false
	return true
end





-- ================================
-- ================================
-- ======= 1/ Page plumbing =======
-- ================================
-- ================================

--- The translated strings the page shows.
--- @return table key -> text
local function page_strings()
	local path = Paths.shared(STRINGS_FILE)
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	local ok, doc = pcall(Json.decode, raw or "")
	local strings = {}
	if not ok or type(doc) ~= "table" or type(doc.keys) ~= "table" then
		Logger.error(LOG, "The layout manager strings list %s is unreadable.", tostring(path))
		return strings
	end
	for _, key in ipairs(doc.keys) do strings[key] = i18n.get(key) end
	return strings
end

--- Evaluates window.<function_name>(payload) in the exact window.
--- @param view any The window the push is meant for.
--- @param function_name string
--- @param payload table
--- @return boolean pushed
local function push_to(view, function_name, payload)
	if view == nil or view ~= _webview then return false end
	local ok, encoded = pcall(Json.encode, payload)
	if not ok or type(encoded) ~= "string" then
		Logger.error(LOG, "The layout manager %s payload could not be encoded.", function_name)
		return false
	end
	local submitted = pcall(function()
		view:evaluateJavaScript("if(window." .. function_name .. ")window." .. function_name .. "(" .. encoded .. ")")
	end)
	if not submitted then Logger.error(LOG, "The layout manager %s push was refused.", function_name) end
	return submitted
end

--- Closes the window this module created.
local function close_window()
	if _settling_retired_window then return false end
	_retiring_window, _retiring_usercontent = _webview, _usercontent
	_retiring_lease = _controller_lease
	_retiring_window_has_metadata = type(_webview) == "userdata" or getmetatable(_webview) ~= nil
	_webview, _usercontent, _controller, _controller_lease = nil, nil, nil, nil
	return settle_retired_window()
end

--- Opens a native panel for the layout editor and reads the chosen file
--- within the store's bounds; WKWebView shows no panel for <input type="file">.
--- @param on_done function on_done({filename, text} | {} | {code, detail})
local function pick_source(on_done)
	local SourceStore = require("layouts.source_store")
	local DialogUtil = require("infra.dialog_util")
	local ok_defaults, defaults = pcall(Json.decode, FileSystem.read(Paths.shared("modules/layouts/defaults.json")) or "")
	local settings, settings_err = SourceStore.settings(ok_defaults and defaults or nil)
	if not settings then
		Logger.error(LOG, "The layout editor cannot open files: %s.", tostring(settings_err))
		on_done({ code = SourceStore.FAILURE_INVALID, detail = settings_err })
		return
	end
	local path = DialogUtil.choose_layout_source(i18n.get("layout_editor.pick_message"),
		i18n.get("layout_editor.pick_title"))
	if not path then
		on_done({})
		return
	end
	local picked = SourceStore.read_picked(settings, path, FileSystem.read)
	if picked.code then Logger.warn(LOG, "Refused to open %s in the layout editor: %s.", path, picked.detail) end
	on_done(picked)
end

--- The controller of one window, bound to that exact window.
--- @param view any
--- @return table
local function controller_for(view)
	local controller = ManagerBridge.new({
		registry = require("modules.keymap.layout_registry"),
		push = function(function_name, payload) return push_to(view, function_name, payload) end,
		strings = page_strings,
		open_url = function(url)
			local ok, ui_builder = pcall(require, "ui.ui_builder")
			if ok then ui_builder.open_http_url(url) end
		end,
		close = function()
			if view == _webview then close_window() end
		end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
		pick_source = pick_source,
		layout_changed = function(id)
			if _layout_change_handler then _layout_change_handler(id) end
		end,
		is_paused = function() return _pause_query ~= nil and _pause_query() == true end,
		apply_nav = _nav_applier and function(text, on_done)
			local applier = _nav_applier
			if not applier then
				on_done({ saved = false, applied = false, errors = {} })
				return
			end
			on_done(applier(text))
		end or nil,
		emulate = _emulation_applier and function(id, on_done)
			local applier = _emulation_applier
			if not applier then
				on_done(false, "emulate_failed", "the layout emulation is not bound")
				return
			end
			on_done(applier(id))
		end or nil,
	})
	local on_message = controller.on_message
	local ready = false
	controller.on_message = function(payload)
		local is_ready = type(payload) == "table" and payload.action == "ready"
		if is_ready then
			if ready then return false end
			-- Native navigation and page readiness both target this exact window.
			ready = true
		end
		local ok, result = pcall(on_message, payload)
		if not ok then
			if is_ready then ready = false end
			error(result, 0)
		end
		return result
	end
	return controller
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Opens the layout manager, or focuses it when it is already open.
--- @return boolean opened
function M.open()
	if _opening_window then return false end
	if settle_retired_window() ~= true then return false end
	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if not ok_ui then
		Logger.error(LOG, "The layout manager cannot open: ui_builder is unavailable.")
		return false
	end
	if _webview ~= nil then
		local view = _webview
		return ui_builder.force_focus(view, false, { is_current = function()
			return rawequal(_webview, view)
		end }) ~= false
	end
	_opening_window = true
	Logger.start(LOG, "Opening the layout manager…")
	local geo = ui_builder.get_app_geometry("layout_manager")
	if not geo then _opening_window = false; return false end
	local lease, uc = ControllerPool.reserve("layout_manager")
	if not lease then
		_opening_window = false
		Logger.error(LOG, "The layout manager message channel could not be created.")
		return false
	end
	local candidate = nil
	local bound, bind_error = ControllerPool.bind(lease, function(message)
		if candidate == nil or candidate ~= _webview or _controller == nil then return end
		if message and type(message.body) == "table" then _controller.on_message(message.body) end
	end)
	if not bound then
		_retiring_usercontent, _retiring_lease = uc, lease
		settle_retired_window()
		_opening_window = false
		Logger.error(LOG, "The layout manager callback binding did not commit: %s.", tostring(bind_error))
		return false
	end
	local masks = hs.webview.windowMasks
	local created, view = pcall(function() return ui_builder.show_webview({
		delete_on_close = true,
		frame = ui_builder.get_centered_frame(geo.width, geo.height),
		title = i18n.get("layout_manager.window_title"),
		style_masks = (masks["titled"] or 1) + (masks["closable"] or 2) + (masks["resizable"] or 8),
		usercontent = uc,
		assets_dir = (Paths.shared("ui/layout_manager") or "") .. "/",
		on_close = function()
			if candidate ~= nil and candidate == _webview then
				_retiring_usercontent = _usercontent
				_retiring_lease = _controller_lease
				_webview, _usercontent, _controller, _controller_lease = nil, nil, nil, nil
				settle_retired_window()
			end
		end,
		on_navigation = function(action)
			if action == "didFinishNavigation" and candidate ~= nil and candidate == _webview and _controller then
				DeferredWork.after(require("infra.timings").sec("ui", "ui_handoff_ms"), function()
					if candidate == _webview and _controller then _controller.on_message({ action = "ready" }) end
				end, "layout_manager.navigation")
			end
			return true
		end,
		on_webview_created = function(owned)
			if _webview ~= nil then return false end
			candidate = owned
			if not ControllerPool.attach(lease, owned) then return false end
			_webview, _usercontent = owned, uc
			_controller_lease = lease
			_controller = controller_for(owned)
			return true
		end,
		is_current = function() return candidate ~= nil and candidate == _webview end,
	}) end)
	if not created then
		pcall(Logger.error, LOG, "The layout manager native construction failed: %s.", tostring(view))
		view = nil
	end
	if view == nil or view ~= candidate then
		-- on_webview_created transferred cleanup to this caller before the factory
		-- could reject a required mutation. Retain that exact candidate for retry.
		_retiring_usercontent, _retiring_lease = uc, lease
		if candidate ~= nil then
			_retiring_window = candidate
			_retiring_window_has_metadata = type(candidate) == "userdata" or getmetatable(candidate) ~= nil
		end
		if _webview == candidate then _webview, _usercontent, _controller, _controller_lease = nil, nil, nil, nil end
		settle_retired_window()
		_opening_window = false
		Logger.error(LOG, "The layout manager window could not be created.")
		return false
	end
	if not ControllerPool.commit(lease) then
		close_window()
		_opening_window = false
		return false
	end
	_opening_window = false
	Logger.success(LOG, "Layout manager opened.")
	return true
end

--- Binds the layout editor's « Apply the navigation layer » to the navigation
--- layer editor's save (ui/layer_editor apply_text). A window opened before
--- this offers no such button.
--- @param applier function|nil applier(text) -> { saved, applied, errors }
function M.set_nav_applier(applier)
	if applier ~= nil and type(applier) ~= "function" then
		error("layout_manager.set_nav_applier: a function or nil is required", 2)
	end
	_nav_applier = applier
end

--- Binds « Emulate without installing » to the layout emulation preferences.
--- A window opened before this offers no such button.
--- @param applier function|nil applier(id) -> ok, code, detail
function M.set_emulation_applier(applier)
	if applier ~= nil and type(applier) ~= "function" then
		error("layout_manager.set_emulation_applier: a function or nil is required", 2)
	end
	_emulation_applier = applier
end

--- Binds the reload that follows a change of the emulated layout.
--- @param handler function|nil handler(id) after a layout was installed, updated,
---   uninstalled, saved or removed.
function M.set_layout_change_handler(handler)
	if handler ~= nil and type(handler) ~= "function" then
		error("layout_manager.set_layout_change_handler: a function or nil is required", 2)
	end
	_layout_change_handler = handler
end

--- Binds the pause state the bridge reads before admitting a page command.
--- @param query function|nil query() returns true while the driver is paused.
function M.set_pause_query(query)
	if query ~= nil and type(query) ~= "function" then
		error("layout_manager.set_pause_query: a function or nil is required", 2)
	end
	_pause_query = query
end

--- Opens the layout manager straight on the layout editor (the menu's « Create
--- or edit a layout… »): the page shows it once it is ready.
--- @return boolean opened
function M.open_editor()
	local opened = M.open()
	if _controller == nil then return false end
	return _controller.open_editor() and opened ~= false
end

--- The open window, for ui/window_toggle (nil when closed).
--- @return userdata|nil view
function M.window() return _webview end

--- Closes the window this module created, for ui/window_toggle.
--- @return boolean committed
function M.close() return close_window() end

--- Builds the "Manage layouts…" menu command.
--- @return function
function M.menu_command()
	return function()
		DeferredWork.after(require("infra.timings").sec("ui", "ui_handoff_ms"), M.open, "layout_manager.open")
	end
end

--- Builds the « Create or edit a layout… » menu command.
--- @return function
function M.editor_menu_command()
	return function()
		DeferredWork.after(require("infra.timings").sec("ui", "ui_handoff_ms"), M.open_editor,
			"layout_manager.open_editor")
	end
end

-- Test seams: the controller factory and the exact-window push.
M._controller_for = controller_for
M._page_strings = page_strings

return M
