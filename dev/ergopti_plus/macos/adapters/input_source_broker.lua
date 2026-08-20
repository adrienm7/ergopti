--- adapters/input_source_broker.lua

--- ==============================================================================
--- MODULE: Input Source Broker Adapter
--- DESCRIPTION:
--- Owns Hammerspoon's single process-wide input-source callback and multiplexes
--- it to named Ergopti subscribers without letting one subsystem replace
--- another.
---
--- FEATURES & RATIONALE:
--- 1. Single native owner: `inputSourceChanged` is setter-only and every call
---    removes its predecessor, so only this adapter may invoke it.
--- 2. Mutation-safe dispatch: callbacks run from a snapshot under independent
---    traceback boundaries.
--- 3. Retryable release: a failed native unset keeps an inert broker handle so
---    a later unsubscribe can retry without resurrecting removed subscribers.
--- ==============================================================================

local M = {}

local hs = hs
local Logger = require("infra.logger")

local LOG = "adapters.input_source_broker"

local _subscribers = {}
local _dispatcher_installed = false
local _native_state_uncertain = false

--- Counts active subscribers without exposing the mutable registry.
--- @return number count Active subscriber count.
local function subscriber_count()
	local count = 0
	for _ in pairs(_subscribers) do count = count + 1 end
	return count
end

--- Fans one native notification out to a stable subscriber snapshot.
local function dispatch()
	local snapshot = {}
	for id, callback in pairs(_subscribers) do
		snapshot[#snapshot + 1] = { id = id, callback = callback }
	end
	table.sort(snapshot, function(left, right) return left.id < right.id end)
	for _, subscriber in ipairs(snapshot) do
		local ok, err = xpcall(subscriber.callback, debug.traceback)
		if not ok then
			pcall(Logger.error, LOG, "Input-source subscriber '%s' failed: %s",
				subscriber.id, tostring(err))
		end
	end
end

--- Installs the one native dispatcher when needed.
--- @return boolean installed True when the native slot is owned.
local function ensure_dispatcher()
	if _dispatcher_installed and not _native_state_uncertain then return true end
	if not hs.keycodes or type(hs.keycodes.inputSourceChanged) ~= "function" then
		Logger.error(LOG, "Input-source callback API is unavailable.")
		return false
	end
	local ok, err = pcall(hs.keycodes.inputSourceChanged, dispatch)
	if not ok then
		-- A setter may replace the process-wide callback and only then throw. We
		-- cannot prove that no native capability was published, so retain an exact
		-- cleanup obligation; unsubscribe() will conservatively unset the slot.
		_dispatcher_installed = true
		_native_state_uncertain = true
		Logger.error(LOG, "Input-source dispatcher installation failed: %s", tostring(err))
		return false
	end
	_dispatcher_installed = true
	_native_state_uncertain = false
	return true
end

--- Registers or replaces one named subscriber.
--- @param id string Stable process-wide subscriber identifier.
--- @param callback function Notification callback.
--- @return boolean subscribed True after broker ownership commits.
function M.subscribe(id, callback)
	if type(id) ~= "string" or id == "" or type(callback) ~= "function" then
		Logger.error(LOG, "subscribe() requires a non-empty id and callback.")
		return false
	end
	local previous = _subscribers[id]
	_subscribers[id] = callback
	if not ensure_dispatcher() then
		_subscribers[id] = previous
		return false
	end
	return true
end

--- Removes one subscriber and unsets the native slot after the last owner.
--- @param id string Stable subscriber identifier.
--- @return boolean unsubscribed True when no native cleanup debt remains.
function M.unsubscribe(id)
	if type(id) ~= "string" or id == "" then
		Logger.error(LOG, "unsubscribe() requires a non-empty id.")
		return false
	end
	_subscribers[id] = nil
	if subscriber_count() > 0 or not _dispatcher_installed then return true end
	if not hs.keycodes or type(hs.keycodes.inputSourceChanged) ~= "function" then
		_native_state_uncertain = true
		Logger.error(LOG, "Input-source callback API vanished during removal.")
		return false
	end
	local ok, err = pcall(hs.keycodes.inputSourceChanged, nil)
	if not ok then
		_native_state_uncertain = true
		Logger.error(LOG, "Input-source dispatcher removal failed: %s", tostring(err))
		return false
	end
	_dispatcher_installed = false
	_native_state_uncertain = false
	return true
end

--- Reports whether a named subscriber is currently active.
--- @param id string Stable subscriber identifier.
--- @return boolean subscribed True only for an active callback.
function M.is_subscribed(id)
	return type(id) == "string" and type(_subscribers[id]) == "function"
end

return M
