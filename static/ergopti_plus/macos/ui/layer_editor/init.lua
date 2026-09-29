--- ui/layer_editor/init.lua

--- ==============================================================================
--- MODULE: Navigation Layer Editor (macOS host)
--- DESCRIPTION:
--- Shows the shared navigation layer editor (_shared/ui/layer_editor) in a
--- webview, answers its "ready" with the user's layers.toml, and saves what it
--- sends. The shared host logic (_shared/lua/keymap/layer_editor.lua) checks
--- the text against every OS's loader and publishes it through the atomic
--- FileSystem adapter; the Karabiner rules are then regenerated, and every
--- regeneration reads layers.toml again, so the edited layer applies.
---
--- FEATURES & RATIONALE:
--- 1. One window: a second open brings the first to the front.
--- 2. A message counts only for the session that owns the window: a late
---    message from a window already closed can neither save nor close a new one.
--- 3. A refused save keeps the window open with the reason. A saved file whose
---    regeneration cannot even be requested keeps it open too, saying the file
---    is written but not applied yet; otherwise the window closes.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("infra.logger")
local i18n        = require("infra.i18n")
local Paths       = require("infra.paths")
local ConfigPaths = require("infra.config_paths")
local FileSystem  = require("adapters.file_system")
local ui_builder  = require("ui.ui_builder")
local Json        = require("json")
local TomlCodec   = require("toml_codec")
local Layers      = require("keymap.layers")
local LayerEditor = require("keymap.layer_editor")

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

--- The layer loader's context, read from the shipped registry and vocabulary.
--- @return table ctx
local function load_context()
	return Layers.load_context({
		shared_root = Paths.shared_root(),
		json_decode = Json.decode,
		toml_decode = TomlCodec.decode,
		read_file   = LayerEditor.read_shipped,
	})
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
local function close_session(session)
	if _session ~= session then return end
	_session = nil
	local webview = session.webview
	session.webview = nil
	if webview then
		local ok, err = pcall(function() webview:delete() end)
		if not ok then Logger.error(LOG, "The layer editor window could not be closed: %s.", tostring(err)) end
	end
	if session.usercontent then pcall(function() session.usercontent:setCallback(nil) end) end
	Logger.info(LOG, "Layer editor closed.")
end

--- Asks the remap engine to regenerate the Karabiner rules.
--- @param karabiner table The remap facade.
--- @return boolean requested True when the regeneration was accepted.
local function request_regeneration(karabiner)
	local ok, accepted = pcall(karabiner.regenerate, function(done, reason)
		if done ~= true then
			Logger.warn(LOG, "The edited navigation layer is saved but not deployed yet: %s.", tostring(reason))
		end
	end)
	if not ok then
		Logger.error(LOG, "The Karabiner regeneration request raised: %s.", tostring(accepted))
		return false
	end
	return accepted == true
end





-- ================================
-- ================================
-- ======= 3/ Page messages =======
-- ================================
-- ================================

--- Sends the page the user's layers.toml.
--- @param session table
local function push_init(session)
	local ok_ctx, ctx = pcall(load_context)
	if not ok_ctx then
		Logger.error(LOG, "The layer data could not be read: %s.", tostring(ctx))
		return
	end
	local payload = LayerEditor.init_payload({
		os          = OS,
		ctx         = ctx,
		config_dir  = ConfigPaths.get_config_dir(),
		read_file   = LayerEditor.read_file,
		toml_decode = TomlCodec.decode,
	})
	call_page(session, "init", payload)
end

--- Validates and saves the page's text, then applies it.
--- @param session table
--- @param text any The payload's text.
local function save(session, text)
	Logger.start(LOG, "Saving the navigation layer…")
	local ok_ctx, ctx = pcall(load_context)
	if not ok_ctx then
		Logger.error(LOG, "The layer data could not be read: %s.", tostring(ctx))
		call_page(session, "saveResult", { saved = false, errors = { { code = "write_failed", detail = tostring(ctx) } } })
		return
	end
	local result = LayerEditor.save({
		text         = text,
		ctx          = ctx,
		config_dir   = ConfigPaths.get_config_dir(),
		toml_decode  = TomlCodec.decode,
		file_adapter = FileSystem,
	})
	if not result.saved then
		for _, err in ipairs(result.errors) do
			Logger.warn(LOG, "Refused: %s (%s) — %s.", tostring(err.code),
				table.concat({ tostring(err.layer or ""), tostring(err.section or ""), tostring(err.key or "") }, "."),
				tostring(err.detail))
		end
		Logger.error(LOG, "The navigation layer was not saved to '%s'.", tostring(result.path))
		call_page(session, "saveResult", { saved = false, errors = result.errors })
		return
	end
	local applied = request_regeneration(session.karabiner)
	if applied then
		Logger.success(LOG, "Navigation layer saved to '%s'; the Karabiner rules are regenerating.", result.path)
	else
		Logger.error(LOG, "Navigation layer saved to '%s' but its regeneration was refused.", result.path)
	end
	call_page(session, "saveResult", { saved = true, applied = applied, errors = {} })
	if applied then close_session(session) end
end

--- Routes one message of the page.
--- @param session table The session the message's bridge belongs to.
--- @param body any The posted payload.
function M._on_message(session, body)
	if _session ~= session then return end
	if body == "ready" then
		push_init(session)
	elseif type(body) ~= "table" then
		Logger.warn(LOG, "Ignored a layer editor message of type %s.", type(body))
	elseif body.action == "save" then
		save(session, body.text)
	elseif body.action == "cancel" then
		close_session(session)
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
			if _session == session then
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

--- Closes the editor if it is open.
function M.close()
	if _session then close_session(_session) end
end

return M
