--- ui/layer_editor/init.lua

--- ==============================================================================
--- MODULE: Navigation Layer Editor (macOS host)
--- DESCRIPTION:
--- Shows the shared navigation layer editor (_shared/ui/layer_editor) in a
--- webview, answers its "ready" with the user's layers.toml, the legends of the
--- current input source and the key whose hold enters the layer, and saves
--- what it sends through the window-free modules/keymap/nav_layer_save.lua,
--- which the layout editor's « Apply the navigation layer » calls too; this
--- host only adds the page's exact opening source and its answers.
---
--- FEATURES & RATIONALE:
--- 1. One window: a second open brings the first to the front.
--- 2. A message counts only for the session that owns the window: a late
---    message from a window already closed can neither save nor close a new one.
--- 3. A refused save keeps the window open with the reason. A saved file whose
---    regeneration cannot even be requested keeps it open too, saying the file
---    is written but not applied yet; otherwise the window closes at once. A
---    regeneration that fails later, once the window is gone, says so in an
---    error notification (maintainer decision LEH-003, 2026-11-12): Windows and
---    Linux apply synchronously, before their window closes.
--- 4. Legends: each key that types a character shows what the current input
---    source puts on it (infra/keycodes over hs.keycodes.map, which follows the
---    input source live), read in the registry's ISO form the navigation layer
---    is generated for. While a layout is emulated
---    (modules/keymap/layout_emulation), a key shows what the emulation types
---    there and the source is « emulation », as on Windows (LEH-001); a key it
---    leaves to the input source shows the input source's character. The page
---    asks again when its window comes back to the front, so a switch made
---    meanwhile shows.
--- 5. The layer key is the tap-hold key whose hold is the layer action
---    (NavLayer.HOLD_ACTION_ID) in the remap facade's configuration, found in
---    the registry by its Karabiner key code.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("core.logger.engine.logger")
local i18n        = require("core.i18n.engine.i18n")
local Paths       = require("core.fs.engine.paths")
local ConfigPaths = require("settings.engine.paths")
local FileSystem  = require("core.fs.adapters.file_system")
local ui_builder  = require("core.ui.ui.builder")
local Json        = require("core.text.engine.json")
local TomlCodec   = require("core.text.engine.toml_codec")
local TomlWriter  = require("core.text.engine.toml_codec.writer")
local Layers      = require("layouts.engine.layers.layers")
local LayerEditor = require("layouts.engine.layers.editor")
local Keycodes    = require("platform.input.keycodes")
local NavLayerSave = require("modules.keymap.nav_layer_save")

local LOG = "layer_editor"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- The shared page, its entry in _shared/ui/apps.manifest.json and the message
-- handler it posts to (_shared/ui/host_bridge.js).
local APP_ID = "layer_editor"
local BRIDGE_NAME = "layer_editor_bridge"
local OS = "macos"

-- The one open window, if any: { serial, webview, usercontent, karabiner }.
local _session = nil
local _serial = 0





-- ==========================
-- ==========================
-- ======= 2/ Helpers =======
-- ==========================
-- ==========================

--- The legends of the layout the user types with: the emulated one, else the
--- current input source.
--- @param ctx table The loader context.
--- @return table legends The page's `legends`.
local function current_legends(ctx)
	local Emulation = require("modules.keymap.layout_emulation")
	local emulating = Emulation.status().active == true
	local legends, unresolved = LayerEditor.legends({
		ctx       = ctx,
		source    = emulating and LayerEditor.LEGEND_SOURCE_EMULATION or LayerEditor.LEGEND_SOURCE_OS,
		character = function(code, entry)
			local emulated = emulating and Emulation.legend(code) or nil
			if emulated ~= nil then return emulated end
			local keycode = NavLayerSave.iso_field(entry, "hs")
			return type(keycode) == "number" and Keycodes.character_for(keycode) or nil
		end,
	})
	LayerEditor.report_unresolved(unresolved, "the current input source types nothing printable there",
		function(message) Logger.warn(LOG, "%s", message) end)
	return legends
end

--- Calls one of the page's functions with a JSON payload.
--- @param session table The session whose page is called.
--- @param fn_name string init | saveResult.
--- @param payload table The argument.
--- @return boolean called
local function call_page(session, fn_name, payload)
	if _session ~= session or not session.webview then return false end
	local encoded = Json.encode(payload)
	if type(encoded) ~= "string" then
		Logger.error(LOG, "The %s payload could not be encoded for the page.", fn_name)
		return false
	end
	local ok, err = pcall(function()
		session.webview:evaluateJavaScript("if(window." .. fn_name .. ")window." .. fn_name .. "(" .. encoded .. ")")
	end)
	if not ok then Logger.error(LOG, "The page's %s() could not be called: %s.", fn_name, tostring(err)) end
	return ok
