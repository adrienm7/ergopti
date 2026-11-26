--- modules/keymap/nav_layer_save.lua

--- ==============================================================================
--- MODULE: Navigation Layer Save (macOS)
--- DESCRIPTION:
--- Saves and applies the user's layers.toml, the compiled form of the
--- navigation layer the layout editor holds in a source. The shared host logic
--- (_shared/layouts/engine/layers/editor.lua) checks the text against every
--- OS's loader and publishes it through the atomic FileSystem adapter; the
--- Karabiner rules are then regenerated, and every regeneration reads
--- layers.toml again, so the layer applies. The wheel bindings, which
--- Karabiner cannot take, are handed to their Hammerspoon owner.
---
--- FEATURES & RATIONALE:
--- 1. No window owns this save: the layout editor's « Apply the navigation
---    layer » (ui/layout_manager, wired by ui/menu) calls apply_text, so the
---    save outlives the navigation layer editor window it used to live in.
--- 2. A regeneration that fails after the save says so in an error
---    notification (maintainer decision LEH-003, 2026-11-12), since nothing
---    waits for it any more.
--- ==============================================================================

local M = {}

local Logger      = require("core.logger.engine.logger")
local i18n        = require("core.i18n.engine.i18n")
local Paths       = require("core.fs.engine.paths")
local ConfigPaths = require("settings.engine.paths")
local FileSystem  = require("core.fs.adapters.file_system")
local Json        = require("core.text.engine.json")
local TomlCodec   = require("core.text.engine.toml_codec")
local Layers      = require("layouts.engine.layers.layers")
local LayerEditor = require("layouts.engine.layers.editor")
local LayerPreset = require("layouts.engine.layers.preset")
local NavLayer    = require("platform.remap.nav_layer")

local LOG = "keymap.nav_layer_save"








-- ==========================
-- ==========================
-- ======= 1/ Helpers =======
-- ==========================
-- ==========================

--- The layer loader's context, read from the shipped registry and vocabulary.
--- @return table ctx
function M.load_context()
	return Layers.load_context({
		shared_root = Paths.shared_root(),
		json_decode = Json.decode,
		toml_decode = TomlCodec.decode,
		read_file   = LayerEditor.read_shipped,
	})
end

--- Hands the saved layer's wheel bindings, which Hammerspoon runs rather than
--- Karabiner, to their owner (modules/shortcuts/layer_wheel.lua).
local function reconcile_wheel()
	local ok, committed = pcall(function()
		return require("modules.shortcuts.layer_wheel").reconcile()
	end)
	if not ok then
		Logger.error(LOG, "The layer's wheel bindings could not be applied: %s.", tostring(committed))
	elseif committed ~= true then
		Logger.warn(LOG, "The layer's wheel bindings are saved; the scroll wheel takes them at the next save or resume.")
	end
end

--- Asks the remap engine to regenerate the Karabiner rules.
--- @param karabiner table The remap facade.
--- @return boolean requested True when the regeneration was accepted.
local function request_regeneration(karabiner)
	local ok, accepted = pcall(karabiner.regenerate, function(done, reason)
		if done ~= true then
			Logger.warn(LOG, "The edited navigation layer is saved but not deployed yet: %s.", tostring(reason))
			local sent, notify_err = require("core.ui.engine.notifications").notify(i18n.get("layout_editor.title"),
				i18n.get("layout_editor.status.nav_not_applied"), "error")
			if not sent then
				Logger.error(LOG, "The late regeneration failure could not be notified: %s.", tostring(notify_err))
			end
		end
	end)
	if not ok then
		Logger.error(LOG, "The Karabiner regeneration request raised: %s.", tostring(accepted))
		return false
	end
	return accepted == true
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Validates and publishes a layers.toml text, then applies it.
--- @param opts table { text, ctx, config_dir, file_adapter, karabiner, current }
---   where current() says whether the caller still owns the destination.
--- @return table result { saved, applied, errors, path }
function M.save(opts)
	local result = LayerEditor.save({
		text = opts.text, ctx = opts.ctx, config_dir = opts.config_dir,
		toml_decode = TomlCodec.decode, file_adapter = opts.file_adapter,
	})
	if not result.saved then
		for _, err in ipairs(result.errors) do
			Logger.warn(LOG, "Refused: %s (%s) — %s.", tostring(err.code),
				table.concat({ tostring(err.layer or ""), tostring(err.section or ""), tostring(err.key or "") }, "."),
				tostring(err.detail))
		end
		Logger.error(LOG, "The navigation layer was not saved to '%s'.", tostring(result.path))
		return { saved = false, errors = result.errors, path = result.path }
	end
	local stale = { saved = true, applied = false, errors = {}, path = result.path }
	if not opts.current() then
		Logger.warn(LOG, "The layer was saved, but its editor destination changed before application.")
		return stale
	end
	local applied = request_regeneration(opts.karabiner)
	if not opts.current() then return stale end
	reconcile_wheel()
	if not opts.current() then return stale end
	if applied then
		Logger.success(LOG, "Navigation layer saved to '%s'; the Karabiner rules are regenerating.", result.path)
	else
		Logger.error(LOG, "Navigation layer saved to '%s' but its regeneration was refused.", result.path)
	end
	return { saved = true, applied = applied, errors = {}, path = result.path }
