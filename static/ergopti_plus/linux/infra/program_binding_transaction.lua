--- infra/program_binding_transaction.lua

--- Publishes an executable parameter and its binding under exact runtime ownership.
local M = {}
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local Logger = require("logger.shim")
local LOG = "infra.program_binding_transaction"
local _current, _sequence = nil, 0
local _constructing = false

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}; for key, child in pairs(value) do out[key] = copy(child) end
	return out
end

local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

--- Builds a conditional publication using existing preference and dispatch owners.
--- @param options table Exact binding, scalar, path, backup, pause and native file ports.
--- @return table owner Apply, retained debt and explicit compensation retry.
function M.new(options)
	assert(type(options) == "table" and type(options.is_paused) == "function", "program binding requires live pause ownership")
	local parameters = options.parameters or require("modules.gestures.manager")
	local binding, slot, section, provider = options.binding
	local families = {
		{ "keyboard__", "shortcuts.keyboard", "modules.shortcuts.keyboard_shortcuts" },
		{ "tap_key__", "shortcuts.tap_keys", "modules.shortcuts.tap_keys" },
		{ "script__", "shortcuts.script_control", "modules.shortcuts.script_chords" },
	}
	if type(binding) == "string" and parameters.DEFAULT_GESTURES[binding] ~= nil then
		slot, section = binding, "gestures"
	else
		for _, family in ipairs(families) do
			if type(binding) == "string" and binding:sub(1, #family[1]) == family[1] then
				provider = require(family[3])
				if provider.configuration_domain(binding) == nil then break end
				slot, section = binding:sub(#family[1] + 1), family[2]
				break
			end
		end
	end
	assert(type(slot) == "string" and parameters.validate_action_parameter("run_program", options.scalar) == true,
		"program binding model is invalid")
	local owner, held, retiring, busy = {}, {}, false, false
	local files = options.files or require("adapters.file_system")
	local checkpoint, reconcile_pending, inverse_source = nil, false, nil
	local ports = { { acquire = parameters.acquire_parameter_configuration, release = parameters.release_parameter_configuration,
		snapshot = function()
			local values = parameters.parameter_configuration_snapshot(owner)
			local actions = parameters.parameter_configuration_actions_snapshot(owner)
			if type(values) ~= "table" or type(actions) ~= "table" then return nil end
			return { parameters = values, actions = actions }
		end } }
	if provider then ports[#ports + 1] = { acquire = provider.acquire_configuration, release = provider.release_configuration,
		snapshot = function() return provider.configuration_snapshot(owner) end } end
	local function read_source()
		local content, status = Writer.read_classified(options.path, files)
		if status ~= "ok" and status ~= "absent" then return nil end
		return { status = status, content = status == "ok" and content or nil }
	end
	local function capture_release()
		if checkpoint ~= nil then return true end
		local source = read_source()
		if source == nil or (inverse_source ~= nil and not equal(source, inverse_source)) then return false end
		local snapshots = {}
		for index, port in ipairs(held) do
			local called, state = pcall(port.snapshot)
			if not called or type(state) ~= "table" then return false end
			snapshots[index] = state
		end
		checkpoint = { source = source, snapshots = snapshots }
		return true
	end
	--- A refused release can mutate ownership before returning. Reacquire only
	--- the missing lease while exact canonical and full runtime checkpoints hold.
	local function reconcile()
		if not capture_release() or not equal(read_source(), checkpoint.source) then return false end
		for index, port in ipairs(held) do
			local called, state = pcall(port.snapshot)
			if not called then return false end
			if state == nil then
				if not equal(read_source(), checkpoint.source) then return false end
				local acquired, receipt = pcall(port.acquire, owner)
				if not acquired or receipt ~= true then return false end
				called, state = pcall(port.snapshot)
			end
			if not called or not equal(state, checkpoint.snapshots[index]) then return false end
		end
		if not equal(read_source(), checkpoint.source) then return false end
		reconcile_pending = false
		return true
	end
	local function release()
		if #held == 0 then return true end
		reconcile_pending = true
		if not capture_release() then return false end
		local paused = options.is_paused()
		if type(paused) ~= "boolean" or parameters.set_program_paused(paused) ~= true
			or not equal(read_source(), checkpoint.source) then return false end
		for index = #held, 1, -1 do
			local called, receipt = pcall(held[index].release, owner)
			if not called or receipt ~= true then return false end
		end
		held, checkpoint, reconcile_pending = {}, nil, false
		return true
	end
	local function assignment_snapshot()
		if provider then return provider.configuration_snapshot(owner) end
		local actions = parameters.parameter_configuration_actions_snapshot(owner)
		return type(actions) == "table" and { assignments = actions } or nil
	end
	local function apply_assignments(state)
		if provider then return provider.apply_configuration(owner, state) == true end
		return parameters.apply_parameter_configuration_actions(owner, state.assignments) == true
	end
	local updates = {
		{ section = "gesture_parameters", key = binding .. "__run_program", value = options.scalar },
		{ section = section, key = slot, value = "run_program" },
	}
	local transaction = Transaction.new({ path = options.path, backup_path = options.backup_path,
		files = files,
		manifest = { scope_plan = function() return { operations = updates, presets = {} } end },
		capture = function()
			local scalar_state = parameters.parameter_configuration_snapshot(owner)
			local assignments = assignment_snapshot()
			if type(scalar_state) ~= "table" or type(assignments) ~= "table" then return nil end
			return { parameters = scalar_state, assignments = assignments }
		end,
		apply = function()
			if options.is_paused() then return false end
			local scalar_state = parameters.parameter_configuration_snapshot(owner)
			local assignments = assignment_snapshot()
			if type(scalar_state) ~= "table" or type(assignments) ~= "table" then return false end
			scalar_state[binding .. "__run_program"] = options.scalar
			assignments = copy(assignments)
			assignments.assignments[slot] = "run_program"
			if assignments.explicit_assignments then assignments.explicit_assignments[slot] = "run_program" end
			return parameters.apply_parameter_configuration(owner, scalar_state) == true and apply_assignments(assignments)
		end,
		restore = function(snapshot)
			return parameters.apply_parameter_configuration(owner, snapshot.parameters) == true
				and apply_assignments(snapshot.assignments)
		end,
	})
	function owner.pending() return #held > 0 or transaction.pending() or retiring or busy end
	local function recover()
		if retiring then
			if parameters.stop_programs() ~= true then return false end
			retiring = false
		end
		if reconcile_pending and not reconcile() then return false end
		if transaction.committed() then
			if transaction.revert() ~= true then return false end
		elseif transaction.retry_restore() ~= true then return false end
		-- A refused eager inverse becomes shared transaction debt. Once its
		-- retry restores the original source, that source replaces the candidate
		-- checkpoint just as it does after an immediately accepted inverse.
		inverse_source = nil
		checkpoint = nil
		if release() ~= true then return false end
		transaction.release()
		return true
	end
	local function apply()
		if options.is_paused() then return false end
		for _, port in ipairs(ports) do
			local ok, receipt = pcall(port.acquire, owner)
			if not ok or receipt ~= true then release(); return false end
			held[#held + 1] = port
		end
		retiring = true
		if parameters.stop_programs() ~= true then return false end
		retiring = false
		local accepted, _, candidate = transaction.apply("program_binding", "configured")
		if transaction.pending() then return false end
		if accepted == true then inverse_source = { status = "ok", content = candidate } end
		if release() ~= true then recover(); return false end
		transaction.release()
		return accepted == true
	end
	local function guarded(operation)
		if busy then return false end
		busy = true
		local called, receipt = pcall(operation)
		busy = false
		return called and receipt == true
	end
	function owner.apply()
		if owner.pending() then return false end
		return guarded(apply)
	end
	function owner.retry_restore() return guarded(recover) end
	function owner.claimed() return busy end
	return owner
end

--- Commits one picker confirmation while retaining any refused native inverse.
--- @param binding string Canonical binding identity.
--- @param scalar string Validated executable parameter.
--- @param is_paused function Live pause getter.
--- @return boolean committed
function M.apply(binding, scalar, is_paused)
	if type(is_paused) ~= "function" or _constructing then return false end
	_constructing = true
	local ok, accepted = pcall(function()
		if _current and _current.pending() and _current.retry_restore() ~= true then return false end
		_sequence = _sequence + 1
		local path = require("infra.config_paths").config("config.toml")
		_current = M.new({ path = path, backup_path = path .. ".program-binding-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak",
			binding = binding, scalar = scalar, is_paused = is_paused })
		return _current.apply()
	end)
	_constructing = false
	if not ok or accepted ~= true then
		Logger.error(LOG, "Private user program binding publication did not commit.")
		return false
	end
	return true
end

--- Reports logical debt even when a refused release removed its physical lease.
--- @return boolean pending
function M.pending() return _constructing or (_current ~= nil and _current.pending()) end

--- Identifies the exact journal token allowed to reconcile its missing lease.
--- @param owner table Exact transaction token, never a caller-provided substitute.
--- @return boolean owned
function M.owns(owner) return owner ~= nil and _current == owner and _current.claimed() end

return M
