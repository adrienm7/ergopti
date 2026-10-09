--- ui/layer_editor/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Navigation Layer Editor
--- Handles JS->Lua messages from _shared/ui/layer_editor/.
--- Bridge name: "layer_editor_bridge"
---
--- The page asks for the user's layers.toml ("ready"), saves the text it built
--- ({action = "save", text}), closes ({action = "cancel"}) or, back in front,
--- asks for the legends again ({action = "legends"}). The shared host logic
--- (_shared/lua/keymap/layer_editor.lua) checks a saved text against every
--- OS's loader and publishes it atomically; the remap manager then regenerates
--- its configuration, which reads layers.toml again, so the layer applies.
--- The Linux part stays this thin on purpose: only the apply call knows which
--- engine carries the layer.
---
--- Legends: each key that types a character shows what the keymap the daemon
--- loaded (adapters/keyboard_layout, the session's own XKB keymap, which it
--- reloads on a layout switch) types on its evdev code at level 1. Linux
--- emulates no layout: an installed Ergopti is the XKB layout itself. The
--- layer key is the tap-hold key whose hold enters the edited layer in the
--- remap manager's keys, found in the registry by its evdev code.
--- ==============================================================================

local M = {}
M.bridge_name = "layer_editor_bridge"

local Json        = require("json")
local Logger      = require("logger.shim")
local TomlCodec   = require("toml_codec")
local Layers      = require("keymap.layers")
local LayerEditor = require("keymap.layer_editor")
local LayerPreset = require("keymap.layer_preset")

local LOG = "bridge.layer_editor"
local APP_NAME = "layer_editor"
local OS = "linux"





-- ==========================
-- ==========================
-- ======= 1/ Helpers =======
-- ==========================
-- ==========================

--- A dependency from the daemon state, else the module itself.
local function dependency(state, field, module_name)
	if type(state[field]) == "table" then return state[field] end
	local ok, module = pcall(require, module_name)
	return ok and type(module) == "table" and module or nil
end

--- Calls one of the page's functions with a JSON payload.
--- @return boolean called
local function call_page(state, fn_name, payload)
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	if not manager or type(manager.eval_js) ~= "function" then
		Logger.error(LOG, "No webview manager: the page's %s() cannot be called.", fn_name)
		return false
	end
	local encoded = Json.encode(payload)
	if type(encoded) ~= "string" then
		Logger.error(LOG, "The %s payload could not be encoded for the page.", fn_name)
		return false
	end
	local ok, called = pcall(manager.eval_js, APP_NAME,
		"if(window." .. fn_name .. ")window." .. fn_name .. "(" .. encoded .. ")")
	return ok and called == true
end

local function close_page(state, context)
	if type(context) == "table" and type(context.close_owned_window) == "function" then
		return context.close_owned_window() == true
	end
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	return manager ~= nil and type(manager.hide) == "function" and manager.hide(APP_NAME) == true
end

--- The folders the layer data and the user's file live in.
--- @return string shared_root
--- @return string config_dir
local function folders(state)
	local paths = dependency(state, "paths", "infra.paths")
	local config_paths = dependency(state, "config_paths", "infra.config_paths")
	if not paths or not config_paths then error("the shared tree or the configuration folder is unknown", 0) end
	return paths.shared_root(), config_paths.get_config_dir()
end

--- The layer loader's context, read from the shipped registry and vocabulary.
local function load_context(shared_root)
	return Layers.load_context({
		shared_root = shared_root,
		json_decode = Json.decode,
		toml_decode = TomlCodec.decode,
		read_file   = LayerEditor.read_shipped,
	})
end

--- The legends of the keymap the daemon loaded.
--- @param state table Daemon state.
--- @param ctx table The loader context.
--- @return table legends The page's `legends`.
local function current_legends(state, ctx)
	local layout = dependency(state, "keyboard_layout", "adapters.keyboard_layout")
	if not layout then error("the keyboard layout adapter is unavailable", 0) end
	local legends, unresolved = LayerEditor.legends({
		ctx       = ctx,
		source    = LayerEditor.LEGEND_SOURCE_OS,
		character = function(_, entry)
			local symbol = type(entry.evdev) == "number" and layout.base_symbol(entry.evdev) or nil
			return type(symbol) == "table" and symbol.text or nil
		end,
	})
	LayerEditor.report_unresolved(unresolved,
		layout.is_ready() and "the loaded keymap types nothing printable there" or "no keymap is loaded",
		function(message) Logger.warn(LOG, "%s", message) end)
	return legends
end

