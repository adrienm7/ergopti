--- _shared/lua/keylogger/physical_context_observation.lua

--- Owns bounded writer receipts, without retained permission history or capture.
local M = {}

local function integral(value)
	return type(value) == "number" and value == value and value >= 0
		and value < math.huge and value == math.floor(value)
end

--- Creates a dormant denied-boundary/completion channel for one exact owner.
---@param capacity integer Maximum acknowledged receipts; no authority is evicted.
---@param clock function Exact native nanoseconds, never a wall or rebased clock.
---@param receive function Copied receipt consumer, acknowledging literal true.
---@param on_refused function Once-only notification after publication is revoked.
---@param correlated boolean|nil Literal true requests native window/app identity evidence.
---@return table channel Exact transaction begin, mark, finish and close ports.
function M.new(capacity, clock, receive, on_refused, correlated)
	assert(integral(capacity) and capacity > 0, "Invalid physical context receipt budget")
	assert(type(clock) == "function" and type(receive) == "function" and type(on_refused) == "function",
		"Missing physical context observation ports")
	assert(correlated == nil or correlated == true, "Invalid physical correlation mode")
	local app_pid, window_pid
	local active, dispatching, pending, previous, revision = true, false, nil, nil, 0
	local known = { app = false, window = false, secure = false }
	local channel = {}

	--- Revokes authority before invoking any foreign refusal observer.
	function channel.refuse(reason)
		if active then active = false; pcall(on_refused, reason) end
		return false, reason
	end

	--- Closes only this channel; caller identity remains with its native owner.
	function channel.close() active = false; return true end

	local function publish(source, stage, decision)
		if not active then return false, "Physical context subscription is retired" end
		if dispatching then return channel.refuse("Physical context publication reentered") end
		if revision >= capacity then return channel.refuse("Physical context receipt budget exhausted") end
		dispatching = true
		local ok, observed = pcall(clock)
		if not ok or not integral(observed)
			or (previous and observed <= previous) then
			dispatching = false; return channel.refuse("Invalid or unordered native context clock")
		end
		if not active then dispatching = false; return false, "Physical context subscription was revoked" end
		local record = { kind = "physical_context", revision = revision + 1, at = observed,
			source = source, stage = stage, complete = false, allowed = false }
		if correlated then record.fields_complete, record.correlated = false, false end
		if decision then
			record.complete, record.allowed = decision.complete, decision.allowed
			if correlated then record.fields_complete, record.correlated = true, decision.correlated end
			record.app = { name = decision.app.name, bundle_id = decision.app.bundle_id,
				path = decision.app.path, pid = decision.app.pid }
			record.private, record.secure = decision.private, decision.secure
		end
		local delivered, accepted = pcall(receive, record)
		dispatching = false
		if not active then return false, "Physical context subscription was revoked" end
		if not delivered or accepted ~= true then return channel.refuse("Physical context subscriber refused receipt") end
		previous, revision = observed, revision + 1
		return true
	end

	--- Seeds denied authority without promoting any cached native state.
	function channel.seed() return publish("binding", "boundary") end

	--- Denies before a writer enters its native multi-field transaction.
	function channel.begin(source)
		if not active then return nil end
		if pending or dispatching then channel.refuse("Physical context writer reentered"); return nil end
		local ticket = { source = source }; pending = ticket
		-- Native window identity belongs to this writer, never to a prior completion.
		window_pid = nil
		if source == "activation" or source == "resync" or source == "capture" or source == "closure" then
			known = { app = false, window = false, secure = false }; app_pid = nil
		elseif source == "private" then known.window = false
		else known.secure = false end
		if publish(source, "boundary") ~= true then return nil end
		return ticket
	end

	--- Checks whether an exact writer may cross another native identity boundary.
	function channel.owns(ticket)
		return active and not dispatching and ticket ~= nil and rawequal(pending, ticket)
	end

	--- Retains the app PID actually supplied by a conclusive native app writer.
	function channel.mark_app_pid(ticket, pid)
		if correlated and channel.owns(ticket) then
			app_pid = integral(pid) and pid > 0 and pid or nil
		end
	end

	--- Records a native identity only for the current correlated writer generation.
	function channel.mark_window_pid(ticket, pid)
		if correlated and channel.owns(ticket) then
			window_pid = integral(pid) and pid > 0 and pid or nil
		end
	end

	--- Records only evidence supplied by the exact current native transaction.
	function channel.mark(ticket, component, complete)
		if active and rawequal(pending, ticket) and ticket ~= nil then known[component] = complete == true end
	end

	--- Completes only after this exact writer and its expected children unwind.
	function channel.finish(ticket, state, paused, may_persist)
		if not active or ticket == nil or not rawequal(pending, ticket) then return false end
		local decision
		if known.app and known.window and known.secure and paused == false
			and type(state.active_app_name) == "string" and state.active_app_name ~= ""
			and type(state.active_app_bundle) == "string" and state.active_app_bundle ~= ""
			and type(state.active_app_path) == "string" and state.active_app_path ~= ""
			and integral(state.active_app_pid) and state.active_app_pid > 0
			and type(state.is_private_window) == "boolean" and type(state.is_secure_field) == "boolean" then
			decision = { app = { name = state.active_app_name, bundle_id = state.active_app_bundle,
				path = state.active_app_path, pid = state.active_app_pid },
				private = state.is_private_window, secure = state.is_secure_field }
			decision.correlated = window_pid ~= nil and app_pid ~= nil
				and rawequal(window_pid, app_pid) and rawequal(app_pid, state.active_app_pid)
			decision.complete = not correlated or decision.correlated
			decision.allowed = false
			if decision.complete then
				local ok, allowed = pcall(may_persist)
				if not ok or type(allowed) ~= "boolean" then return channel.refuse("Physical persistence predicate failed") end
				if not active or not rawequal(pending, ticket) then return false end
				decision.allowed = allowed
			end
		end
		local accepted = publish(ticket.source, decision and decision.complete and "complete" or "incomplete", decision)
		if rawequal(pending, ticket) then pending = nil end
		return accepted
	end
	return channel
end

return M
