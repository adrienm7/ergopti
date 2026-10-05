--- infra/dynamic_hotstrings_scope.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstring Bulk Selection (Linux)
--- DESCRIPTION:
--- Commits the dynamic master and its manifest families as one acknowledged
--- transaction. Ordinary mappings and dynamic guards adopt the same candidate;
--- an unavailable runtime or refused publication restores their exact snapshots.
--- Global hotstring gates, pause, previews and unrelated preferences stay owned
--- by their existing readers.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local BulkScope = require("hotstrings.bulk_scope")
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local LeafRows = require("toml_codec.leaf_rows")
local KeyPath = require("toml_codec.key_path")
local Shell = require("adapters.shell_runner")
local Logger = require("logger.shim")

local LOG = "infra.dynamic_hotstrings_scope"
local _owner, _sequence = nil, 0

--- Builds one recoverable transaction through the actual runtime owners.
--- @param options table Configuration/backup paths, config, preferences, dynamic, files.
--- @return table owner Apply, pending and compensation operations.
function M.new(options)
	assert(type(options) == "table", "dynamic bulk selection requires its owners")
	local Config, Preferences, Dynamic = options.config, options.preferences, options.dynamic
	assert(type(Config) == "table" and type(Preferences) == "table" and type(Dynamic) == "table",
		"dynamic bulk selection owners are incomplete")
	local owner, held = {}, false
	local active_snapshot
	local files = options.files or require("adapters.file_system")
	local manifest_port = {}
	function manifest_port.scope_plan(scope, mode)
		assert(scope == "dynamic" and (mode == "enable_all" or mode == "disable_all"),
			"invalid dynamic bulk selection")
		-- Rediscover after acquisition; a menu's family rows are only a view.
		local families, owned = {}, {}
		for _, path in ipairs(Preferences.paths()) do owned[path] = true end
		for _, entry in ipairs(Manifest.features()) do
			if entry.section == "hotstrings.dynamic" and entry.type == "feature" then
				assert(owned[entry.path .. ".enabled"], "dynamic family has no preference owner")
				families[#families + 1] = entry.id
			end
		end
		local changes, detail = BulkScope.plan({ dynamic = families }, { "dynamic" }, mode == "enable_all")
		assert(changes, detail)
		local operations = {}
		for _, change in ipairs(changes) do
			local section = "hotstrings.dynamic" .. (change.section and ("." .. change.section) or "")
			local path = section .. ".enabled"
			assert(owned[path], "dynamic selection has no preference owner")
			local row = { section = section, key = "enabled" }
			if change.enabled == Manifest.default_for(path) then row.delete = true
			else row.value = change.enabled end
			operations[#operations + 1] = row
		end
		return { presets = {}, operations = operations }
	end

	local transaction = Transaction.new({
		path = options.path, backup_path = options.backup_path, files = files, manifest = manifest_port,
		prepare_batch = function(path, updates, adapter)
			local content, status, detail = Writer.read_classified(path, adapter)
			if status ~= "ok" and status ~= "absent" then return false, detail end
			local operations = {}
			for _, row in ipairs(updates) do
				local segments = assert(KeyPath.parse(row.section, true))
				segments[#segments + 1] = row.key
				operations[#operations + 1] = { path = segments, value = row.value, delete = row.delete }
			end
			return Writer.prepare_batch(path, LeafRows.prepare(content or "", operations), adapter,
				{ status = status, content = content })
		end,
		capture = function()
			local config, preferences = Config.configuration_snapshot(), Preferences.snapshot()
			if type(config) ~= "table" or type(preferences) ~= "table" then return nil end
			active_snapshot = { config = config, preferences = preferences, dynamic_enabled = Dynamic.is_enabled(),
				programmable = Dynamic.user_code_scope_snapshot and Dynamic.user_code_scope_snapshot() }
			if Dynamic.user_code_time_activation and Dynamic.user_code_time_activation() ~= nil
				and type(active_snapshot.programmable) ~= "table" then return nil end
			return active_snapshot
		end,
		apply = function(document, updates)
			local touched = {}
			for _, row in ipairs(updates) do touched[row.section .. "." .. row.key] = true end
			if Preferences.adopt(owner, document, touched) ~= true then return false end
			if Dynamic.refresh(active_snapshot.programmable) ~= true then return false end
			-- Prefix families live in the ordinary matcher, unlike date guards.
			local _, committed = Config.reload()
			if committed ~= true then return false end
			local directory = options.path:match("^(.*)/[^/]+$")
			return Shell.run("mkdir -p " .. Shell.quote(directory) .. " 2>/dev/null") == true
		end,
		restore = function(snapshot)
			if snapshot.programmable and Dynamic.user_code_scope_current(snapshot.programmable) ~= true then return false end
			if Preferences.restore(owner, snapshot.preferences) ~= true then return false end
			local acknowledged, reason = Dynamic.refresh(snapshot.programmable, true)
			if acknowledged ~= true and not (reason == "builtin-unavailable" and Dynamic.get_rules_count() == 0) then
				return false
			end
			-- A previous true preference can legitimately have no loaded rules.
			-- Restore its effective posture, including that disabled runtime.
			if Dynamic.is_enabled() ~= snapshot.dynamic_enabled then return false end
			return Config.restore_configuration(owner, snapshot.config) == true
		end,
	})

	local function acquire()
		if held or not Config.acquire(owner) then return false end
		if not Preferences.acquire(owner) then Config.release(owner); return false end
		held = true
		return true
	end
	local function release()
		assert(Config.release(owner) and Preferences.release(owner), "dynamic bulk ownership release refused")
		held = false
	end
	function owner.pending() return transaction.pending() end
	function owner.apply(enabled)
		if type(enabled) ~= "boolean" then return false, "invalid dynamic bulk posture" end
		if not acquire() then return false, "hotstring configuration is already owned" end
		local committed, detail = transaction.apply("dynamic", enabled and "enable_all" or "disable_all")
		if not transaction.pending() then release() end
		return committed, detail
	end
	function owner.retry_restore()
		if transaction.retry_restore() ~= true then return false end
		if held then release() end
		return true
	end
	function owner.revert()
		if not acquire() then return false, "hotstring configuration is already owned" end
		local reverted, detail = transaction.revert()
		if not transaction.pending() then release() end
		return reverted, detail
	end
	function owner.release() transaction.release() end
	return owner
end

--- Handles a menu request, retaining refused compensation for the next retry.
--- @param enabled boolean Explicit requested posture.
--- @param dynamic table Dynamic manager held by the daemon.
--- @param config table|nil Ordinary hotstring configuration owner.
--- @return boolean committed
--- @return string|nil detail
function M.apply(enabled, dynamic, config)
	if type(enabled) ~= "boolean" then return false, "invalid dynamic bulk posture" end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then return false, "dynamic rollback is pending" end
	_sequence = _sequence + 1
	local path = require("infra.config_paths").config("config.toml")
	_owner = M.new({ path = path,
		backup_path = path .. ".dynamic-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak",
		config = config or require("modules.hotstrings.hotstrings_config"),
		preferences = require("infra.hotstring_preferences"), dynamic = dynamic })
	local committed, detail = _owner.apply(enabled)
	if committed ~= true then Logger.error(LOG, "Dynamic bulk selection refused: %s.", tostring(detail)) end
	return committed == true, detail
end

return M
