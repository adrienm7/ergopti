--- adapters/physical_shortcut_hook.lua

--- ==============================================================================
--- MODULE: Physical Shortcut Input Owner
--- DESCRIPTION:
--- Intercepts configured native keyboard positions through a provenance-aware
--- event tap. Unlike named hotkeys, the callback can reject Ergopti output and
--- unreadable input before any suppression. Positions needing board-form proof
--- remain unavailable; this adapter never registers both swapped positions.
--- ==============================================================================

local M = {}

local hs = hs
local Provenance = require("adapters.event_provenance")
local Timer = require("adapters.timer_scheduler")
local Broker = require("adapters.input_source_broker")
local Logger = require("infra.logger")

local LOG = "adapters.physical_shortcut_hook"
local CONSUMER = "shortcuts.physical"

--- Creates one keyboard-owned native input lifecycle.
--- @param model table Shared physical-slot policy over canonical registry data.
--- @return table owner Retryable native tap and deferred delivery owner.
function M.new(model)
	assert(type(model) == "table" and type(model.stable_native_code) == "function",
		"physical shortcut hook requires its shared physical-slot owner")
	local owner = {}
	local tap, spec, generation, installing = nil, nil, 0, false
	local subscribed, committed = false, false
	local pending, native_entries = {}, {}

	--- Probes only the retained exact tap.
	--- @return boolean|nil enabled Exact native state, or unavailable proof.
	local function enabled()
		if not tap or type(tap.isEnabled) ~= "function" then return nil end
		local called, value = pcall(tap.isEnabled, tap)
		if called and type(value) == "boolean" then return value end
		return nil
	end

	--- Fences queued callbacks before asking their actual timer owner to retire.
	--- @return boolean settled True only after every retained handle retires.
	local function cancel_pending()
		local records, settled = {}, true
		for record in pairs(pending) do records[#records + 1] = record end
		for _, record in ipairs(records) do
			record.fenced = true
			if record.installing then settled = false
			elseif record.timer ~= nil then
				local called, cancelled = pcall(Timer.cancel, record.timer)
				if called and cancelled == true then pending[record] = nil
				else settled = false end
			else pending[record] = nil end
		end
		return settled
	end

	--- Performs only private checks; callback reentry cannot revive an old receipt.
	local function live(current, epoch, record)
		return committed and not installing and spec == current and generation == epoch
			and (record == nil or record.fenced ~= true)
	end

	--- Checks private currency on both sides of the owner admission callback.
	local function admitted(current, epoch, record, receipt)
		if not live(current, epoch, record) then return false end
		local called, value, captured = pcall(current.admitted, receipt)
		if not called or value ~= true or not live(current, epoch, record) then return false end
		return true, captured
	end

	--- Schedules one action with the same source/runtime admission receipt.
	local function queue(slot, action, current, epoch, receipt)
		if admitted(current, epoch, nil, receipt) ~= true then return false end
		local record = { generation = epoch, admission = receipt, installing = true, fenced = false }
		pending[record] = true
		local called, timer, armed = pcall(Timer.after, 0, function()
			if record.installing then record.early = true; return end
			if admitted(current, epoch, record, receipt) ~= true then return end
			local action_called, current_action = pcall(current.action, slot)
			if not action_called or current_action ~= action or not live(current, epoch, record) then return end
			local native = model.stable_native_code(slot, "hs")
			local descriptor = model.parse(slot)
			if not native or not descriptor or not live(current, epoch, record) then return end
			local conflict_called, conflict = pcall(current.conflicts, slot, descriptor.mods, native)
			if not conflict_called or conflict ~= false or not live(current, epoch, record) then return end
			if admitted(current, epoch, record, receipt) ~= true or not live(current, epoch, record) then return end
			local delivered, result = pcall(current.execute, slot, action, receipt)
			if not delivered or result ~= true then
				Logger.error(LOG, "Physical shortcut '%s' did not acknowledge action '%s'.", slot, action)
			end
		end)
		record.timer, record.installing = called and timer or nil, false
		if not called or timer == nil or timer == false then pending[record] = nil; return false end
		local observed, accepted = pcall(Timer.onSettled, timer, function() pending[record] = nil end)
		if not observed or accepted ~= true or armed ~= true or record.early
			or admitted(current, epoch, record, receipt) ~= true or not live(current, epoch, record) then
			record.fenced = true
			local cancelled, result = pcall(Timer.cancel, timer)
			if cancelled and result == true then pending[record] = nil end
			return false
		end
		return true
	end

	--- Decides native keyDown with one receipt retained across every callback.
	local function handle(event)
		local current, epoch = spec, generation
		local called, provenance, status, fence = pcall(Provenance.classify_with_fence, event, CONSUMER)
		local fence_events = called and fence and fence.events or nil
		if called and fence and fence.consume_original == true then return true, fence_events end
		if not called or provenance ~= nil or status ~= Provenance.STATUS_FOREIGN or current == nil then return false, fence_events end
		local allowed, receipt = admitted(current, epoch)
		if not allowed then return false, fence_events end
		local readable, code, flags = pcall(function() return event:getKeyCode(), event:getFlags() end)
		if not readable or not live(current, epoch) or type(code) ~= "number" or code % 1 ~= 0
			or type(flags) ~= "table" or flags.fn then return false, fence_events end
		for _, name in ipairs({ "ctrl", "alt", "shift", "cmd" }) do
			if flags[name] ~= nil and type(flags[name]) ~= "boolean" then return false, fence_events end
		end
		local mods = { ctrl = flags.ctrl == true, alt = flags.alt == true, shift = flags.shift == true, super = flags.cmd == true }
		for slot, native in pairs(native_entries) do
			if native == code then
				local descriptor = model.parse(slot)
				if model.encode(descriptor.code, mods) == slot then
					local action_called, action = pcall(current.action, slot)
					if not action_called or action == nil or action == "none" or not live(current, epoch) then return false, fence_events end
					local conflict_called, conflict = pcall(current.conflicts, slot, mods, native)
					if not conflict_called or conflict ~= false or not live(current, epoch) then return false, fence_events end
					return queue(slot, action, current, epoch, receipt), fence_events
				end
			end
		end
		return false, fence_events
	end

	--- Retires the exact tap, broker subscription and queued timer handles.
	--- @return boolean settled
	function owner.stop()
		generation, committed, spec = generation + 1, false, nil
		native_entries = {}
		local settled = cancel_pending()
		if tap then
			local current = tap
			local called, stopped = pcall(current.stop, current)
			if called and stopped == current and enabled() == false and not installing then tap = nil
			else settled = false end
		end
		if subscribed then
			local called, removed = pcall(Broker.unsubscribe, CONSUMER)
			if called and removed == true and not installing then subscribed = false
			else settled = false end
		end
		return settled and tap == nil and not subscribed and next(pending) == nil and not installing
	end

	--- Acquires one coherent native input set; empty defaults acquire nothing.
	--- @param options table { assignments, admitted, action, conflicts, execute }.
	--- @return boolean started
	--- @return string|nil reason Closed capability refusal.
	function owner.start(options)
		if installing or committed or tap ~= nil or subscribed or next(pending) ~= nil then return false, "ownership_pending" end
		if type(options) ~= "table" or type(options.assignments) ~= "table" then return false, "invalid_assignments" end
		for _, name in ipairs({ "admitted", "action", "conflicts", "execute" }) do
			if type(options[name]) ~= "function" then return false, "invalid_collaborators" end
		end
		local entries = {}
		for slot, action in pairs(options.assignments) do
			if not model.owns(slot) or type(action) ~= "string" or action == "" then return false, "invalid_assignments" end
			if model.key_group(slot) == "media" then return false, "native_key_unavailable" end
			local native, reason = model.stable_native_code(slot, "hs")
			if not native then return false, reason end
			if action ~= "none" then entries[slot] = native end
		end
		if next(entries) == nil then return true end
		generation, installing, spec, native_entries = generation + 1, true, options, entries
		local epoch = generation
		local constructed, candidate = pcall(hs.eventtap.new, { hs.eventtap.event.types.keyDown }, handle)
		if not constructed or candidate == nil or candidate == false then
			installing, spec, native_entries = false, nil, {}
			return false, "tap_construction_failed"
		end
		tap = candidate
		local started, result = pcall(candidate.start, candidate)
		if not started or result ~= candidate or enabled() ~= true or generation ~= epoch then
			installing = false
			owner.stop()
			return false, "tap_start_failed"
		end
		-- Subscribe ownership precedes the setter; a thrown native installation
		-- can require an exact broker unsubscribe even after callback rollback.
		subscribed = true
		local registered, acknowledged = pcall(Broker.subscribe, CONSUMER, function()
			generation = generation + 1
			cancel_pending()
		end)
		if not registered or acknowledged ~= true or generation ~= epoch then
			installing = false
			owner.stop()
			return false, "source_subscription_failed"
		end
		installing, committed = false, true
		return true
	end

	--- Reports actual native input ownership rather than desired settings.
	--- @return boolean started
	function owner.is_started() return committed and enabled() == true end

	--- Reports retained native ownership independently from callback fencing.
	--- @return boolean pending
	function owner.has_debt() return tap ~= nil or subscribed or next(pending) ~= nil or installing end

	return owner
end

return M
