--- platform/remap/tap_copy.lua

--- ==============================================================================
--- MODULE: Tap-Hold Copy (Linux)
--- DESCRIPTION:
--- Sends a tap-hold's copy (Ctrl+C) and proves it reached the clipboard with
--- the shared copy check: the change counter is read before the keystroke,
--- checked on a timer, the copy is sent once more when it did not move, and
--- the user is warned when it still did not.
---
--- FEATURES & RATIONALE:
--- 1. The counter is the X11 CLIPBOARD owner's TIMESTAMP (adapters/clipboard
---    change_counter), never the content: copying the same text again moves
---    the counter and leaves the content as it was.
--- 2. A Wayland session has no counter a client can read, so its copies go
---    unchecked; that is said once in the log, not at every copy.
--- 3. Pure over its ports, so the suite drives it with a fake counter and
---    clock; platform/remap/tap_hold_manager.lua owns the live instance.
--- ==============================================================================

local M = {}

local CopyCheck = require("tap_hold.copy_check")

local Owner = {}
Owner.__index = Owner

--- Creates one copy owner.
--- @param ports table {
---   read_counter = function() -> number|nil, reason|nil ("unsupported" or
---     "unreadable", as adapters/clipboard change_counter returns them),
---   send_copy = function() -> boolean, sends Ctrl+C again for the retry,
---   after = function(delay_ms, callback) -> handle|nil, cancel = function(handle),
---   log = function(level, fmt, ...), warn_user = function(),
---   verify_ms = number,
--- }
--- @return table owner
function M.new(ports)
	assert(type(ports) == "table", "tap_copy.new: ports must be a table")
	for _, name in ipairs({ "read_counter", "send_copy", "after", "cancel", "log", "warn_user" }) do
		assert(type(ports[name]) == "function", "tap_copy.new: port '" .. name .. "' must be a function")
	end
	local self = setmetatable({ ports = ports, unsupported_reported = false, activity_generation = 0 }, Owner)
	self.checker = CopyCheck.new({
		verify_ms = ports.verify_ms,
		read_counter = function() return (ports.read_counter()) end,
		send_copy = ports.send_copy,
		after = ports.after,
		cancel = ports.cancel,
		report = CopyCheck.reporter(ports.log, ports.warn_user),
	})
	return self
end

--- Sends one tap-hold copy and starts its check.
--- @param source string The binding that tapped, for the log.
--- @param send function Sends the copy keystroke; raises on failure.
function Owner:run(source, send)
	local baseline, reason = self.ports.read_counter()
	local generation = self.activity_generation
	local destination = nil
	if type(self.ports.capture_destination) == "function" then
		local ok, value = pcall(self.ports.capture_destination)
		if ok then destination = value end
	end
	send()
	if baseline == nil and reason == "unsupported" then
		if not self.unsupported_reported then
			self.unsupported_reported = true
			self.ports.log("info",
				"Tap-hold copies are not checked: this session exposes no clipboard change counter (Wayland, or X11 without xclip).")
		end
		return
	end
	self.checker:start(baseline, source, function()
		if generation ~= self.activity_generation or destination == nil
			or type(self.ports.destination_current) ~= "function" then return false end
		local current = self.ports.destination_current(destination)
		return current == true and generation == self.activity_generation
	end)
end

--- Invalidates a retry after observed physical activity.
function Owner:activity()
	self.activity_generation = self.activity_generation + 1
end

--- Abandons a pending check (pause, stop, a new engine).
function Owner:stop()
	self.checker:stop()
end

return M
