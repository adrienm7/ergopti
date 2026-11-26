--- modules/keymap/nav_layer_save.lua

--- ==============================================================================
--- MODULE: Navigation Layer Save (Linux)
--- DESCRIPTION:
--- Saves and applies the user's layers.toml, the compiled form of the
--- navigation layer the layout editor holds in a source. The shared host logic
--- (_shared/layouts/engine/layers/editor.lua) checks the text against every
--- OS's loader and publishes it atomically; the remap manager then regenerates
--- its configuration, which reads layers.toml again, so the layer applies.
---
--- FEATURES & RATIONALE:
--- 1. No window owns this save: the layout editor's « Apply the navigation
---    layer » (ui/layout_manager/bridge.lua) calls apply_text, so the save
---    outlives the navigation layer editor window it used to live in.
--- 2. Only the apply call knows which engine carries the layer, so the Linux
---    part stays this thin.
--- 3. Every collaborator comes from the daemon state when it holds one, so the
---    portable suite replays the save without a session.
--- ==============================================================================

local Json        = require("core.text.engine.json")
local Logger      = require("core.logger.engine.shim")
local TomlCodec   = require("core.text.engine.toml_codec")
local Layers      = require("layouts.engine.layers.layers")
local LayerEditor = require("layouts.engine.layers.editor")
local LayerPreset = require("layouts.engine.layers.preset")

local M = {}

local LOG = "keymap.nav_layer_save"





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

--- The folders the layer data and the user's file live in.
--- @param state table Daemon state.
--- @return string shared_root
--- @return string config_dir
function M.folders(state)
	local paths = dependency(state, "paths", "core.fs.engine.paths")
	local config_paths = dependency(state, "config_paths", "settings.engine.paths")
	if not paths or not config_paths then error("the shared tree or the configuration folder is unknown", 0) end
	return paths.shared_root(), config_paths.get_config_dir()
end

--- The layer loader's context, read from the shipped registry and vocabulary.
--- @param shared_root string The _shared folder.
--- @return table ctx
function M.load_context(shared_root)
	return Layers.load_context({
		shared_root = shared_root,
		json_decode = Json.decode,
		toml_decode = TomlCodec.decode,
		read_file   = LayerEditor.read_shipped,
	})
end

--- Asks the remap manager to regenerate and reload its configuration.
--- @param state table Daemon state.
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





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Validates and publishes a layers.toml text, then applies it.
--- @param state table Daemon state.
--- @param opts table { text, ctx, config_dir, file_adapter, current } where
---   current() says whether the saved folder is still the configuration folder.
--- @return table result LayerEditor.save's, with `applied`, or `stale` when the
---   folder changed after the save.
function M.save(state, opts)
	local result = LayerEditor.save({
		text = opts.text, ctx = opts.ctx, config_dir = opts.config_dir, toml_decode = TomlCodec.decode,
		file_adapter = opts.file_adapter,
	})
	if not result.saved then
		for _, err in ipairs(result.errors) do
			Logger.warn(LOG, "Refused: %s (%s.%s.%s) — %s.", tostring(err.code), tostring(err.layer or ""),
				tostring(err.section or ""), tostring(err.key or ""), tostring(err.detail))
		end
		Logger.error(LOG, "The navigation layer was not saved to '%s'.", tostring(result.path))
		return result
	end
	if not opts.current() then
		result.applied, result.stale = false, true
		return result
	end
	result.applied = apply(state)
	if result.applied then
		Logger.success(LOG, "Navigation layer saved to '%s' and applied.", result.path)
	else
		Logger.error(LOG, "Navigation layer saved to '%s' but not applied.", result.path)
	end
	return result
end

--- The registry codes of the keys whose hold enters the navigation layer.
--- @param state table Daemon state.
--- @param ctx table The loader context.
--- @param shared_root string The _shared folder.
--- @return table codes
function M.layer_keys(state, ctx, shared_root)
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

--- What Ergopti Studio shows for the « Navigation layer » entries: the user's
--- layers.toml (else the preset) and the key whose hold enters the layer.
--- @param state table Daemon state.
--- @return table nav { text, hold } where hold is nil when no key enters it.
function M.studio_nav(state)
	state = type(state) == "table" and state or {}
	local shared_root, config_dir = M.folders(state)
	local ctx = M.load_context(shared_root)
	local text = LayerPreset.studio_text({
		shared_root = shared_root, path = Layers.user_file_path(config_dir, ctx), toml_decode = TomlCodec.decode,
	})
	return { text = text, hold = M.layer_keys(state, ctx, shared_root)[1] }
end

--- Saves and applies a layers.toml the layout editor built from a source's
--- navigation layer. The destination is the user's layers.toml as read now: it
--- is replaced only while it still holds those bytes (LayerEditor.save's
--- exact-byte precondition).
--- @param text any The layers.toml text.
--- @param state table Daemon state.
--- @return table result { saved, applied, errors }
function M.apply_text(text, state)
	state = type(state) == "table" and state or {}
	Logger.start(LOG, "Applying the navigation layer from the layout editor…")
	local ok, shared_root, config_dir = pcall(M.folders, state)
	local ok_ctx, ctx = false, shared_root
	if ok then ok_ctx, ctx = pcall(M.load_context, shared_root) end
	if not ok or not ok_ctx then
		local detail = "the layer data could not be read: " .. tostring(ctx)
		Logger.error(LOG, "The navigation layer was not applied: %s.", detail)
		return { saved = false, applied = false, errors = { { code = LayerEditor.WRITE_FAILED, detail = detail } } }
	end
	local result = M.save(state, {
		text = text, ctx = ctx, config_dir = config_dir, file_adapter = nil,
		current = function()
			local still, _, dir = pcall(M.folders, state)
			return still and dir == config_dir
		end,
	})
	return { saved = result.saved == true, applied = result.applied == true, errors = result.errors or {} }
end

return M