end

--- Closes one session's window; a stale session closes nothing.
--- @param session table
--- @return boolean committed True after the window and bridge are released.
local function close_session(session)
	if _session ~= session then return false end
	if session.closing then return false end
	session.retired = true
	session.closing = true
	local webview = session.webview
	if webview then
		local ok, err = pcall(function() webview:delete() end)
		if not ok then
			session.closing = false
			Logger.error(LOG, "The layer editor window could not be closed; exact owner retained: %s.", tostring(err))
			return false
		end
		session.webview = nil
	end
	if session.usercontent then
		local ok, err = pcall(function() session.usercontent:setCallback(nil) end)
		if not ok then
			session.closing = false
			Logger.error(LOG, "The layer editor bridge could not be released; exact owner retained: %s.", tostring(err))
			return false
		end
		session.usercontent = nil
	end
	session.closing = false
	_session = nil
	Logger.info(LOG, "Layer editor closed.")
	return true
end





-- ================================
-- ================================
-- ======= 3/ Page messages =======
-- ================================
-- ================================

--- Tests whether the original page and configuration folder still own this draft.
local function opening_current(session, opening)
	local function identities_current()
		return _session == session and not session.retired and session.opening == opening
			and rawequal(package.loaded["settings.engine.paths"], ConfigPaths)
			and rawequal(package.loaded["core.fs.adapters.file_system"], FileSystem)
			and FileSystem.read_with_status == opening.read_with_status
			and FileSystem.write_if_unchanged_admitted == opening.publish
			and ConfigPaths.get_config_dir == opening.get_config_dir
	end
	if not identities_current() then return false end
	local ok, dir = pcall(opening.get_config_dir)
	return ok and dir == opening.config_dir and identities_current()
end
--- Sends the original page the original classified source, including on retry.
--- @param session table
local function push_init(session)
	if _session ~= session or session.retired or not session.webview then return end
	local opening = session.opening
	if not opening then
		local ok_ctx, ctx = pcall(NavLayerSave.load_context)
		if not ok_ctx then
			Logger.error(LOG, "The layer data could not be read: %s.", tostring(ctx))
			return
		end
		local get_config_dir = ConfigPaths.get_config_dir
		local dir_ok, config_dir = pcall(get_config_dir)
		if not dir_ok or type(config_dir) ~= "string" or config_dir == "" then return end
		local path = Layers.user_file_path(config_dir, ctx)
		local read_with_status, publish = FileSystem.read_with_status, FileSystem.write_if_unchanged_admitted
		local content, status, detail = TomlWriter.read_classified(path, FileSystem)
		opening = { get_config_dir = get_config_dir, config_dir = config_dir, path = path,
			read_with_status = read_with_status, publish = publish,
			ctx = ctx, source = { status = status, content = content }, detail = detail }
		session.opening = opening
		opening.payload = LayerEditor.init_payload({
			os = OS, ctx = ctx, config_dir = config_dir,
			read_file = function()
				if status == "ok" then return content end
				if status == "absent" then return nil end
				error(detail or "the layer file is unreadable", 0)
			end,
			toml_decode = TomlCodec.decode, legends = current_legends(ctx),
			layer_keys = NavLayerSave.layer_keys(ctx, session.karabiner),
		})
	end
	if not opening_current(session, opening) then return end
	local offered = call_page(session, "init", opening.payload)
	opening.offered = offered == true and opening_current(session, opening)
end

--- Adapts the shared writer to the source retained when the page opened.
local function opening_files(session, opening)
	local function publish(path, content, _, _, outer_admission)
		if path ~= opening.path or not opening_current(session, opening) then
			return false, "the layer editor source is no longer current"
		end
		local written, detail, receipt = TomlWriter.publish_if_unchanged(path, content, FileSystem,
			opening.source, nil, function()
				return opening_current(session, opening)
					and (outer_admission == nil or outer_admission() == true)
					and opening_current(session, opening)
			end)
		if written == true and opening_current(session, opening) then
			opening.source = { status = "ok", content = content }
		end
		return written, detail, receipt
	end
	return {
		read_with_status = function(path)
			if path ~= opening.path or not opening_current(session, opening) then
				return nil, "error", "the layer editor source is no longer current"
			end
			return FileSystem.read_with_status(path)
		end,
		write_if_unchanged = publish,
		write_if_unchanged_admitted = publish,
	}
end

