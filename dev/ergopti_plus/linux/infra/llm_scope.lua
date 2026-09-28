--- infra/llm_scope.lua

--- Owns terminal AI preference restoration through the shared transaction.
local M = {}
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.llm_preferences")
local Transaction = require("config_scope_transaction")
local Logger = require("logger.shim")
local LOG = "infra.llm_scope"
local _owner, _sequence = nil, 0

local OWNERS = { "settings", "trigger_settings", "display_settings", "navigation_settings",
	"profile_settings", "profiles" }

--- Builds a terminal owner; the ordinary readers consume a detached candidate.
--- @param options table Path, backup path, filesystem and optional engine ports.
--- @return table owner Retained compensation and explicit recovery.
function M.new(options)
	local engine = options.engine or require("modules.llm.prediction_engine")
	local readers = {}
	for _, name in ipairs(OWNERS) do readers[name] = require("modules.llm." .. name) end
	local owner, stopping, acquired = {}, false, false
	local transaction
	local function capture(source)
		assert(Preferences.with_configuration(owner, source, function() return true end), "invalid AI source")
		local result = { engine = engine.configuration_snapshot(owner), readers = {} }
		assert(type(result.engine) == "table", "AI prediction work is not quiescent")
		for name, reader in pairs(readers) do result.readers[name] = reader.configuration_snapshot() end
		return result
	end
	local function restore(snapshot)
		if not engine.quiesce_configuration(owner) then return false end
		for _, name in ipairs(OWNERS) do
			if readers[name].restore_configuration(snapshot.readers[name]) ~= true then return false end
		end
		return engine.apply_configuration(owner, snapshot.engine) == true
	end
	transaction = Transaction.new({
		path = options.path, backup_path = options.backup_path,
		files = options.files or require("adapters.file_system"), manifest = Manifest,
		capture = capture, restore = restore,
		apply = function(_, _, _, candidate)
			local applied = Preferences.with_configuration(owner, { status = "ok", content = candidate }, function()
				for _, name in ipairs(OWNERS) do
					if readers[name].reload_configuration() ~= true then return false end
				end
				return true
			end)
			if not applied then return false end
			return engine.apply_configuration(owner, { enabled = readers.profiles.is_enabled() }) == true
		end,
	})
	function owner.pending() return stopping or transaction.pending() end
	local function release()
		if owner.pending() then return false end
		if not engine.release_configuration(owner) or not Preferences.release(owner) then return false end
		acquired = false
		return true
	end
	function owner.apply(mode)
		if acquired or (mode ~= "clear" and mode ~= "recommended") then return false end
		if not Preferences.acquire(owner) then return false end
		if not engine.acquire_configuration(owner) then Preferences.release(owner); return false end
		acquired, stopping = true, true
		-- A cancelled HTTP prompt is irreversible. Only the later quiescent
		-- preference posture is compensable; no failure resends paid work.
		local ok, settled = pcall(engine.quiesce_configuration, owner)
		if not ok or settled ~= true then return false, "AI work cancellation remains pending" end
		stopping = false
		local committed, detail = transaction.apply("llm", mode)
		if not owner.pending() then release() end
		return committed, detail
	end
	function owner.retry_restore()
		if not acquired then return true end
		if stopping then
			local ok, settled = pcall(engine.quiesce_configuration, owner)
			if not ok or settled ~= true then return false end
			stopping = false
		end
		if transaction.retry_restore() ~= true then return false end
		return release()
	end
	return owner
end

--- Applies one real AI scope without exposing credentials or model files.
--- @param mode string Clear or recommended.
--- @param is_paused boolean Optional menu pause state.
--- @return boolean committed
function M.apply(mode, is_paused)
	if is_paused or (mode ~= "clear" and mode ~= "recommended") then return false end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then return false end
	_sequence = _sequence + 1
	local path = require("infra.config_paths").config("config.toml")
	_owner = M.new({ path = path, backup_path = path .. ".llm-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak" })
	Logger.start(LOG, "AI preference scope %s started.", mode)
	local ok, detail = _owner.apply(mode)
	if ok then Logger.success(LOG, "AI preference scope %s completed.", mode)
	else Logger.error(LOG, "AI preference scope %s refused: %s.", mode, tostring(detail)) end
	return ok == true
end

return M
