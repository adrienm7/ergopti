--- modules/keymap/control_sentinels.lua

--- ==============================================================================
--- MODULE: Karabiner Control Sentinel Owner
--- DESCRIPTION:
--- Single owner of the reserved key events that Karabiner emits only to signal
--- Hammerspoon. Such an event is a control message, never application input: the
--- frontmost application must not receive it. A text field with a selection
--- treats an unknown function key as typing and replaces the selection (QSpace
--- rename lost the whole file name whenever the navigation layer was held).
---
--- FEATURES & RATIONALE:
--- 1. One claim point: the keymap keyDown and keyUp eventtaps call claim_key()
---    with the keycode they already read. They are installed for the whole
---    process lifetime, including PAUSE, so the sentinel is deleted there. Every
---    other Ergopti tap passes the reserved code through without acting on it,
---    which makes the outcome independent of Quartz tap insertion order.
--- 2. In-process fan-out: consumers that need the signal (the LLM tooltip idle
---    deadline) register a named listener instead of decoding the key in their
---    own tap, which may run after the owner deleted the event.
--- 3. Bounded hot path: claim_key() is one table lookup on an already-read
---    keycode; no additional native event field is read for ordinary keys.
--- ==============================================================================

local M = {}

local Keycodes       = require("keycodes")
local Logger         = require("infra.logger")
local SyntheticInput = require("adapters.synthetic_input")

local LOG = "keymap.control_sentinels"

--- Signal published when Karabiner enters the navigation layer (F20 sentinel).
M.NAV_LAYER_ENTERED = "nav_layer_entered"

-- Reserved keycode → published signal. Karabiner prepends F20 to every action
-- that activates the navigation layer (platform/remap/generator.lua).
local SIGNAL_BY_KEYCODE = {
	[Keycodes.F20_LAYER_NAV_ENTERED] = M.NAV_LAYER_ENTERED,
}

-- name → callback(signal). Keyed slots, so a module reload replaces its own
-- listener instead of stacking a stale closure beside the new one.
local _listeners = {}
local _listener_failure_logged = {}


--- Registers, replaces, or removes one named listener.
--- Listeners run inside the eventtap callback that claimed the sentinel. They
--- must do bounded in-memory work and defer anything else off the callback.
--- @param name string Stable listener identity.
--- @param callback function|nil Receives the signal name; nil unregisters.
function M.set_listener(name, callback)
	assert(type(name) == "string" and name ~= "",
		"keymap.control_sentinels.set_listener: name must be a non-empty string")
	assert(callback == nil or type(callback) == "function",
		"keymap.control_sentinels.set_listener: callback must be a function or nil")
	_listeners[name] = callback
	_listener_failure_logged[name] = nil
end


--- Reports one listener failure off the eventtap, once per listener.
--- @param name string Listener identity.
--- @param detail any Failure detail.
local function report_listener_failure(name, detail)
	if _listener_failure_logged[name] then return end
	_listener_failure_logged[name] = true
	-- Logger writes files synchronously; never do that on the HID callback.
	local scheduled = SyntheticInput.defer_after_callback("control sentinel listener failure",
		function()
			Logger.error(LOG, "Sentinel listener '%s' failed: %s.", name, tostring(detail))
		end)
	if not scheduled then _listener_failure_logged[name] = nil end
end


--- Delivers one signal to every registered listener.
--- @param signal string Published signal name.
local function publish(signal)
	for name, callback in pairs(_listeners) do
		local ok, err = pcall(callback, signal)
		if not ok then report_listener_failure(name, err) end
	end
end


--- Returns whether a keycode is a reserved Karabiner control sentinel.
--- @param keycode number Quartz keycode.
--- @return boolean
function M.is_sentinel(keycode)
	return SIGNAL_BY_KEYCODE[keycode] ~= nil
end


--- Claims one reserved Karabiner control key so the calling tap deletes it.
--- Key-down publishes the signal; key-up is swallowed silently so no orphan
--- release reaches the application either.
--- @param keycode number Keycode already read by the calling tap.
--- @param is_down boolean True for key-down, false for key-up.
--- @return boolean consumed True when the caller must delete the event.
function M.claim_key(keycode, is_down)
	local signal = SIGNAL_BY_KEYCODE[keycode]
	if signal == nil then return false end
	if is_down then publish(signal) end
	return true
end


return M
