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
---    (_shared/layouts/engine/manager_bridge.lua): an allowlist of actions, each
---    checked against the catalogue or the installed layouts before it runs.
--- 2. Singleton: a second open focuses the existing window. Only the exact
---    window this module created may receive pushes or close, so a late
---    callback of a closed window never writes into its successor.
--- 3. Nothing here runs on the typing path; every operation is asynchronous.
--- 4. The layout editor has its own window (_shared/ui/layout_editor_window),
---    built by the same window factory: the menu's « Create or edit a
---    layout… » and the manager's « Layout editor » button open it, and its
---    controller answers the page's ready with the last saved source.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("infra.logger")
local DeferredWork  = require("infra.deferred_work")
local i18n          = require("infra.i18n")
local Paths         = require("infra.paths")
local FileSystem    = require("adapters.file_system")
local Json          = require("core.text.engine.json")
local ManagerBridge = require("layouts.engine.manager_bridge")
local ControllerPool = require("ui.webview_controller_pool").new(function(name)
	return hs.webview.usercontent.new(name)
end, Logger)

local LOG = "layout_manager"

-- The two windows this module hosts: the page each one loads, the strings it
-- declares next to it, its usercontent role (ui/webview_controller_pool) and
-- its geometry entry (_shared/ui/apps.manifest.json).
local MANAGER_SPEC = {
	app = require("settings.engine.keys").COMMAND.LAYOUT_MANAGER,
	label = "layout manager",
	title_key = "layout_manager.window_title",
	strings_file = "ui/layout_manager/strings.json",
	editor_window = false,
}
local EDITOR_SPEC = {
	app = "layout_editor_window",
	label = "layout editor window",
	title_key = "layout_editor.title",
	strings_file = "ui/layout_editor_window/strings.json",
	editor_window = true,
}

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

-- Reloads the driver after a layout's hotstring extension changed (LMH-004),
-- bound by the menu (M.set_extension_reloader); nil until then.
local _extension_reloader = nil





-- ================================
-- ================================
-- ======= 1/ Page plumbing =======
-- ================================
-- ================================

--- The translated strings a page shows.
--- @param strings_file string|nil The page's strings.json under _shared (the manager's by default).
--- @return table key -> text
local function page_strings(strings_file)
	local path = Paths.shared(strings_file or MANAGER_SPEC.strings_file)
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	local ok, doc = pcall(Json.decode, raw or "")
	local strings = {}
	if not ok or type(doc) ~= "table" or type(doc.keys) ~= "table" then
		Logger.error(LOG, "The layout window strings list %s is unreadable.", tostring(path))
		return strings
	end
	for _, key in ipairs(doc.keys) do strings[key] = i18n.get(key) end
	return strings
end

--- Opens a native panel for the layout editor and reads the chosen file
--- within the store's bounds; WKWebView shows no panel for <input type="file">.
--- @param on_done function on_done({filename, text} | {} | {code, detail})
local function pick_source(on_done)
	local SourceStore = require("layouts.engine.composer.source_store")
	local DialogUtil = require("infra.dialog_util")
	local ok_defaults, defaults = pcall(Json.decode, FileSystem.read(Paths.shared("layouts/data/defaults.json")) or "")
	local settings, settings_err = SourceStore.settings(ok_defaults and defaults or nil)
	if not settings then
		Logger.error(LOG, "The layout editor cannot open files: %s.", tostring(settings_err))
		on_done({ code = require("modules.keymap.layout_registry").FAILURE_INVALID, detail = settings_err })
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





-- =================================
-- =================================
-- ======= 2/ Window factory =======
-- =================================
-- =================================

