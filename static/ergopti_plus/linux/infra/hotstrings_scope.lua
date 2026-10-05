--- infra/hotstrings_scope.lua

--- ==============================================================================
--- MODULE: Hotstrings Scope Transaction (Linux)
--- DESCRIPTION:
--- Restores the recommended hotstring settings, or clears them to the neutral
--- state, across both files that hold them: config.toml (category and section
--- choices, the scalar leaves, the word delimiters) and the override file
--- (delays, colours, previews and priorities). One user command is one
--- transaction with one inverse.
---
--- FEATURES & RATIONALE:
--- 1. Runtime first, then files. The engine, the scalar owners and the preview
---    renderer adopt the candidates before either file is published, so a
---    catalogue the engine refuses never reaches the disk.
--- 2. Exact inverses. Both files are backed up and read back before any change,
---    publish only while they still hold the bytes the plan was prepared from,
---    and the previous runtime and override bytes are restored when a later step
---    is refused. A refused restoration is retained and retried, and every
---    ordinary hotstring setter waits for it.
--- 3. Recommended delays are measured, not assumed: the shared planner writes an
---    explicit delay wherever the corpus inheritance differs from the manifest.
--- 4. Only this driver's readers are written. A manifest row no Linux reader
---    consumes (a Windows feature row) is removed by both modes, never set.
--- 5. Shipped word delimiters return to their catalogue defaults in both modes,
---    as the delimiter submenu's own « restore recommended » does. The user's
---    own delimiters and their states are user data and are kept; a state for
---    an unknown key is left for the config cleanup.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local LeafRows = require("toml_codec.leaf_rows")
local KeyPath = require("toml_codec.key_path")
local Codec = require("toml_codec")
local Planner = require("hotstrings.scope_overrides")
local ScopeFile = require("config_scope_file")
local Shell = require("adapters.shell_runner")
local Logger = require("logger.shim")

local LOG = "infra.hotstrings_scope"
local REPEAT_PATH = "hotstrings.repeat_key_enabled"
local _owner, _sequence = nil, 0

--- Whether a category or section identity can be named by a canonical path.
--- @param id string
--- @return boolean
local function addressable(id)
	return type(id) == "string" and id ~= "" and not id:find(".", 1, true)
end

