--- keyboard/engine/tap_copy.lua

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
--- 2. A session with no counter (Wayland without data-control, or no
---    display) leaves its copies unchecked; that is said once in the log, not
---    at every copy.
--- 3. Pure over its ports, so the suite drives it with a fake counter and
---    clock; tap_hold/engine/manager.lua owns the live instance.
--- ==============================================================================

local M = {}

local CopyCheck = require("tap_hold.engine.copy_check")

local Owner = {}
Owner.__index = Owner

--- Creates one copy owner.
--- @param ports table {
---   read_counter = function() -> number|nil, reason|nil ("unsupported" or
---     "unreadable", as adapters/clipboard change_counter returns them),
---   send_copy = function() -> boolean, sends Ctrl+C again for the retry,
---   capture_destination = function() -> owner|nil with current() -> boolean,
---   after = function(delay_ms, callback) -> handle|nil, cancel = function(handle),
---   log = function(level, fmt, ...), warn_user = function(),
---   verify_ms = number,
--- }
--- @return table owner
function M.new(ports)
	assert(type(ports) == "table", "tap_copy.new: ports must be a table")
	for _, name in ipairs({ "read_counter", "send_copy", "capture_destination", "after", "cancel", "log", "warn_user" }) do
		assert(type(ports[name]) == "function", "tap_copy.new: port '" .. name .. "' must be a function")
	end
	local self = setmetatable({ ports = ports, unsupported_reported = false, generation = 0, activity_generation = 0 }, Owner)
	local report = CopyCheck.reporter(ports.log, ports.warn_user)
	self.checker = CopyCheck.new({
		verify_ms = ports.verify_ms,
		read_counter = function() return (ports.read_counter()) end,
		send_copy = function()
			local destination, source, generation = self.retry_destination, self.retry_source, self.generation
			local activity = self.retry_activity
			-- Physical activity during the focus or source proof also revokes it.
			local function current_generation()
				return self.generation == generation and self.activity_generation == activity
			end
			if type(source) ~= "function" then return false end
			local observed, admitted = pcall(source)
			if not current_generation() or not observed or admitted ~= true then return false end
			if type(destination) ~= "table" or type(destination.current) ~= "function" then return false end
			local checked, current = pcall(destination.current)
			if not current_generation() or not checked or current ~= true
				or self.retry_destination ~= destination or self.retry_source ~= source then return false end
			observed, admitted = pcall(source)
			if not current_generation() or not observed or admitted ~= true
				or self.retry_destination ~= destination or self.retry_source ~= source then return false end
			local called, sent = pcall(ports.send_copy)
			if not current_generation() then return false end
			if not called then error(sent, 0) end
			return sent
		end,
		after = ports.after,
		cancel = ports.cancel,
		report = report,
	})
	return self
end

--- Sends one tap-hold copy and starts its check.
--- @param source string The binding that tapped, for the log.
--- @param send function Sends the copy keystroke; raises on failure.
--- @param source_current function Whether the original remap source remains in force.
function Owner:run(source, send, source_current)
	-- Revoke an older retry before any focus or clipboard probe can dispatch.
	self:stop()
	local generation = self.generation
	local baseline, reason = self.ports.read_counter()
	if self.generation ~= generation then return false end
	-- Physical activity after this tap revokes its delayed retry.
	local activity = self.activity_generation
	local function source_admitted()
		if type(source_current) ~= "function" then return self.generation == generation end
		local ok, current = pcall(source_current)
		return ok and current == true and self.generation == generation
	end
	if baseline == nil and reason == "unsupported" then
		-- A previous X11 check must not retry over this newer selection.
		if not source_admitted() then return false end
		local sent = send()
		if self.generation ~= generation or sent == false then return false end
		if not self.unsupported_reported then
			self.unsupported_reported = true
			self.ports.log("info",
				"Tap-hold copies are not checked: this session exposes no clipboard change counter (Wayland without a clipboard watch, or no display).")
		end
		return true
	end
	local captured, destination = pcall(self.ports.capture_destination)
	if self.generation ~= generation or not source_admitted() then return false end
	self.retry_destination = captured and destination or nil
	self.retry_source = type(source_current) == "function" and source_current or nil
	self.retry_activity = activity
	local ok, err = pcall(send)
	if not ok then
		if self.generation == generation then self:stop() end
		error(err, 0)
	end
	if self.generation ~= generation or err == false then
		if self.generation == generation then self:stop() end
		return false
	end
	self.checker:start(baseline, source, function() return activity == self.activity_generation end)
	return true
end

--- Invalidates a retry after observed physical activity.
function Owner:activity()
	self.activity_generation = self.activity_generation + 1
end

--- Abandons a pending check (pause, stop, a new engine).
function Owner:stop()
	self.generation = self.generation + 1
	self.retry_destination, self.retry_source, self.retry_activity = nil, nil, nil
	self.checker:stop()
end

return M
