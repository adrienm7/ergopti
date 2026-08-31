--- infra/input_capture_gate.lua

--- ==============================================================================
--- MODULE: Input Capture Gate
--- DESCRIPTION:
--- Owns epoch-scoped inhibition of global input consumers while a trusted UI
--- surface is receiving text. Each daemon constructs and owns one gate.
--- ==============================================================================

local M = {}

local function valid_owner(owner)
	return type(owner) == "string" and owner ~= ""
end

local function valid_epoch(epoch)
	return type(epoch) == "number" and epoch >= 0 and epoch % 1 == 0
end

--- Creates an isolated capture gate.
--- @param options table|nil Optional { on_block = function } transition hook.
--- @return table gate
function M.new(options)
	options = type(options) == "table" and options or {}
	if options.on_block ~= nil and type(options.on_block) ~= "function" then
		error("input_capture_gate: on_block must be a function")
	end

	local active = {}
	local latest = {}
	local sequence = 0
	local gate = {}

	local function blocked()
		return next(active) ~= nil
	end

	--- Acquires one owner at a caller-supplied window epoch.
	--- @param owner string Stable application identity.
	--- @param epoch number|nil Window epoch; generated when omitted.
	--- @return boolean accepted
	--- @return number|nil effective_epoch
	function gate.acquire(owner, epoch)
		if not valid_owner(owner) then return false, nil end
		if epoch == nil then
			sequence = sequence + 1
			epoch = sequence
		elseif not valid_epoch(epoch) then
			return false, nil
		else
			sequence = math.max(sequence, epoch)
		end

		if latest[owner] ~= nil and epoch < latest[owner] then return false, nil end
		local was_blocked = blocked()
		latest[owner] = epoch
		active[owner] = epoch
		if not was_blocked and options.on_block then options.on_block() end
		return true, epoch
	end

	--- Releases an owner only when the event belongs to its active epoch.
	--- @param owner string Stable application identity.
	--- @param epoch number|nil Exact epoch, or nil for an owned lifecycle reset.
	--- @return boolean accepted
	function gate.release(owner, epoch)
		if not valid_owner(owner) or (epoch ~= nil and not valid_epoch(epoch)) then return false end
		local current = active[owner]
		if current == nil then
			return epoch == nil or latest[owner] == nil or epoch == latest[owner]
		end
		if epoch ~= nil and epoch ~= current then return false end
		active[owner] = nil
		return true
	end

	--- Returns whether at least one UI owns the global input path.
	--- @return boolean
	function gate.blocks_text()
		return blocked()
	end

	--- Wraps a callback so none of its side effects run while capture is owned.
	--- @param callback function
	--- @param on_blocked function|nil Optional bookkeeping that itself has no global side effect.
	--- @return function
	function gate.guard(callback, on_blocked)
		if type(callback) ~= "function" then error("input_capture_gate: callback must be a function") end
		if on_blocked ~= nil and type(on_blocked) ~= "function" then
			error("input_capture_gate: on_blocked must be a function")
		end
		return function(...)
			if blocked() then
				if on_blocked then on_blocked(...) end
				return nil, "input capture blocked"
			end
			return callback(...)
		end
	end

	--- Releases all owners during daemon shutdown.
	function gate.release_all()
		active = {}
	end

	return gate
end

return M
