--- tests/support/keystats/absent_ledger_file_system.lua

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
--- @param get_current_paths function|nil Reads the bound manager's current path owner.
function M.extend(files, get_current_paths)
	assert(type(files) == "table", "fixture filesystem model required")
	assert(get_current_paths == nil or type(get_current_paths) == "function", "invalid fixture path owner")
	local model = MODELS[files]
	if model then
		assert(model.held == nil, "cannot rebind an empty volume with a held lease")
		if get_current_paths ~= nil then model.get_current_paths = get_current_paths end
		return
	end
	assert(files.acquire_write_locks == nil, "empty-volume model cannot replace a real publication owner")
	model = { get_current_paths = get_current_paths }
	MODELS[files] = model
	local read = files.read_with_status
	function files.acquire_write_locks(paths)
		assert(model.held == nil and type(paths) == "table" and getmetatable(paths) == nil
			and type(paths[1]) == "string", "invalid empty-volume lease request")
		local ledger, today = paths[1], nil
		if model.get_current_paths then
			local expected = model.get_current_paths()
			assert(type(expected) == "table" and type(expected.data_sql_path) == "string",
				"empty-volume manager lost its canonical ledger path")
			ledger, today = expected.data_sql_path, expected.today_log_path
		end
		assert(paths[1] == ledger, "empty-volume lease must name its bound ledger")
		local count = 1
		if paths[2] ~= nil then
			assert(model.get_current_paths ~= nil and type(today) == "string" and today ~= ledger
				and paths[2] == today, "empty-volume adjacent lease must name its bound today.log")
			count = 2
		end
		for index in pairs(paths) do
			assert(index == 1 or (count == 2 and index == 2), "unexpected empty-volume lease path")
		end
		assert(#paths == count, "empty-volume lease paths must be dense")
		local resolved = { [ledger] = ledger }
		if count == 2 then resolved[today] = today end
		model.ledger = ledger
		model.held = { resolved_paths = resolved, committed = true }
		return model.held, true
	end
	function files.release_write_locks(group)
		if group == nil then
			assert(model.held == nil, "a nil release cannot retire a held fixture lease")
			return true
		end
		assert(model.held == group, "only the exact fixture native lease may be released")
		model.held, model.ledger, group.committed, group.released = nil, nil, false, true
		return true
	end
	function files.read_with_status(path, ...)
		if path:sub(-#".append-journal.json") == ".append-journal.json" then
			assert(model.held ~= nil and path == model.ledger .. ".append-journal.json",
				"journal absence must be observed under its exact ledger lock")
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
	local manager, ingest_once
	local function get_current_paths()
		assert(type(ingest_once) == "function", "fixture manager is not loaded")
		for index = 1, math.huge do
			local name, value = debug.getupvalue(ingest_once, index)
			assert(name, "fixture manager lost its append boundary")
			if name == "_flush_local_data_sql_outbox" then
				for nested = 1, math.huge do
					local key, paths = debug.getupvalue(value, nested)
					assert(key, "fixture manager lost its path owner")
					if key == "_paths" then return paths end
				end
			end
		end
	end
	M.extend(files, get_current_paths)
	package.loaded["adapters.ledger_append"] = nil
	manager = helpers.load_with_stubs("modules.keystats.log_manager", overrides)
	-- Scenarios may wrap the public method; retain its actual path owner.
	ingest_once = manager.ingest_once
	-- Init replaces this upvalue table; every later acquisition reads it again.
	get_current_paths().data_sql_path = "/virtual/empty-ledger/data.sql"
	return manager
end

return M
