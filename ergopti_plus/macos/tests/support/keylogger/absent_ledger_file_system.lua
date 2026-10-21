--- tests/support/keylogger/absent_ledger_file_system.lua

--- ==============================================================================
--- MODULE: Empty Ledger Volume Ports for Non-IO Scenarios
--- DESCRIPTION:
--- Older manager scenarios model an empty outbox and no durable append journal.
--- They still execute the real append owner: exact lock acquisition/release and
--- journal absence are explicit ports. Any nonempty publication is refused.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local MODELS = setmetatable({}, { __mode = "k" })

--- Extends a fixture's filesystem model without admitting a real SQL publication.
--- @param files table Existing fixture-owned filesystem model.
function M.extend(files)
	assert(type(files) == "table", "fixture filesystem model required")
	if MODELS[files] then return end
	assert(files.acquire_write_locks == nil, "empty-volume model cannot replace a real publication owner")
	MODELS[files] = true
	local read, held = files.read_with_status, nil
	function files.acquire_write_locks(paths)
		assert(held == nil and type(paths) == "table" and #paths == 1 and type(paths[1]) == "string")
		held = { resolved_paths = { [paths[1]] = paths[1] }, committed = true }
		return held, true
	end
	function files.release_write_locks(group)
		if group == nil then return true end
		assert(held == group, "only the exact fixture native lease may be released")
		held, group.committed, group.released = nil, false, true
		return true
	end
	function files.read_with_status(path, ...)
		if path:sub(-#".append-journal.json") == ".append-journal.json" then
			assert(held ~= nil, "journal absence must be observed under its ledger lock")
			return nil, "absent"
		end
		if read then return read(path, ...) end
		return nil, "absent"
	end
end

--- Loads the real manager with a closed empty-volume model and an explicit path.
--- @param overrides table|nil Existing scenario's native overrides.
--- @return table manager Actual production manager, with no method wrapped.
function M.load(overrides)
	local files = package.loaded["adapters.file_system"]
	if type(files) ~= "table" then files = {}; package.loaded["adapters.file_system"] = files end
	M.extend(files)
	package.loaded["adapters.ledger_append"] = nil
	local manager = helpers.load_with_stubs("modules.keylogger.log_manager", overrides)
	for index = 1, math.huge do
		local name, value = debug.getupvalue(manager.ingest_once, index)
		assert(name, "fixture manager lost its append boundary")
		if name == "_flush_local_data_sql_outbox" then
			for nested = 1, math.huge do
				local key, paths = debug.getupvalue(value, nested)
				assert(key, "fixture manager lost its path owner")
				if key == "_paths" then paths.data_sql_path = "/virtual/empty-ledger/data.sql"; break end
			end
			break
		end
	end
	return manager
end

return M