end

--- An override of a registry key for the ISO form, when it has one.
--- @param entry table A registry key.
--- @param field string hs | karabiner.
--- @return any
function M.iso_field(entry, field)
	local override = entry["macos_" .. NavLayer.KEYBOARD_FORM]
	if type(override) == "table" and override[field] ~= nil then return override[field] end
	return entry[field]
end

--- The registry codes of the keys whose hold enters the layer.
--- @param ctx table The loader context.
--- @param karabiner table The remap facade.
--- @return table codes
function M.layer_keys(ctx, karabiner)
	local codes = {}
	local karabiner_key_code = function(entry)
		local event = M.iso_field(entry, "karabiner")
		return type(event) == "table" and event.key_code or nil
	end
	for _, key in ipairs(karabiner.TAP_HOLD_KEYS or {}) do
		if karabiner.get_hold_action(key.id) == NavLayer.HOLD_ACTION_ID then
			local key_code = type(key.from) == "table" and key.from.key_code or nil
			local code = LayerEditor.code_of(ctx, karabiner_key_code, key_code)
			if code then
				codes[#codes + 1] = code
			else
				-- Fn has no place on the registry's board: nothing to mark.
				Logger.debug(LOG, "The layer key '%s' is not on the registry's board.", tostring(key.id))
			end
		end
	end
	table.sort(codes)
	return codes
end

--- What Ergopti Studio shows for the « Navigation layer » entries: the user's
--- layers.toml (else the preset) and the key whose hold enters the layer.
--- @param opts table { karabiner = the remap facade }.
--- @return table nav { text, hold } where hold is nil when no key enters it.
function M.studio_nav(opts)
	local karabiner = type(opts) == "table" and opts.karabiner or nil
	if type(karabiner) ~= "table" or type(karabiner.get_hold_action) ~= "function" then
		error("the remap facade is unavailable", 0)
	end
	local ctx = M.load_context()
	local text = LayerPreset.studio_text({
		shared_root = Paths.shared_root(), path = Layers.user_file_path(ConfigPaths.get_config_dir(), ctx),
		toml_decode = TomlCodec.decode, file_adapter = FileSystem,
	})
	return { text = text, hold = M.layer_keys(ctx, karabiner)[1] }
end

--- Saves and applies a layers.toml the layout editor built from a source's
--- navigation layer. The destination is the user's layers.toml as read now:
--- it is replaced only while it still holds those bytes (LayerEditor.save's
--- exact-byte precondition).
--- @param text any The layers.toml text.
--- @param opts table { karabiner = the remap facade }.
--- @return table result { saved, applied, errors }
function M.apply_text(text, opts)
	Logger.start(LOG, "Applying the navigation layer from the layout editor…")
	local karabiner = type(opts) == "table" and opts.karabiner or nil
	local function refused(detail)
		Logger.error(LOG, "The navigation layer was not applied: %s.", detail)
		return { saved = false, applied = false, errors = { { code = LayerEditor.WRITE_FAILED, detail = detail } } }
	end
	if type(karabiner) ~= "table" or type(karabiner.regenerate) ~= "function" then
		return refused("the remap facade is unavailable")
	end
	local ok_ctx, ctx = pcall(M.load_context)
	if not ok_ctx then return refused("the layer data could not be read: " .. tostring(ctx)) end
	local get_config_dir = ConfigPaths.get_config_dir
	local dir_ok, config_dir = pcall(get_config_dir)
	if not dir_ok or type(config_dir) ~= "string" or config_dir == "" then
		return refused("the configuration folder is unknown")
	end
	local result = M.save({
		text = text, ctx = ctx, config_dir = config_dir, file_adapter = FileSystem, karabiner = karabiner,
		current = function()
			local ok, dir = pcall(ConfigPaths.get_config_dir)
			return ok and dir == config_dir
		end,
	})
	return { saved = result.saved, applied = result.applied == true, errors = result.errors }
end

return M
