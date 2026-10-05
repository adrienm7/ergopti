--- _shared/lua/keylogger/physical_subscription_lifetime.lua

--- Owns exact callback retirement, independently of global native task lifetimes.
local M = {}
local unpack_values = table.unpack or unpack
local function pack(...) return { n = select("#", ...), ... } end

--- Creates one private subscription lifetime with detached read-only identity ports.
---@param owner table Exact source subscriber identity.
---@param token table Exact source binding token.
---@return table lifetime Private run, revoke, detach and capability ports.
function M.new(owner, token)
	assert(type(owner) == "table" and type(token) == "table", "Missing subscription identities")
	local active, detached, frames = true, false, 0
	local detach_operation, detaching
	local pending = {}
	local lifetime, capability = {}, {}
	local function exact(candidate_owner, candidate_token)
		return rawequal(candidate_owner, owner) and rawequal(candidate_token, token)
	end


	--- Returns this original source identity, including after failed acquisition.
	--- Identity grants neither current authority nor replacement ownership.
	---@param candidate_owner table Exact original subscriber.
	---@return table|nil token Original source-minted token, or nil for a foreign owner.
	function capability.identity(candidate_owner)
		if rawequal(candidate_owner, owner) then return token end
		return nil
	end

	--- Reads exact callback authority without invoking a foreign equality hook.
	---@param candidate_owner table Exact original subscriber.
	---@param candidate_token table Exact original binding token.
	---@return boolean current Whether this subscription still admits callbacks.
	function capability.current(candidate_owner, candidate_token)
		return exact(candidate_owner, candidate_token) and active and not detached
	end

	--- Reports only subscription detach and completed in-flight source callbacks.
	--- This never establishes global watcher, native task or host clock retirement.
	---@param candidate_owner table Exact original subscriber.
	---@param candidate_token table Exact original binding token.
	---@return boolean retired Whether no callback under this token can remain in flight.
	function capability.retired(candidate_owner, candidate_token)
		return exact(candidate_owner, candidate_token) and detached and frames == 0
	end


	--- Requests actual exact-owner detach without accepting a caller completion flag.
	--- Completed old detach is retained independently of any successor subscription.
	---@param candidate_owner table Exact original subscriber.
	---@param candidate_token table Exact original binding token.
	---@return boolean detached Whether the actual source acknowledged exact detach.
	function capability.detach(candidate_owner, candidate_token)
		if not exact(candidate_owner, candidate_token) then return false end
		if detached then return true end
		if detaching or detach_operation == nil then return false end
		active, detaching = false, true
		local ok, accepted = pcall(lifetime.run, detach_operation, owner, token)
		detaching = false
		return ok and accepted == true and detached
	end

	--- Binds the source's actual retirement operation once, before capability delivery.
	---@param operation function Exact source detach, whose implementation marks detach.
	function lifetime.bind_detach(operation)
		assert(type(operation) == "function" and detach_operation == nil, "Invalid subscription detach owner")
		detach_operation = operation
	end

	--- Returns one stable read-only capability without exposing writable accounting.
	---@return table capability Exact current and retirement observations.
	function lifetime.capability() return capability end

	--- Revokes permission before foreign terminal refusal notification.
	function lifetime.revoke() active = false end

	--- Commits exact source detach while retaining all actual unfinished frames.
	function lifetime.detach() active, detached = false, true end


	--- Retains an exact source frame before any asynchronous foreign operation.
	---@return table|nil frame Opaque actual frame, or nil after subscription detach.
	function lifetime.enter()
		if detached then return nil end
		local frame = {}
		pending[frame], frames = true, frames + 1
		return frame
	end

	--- Completes only the exact retained source frame after its terminal unwinds.
	---@param frame table Exact opaque frame returned by enter.
	---@return boolean completed Whether this frame's retained obligation completed once.
	function lifetime.leave(frame)
		if pending[frame] ~= true then return false end
		pending[frame], frames = nil, frames - 1
		return true
	end

	--- Tracks the exact synchronous source frame and preserves its complete outcome.
	--- Calls begun after detach belong to the legacy source, not this subscription.
	---@param operation function Actual source writer or receipt publication.
	---@param ... any Original arguments, including nil positions.
	---@return any results Original result tuple or original raised error.
	function lifetime.run(operation, ...)
		local frame = lifetime.enter()
		if frame == nil then return operation(...) end
		local results = pack(pcall(operation, ...))
		assert(lifetime.leave(frame), "Subscription source frame was already released")
		if not results[1] then error(results[2], 0) end
		return unpack_values(results, 2, results.n)
	end
	return lifetime
end

return M
