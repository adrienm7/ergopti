--- infra/llm_scope.lua

--- Owns terminal AI preference restoration through the shared transaction.
local M = {}
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.llm_preferences")
local Transaction = require("config_scope_transaction")
local FencedTransaction = require("config_scope_fenced_transaction")
local Logger = require("logger.shim")
local LOG = "infra.llm_scope"
local _owner, _sequence = nil, 0

local OWNERS = { "settings", "trigger_settings", "display_settings", "navigation_settings",
	"profile_settings", "agent_settings", "profiles" }

--- Builds a terminal owner; the ordinary readers consume a detached candidate.
--- @param options table Path, backup path, filesystem and optional engine ports.
--- @return table owner Retained compensation and explicit recovery.
function M.new(options)
	local engine = options.engine or require("modules.llm.prediction_engine")
	local readers = {}
	for _, name in ipairs(OWNERS) do readers[name] = require("modules.llm." .. name) end
	local owner, native_token, stopping = {}, {}, false
	local transaction
	local function capture(source)
		assert(Preferences.with_configuration(native_token, source, function() return true end), "invalid AI source")
		local result = { engine = engine.configuration_snapshot(native_token), readers = {} }
		assert(type(result.engine) == "table", "AI prediction work is not quiescent")
		for name, reader in pairs(readers) do result.readers[name] = reader.configuration_snapshot() end
		return result
	end
	local function restore(snapshot)
		if not engine.quiesce_configuration(native_token) then return false end
		for _, name in ipairs(OWNERS) do
			if readers[name].restore_configuration(snapshot.readers[name]) ~= true then return false end
		end
		return engine.apply_configuration(native_token, snapshot.engine) == true
	end
	transaction = Transaction.new({
		path = options.path, backup_path = options.backup_path,
		files = options.files or require("adapters.file_system"), manifest = Manifest,
		capture = capture, restore = restore,
		apply = function(_, _, _, candidate)
			local applied = Preferences.with_configuration(native_token, { status = "ok", content = candidate }, function()
				for _, name in ipairs(OWNERS) do
					if readers[name].reload_configuration() ~= true then return false end
				end
				return true
			end)
			if not applied then return false end
			return engine.apply_configuration(native_token, { enabled = readers.profiles.is_enabled() }) == true
		end,
	})
	local function quiesce()
		stopping = true
		-- A canceled HTTP prompt is irreversible. The same native stop must
		-- acknowledge before any source snapshot or preference inverse runs.
		local called, settled = pcall(engine.quiesce_configuration, native_token)
		if not called or settled ~= true then return false, "AI work cancellation remains pending" end
		stopping = false
		return true
	end
	function native_token.pending() return stopping or transaction.pending() end
	-- This native phase adapter retains only AI quiescence and forwards the
	-- actual primary journal. The shared fence owner never stops paid work.
	local phase = { committed = transaction.committed, release = transaction.release, pending = native_token.pending }
	function phase.apply(scope, mode)
		local settled, detail = quiesce()
		if settled ~= true then return false, detail end
		return transaction.apply(scope, mode)
	end
	function phase.revert()
		local settled, detail = quiesce()
		if settled ~= true then return false, detail end
		return transaction.revert()
	end
	function phase.retry_restore()
		if stopping and quiesce() ~= true then return false end
		return transaction.retry_restore()
	end
	return FencedTransaction.new({ owner = owner, native_token = native_token, transaction = phase, scope = "llm",
		fences = { { acquire = Preferences.acquire, release = Preferences.release },
			{ acquire = engine.acquire_configuration, release = engine.release_configuration } },
		available = function() return true end })
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

--- The AI participant of a composed scope, bound to the retained owner.
--- @param is_paused function Live pause getter.
--- @return table participant See config_scope_composition.
function M.participant(is_paused)
	return require("config_scope_participant").synchronous({
		apply = function(mode) return M.apply(mode, is_paused()) end,
		owner = function() return _owner end,
	})
end

return M