--- Builds one transaction over the real owners.
--- @param options table path, backup_suffix, is_paused, and the runtime owners:
---   config, preferences, repeat_key, magic_key, terminators, dynamic (optional),
---   preview_settings with preview (optional), files, remove.
--- @return table owner apply(mode), revert(), release(), pending(), retry_restore()
function M.new(options)
	assert(type(options) == "table" and type(options.path) == "string" and type(options.is_paused) == "function"
		and type(options.backup_suffix) == "string", "hotstrings scope requires its path and pause owner")
	local Config, Preferences = options.config, options.preferences
	local RepeatKey, MagicKey = options.repeat_key, options.magic_key
	local Dynamic, PreviewSettings, preview = options.dynamic, options.preview_settings, options.preview
	local Terminators = options.terminators
	assert(type(Config) == "table" and type(Preferences) == "table" and type(RepeatKey) == "table"
		and type(MagicKey) == "table" and type(PreviewSettings) == "table" and type(Terminators) == "table",
		"hotstrings scope owners are incomplete")
	local files = options.files or require("adapters.file_system")
	local remove = options.remove or function(target) return os.remove(target) == true end
	local owner, held, current_mode = {}, false, nil
	local source, secondary, owned_set = nil, nil, nil
	local active_snapshot

	--- The catalogue identities the loaded runtime owns, as canonical paths.
	local function inventory()
		local bytes, status, detail = Writer.read_classified(options.path, files)
		assert(status == "ok" or status == "absent", "hotstring configuration is unreadable: " .. tostring(detail))
		source = { status = status, content = bytes }
		assert(type(Codec.decode(bytes or "")) == "table", "hotstring configuration is malformed")
		local paths = {}
		for id, category in pairs(Config.get_categories()) do
			if addressable(id) then
				paths[#paths + 1] = "hotstrings.groups." .. id
				for section in pairs(category.sections or {}) do
					if addressable(section) then paths[#paths + 1] = "hotstrings.modules." .. id .. "." .. section end
				end
			end
		end
		local inventory_paths = Manifest.scope_inventory("hotstrings", { catalogue = function() return paths end })
		owned_set = { [REPEAT_PATH] = true }
		for _, path in ipairs(inventory_paths) do owned_set[path] = true end
		for _, path in ipairs(Preferences.paths()) do owned_set[path] = true end
		return inventory_paths
	end

	--- The override rows of the same plan, prepared against the file as it is now.
	--- @param mode string
	--- @return boolean prepared
	--- @return string|nil reason
	local function prepare_overrides(mode)
		local bundled = Config.bundled_categories()
		local groups = {}
		for id, category in pairs(Config.get_categories()) do
			local sections = {}
			for section in pairs(category.sections or {}) do sections[#sections + 1] = section end
			table.sort(sections)
			groups[#groups + 1] = { id = id, override = { id }, sections = sections, bundled = bundled[id] == true }
		end
		table.sort(groups, function(left, right) return left.id < right.id end)
		local changes = Planner.plan({ mode = mode, features = Manifest.features(), groups = groups,
			inherited = Config.inherited_delay,
			extra = { { override = { "_global" }, fields = { "delay" } },
				{ override = { "dynamichotstrings" }, fields = Planner.FIELDS } } })
		secondary = ScopeFile.new({ path = Config.override_path(),
			backup_path = Config.override_path() .. options.backup_suffix, remove = remove })
		return secondary.prepare(Planner.writer_rows(changes))
	end

	local function capture()
		local config = Config.configuration_snapshot()
		local preferences = Preferences.snapshot()
		if type(config) ~= "table" or type(preferences) ~= "table" then return nil end
		local programmable = Dynamic and Dynamic.user_code_scope_snapshot and Dynamic.user_code_scope_snapshot()
		if Dynamic and Dynamic.user_code_time_activation and Dynamic.user_code_time_activation() ~= nil
			and type(programmable) ~= "table" then return nil end
		active_snapshot = { config = config, preferences = preferences, programmable = programmable, repeat_enabled = RepeatKey.is_enabled(),
			trigger = MagicKey.get(), terminators = Terminators.snapshot() }
		return active_snapshot
	end

	--- Applies the dynamic owner and the preview renderer to the adopted leaves.
	--- @param trigger string Effective magic key.
	--- @param previous string Magic key before this step.
	--- @return boolean acknowledged
	local function apply_dependents(trigger, previous, programmable, inverse)
		if Dynamic then
			if trigger ~= previous and Dynamic.init({ trigger_char = trigger }) ~= true then return false end
			local acknowledged, reason = Dynamic.refresh(programmable, inverse)
			if acknowledged ~= true and not (reason == "builtin-unavailable" and Dynamic.get_rules_count() == 0) then
				return false
			end
		end
		if preview and PreviewSettings.apply(preview) ~= #PreviewSettings.toggles() then return false end
		return true
	end

	local function restore(snapshot)
		if snapshot.programmable and Dynamic.user_code_scope_current(snapshot.programmable) ~= true then return false end
		if secondary and secondary.restore() ~= true then return false end
		if Preferences.restore(owner, snapshot.preferences) ~= true then return false end
		if RepeatKey.restore_configuration(snapshot.repeat_enabled) ~= true then return false end
		if Terminators.restore_configuration(snapshot.terminators) ~= true then return false end
		local current = MagicKey.get()
		if Config.restore_configuration(owner, snapshot.config) ~= true then return false end
		return apply_dependents(snapshot.trigger, current, snapshot.programmable, true)
	end

	local transaction = Transaction.new({
		path = options.path, backup_path = options.path .. options.backup_suffix, files = files,
		manifest = Manifest, owned_paths = inventory, capture = capture, restore = restore,
		prepare_batch = function(path, updates, adapter)
			local operations = {}
			for _, row in ipairs(updates) do
				local segments = KeyPath.parse(row.section, true)
				assert(segments, "scope row has an invalid table path: " .. tostring(row.section))
				segments[#segments + 1] = row.key
				local path_text = row.section .. "." .. row.key
				if row.delete or not owned_set[path_text] then
					operations[#operations + 1] = { path = segments, delete = true }
				else
					operations[#operations + 1] = { path = segments, value = row.value }
				end
			end
			for _, segments in ipairs(Terminators.builtin_state_leaves(Codec.decode(source.content or ""))) do
				operations[#operations + 1] = { path = segments, delete = true }
			end
			local prepared, detail = prepare_overrides(current_mode)
			if prepared ~= true then return false, "override file: " .. tostring(detail) end
			return Writer.prepare_batch(path, LeafRows.prepare(source.content or "", operations), adapter, source)
		end,
		apply = function(decoded)
			if options.is_paused() then return false end
			local backed, detail = secondary.backup()
			if backed ~= true then
				Logger.error(LOG, "Override backup refused: %s.", tostring(detail))
				return false
			end
			local previous = MagicKey.get()
			if Preferences.adopt(owner, decoded) ~= true then return false end
			if RepeatKey.adopt_configuration(decoded) ~= true then return false end
			if Terminators.adopt_configuration(decoded) ~= true then return false end
			local trigger = MagicKey.get()
			if trigger ~= previous and Config.set_magic_key(trigger, MagicKey.default()) ~= true then return false end
			if Config.apply_configuration(owner, decoded, secondary.candidate(), secondary.target()) ~= true then return false end
			if not apply_dependents(trigger, previous, active_snapshot.programmable) then return false end
			-- A first write creates the configuration folder the two files share.
			local directory = options.path:match("^(.*)/[^/]+$")
			if not Shell.run("mkdir -p " .. Shell.quote(directory) .. " 2>/dev/null") then return false end
			local published, why = secondary.publish()
			if published ~= true then
				Logger.error(LOG, "Override publication refused: %s.", tostring(why))
				return false
			end
			return true
		end,
	})

	local function release()
		assert(Config.release(owner) and Preferences.release(owner), "hotstring configuration release refused")
		held = false
	end

	function owner.pending() return transaction.pending() end

	--- Runs one scope operation.
	--- @param mode string "recommended" or "clear".
	--- @return boolean committed
	--- @return string|nil reason
	function owner.apply(mode)
		if held or (mode ~= "recommended" and mode ~= "clear") or options.is_paused() then
			return false, "the hotstrings scope cannot start"
		end
		if not Config.acquire(owner) then return false, "hotstring configuration is already owned" end
		if not Preferences.acquire(owner) then
			Config.release(owner)
			return false, "hotstring preferences are already owned"
		end
		held, current_mode = true, mode
		local committed, detail = transaction.apply("hotstrings", mode)
		if not transaction.pending() then release() end
		return committed, detail
	end

	--- Retries a refused restoration and releases the owners once it settles.
	--- @return boolean restored
	function owner.retry_restore()
		if transaction.retry_restore() ~= true then return false end
		if held then release() end
		return true
	end

	--- Undoes the last committed operation when a later scope of the same
	--- composition is refused: the runtime and the override file first, then
	--- config.toml, each only while it still holds this scope's bytes. A refused
	--- step stays pending and keeps the owners held until retry_restore().
	--- @return boolean reverted
	--- @return string|nil reason
	function owner.revert()
		if held then return false, "the hotstrings scope is still held" end
		if not Config.acquire(owner) then return false, "hotstring configuration is already owned" end
		if not Preferences.acquire(owner) then
			Config.release(owner)
			return false, "hotstring preferences are already owned"
		end
		held = true
		local reverted, detail = transaction.revert()
		if not transaction.pending() then release() end
		return reverted == true, detail
	end

	--- Forgets the last commit's inverse once its composition has committed.
	function owner.release() transaction.release() end

	return owner
end

--- Applies a menu request with the daemon's owners, retaining a refused inverse.
--- @param mode string "recommended" or "clear".
--- @param is_paused function Live pause getter.
--- @param ports table|nil dynamic and preview runtime owners the daemon holds.
--- @return boolean committed
--- @return string|nil reason
function M.apply(mode, is_paused, ports)
	if mode ~= "recommended" and mode ~= "clear" then return false, "invalid hotstrings scope mode" end
	if type(is_paused) ~= "function" or is_paused() then return false, "hotstrings configuration is paused" end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then return false, "hotstrings rollback is pending" end
	ports = type(ports) == "table" and ports or {}
	_sequence = _sequence + 1
	_owner = M.new({
		path = require("infra.config_paths").config("config.toml"),
		backup_suffix = ".hotstrings-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak",
		is_paused = is_paused,
		config = require("modules.hotstrings.hotstrings_config"),
		preferences = require("infra.hotstring_preferences"),
		repeat_key = require("modules.hotstrings.repeat_key"),
		magic_key = require("modules.hotstrings.magic_key"),
		terminators = require("modules.hotstrings.terminator_settings"),
		preview_settings = require("modules.hotstrings.preview_settings"),
		dynamic = ports.dynamic, preview = ports.preview,
	})
	Logger.start(LOG, "Hotstrings scope '%s' started.", mode)
	local committed, detail = _owner.apply(mode)
	if committed == true then
		Logger.success(LOG, "Hotstrings scope '%s' completed.", mode)
	else
		Logger.error(LOG, "Hotstrings scope '%s' refused: %s.", mode, tostring(detail))
	end
	return committed == true, detail
end

--- The hotstrings participant of a composed scope, bound to the retained owner.
--- @param is_paused function Live pause getter.
--- @param ports table|nil dynamic and preview runtime owners the daemon holds.
--- @return table participant See config_scope_composition.
function M.participant(is_paused, ports)
	return require("config_scope_participant").synchronous({
		apply = function(mode) return M.apply(mode, is_paused, ports) end,
		owner = function() return _owner end,
	})
end

return M