--- The registry codes of the keys whose hold enters the edited layer.
--- @param state table Daemon state.
--- @param ctx table The loader context.
--- @param shared_root string The _shared folder.
--- @return table codes
local function layer_keys(state, ctx, shared_root)
	local manager = dependency(state, "tap_hold", "platform.remap.tap_hold_manager")
	local engine = dependency(state, "tap_hold_engine", "platform.remap.tap_hold_engine")
	local ok, keys = pcall(function() return manager.keys() end)
	if not ok or type(keys) ~= "table" or not engine then
		Logger.warn(LOG, "The tap-hold keys are unknown, so no layer key is marked: %s.", tostring(keys))
		return {}
	end
	local layer_id = LayerPreset.read(shared_root, TomlCodec.decode).layer_id
	local codes = {}
	for id, entry in pairs(keys) do
		if type(entry) == "table" and entry.hold_layer == layer_id then
			local evdev = engine.KEY_CODES[id]
			local code = evdev and LayerEditor.code_of(ctx, function(key) return key.evdev end, evdev) or nil
			if code then codes[#codes + 1] = code end
		end
	end
	table.sort(codes)
	return codes
end

--- Asks the remap manager to regenerate and reload its configuration.
--- @return boolean applied
local function apply(state)
	local remap = dependency(state, "tap_hold", "platform.remap.tap_hold_manager")
	if not remap or type(remap.reload) ~= "function" then
		Logger.error(LOG, "No remap manager: the saved navigation layer cannot be applied.")
		return false
	end
	local ok, applied = pcall(remap.reload)
	if not ok then
		Logger.error(LOG, "The native remap reload raised: %s.", tostring(applied))
		return false
	end
	return applied == true
end





-- ===================================
-- ===================================
-- ======= 2/ Message handlers =======
-- ===================================
-- ===================================

--- Handles an incoming JS message.
--- @param payload any String or table from host_bridge.js.
--- @param state table Daemon state.
--- @param context table|nil The window context (close_owned_window).
--- @return table|nil The outcome, for the manager and the tests.
function M.on_message(payload, state, context)
	state = type(state) == "table" and state or {}
	if payload == "ready" then
		local ok, shared_root, config_dir = pcall(folders, state)
		local ok_ctx, ctx = false, shared_root
		if ok then ok_ctx, ctx = pcall(load_context, shared_root) end
		if not ok or not ok_ctx then
			Logger.error(LOG, "The layer editor cannot read the layer data: %s.", tostring(ctx))
			return { pushed = false }
		end
		local data = LayerEditor.init_payload({
			os = OS, ctx = ctx, config_dir = config_dir,
			read_file = LayerEditor.read_file, toml_decode = TomlCodec.decode,
			legends = current_legends(state, ctx), layer_keys = layer_keys(state, ctx, shared_root),
		})
		local manager = dependency(state, "webview_manager", "ui.webview_manager")
		local i18n = dependency(state, "i18n", "infra.i18n")
		if manager and type(manager.set_title) == "function" and i18n and type(i18n.get) == "function" then
			manager.set_title(APP_NAME, i18n.get("layer_editor.window_title"))
		end
		return { pushed = call_page(state, "init", data), data = data }
	end
	if type(payload) ~= "table" then
		Logger.warn(LOG, "Ignored a layer editor message of type %s.", type(payload))
		return nil
	end
	if payload.action == "save" then
		Logger.start(LOG, "Saving the navigation layer…")
		local ok, shared_root, config_dir = pcall(folders, state)
		local ok_ctx, ctx = false, shared_root
		if ok then ok_ctx, ctx = pcall(load_context, shared_root) end
		if not ok or not ok_ctx then
			local detail = tostring(ctx)
			Logger.error(LOG, "The navigation layer was not saved: %s.", detail)
			local refused = { saved = false, errors = { { code = LayerEditor.WRITE_FAILED, detail = detail } } }
			call_page(state, "saveResult", refused)
			return refused
		end
		local result = LayerEditor.save({
			text = payload.text, ctx = ctx, config_dir = config_dir, toml_decode = TomlCodec.decode,
		})
		if not result.saved then
			for _, err in ipairs(result.errors) do
				Logger.warn(LOG, "Refused: %s (%s.%s.%s) — %s.", tostring(err.code), tostring(err.layer or ""),
					tostring(err.section or ""), tostring(err.key or ""), tostring(err.detail))
			end
			Logger.error(LOG, "The navigation layer was not saved to '%s'.", tostring(result.path))
			call_page(state, "saveResult", { saved = false, errors = result.errors })
			return result
		end
		result.applied = apply(state)
		if result.applied then
			Logger.success(LOG, "Navigation layer saved to '%s' and applied.", result.path)
		else
			Logger.error(LOG, "Navigation layer saved to '%s' but not applied.", result.path)
		end
		call_page(state, "saveResult", { saved = true, applied = result.applied, errors = {} })
		if result.applied then result.closed = close_page(state, context) end
		return result
	end
	if payload.action == "cancel" then
		return { cancelled = true, closed = close_page(state, context) }
	end
	if payload.action == "legends" then
		local ok, shared_root = pcall(folders, state)
		local ok_ctx, ctx = false, shared_root
		if ok then ok_ctx, ctx = pcall(load_context, shared_root) end
		if not ok or not ok_ctx then
			Logger.error(LOG, "The layer editor cannot read the layer data: %s.", tostring(ctx))
			return { pushed = false }
		end
		local legends = current_legends(state, ctx)
		return { pushed = call_page(state, "setLegends", legends), legends = legends }
	end
	Logger.warn(LOG, "Ignored the unknown layer editor action '%s'.", tostring(payload.action))
	return nil
end

return M
