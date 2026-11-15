--- ui/layer_editor/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Navigation Layer Editor
--- Handles JS->Lua messages from _shared/ui/layer_editor/.
--- Bridge name: "layer_editor_bridge"
---
--- The page asks for the user's layers.toml ("ready"), saves the text it built
--- ({action = "save", text}), closes ({action = "cancel"}) or, back in front,
--- asks for the legends again ({action = "legends"}). The save and its apply
--- are the window-free modules/keymap/nav_layer_save.lua, which the layout
--- editor's « Apply the navigation layer » calls too; this bridge only adds the
--- page's exact opening source and its answers.
---
--- Legends: each key that types a character shows what the keymap the daemon
--- loaded (adapters/keyboard_layout, the session's own XKB keymap, which it
--- reloads on a layout switch) types on its evdev code at level 1, or, while a
--- layout is emulated (modules/keymap/layout_emulation), what the emulation
--- types there, with the source « emulation » as on Windows (LEH-001). The
--- layer key is the tap-hold key whose hold enters the edited layer in the
--- remap manager's keys, found in the registry by its evdev code.
--- ==============================================================================

local M = {}
M.bridge_name = "layer_editor_bridge"

local Json        = require("core.text.engine.json")
local Logger      = require("core.logger.engine.shim")
local TomlCodec   = require("core.text.engine.toml_codec")
local Layers      = require("layouts.engine.layers.layers")
local LayerEditor = require("layouts.engine.layers.editor")
local NavLayerSave = require("modules.keymap.nav_layer_save")
local Writer      = require("core.text.engine.toml_codec.writer")

local LOG = "bridge.layer_editor"
local APP_NAME = "layer_editor"
local OS = "linux"
local _opening = nil





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
	local manager = dependency(state, "webview_manager", "core.ui.ui.webview_manager")
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
	local manager = dependency(state, "webview_manager", "core.ui.ui.webview_manager")
	return manager ~= nil and type(manager.hide) == "function" and manager.hide(APP_NAME) == true
end

--- Retains the page and exact file which supplied the editor's current draft.
local function capture_opening(state, context, shared_root, config_dir, ctx)
	local config_paths = dependency(state, "config_paths", "settings.engine.paths")
	local manager = dependency(state, "webview_manager", "core.ui.ui.webview_manager")
	local path = Layers.user_file_path(config_dir, ctx)
	local content, status, detail = Writer.read_classified(path)
	return {
		state = state, config_paths = config_paths, get_config_dir = config_paths.get_config_dir,
		manager = manager, epoch = type(context) == "table" and context.epoch or nil,
		shared_root = shared_root, config_dir = config_dir, ctx = ctx, path = path,
		source = { status = status, content = content }, read_error = detail,
	}
end

--- A duplicate ready belongs to the same first offer even without a live ACK.
local function opening_page_matches(owner, state, context)
	local epoch = type(context) == "table" and context.epoch or nil
	return owner ~= nil and _opening == owner and epoch == owner.epoch
		and dependency(state, "webview_manager", "core.ui.ui.webview_manager") == owner.manager
end

--- A different page cannot receive this draft's save result or close request.
local function opening_page_current(owner, state, context)
	if not opening_page_matches(owner, state, context) or owner.state ~= state then return false end
	local epoch = owner.epoch
	if epoch ~= nil then
		local current = owner.manager and owner.manager.page_current
		if type(current) ~= "function" then return false end
		local called, live = pcall(current, APP_NAME, epoch)
		if not called or live ~= true or _opening ~= owner then return false end
	end
	return true
end

--- Folder admission remains separate from the writer's exact-byte precondition.
local function opening_current(owner, state, context)
	if not opening_page_current(owner, state, context)
		or dependency(state, "config_paths", "settings.engine.paths") ~= owner.config_paths
		or owner.config_paths.get_config_dir ~= owner.get_config_dir then return false end
	local called, dir = pcall(owner.get_config_dir)
	return called and dir == owner.config_dir and opening_page_current(owner, state, context)
		and owner.config_paths.get_config_dir == owner.get_config_dir
end

--- A committed file may still need application after its page was replaced.
local function committed_folder_current(owner, state)
	if not owner or dependency(state, "config_paths", "settings.engine.paths") ~= owner.config_paths
		or owner.config_paths.get_config_dir ~= owner.get_config_dir then return false end
	local called, dir = pcall(owner.get_config_dir)
	return called and dir == owner.config_dir
		and dependency(state, "config_paths", "settings.engine.paths") == owner.config_paths
		and owner.config_paths.get_config_dir == owner.get_config_dir
end

--- Uses the existing adapter seam to keep the opening snapshot at publication.
local function opening_files(owner, state, context)
	return {
		read_with_status = function(path)
			if path ~= owner.path or not opening_current(owner, state, context) then
				return nil, "error", "the layer editor source is no longer current"
			end
			return Writer.read_classified(path)
		end,
		write_if_unchanged = function(path, content)
			if path ~= owner.path then return false, "the layer editor path changed" end
			-- Validation may read the current file, but it cannot adopt new bytes.
			local written, detail, receipt = Writer.publish_if_unchanged(path, content, nil, owner.source, nil,
				function() return opening_current(owner, state, context) end)
			if written == true and opening_current(owner, state, context) then
				owner.source = { status = "ok", content = content }
			end
			return written, detail, receipt
		end,
	}
end

