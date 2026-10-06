--- _shared/lua/native_app_switcher_owner.lua

--- Retains one native switcher input session until exact input and timer retirement.
--- Post admission, tagged event observation, session release and visible effect
--- are distinct receipts. No window activation substitutes for native switching.
local M = {}

local REQUIRED = {
	"ready", "prepare", "post", "observed", "released", "cancel_input",
	"retire_input", "every", "cancel_timer", "now", "frontmost", "provider_current",
}

local function finite(value)
	return type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

local function pid(value)
	return finite(value) and value % 1 == 0 and value > 0 and value <= 2147483647
end

--- Constructs an owner with explicit policy, never an invented timing default.
--- @param ports table Native input, source, clock, timer and window ports.
--- @param policy table {deadline_sec=number, poll_sec=number}.
--- @return table|nil owner
function M.new(ports, policy)
	if type(ports) ~= "table" or getmetatable(ports) ~= nil
		or type(policy) ~= "table" or getmetatable(policy) ~= nil
		or not finite(policy.deadline_sec) or policy.deadline_sec <= 0
		or not finite(policy.poll_sec) or policy.poll_sec <= 0
		or policy.poll_sec > policy.deadline_sec then return nil end
	local calls = {}
	for _, name in ipairs(REQUIRED) do
		if type(rawget(ports, name)) ~= "function" then return nil end
		calls[name] = rawget(ports, name)
	end
	local deadline_sec, poll_sec = policy.deadline_sec, policy.poll_sec
	local active, checking = nil, false
	local states = setmetatable({}, { __mode = "k" })
	local owner = {}

	local function invoke(name, ...)
		return pcall(calls[name], ...)
	end
	local function literal(name, ...)
		local ok, value = invoke(name, ...)
		return ok and value == true
	end
	local function references()
		if getmetatable(ports) ~= nil then return false end
		for _, name in ipairs(REQUIRED) do
			if not rawequal(rawget(ports, name), calls[name]) then return false end
		end
		return true
	end
	local function owned(entry)
		return rawequal(active, entry) and entry.finished ~= true
	end
	local function source(entry)
		if not owned(entry) or entry.cancelled then return false end
		if getmetatable(entry.publication) ~= nil or not references()
			or not rawequal(rawget(entry.publication, "current"), entry.current)
			or not rawequal(rawget(entry.publication, "cached"), entry.cached) then return false end
		local ok, current = pcall(entry.current)
		if not ok or current ~= true or not owned(entry) or entry.cancelled then return false end
		if not literal("provider_current") or not owned(entry) or entry.cancelled then return false end
		-- The publication owner supplies this callback-free terminal seal. A native
		-- observation callback may revoke its source after the full current check.
		local sealed, cached = pcall(entry.cached)
		return sealed and cached == true and owned(entry) and not entry.cancelled
			and rawequal(rawget(entry.publication, "current"), entry.current)
			and rawequal(rawget(entry.publication, "cached"), entry.cached)
			and getmetatable(entry.publication) == nil and references()
	end
	local function finish(entry)
		if not owned(entry) or entry.acquiring or entry.retiring then return false end
		entry.retiring = true
		if entry.input_reserved and not entry.input_retired then
			entry.input_retired = literal("retire_input", entry.cap)
		end
		if entry.input_reserved and not entry.input_retired then
			entry.retiring = false
			return false
		end
		-- A throwing constructor has not provided a cleanup capability. Do not
		-- manufacture physical retirement from the absence of a returned handle.
		if entry.timer_unknown then entry.retiring = false; return false end
		if entry.timer and not entry.timer_retired then
			entry.timer_retired = literal("cancel_timer", entry.timer)
		end
		if entry.timer and not entry.timer_retired then entry.retiring = false; return false end
		if not owned(entry) then entry.retiring = false; return false end
		-- Cleanup crossed native callbacks after the visible-effect observation.
		-- Keep publication reserved while the full source/provider check runs;
		-- its final cached seal is pure, with no later native calls before publish.
		if entry.result == "switched" and not source(entry) and not entry.cancelled then
			entry.result = "refused"
		end
		if not owned(entry) then entry.retiring = false; return false end
		entry.retiring = false
		entry.finished = true
		states[entry.cap] = entry.result
		active = nil
		local complete = entry.complete
		entry.complete = nil
		if complete then pcall(complete, entry.cap, entry.result) end
		return true
	end
	local function cancel(entry, reason)
		if not owned(entry) then return false end
		if not entry.cancelled then entry.result = reason end
		entry.cancelled = true
		if entry.input_reserved and not entry.input_retired and not entry.cancel_requested then
			entry.cancel_requested = true
			literal("cancel_input", entry.cap)
		end
		return finish(entry)
	end

	--- Reports verified readiness without creating an input operation.
	--- @return boolean ready
	function owner.available()
		if active or checking or not references() then return false end
		checking = true
		local ready = literal("ready") and literal("provider_current")
		checking = false
		return ready and active == nil and references()
	end

	--- Advances a single acknowledged edge outside the event-tap callback.
	--- @return boolean settled
	function owner.tick()
		local entry = active
		if not entry or entry.acquiring or entry.busy then return false end
		if entry.cancelled or entry.result == "switched" then return finish(entry) end
		entry.busy = true
		local function leave(value) entry.busy = false; return value end
		local clock_ok, now = invoke("now")
		if not clock_ok or not finite(now) or now < entry.last_time then
			return leave(cancel(entry, "refused"))
		end
		entry.last_time = now
		if now >= entry.deadline then return leave(cancel(entry, "timeout")) end
		if not source(entry) then return leave(cancel(entry, "refused")) end
		if entry.waiting then
			if not entry.received then return leave(false) end
			if not literal("observed", entry.cap, entry.waiting) or not source(entry) then
				return leave(cancel(entry, "refused"))
			end
			entry.next_edge = entry.waiting + 1
			entry.waiting, entry.received = nil, nil
		end
		if entry.next_edge <= 4 then
			entry.waiting = entry.next_edge
			entry.received = false
			local posted = literal("post", entry.cap, entry.waiting)
			if not posted or not source(entry) then return leave(cancel(entry, "refused")) end
			return leave(false)
		end
		local released = literal("released", entry.cap)
		if not source(entry) then return leave(cancel(entry, "refused")) end
		if not released then return leave(false) end
		local observed, front = invoke("frontmost")
		if not source(entry) then return leave(cancel(entry, "refused")) end
		if observed and pid(front) and front ~= entry.before_pid then
			entry.result = "switched"
			return leave(finish(entry))
		end
		return leave(false)
	end

	--- Reserves before all acquisition callbacks and retains refused candidates.
	--- @param publication table {current=function, cached=function}.
	--- @param complete function|nil fn(capability, closed_status).
	--- @return table|nil capability
	--- @return boolean admitted
	function owner.request(publication, complete)
		if active or checking or type(publication) ~= "table"
			or getmetatable(publication) ~= nil
			or type(rawget(publication, "current")) ~= "function"
			or type(rawget(publication, "cached")) ~= "function"
			or (complete ~= nil and type(complete) ~= "function") then return nil, false end
		local entry = {
			cap = {}, publication = publication, current = rawget(publication, "current"),
			cached = rawget(publication, "cached"), complete = complete,
			acquiring = true, next_edge = 1, result = "refused",
		}
		active = entry
		local clock_ok, now = invoke("now")
		local front_ok, front = invoke("frontmost")
		if not clock_ok or not finite(now) or not front_ok or not pid(front)
			or not literal("ready") or not source(entry) then
			entry.acquiring = false
			cancel(entry, "refused")
			return entry.cap, false
		end
		entry.before_pid, entry.last_time, entry.deadline = front, now, now + deadline_sec
		if not finite(entry.deadline) then
			entry.acquiring = false; cancel(entry, "refused"); return entry.cap, false
		end
		-- G5 reserves this exact attempt before acquisition. Even a thrown prepare
		-- leaves its input/tap/task debt addressable by cancel/retire(attempt).
		entry.input_reserved = true
		local prepared = literal("prepare", entry.cap, function(cap, ordinal)
			if not owned(entry) or not rawequal(cap, entry.cap) or entry.cancelled
				or ordinal ~= entry.waiting or entry.waiting == nil then return false end
			entry.received = true
			return true
		end, function() return source(entry) end)
		if not prepared or not source(entry) then
			entry.acquiring = false; cancel(entry, "refused"); return entry.cap, false
		end
		local timer_ok, timer, committed = invoke("every", poll_sec, owner.tick)
		if timer_ok and (type(timer) == "table" or type(timer) == "userdata") then
			entry.timer = timer
		elseif not timer_ok or (timer ~= nil and timer ~= false) or committed == true then
			entry.timer_unknown = true
		end
		entry.acquiring = false
		if not timer_ok or entry.timer == nil or committed ~= true
			or not source(entry) then
			cancel(entry, "refused")
			return entry.cap, false
		end
		return entry.cap, true
	end

	--- Revokes normal emission and retries only the exact retained capability.
	--- @param cap table Operation capability.
	--- @return boolean physically_settled
	function owner.cancel(cap)
		return active ~= nil and rawequal(active.cap, cap) and cancel(active, "cancelled")
	end

	--- Revokes the privately held operation during acquisition or shutdown.
	--- @return boolean physically_settled
	function owner.stop()
		if not active then return true end
		return cancel(active, "cancelled")
	end

	--- Retries retained compensation without admitting any successor output.
	--- @param cap table Operation capability.
	--- @return boolean physically_settled
	function owner.retry(cap)
		if not active or not rawequal(active.cap, cap) then return false end
		if not active.cancelled and active.result ~= "switched" then return false end
		return finish(active)
	end

	--- @return boolean pending Exact input/timer custody remains.
	function owner.has_pending() return active ~= nil end

	--- @param cap table Operation capability.
	--- @return string|nil status Published only after physical retirement.
	function owner.status(cap) return states[cap] end

	return owner
end

return M
