--- infra/tap_hold_scope.lua

--- ==============================================================================
--- MODULE: Tap-Hold Scope Transaction (Linux)
--- DESCRIPTION:
--- Restores Ergopti's recommended tap-holds or clears them to the keyboard's own
--- behaviour through the shared scope transaction: the user's tap_hold.toml is
--- the manifest preset's file, and the tap-hold action parameters stay in
--- config.toml. Both get verified backups, the engine acknowledges the exact
--- candidate before anything is published, and a refusal restores both.
---
--- FEATURES & RATIONALE:
--- 1. Explicit Preset: a restore writes every shipped key field instead of
---    `inherit_defaults = true`, so the file states what the engine runs and a
---    later change to the shipped defaults never silently reaches the user.
--- 2. Exact Ownership: only the tray's per-key fields, the master flag and the
---    tap_hold parameter domain change; unknown sections and fields survive.
---    A clear leaves the master flag as it is (the manifest's `clear_exclude`):
---    it empties the keys, and the user sets the next one from there.
--- 3. Revertible: a committed owner keeps its exact inverse, so a composed
---    scope can undo it when a later category refuses.
--- 4. The layer comes with its key: a restore also creates the folder's
---    layers.toml from Ergopti's recommended navigation layer when there is
---    none (keymap.layer_preset), before the engine is rebuilt, so the key the
---    preset holds on the layer never enters an empty one. An existing
---    layers.toml is the user's and stays; a refused or reverted restore
---    removes only the file it created.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Logger = require("logger.shim")
local LayerPreset = require("keymap.layer_preset")
local LOG = "infra.tap_hold_scope"
local _owner, _sequence = nil, 0

--- Whether a parameter binding belongs to the tap-hold domain: the daemon runs
--- tap actions under the binding "tap_hold"; per-key bindings keep its prefix.
--- @param binding string|nil Parameter binding.
--- @return boolean
local function is_tap_hold_binding(binding)
	return binding == "tap_hold" or (type(binding) == "string" and binding:match("^tap_hold__[a-z0-9_]+$") ~= nil)
end

--- Creates the recommended layers.toml beside tap_hold.toml when there is none.
--- @param options table The owner's options (tap_hold_path, shared_root).
--- @param files table The owner's file port, the one undo_layer() removes through.
--- @return table|nil import What LayerPreset.import_if_absent() returned.
--- @return string|nil err Why the absent file could not be created.
local function import_layer(options, files)
	local config_dir = assert(options.tap_hold_path:match("^(.*)[/\\][^/\\]+$"),
		"tap-hold scope needs tap_hold.toml inside a configuration folder")
	local ok, import, err = pcall(LayerPreset.import_if_absent, {
		shared_root = options.shared_root or require("infra.paths").shared_root(),
		config_dir = config_dir, toml_decode = Codec.decode, file_adapter = files,
	})
	if not ok then return nil, tostring(import) end
	if not import then return nil, err end
	if import.status == LayerPreset.IMPORTED then
		Logger.info(LOG, "Recommended navigation layer imported into '%s'.", import.path)
	elseif import.detail then
		Logger.warn(LOG, "'%s' is kept as it is (%s): the restore never replaces a layer file.",
			import.path, import.detail)
	end
	return import
end

--- Removes the layers.toml a restore created, while it holds the preset's bytes.
--- @param import table|nil What import_layer() returned.
--- @param files table The owner's file port.
--- @return boolean undone
local function undo_layer(import, files)
	local undone, err = LayerPreset.undo(import, files)
	if undone ~= true then
		Logger.error(LOG, "The navigation layer '%s' a refused restore created could not be removed: %s.",
			tostring(import and import.path), tostring(err))
	end
	return undone == true
end

--- Builds one transaction owner over tap_hold.toml and config.toml.
--- @param options table path, backup_path, tap_hold_path, tap_hold_backup_path,
---   is_paused and optional manager, loader, writer, parameters, files and
---   shared_root ports.
--- @return table owner apply(mode), revert(), release(), pending(), retry_restore().
function M.new(options)
	assert(type(options) == "table" and type(options.is_paused) == "function", "tap-hold scope requires live pause ownership")
	for _, name in ipairs({ "path", "backup_path", "tap_hold_path", "tap_hold_backup_path" }) do
		assert(type(options[name]) == "string" and options[name] ~= "", "tap-hold scope requires " .. name)
	end
	local manager = options.manager or require("platform.remap.tap_hold_manager")
	local loader = options.loader or require("platform.remap.tap_hold_loader")
	local writer = options.writer or require("platform.remap.tap_hold_writer")
	local parameters = options.parameters or require("modules.gestures.manager")
	local files = options.files or require("adapters.file_system")
	local owner, held, legacy, source, layer = {}, false, {}, nil, nil
	local preset = loader.preset_keys(manager.defaults_path())
	local function parameter_domain(path)
		local key = path:match("^gesture_parameters%.(.+)$")
		if not key then return nil end
		local binding, action = parameters.split_action_parameter_key(key)
		if action and parameters.get_action_parameter_spec(action) and is_tap_hold_binding(binding) then
			return "tap_hold"
		end
		return nil
	end
	local validators = { action_parameter_domain = parameter_domain }
	local function inventory()
		local bytes, status, detail = Writer.read_classified(options.path, files)
		assert(status == "ok" or status == "absent", "tap-hold scope configuration is unreadable: " .. tostring(detail))
		source = { status = status, content = bytes }
		local document = Codec.decode(bytes or "")
		assert(type(document) == "table", "tap-hold scope configuration is malformed")
		local paths
		paths, legacy = parameters.parameter_configuration_inventory(document, is_tap_hold_binding)
		return Manifest.scope_inventory("tap_holds", { parameters = function() return paths end }, validators)
	end
	local function acquire()
		if held then return true end
		local called, acquired = pcall(parameters.acquire_parameter_configuration, owner)
		held = called and acquired == true
		return held
	end
	local function release()
		if not held then return true end
		if parameters.release_parameter_configuration(owner) ~= true then return false end
		held = false
		return true
	end
	local function apply_state(state)
		if parameters.apply_parameter_configuration(owner, state.parameters) ~= true then return false end
		return manager.restore_configuration(state.tap_hold) == true
	end
	local transaction = Transaction.new({
		path = options.path, backup_path = options.backup_path, files = files, manifest = Manifest,
		owned_paths = inventory, owners = validators,
		presets = { tap_hold = {
			path = options.tap_hold_path, backup_path = options.tap_hold_backup_path, prefixes = { "tap_holds" },
			render = function(mode, document, rows) return writer.render_scope(mode, document, rows, preset) end,
		} },
		prepare_batch = function(path, updates, adapter)
			local operations = {}
			for _, row in ipairs(updates) do operations[#operations + 1] = row end
			for _, row in ipairs(legacy) do operations[#operations + 1] = row end
			return Writer.prepare_batch(path, operations, adapter, source)
		end,
		capture = function()
			local snapshot = { tap_hold = manager.configuration_snapshot(),
				parameters = parameters.parameter_configuration_snapshot(owner) }
			if type(snapshot.tap_hold) ~= "table" or type(snapshot.parameters) ~= "table" then return nil end
			return snapshot
		end,
		apply = function(_, _, _, _, presets)
			if options.is_paused() then return false end
			local candidate = parameters.parameter_configuration_snapshot(owner)
			if type(candidate) ~= "table" then return false end
			for key in pairs(candidate) do
				if parameter_domain("gesture_parameters." .. key) then candidate[key] = nil end
			end
			if parameters.apply_parameter_configuration(owner, candidate) ~= true then return false end
			return manager.apply_configuration(presets.tap_hold.decoded) == true
		end,
		restore = apply_state,
	})
	function owner.pending() return transaction.pending() end
	function owner.apply(mode)
		if held or (mode ~= "clear" and mode ~= "recommended") or options.is_paused() then return false end
		if not acquire() then return false, "tap-hold parameters are already owned" end
		layer = nil
		if mode == "recommended" then
			local import, err = import_layer(options, files)
			if not import then
				release()
				return false, "the recommended navigation layer cannot be imported: " .. tostring(err)
			end
			layer = import
		end
		local committed, detail = transaction.apply("tap_holds", mode)
		if committed ~= true and undo_layer(layer, files) then layer = nil end
		if not transaction.pending() then release() end
		return committed, detail
	end
	function owner.revert()
		if not acquire() then return false, "tap-hold parameters are already owned" end
		local reverted, detail = transaction.revert()
		if reverted == true and undo_layer(layer, files) then layer = nil end
		if not transaction.pending() then release() end
		return reverted, detail
	end
	function owner.release() transaction.release() end
	function owner.retry_restore()
		if transaction.pending() and not acquire() then return false end
		if transaction.retry_restore() ~= true then return false end
		return release()
	end
	return owner
end

--- The backup pair for one request, unique within this process.
--- @return string config_path, string backup_path, string tap_hold_path, string tap_hold_backup_path
local function paths()
	_sequence = _sequence + 1
	local stamp = os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence
	local config_path = require("infra.config_paths").config("config.toml")
	local tap_hold_path = require("platform.remap.tap_hold_manager").user_path()
	return config_path, config_path .. ".tap_holds-" .. stamp .. ".bak",
		tap_hold_path, tap_hold_path .. ".tap_holds-" .. stamp .. ".bak"
end

--- Applies a menu request, retaining any refused compensation for a retry.
--- @param mode string "recommended" or "clear".
--- @param is_paused function Live pause getter.
--- @return boolean committed
--- @return string|nil detail
function M.apply(mode, is_paused)
	if type(is_paused) ~= "function" or is_paused() then return false, "tap-hold configuration is paused" end
	if mode ~= "clear" and mode ~= "recommended" then return false, "invalid tap-hold scope mode" end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then
		return false, "tap-hold rollback is pending"
	end
	local path, backup_path, tap_hold_path, tap_hold_backup_path = paths()
	_owner = M.new({ path = path, backup_path = backup_path, tap_hold_path = tap_hold_path,
		tap_hold_backup_path = tap_hold_backup_path, is_paused = is_paused })
	Logger.start(LOG, "Tap-hold scope %s started.", mode)
	local committed, detail = _owner.apply(mode)
	if committed == true then
		Logger.success(LOG, "Tap-hold scope %s completed.", mode)
	else
		Logger.error(LOG, "Tap-hold scope %s refused: %s.", mode, tostring(detail))
	end
	return committed == true, detail
end

--- The tap-hold participant of a composed scope, bound to the retained owner.
--- @param is_paused function Live pause getter.
--- @return table participant See config_scope_composition.
function M.participant(is_paused)
	return require("config_scope_participant").synchronous({
		apply = function(mode) return M.apply(mode, is_paused) end,
		owner = function() return _owner end,
	})
end

--- Test seam: forgets the retained owner.
function M._reset_for_test()
	_owner, _sequence = nil, 0
end

return M
