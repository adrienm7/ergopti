--- adapters/system_switcher_input.lua

--- Owns explicit Command/Tab edges, native observations and release compensation.
--- A queued edge is admission only; the broker advances after tagged tap receipt.
local M = {}
local Scheduler = require("adapters.timer_scheduler")
local Sampler = require("adapters.system_switcher_sampler")

--- Binds one admitted native helper and the central synthetic provenance owner.
--- @param config table Pinned helper descriptor and current/cached callbacks.
--- @param provenance table acquire, tag and release functions.
--- @param policy table Explicit poll_sec.
--- @return table|nil input Exact native port owner.
function M.new(config, provenance, policy)
	if type(provenance) ~= "table" or getmetatable(provenance) ~= nil
		or type(policy) ~= "table" or type(policy.poll_sec) ~= "number"
		or policy.poll_sec <= 0 or policy.poll_sec >= math.huge then return nil end
	local acquire, tag, release = provenance.acquire, provenance.tag, provenance.release
	if type(acquire) ~= "function" or type(tag) ~= "function"
		or type(release) ~= "function" then return nil end
	local sampler = Sampler.new(config)
	if not sampler then return nil end
	local native = hs
	local types, props = native.eventtap.event.types, native.eventtap.event.properties
	local create_event = native.eventtap.event.newKeyEvent
	if type(create_event) ~= "function" then return nil end
	local pid = tonumber(native.processInfo.processID)
	if not pid or pid <= 0 then return nil end
	local commands = {
		{ key = 55, down = true, kind = types.flagsChanged, cmd = true },
		{ key = 48, down = true, kind = types.keyDown, cmd = true },
		{ key = 48, down = false, kind = types.keyUp, cmd = true },
		{ key = 55, down = false, kind = types.flagsChanged, cmd = false },
	}
	local active, checking = nil, false
	local retired = setmetatable({}, { __mode = "k" })
	local owner = {}
	local function literal(fn, ...)
		local ok, receipt = pcall(fn, ...)
		return ok and receipt == true
	end
	local function owned(entry) return rawequal(entry, active) and not entry.retired end
	local function revoke(entry) entry.cancelled = true; entry.queued = nil end
	local function source(entry)
		if not owned(entry) or entry.cancelled then return false end
		return literal(entry.admission) and owned(entry) and not entry.cancelled
			and sampler.current() and owned(entry) and not entry.cancelled
			and (not entry.tap or literal(entry.tap.isEnabled, entry.tap))
			and rawequal(native.eventtap.event.newKeyEvent, create_event)
	end
	local function settle_observation(entry)
		local waiting = entry.waiting
		if not waiting or not waiting.seen or waiting.admitted ~= true then return false end
		local command = waiting.command
		if not command.down then
			if command.key == 48 then entry.tab_debt = false else entry.cmd_debt = false end
		end
		entry.waiting = nil
		if waiting.ordinal then
			entry.observations[waiting.ordinal] = true
			-- Delivery outside the event tap keeps its callback free of native work.
			if not entry.cancelled and not literal(entry.observed, entry.cap, waiting.ordinal) then
				revoke(entry)
			end
		end
		return true
	end
	local function flags_match(event, command)
		local flags = event:getFlags()
		return (flags.cmd == true) == command.cmd and not flags.shift
			and not flags.alt and not flags.ctrl and not flags.fn
	end
	local function observe(entry, event)
		if not owned(entry) then return false end
		-- Every delivered key edge invalidates samples acquired before that edge.
		-- A foreign event revokes ordinary output even when no edge is pending.
		entry.event_epoch = entry.event_epoch + 1
		local waiting = entry.waiting
		local ok, value = pcall(event.getProperty, event, props.eventSourceUserData)
		if not waiting or not ok or value ~= waiting.tag then revoke(entry); return false end
		local command = waiting.command
		local valid, matches = pcall(function()
			return event:getProperty(props.eventSourceUnixProcessID) == pid
				and event:getProperty(props.eventSourceStateID) == waiting.source_id
				and event:getKeyCode() == command.key and event:getType() == command.kind
				and flags_match(event, command)
		end)
		if not valid or not matches or waiting.seen then revoke(entry)
		else waiting.seen = true end
		return false
	end
	local function post(entry, command, ordinal, sample_epoch)
		if entry.event_epoch ~= sample_epoch then return false end
		if ordinal and not source(entry) then revoke(entry); return false end
		local ok, event = pcall(create_event, command.key, command.down)
		if not ok or event == nil or event == false then revoke(entry); return false end
		local tagged, identity, source_id = pcall(function()
			-- The trusted native factory owns creation. Its event field is an
			-- exact identity; the SDK's private selector -1 is not that identity.
			local state = event:getProperty(props.eventSourceStateID)
			if type(state) ~= "number" or state ~= state or state % 1 ~= 0
				or state < -2147483648 or state > 4294967295 then return nil end
			local value = tag(entry.lease, command.key, command.down)
			if type(value) ~= "number" then return nil end
			event:setProperty(props.eventSourceUserData, value)
			if event:getProperty(props.eventSourceUserData) ~= value
				or event:getProperty(props.eventSourceUnixProcessID) ~= pid
				or event:getProperty(props.eventSourceStateID) ~= state
				or event:getType() ~= command.kind or event:getKeyCode() ~= command.key
				or not flags_match(event, command) then return nil end
			return value, state
		end)
		if not tagged or identity == nil or not owned(entry) then revoke(entry); return false end
		if entry.event_epoch ~= sample_epoch then return false end
		if ordinal and not source(entry) then revoke(entry); return false end
		if not literal(entry.tap.isEnabled, entry.tap) or entry.event_epoch ~= sample_epoch then return false end
		-- Set debt before post: a throw or refused return can follow native handoff.
		if command.down then
			if command.key == 55 then entry.cmd_debt = true else entry.tab_debt = true end
			entry.session_debt = true
		end
		local waiting = { command = command, tag = identity, ordinal = ordinal, source_id = source_id }
		entry.waiting = waiting
		local posted, receipt = pcall(event.post, event)
		waiting.admitted = posted and rawequal(receipt, event)
		if not waiting.admitted then revoke(entry) end
		return waiting.admitted
	end
	local function session_matches(entry, frame, exact)
		local expected = {}
		if entry.cmd_debt then expected[55] = true end
		if entry.tab_debt then expected[48] = true end
		for key in pairs(frame.session_held) do if not expected[key] then return false end end
		if exact then
			for key in pairs(expected) do if not frame.session_held[key] then return false end end
		end
		local flags = entry.cmd_debt and 0x100000 or 0
		return frame.session_flags == flags or (not exact and frame.session_flags == 0)
	end
	local function tick(entry)
		if not owned(entry) or entry.acquiring or entry.busy then return end
		entry.busy = true
		local ok = pcall(function()
			if not entry.cancelled and not source(entry) then revoke(entry) end
			if not entry.tap or not literal(entry.tap.isEnabled, entry.tap) then revoke(entry); return end
			if entry.waiting then
				if settle_observation(entry) then return end
				if not entry.cancelled then return end
				-- Ambiguous down handoffs retain debt even with no observed callback.
				entry.waiting = nil
			end
			local sampled, frame = sampler.take(entry.cap)
			if sampled == false then revoke(entry) end
			if frame and entry.sample_epoch ~= entry.event_epoch then frame = nil end
			if not frame then
				local epoch = entry.event_epoch
				if sampler.request(entry.cap) then entry.sample_epoch = epoch end
				return
			end
			if not frame.hid_clear then revoke(entry); return end
			if not entry.cmd_debt and not entry.tab_debt and frame.session_clear then
				entry.session_debt = false
			end
			if entry.cancelled then
				if not session_matches(entry, frame, false) then return end
				if entry.tab_debt then
					post(entry, { key = 48, down = false, kind = types.keyUp, cmd = entry.cmd_debt }, nil, entry.sample_epoch)
				elseif entry.cmd_debt then post(entry, commands[4], nil, entry.sample_epoch) end
				return
			end
			local ordinal = entry.queued
			if ordinal then
				if not session_matches(entry, frame, true) then revoke(entry); return end
				entry.queued = nil
				post(entry, commands[ordinal], ordinal, entry.sample_epoch)
			end
		end)
		if not ok then revoke(entry) end
		entry.busy = false
	end

	--- Reports native prerequisites without assuming TCC grant or posting input.
	function owner.ready()
		if active or checking then return false end
		checking = true
		local ok = literal(native.accessibilityState, false) and sampler.current()
			and rawequal(native.eventtap.event.newKeyEvent, create_event)
		checking = false
		return ok and active == nil
	end

	--- Reserves exact acquisition before constructors; refusal retains cleanup debt.
	function owner.prepare(cap, observed, admission)
		if active or checking or type(cap) ~= "table" or type(observed) ~= "function"
			or type(admission) ~= "function" then return false end
		local entry = { cap = cap, observed = observed, admission = admission,
			acquiring = true, observations = {}, next_edge = 1, event_epoch = 0 }
		active = entry
		local ok = pcall(function()
			entry.lease_unknown = true
			entry.lease = acquire(cap, admission)
			entry.lease_unknown = false
			if entry.lease == nil or entry.lease == false or not source(entry) then return end
			entry.tap = native.eventtap.new({ types.flagsChanged, types.keyDown, types.keyUp },
				function(event) return observe(entry, event) end)
			if not entry.tap then return end
			local receipt = entry.tap:start()
			if not rawequal(receipt, entry.tap) or entry.tap:isEnabled() ~= true
				or not source(entry) then return end
			entry.timer_unknown = true
			local timer, committed = Scheduler.every(policy.poll_sec, function() tick(entry) end)
			entry.timer = timer
			entry.timer_unknown = false
			entry.committed = timer ~= nil and committed == true and source(entry)
		end)
		entry.acquiring = false
		if not ok or not entry.committed then revoke(entry); return false end
		return true
	end

	--- Accepts an exact ordinal; receipt does not acknowledge native delivery.
	function owner.post(cap, ordinal)
		local entry = active
		if not entry or not rawequal(entry.cap, cap) or not source(entry)
			or ordinal ~= entry.next_edge or not commands[ordinal]
			or entry.queued or entry.waiting then return false end
		entry.next_edge, entry.queued = ordinal + 1, ordinal
		return true
	end

	--- Validates the exact acknowledged edge, independently from post admission.
	function owner.observed(cap, ordinal)
		return active ~= nil and rawequal(active.cap, cap) and not active.cancelled
			and active.observations[ordinal] == true and source(active)
	end

	--- Session release requires a new combined-session sample after the final up.
	function owner.released(cap)
		local entry = active
		return entry ~= nil and rawequal(entry.cap, cap) and source(entry)
			and entry.observations[4] == true and not entry.cmd_debt
			and not entry.tab_debt and not entry.session_debt and not entry.waiting
	end

	--- Revokes ordinary output while the timer continues exact compensation.
	function owner.cancel(cap)
		if not active or not rawequal(active.cap, cap) then return retired[cap] == true end
		revoke(active)
		active.queued = nil
		return true
	end

	--- Acknowledges retirement only after input, task, tap and timer debts settle.
	function owner.retire(cap)
		local entry = active
		if not entry or not rawequal(entry.cap, cap) then return retired[cap] == true end
		if entry.acquiring or entry.busy or entry.retiring then return false end
		entry.retiring = true
		local settled = false
		local ok = pcall(function()
			if entry.timer_unknown or entry.lease_unknown or entry.cmd_debt or entry.tab_debt or entry.session_debt or entry.waiting
				or entry.queued then return end
			if not sampler.retire(cap) then return end
			if entry.tap then
				local receipt = entry.tap:stop()
				if not rawequal(receipt, entry.tap) or entry.tap:isEnabled() ~= false then return end
				entry.tap = nil
			end
			if entry.timer and Scheduler.cancel(entry.timer) ~= true then return end
			entry.timer = nil
			if entry.lease and not literal(release, entry.lease) then return end
			entry.lease = nil
			settled = true
		end)
		entry.retiring = false
		if not ok or not settled then return false end
		entry.retired, retired[cap], active = true, true, nil
		return true
	end

	return owner
end

return M