--- Builds one window of this module: the layout manager or the layout editor.
--- Each one owns its exact window, message channel and controller, so a late
--- callback of one never writes into the other or into its own successor.
--- @param spec table MANAGER_SPEC or EDITOR_SPEC.
--- @return table window { open, close, window, controller, controller_for }
local function new_window(spec)
	local W = {}

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
				pcall(Logger.error, LOG, "The %s candidate cleanup remains pending: %s.", spec.label, tostring(result))
				_settling_retired_window = false
				return false
			end
			if _retiring_window == view then _retiring_window = nil end
		end
		local bridge = _retiring_usercontent
		if bridge ~= nil then
			local released, result = ControllerPool.release(_retiring_lease)
			if not released then
				pcall(Logger.error, LOG, "The %s callback cleanup remains pending: %s.", spec.label, tostring(result))
				_settling_retired_window = false
				return false
			end
			if _retiring_usercontent == bridge then _retiring_usercontent, _retiring_lease = nil, nil end
		end
		_settling_retired_window = false
		return true
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
			Logger.error(LOG, "The %s %s payload could not be encoded.", spec.label, function_name)
			return false
		end
		local submitted = pcall(function()
			view:evaluateJavaScript("if(window." .. function_name .. ")window." .. function_name .. "(" .. encoded .. ")")
		end)
		if not submitted then Logger.error(LOG, "The %s %s push was refused.", spec.label, function_name) end
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

	--- The controller of one window, bound to that exact window.
	--- @param view any
	--- @return table
	local function controller_for(view)
		local controller = ManagerBridge.new({
			registry = require("modules.keymap.layout_registry"),
			push = function(function_name, payload) return push_to(view, function_name, payload) end,
			strings = function() return page_strings(spec.strings_file) end,
			editor_window = spec.editor_window,
			open_editor_window = not spec.editor_window and function() return M.open_editor() end or nil,
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
			reload_extensions = function(id) return _extension_reloader ~= nil and _extension_reloader(id) == true end,
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

	--- Opens this window, or focuses it when it is already open.
	--- @return boolean opened
	function W.open()
		if _opening_window then return false end
		if settle_retired_window() ~= true then return false end
		local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
		if not ok_ui then
			Logger.error(LOG, "The %s cannot open: ui_builder is unavailable.", spec.label)
			return false
		end
		if _webview ~= nil then
			local view = _webview
			return ui_builder.force_focus(view, false, { is_current = function()
				return rawequal(_webview, view)
			end }) ~= false
		end
		_opening_window = true
		Logger.start(LOG, "Opening the %s…", spec.label)
		-- Each window names its own manifest entry (test-webview-geometry-single-source).
		local geo
		if spec.editor_window then
			geo = ui_builder.get_app_geometry("layout_editor_window")
		else
			geo = ui_builder.get_app_geometry("layout_manager")
		end
		if not geo then _opening_window = false; return false end
		local lease, uc = ControllerPool.reserve(spec.app)
		if not lease then
			_opening_window = false
			Logger.error(LOG, "The %s message channel could not be created.", spec.label)
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
			Logger.error(LOG, "The %s callback binding did not commit: %s.", spec.label, tostring(bind_error))
			return false
		end
		local masks = hs.webview.windowMasks
		local created, view = pcall(function() return ui_builder.show_webview({
			delete_on_close = true,
			frame = ui_builder.get_centered_frame(geo.width, geo.height),
			title = i18n.get(spec.title_key),
			style_masks = (masks["titled"] or 1) + (masks["closable"] or 2) + (masks["resizable"] or 8),
			usercontent = uc,
			assets_dir = (Paths.shared("ui/" .. spec.app) or "") .. "/",
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
					end, spec.app .. ".navigation")
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
			pcall(Logger.error, LOG, "The %s native construction failed: %s.", spec.label, tostring(view))
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
			Logger.error(LOG, "The %s could not be created.", spec.label)
			return false
		end
		if not ControllerPool.commit(lease) then
			close_window()
			_opening_window = false
			return false
		end
		_opening_window = false
		Logger.success(LOG, "The %s opened.", spec.label)
		return true
	end

	--- The open window (nil when closed).
	function W.window() return _webview end

	--- Closes the window this factory created.
	function W.close() return close_window() end

	--- The controller of the open window (nil when closed).
	function W.controller() return _controller end

	W.controller_for = controller_for
	return W
end

local Manager = new_window(MANAGER_SPEC)
local Editor = new_window(EDITOR_SPEC)





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

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

--- Binds the driver reload that follows a change of a layout's extension.
--- @param reloader function|nil reloader(id) returns true when the reload started.
function M.set_extension_reloader(reloader)
	if reloader ~= nil and type(reloader) ~= "function" then
		error("layout_manager.set_extension_reloader: a function or nil is required", 2)
	end
	_extension_reloader = reloader
end

--- Opens the layout manager, or focuses it when it is already open.
--- @return boolean opened
function M.open() return Manager.open() end

--- Opens the layout editor in its own window (the menu's « Create or edit a
--- layout… », the manager's « Layout editor »), or focuses it when it is
--- already open: an open editor keeps its unsaved work. A new window shows the
--- last saved source once its page is ready.
--- @return boolean opened
function M.open_editor() return Editor.open() end

--- The open layout manager window, for ui/window_toggle (nil when closed).
--- @return userdata|nil view
function M.window() return Manager.window() end

--- Closes the layout manager window, for ui/window_toggle.
--- @return boolean committed
function M.close() return Manager.close() end

--- The open layout editor window (nil when closed).
--- @return userdata|nil view
function M.editor_window() return Editor.window() end

--- Closes the layout editor window.
--- @return boolean committed
function M.close_editor() return Editor.close() end

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

-- Test seams: each window's controller factory and the strings of a page.
M._controller_for = Manager.controller_for
M._editor_controller_for = Editor.controller_for
M._page_strings = page_strings

return M