--- Sends the page the legends of the input source in use now.
--- @param session table
local function push_legends(session)
	local ok_ctx, ctx = pcall(NavLayerSave.load_context)
	if not ok_ctx then
		Logger.error(LOG, "The layer data could not be read: %s.", tostring(ctx))
		return
	end
	call_page(session, "setLegends", current_legends(ctx))
end

--- Validates and saves the page's text, then applies it.
--- @param session table
--- @param text any The payload's text.
local function save(session, text)
	Logger.start(LOG, "Saving the navigation layer…")
	local opening = session.opening
	if not opening or opening.offered ~= true or not opening_current(session, opening)
		or (opening.source.status ~= "ok" and opening.source.status ~= "absent") then
		call_page(session, "saveResult", { saved = false,
			errors = { { code = LayerEditor.WRITE_FAILED, detail = "the layer editor source is no longer current" } } })
		return
	end
	local result = NavLayerSave.save({
		text = text, ctx = opening.ctx, config_dir = opening.config_dir,
		file_adapter = opening_files(session, opening), karabiner = session.karabiner,
		current = function() return opening_current(session, opening) end,
	})
	call_page(session, "saveResult", { saved = result.saved, applied = result.applied, errors = result.errors })
	if result.applied then close_session(session) end
end

--- Routes one message of the page.
--- @param session table The session the message's bridge belongs to.
--- @param body any The posted payload.
function M._on_message(session, body)
	if _session ~= session then return end
	if session.retired then
		if type(body) == "table" and body.action == "cancel" then close_session(session) end
		return
	end
	if body == "ready" then
		push_init(session)
	elseif type(body) ~= "table" then
		Logger.warn(LOG, "Ignored a layer editor message of type %s.", type(body))
	elseif body.action == "save" then
		save(session, body.text)
	elseif body.action == "cancel" then
		close_session(session)
	elseif body.action == "legends" then
		push_legends(session)
	else
		Logger.warn(LOG, "Ignored the unknown layer editor action '%s'.", tostring(body.action))
	end
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Opens the editor, or brings the open one to the front.
--- @param opts table { karabiner = the remap facade, whose regenerate() applies the saved layer }.
--- @return boolean shown
function M.open(opts)
	local karabiner = type(opts) == "table" and opts.karabiner or nil
	if type(karabiner) ~= "table" or type(karabiner.regenerate) ~= "function" then
		Logger.error(LOG, "The layer editor needs the remap facade to apply what it saves.")
		return false
	end
	if _session and _session.retired then
		if close_session(_session) ~= true then return false end
	end
	if _session then
		_session.karabiner = karabiner
		local session, view = _session, _session.webview
		if view then
			ui_builder.force_focus(view, false, { is_current = function()
				return _session == session and session.webview == view
			end })
		end
		return true
	end
	local geo = ui_builder.get_app_geometry("layer_editor")
	if not geo then return false end
	local ok_uc, uc = pcall(hs.webview.usercontent.new, BRIDGE_NAME)
	if not ok_uc or not uc then
		Logger.error(LOG, "The layer editor bridge could not be created.")
		return false
	end
	_serial = _serial + 1
	local session = { serial = _serial, usercontent = uc, karabiner = karabiner }
	_session = session
	uc:setCallback(function(message)
		M._on_message(session, type(message) == "table" and message.body or nil)
	end)
	local ok_view, webview = pcall(ui_builder.show_webview, {
		delete_on_close = true,
		frame         = ui_builder.get_centered_frame(geo.width, geo.height),
		title         = i18n.get("layer_editor.window_title"),
		style_masks   = { "titled", "closable", "resizable" },
		usercontent   = uc,
		assets_dir    = (Paths.shared("ui/" .. APP_ID) or "") .. "/",
		on_navigation = function(action)
			if action == "didFinishNavigation" then push_init(session) end
			return true
		end,
		on_close      = function()
			if _session == session and not session.closing then
				session.webview = nil
				close_session(session)
			end
		end,
	})
	if not ok_view or not webview then
		Logger.error(LOG, "The layer editor window could not be created: %s.", tostring(webview))
		close_session(session)
		return false
	end
	if _session ~= session then
		pcall(function() webview:delete() end)
		return false
	end
	session.webview = webview
	Logger.info(LOG, "Layer editor opened.")
	return true
end

--- The open window, for ui/window_toggle (nil when closed).
--- @return userdata|nil view
function M.window() return _session and _session.webview or nil end

--- Closes the editor if it is open.
--- @return boolean committed True when no native resource remains owned.
function M.close()
	if _session then return close_session(_session) end
	return true
end

return M