--- The legends of the layout the user types with: the emulated one, else the
--- keymap the daemon loaded.
--- @param state table Daemon state.
--- @param ctx table The loader context.
--- @return table legends The page's `legends`.
local function current_legends(state, ctx)
	local layout = dependency(state, "keyboard_layout", "adapters.keyboard_layout")
	if not layout then error("the keyboard layout adapter is unavailable", 0) end
	local emulation = dependency(state, "layout_emulation", "modules.keymap.layout_emulation")
	if not emulation then error("the layout emulation is unavailable", 0) end
	local emulating = emulation.status().active == true
	local legends, unresolved = LayerEditor.legends({
		ctx       = ctx,
		source    = emulating and LayerEditor.LEGEND_SOURCE_EMULATION or LayerEditor.LEGEND_SOURCE_OS,
		character = function(code, entry)
			local emulated = emulating and emulation.legend(code) or nil
			if emulated ~= nil then return emulated end
			local symbol = type(entry.evdev) == "number" and layout.base_symbol(entry.evdev) or nil
			return type(symbol) == "table" and symbol.text or nil
		end,
	})
	LayerEditor.report_unresolved(unresolved,
		layout.is_ready() and "the loaded keymap types nothing printable there" or "no keymap is loaded",
		function(message) Logger.warn(LOG, "%s", message) end)
	return legends
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
		if opening_page_matches(_opening, state, context) then
			local owner = _opening
			-- The shared page ignores later init calls, even if delivery was ambiguous.
			-- Retry only the first source; selecting a new one requires a new page.
			local pushed = owner.data ~= nil and opening_current(owner, state, context)
				and call_page(state, "init", owner.data)
			owner.offered = pushed == true and opening_current(owner, state, context)
			return { pushed = owner.offered, data = owner.data }
		end
		local ok, shared_root, config_dir = pcall(NavLayerSave.folders, state)
		local ok_ctx, ctx = false, shared_root
		if ok then ok_ctx, ctx = pcall(NavLayerSave.load_context, shared_root) end
		if not ok or not ok_ctx then
			Logger.error(LOG, "The layer editor cannot read the layer data: %s.", tostring(ctx))
			return { pushed = false }
		end
		local owner = capture_opening(state, context, shared_root, config_dir, ctx)
		_opening = owner
		local data = LayerEditor.init_payload({
			os = OS, ctx = ctx, config_dir = config_dir,
			read_file = function()
				if owner.source.status == "ok" then return owner.source.content end
				if owner.source.status == "absent" then return nil end
				error(owner.read_error or "the layer file is unreadable", 0)
			end, toml_decode = TomlCodec.decode,
			legends = current_legends(state, ctx), layer_keys = NavLayerSave.layer_keys(state, ctx, shared_root),
		})
		owner.data = data
		local manager = dependency(state, "webview_manager", "core.ui.ui.webview_manager")
		local i18n = dependency(state, "i18n", "core.i18n.engine.i18n")
		if manager and type(manager.set_title) == "function" and i18n and type(i18n.get) == "function" then
			manager.set_title(APP_NAME, i18n.get("layer_editor.window_title"))
		end
		local pushed = opening_current(owner, state, context) and call_page(state, "init", data)
		owner.offered = pushed == true and opening_current(owner, state, context)
		return { pushed = owner.offered, data = data }
	end
	if type(payload) ~= "table" then
		Logger.warn(LOG, "Ignored a layer editor message of type %s.", type(payload))
		return nil
	end
	if payload.action == "save" then
		local owner = _opening
		Logger.start(LOG, "Saving the navigation layer…")
		if not opening_current(owner, state, context) or owner.offered ~= true
			or (owner.source.status ~= "ok" and owner.source.status ~= "absent") then
			local detail = "the layer editor source is no longer current"
			Logger.error(LOG, "The navigation layer was not saved: %s.", detail)
			local refused = { saved = false, errors = { { code = LayerEditor.WRITE_FAILED, detail = detail } } }
			if opening_page_current(owner, state, context) then call_page(state, "saveResult", refused) end
			return refused
		end
		if owner.saving then return { saved = false, busy = true } end
		owner.saving = true
		local function save_and_apply()
			local result = NavLayerSave.save(state, {
				text = payload.text, ctx = owner.ctx, config_dir = owner.config_dir,
				file_adapter = opening_files(owner, state, context),
				current = function() return committed_folder_current(owner, state) end,
			})
			if not result.saved then
				if opening_page_current(owner, state, context) then
					call_page(state, "saveResult", { saved = false, errors = result.errors })
				end
				return result
			end
			if result.stale then
				-- The folder moved after the write: nothing was applied, but the page
				-- still waits for its answer and keeps every button disabled until
				-- it comes, as Windows and macOS answer applied=false (LEH-002).
				result.stale = nil
				if opening_page_current(owner, state, context) then
					call_page(state, "saveResult", { saved = true, applied = false, errors = {} })
				end
				return result
			end
			if opening_page_current(owner, state, context) then
				call_page(state, "saveResult", { saved = true, applied = result.applied, errors = {} })
			end
			if result.applied and opening_current(owner, state, context) then result.closed = close_page(state, context) end
			return result
		end
		local ok, result = pcall(save_and_apply)
		owner.saving = false
		if not ok then error(result, 0) end
		return result
	end
	if payload.action == "cancel" then
		if _opening and _opening.saving and opening_current(_opening, state, context) then
			return { cancelled = false, closed = false, busy = true }
		end
		return { cancelled = true, closed = close_page(state, context) }
	end
	if payload.action == "legends" then
		local ok, shared_root = pcall(NavLayerSave.folders, state)
		local ok_ctx, ctx = false, shared_root
		if ok then ok_ctx, ctx = pcall(NavLayerSave.load_context, shared_root) end
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
