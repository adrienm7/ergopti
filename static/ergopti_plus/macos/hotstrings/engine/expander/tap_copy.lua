--- hotstrings/engine/expander/tap_copy.lua

--- ==============================================================================
--- MODULE: Tap-Hold Copy Watch (macOS)
--- DESCRIPTION:
--- Watches the copy a tap-hold key sends (Left Shift tapped = Cmd+C by
--- default) and proves it reached the clipboard. Karabiner decides the tap and
--- posts the Cmd+C; Hammerspoon only sees the result, so this module reads it
--- from the event stream the keymap taps already receive.
---
--- FEATURES & RATIONALE:
--- 1. What Karabiner decided, from the events it posted: a tap-hold modifier
---    whose hold is itself reaches the keymap's flagsChanged tap as its own
---    press and release, and a tap's Cmd+C follows the release within a few
---    milliseconds. A lone press (no other key, modifier or click under it)
---    followed by Cmd+C is that key's copy; a lone press followed by nothing is
---    a tap Karabiner did not take, and the press duration (from the window
---    server's event stamps, not from callback times a held main thread
---    delays) says whether it was held past the tap threshold.
--- 2. The clipboard counter is read in the keyDown tap, before the application
---    receives the Cmd+C, so the baseline can never already include the copy.
---    The shared copy check (tap_hold.copy_check) then waits on a timer, sends
---    Cmd+C once more when the counter did not move, and the user is warned
---    when it still did not.
--- 3. Nothing is logged on the event taps: every log line, the configuration
---    lookup and the check start run after the callback returned.
--- 4. One log line per watched tap, so a field report decides why a copy was
---    missing: held past the threshold, cancelled, or sent and lost.
--- ==============================================================================

local M = {}

-- The keys whose hold is the modifier they are, by Quartz keycode, named by
-- their tap-hold id (keyboard/data/tap_hold_keys.json). Only these reach
-- the flagsChanged tap as themselves.
M.KEY_IDS = {
	[56] = "left_shift", [60] = "right_shift",
	[59] = "left_control",
	[58] = "left_option", [61] = "right_option",
	[55] = "left_command", [54] = "right_command",
}

-- The modifier flag each of those keys sets.
local KEY_FLAGS = {
	[56] = "shift", [60] = "shift", [59] = "ctrl", [58] = "alt", [61] = "alt", [55] = "cmd", [54] = "cmd",
}

-- kVK_Command: Karabiner presses it for the copy's Cmd+C right after the
-- release it answers, so it must not end the watch.
local COPY_COMMAND_KEYCODE = 55

-- Karabiner posts a tap's output at the release itself; a Cmd+C stamped later
-- than this after the release was typed by the hand, not by the tap.
M.ATTRIBUTION_WINDOW_MS = 100

-- The tap action whose output is watched.
local COPY_ACTION = "copy"

local Owner = {}
Owner.__index = Owner

--- Creates one watch.
--- @param ports table {
---   change_count = function() -> number|nil, NSPasteboard changeCount,
---   duration_ms = function(earlier_stamp, later_stamp) -> number|nil,
---   defer = function(label, fn) -> boolean, runs fn after the tap returned,
---   event_flags = function(event) -> table, the event's modifier flags,
---   event_chars = function(event) -> string, its characters ignoring modifiers,
---   key_config = function(key_id) -> tap_action|nil, threshold_ms|nil,
---   log = function(level, fmt, ...), the central logger,
---   checker = table, a tap_hold.copy_check checker,
--- }
--- @return table owner
function M.new(ports)
	assert(type(ports) == "table", "tap_copy.new: ports must be a table")
	for _, name in ipairs({ "change_count", "duration_ms", "defer", "event_flags", "event_chars",
		"key_config", "log" }) do
		assert(type(ports[name]) == "function", "tap_copy.new: port '" .. name .. "' must be a function")
	end
	assert(type(ports.checker) == "table" and type(ports.checker.start) == "function",
		"tap_copy.new: checker must be a tap_hold.engine.copy_check checker")
	return setmetatable({ ports = ports, down = {}, candidate = nil, released = nil,
		generation = 0, stats = M.empty_stats() }, Owner)
end

-- How many press durations the statistics keep, the most recent ones.
M.HELD_SAMPLES = 20

--- Fresh session statistics for the field run (diagnostics/engine/field_check/tap_copy.lua):
--- the watched copy taps since the driver started, how each ended, and the
--- press durations, so a report from a real Mac says why copies were missing.
--- @return table stats
function M.empty_stats()
	return { sent = 0, missing_past = 0, missing_within = 0, outcomes = {}, held_ms = {}, missing_held_ms = {} }
end

--- Appends one duration to a bounded sample list.
local function sample(list, ms)
	if type(ms) ~= "number" then return end
	list[#list + 1] = math.floor(ms + 0.5)
	if #list > M.HELD_SAMPLES then table.remove(list, 1) end
end

--- Counts one copy check outcome (tap_hold.copy_check).
--- @param outcome string
function Owner:note_outcome(outcome)
	self.stats.outcomes[outcome] = (self.stats.outcomes[outcome] or 0) + 1
end

--- A detached copy of the session statistics.
--- @return table stats
function Owner:statistics()
	local copy = M.empty_stats()
	copy.sent, copy.missing_past, copy.missing_within = self.stats.sent, self.stats.missing_past, self.stats.missing_within
	for outcome, count in pairs(self.stats.outcomes) do copy.outcomes[outcome] = count end
	for _, ms in ipairs(self.stats.held_ms) do copy.held_ms[#copy.held_ms + 1] = ms end
	for _, ms in ipairs(self.stats.missing_held_ms) do copy.missing_held_ms[#copy.missing_held_ms + 1] = ms end
	return copy
end

--- Rounds a duration for a log line; nil reads as unknown.
--- @param ms number|nil
--- @return string
local function ms_text(ms)
	if type(ms) ~= "number" then return "?" end
	return tostring(math.floor(ms + 0.5))
end

--- Logs, after the callback, a watched tap that sent no copy.
--- @param released table The release that was waiting for its Cmd+C.
--- @param why string What came instead.
function Owner:report_missing(released, why)
	local ports = self.ports
	local generation = self.generation
	ports.defer("tap copy missing", function()
		if self.generation ~= generation then return end
		local tap, threshold_ms = ports.key_config(released.key_id)
		if tap ~= COPY_ACTION then return end
		local past = type(released.held_ms) == "number" and type(threshold_ms) == "number"
			and released.held_ms > threshold_ms
		local verdict = past and "held past the threshold, so Karabiner took it as a hold"
			or "within the threshold, so Karabiner cancelled the tap or its Cmd+C was lost"
		if past then
			self.stats.missing_past = self.stats.missing_past + 1
		else
			self.stats.missing_within = self.stats.missing_within + 1
		end
		sample(self.stats.missing_held_ms, released.held_ms)
		ports.log("info", "Tap-hold copy: %s held %s ms (threshold %s ms) sent no Cmd+C (%s; %s).",
			released.key_id, ms_text(released.held_ms), ms_text(threshold_ms), verdict, why)
	end)
end

--- Observes one modifier edge read by the flagsChanged tap. A flagsChanged
--- event names the key that changed, not its direction: the direction is the
--- key's own toggle, forced to a release when its flag is no longer down.
--- @param keycode number Quartz keycode of the modifier that changed.
--- @param flags table The event's modifier flags.
--- @param stamp number|nil The event's raw stamp (adapters.event_clock).
function Owner:modifier_edge(keycode, flags, stamp)
	local flag = KEY_FLAGS[keycode]
	if flag == nil then
		self.retry_token = nil
		-- Caps Lock, Fn: part of a chord, never a watched tap.
		if self.candidate then self.candidate.clean = false end
		if self.released then
			local released = self.released
			self.released = nil
			self:report_missing(released, "another modifier came first")
		end
		return
	end
	-- The Cmd release immediately following Karabiner's copy belongs to that
	-- copy. Any other modifier edge can change the user's selection or context.
	if self.retry_token and not (keycode == COPY_COMMAND_KEYCODE and self.down[keycode]
		and type(flags) == "table" and flags.cmd ~= true) then self.retry_token = nil end
	if not self.down[keycode] and type(flags) == "table" and flags[flag] == true then
		if self.released ~= nil then
			if keycode == COPY_COMMAND_KEYCODE and next(self.down) == nil then
				self.down[keycode] = true
				return
			end
			local released = self.released
			self.released = nil
			self:report_missing(released, "another modifier came first")
		end
		if self.candidate == nil and next(self.down) == nil then
			self.candidate = { keycode = keycode, stamp = stamp, clean = true }
		elseif self.candidate then
			self.candidate.clean = false
		end
		self.down[keycode] = true
		return
	end
	self.down[keycode] = nil
	local candidate = self.candidate
	if candidate == nil or candidate.keycode ~= keycode then return end
	self.candidate = nil
	if not candidate.clean or next(self.down) ~= nil then return end
	self.released = {
		key_id = M.KEY_IDS[keycode],
		held_ms = self.ports.duration_ms(candidate.stamp, stamp),
		stamp = stamp,
	}
end

--- Observes a click: whatever modifier is down is used with it.
function Owner:activity()
	self.retry_token = nil
	if self.candidate then self.candidate.clean = false end
	if self.released then
		local released = self.released
		self.released = nil
		self:report_missing(released, "a click came first")
	end
end

--- Whether a key-down matters to the watch: a modifier is down or a watched
--- release waits for its Cmd+C. Ordinary typing costs this one check.
--- @return boolean
function Owner:watching()
	return self.candidate ~= nil or self.released ~= nil or self.retry_token ~= nil
end

--- Observes one physical key-down read by the keyDown tap. Its flags and
--- characters are read only when a watched release is waiting for its Cmd+C.
--- @param event any The keyDown event, handed to the event_flags and
---   event_chars ports.
--- @param stamp number|nil The event's raw stamp.
--- @param lateness_ms number|nil How late the event reached the tap.
function Owner:key_down(event, stamp, lateness_ms)
	if self.candidate then self.candidate.clean = false end
	local released = self.released
	if released == nil then self.retry_token = nil; return end
	self.released = nil
	local ports = self.ports
	local flags = ports.event_flags(event)
	local copy = type(flags) == "table" and flags.cmd == true and not flags.ctrl and not flags.alt
		and not flags.shift and ports.event_chars(event) == "c"
	local gap_ms = ports.duration_ms(released.stamp, stamp)
	if not copy or type(gap_ms) ~= "number" or gap_ms < 0 or gap_ms > M.ATTRIBUTION_WINDOW_MS then
		self:report_missing(released, copy and "the Cmd+C timing did not match the tap" or "the next key was not Cmd+C")
		return
	end
	-- Read now: the application has not received this Cmd+C yet.
	local baseline = ports.change_count()
	local target = nil
	if type(ports.capture_destination) == "function" then
		local captured, value = pcall(ports.capture_destination)
		if captured then target = value end
	end
	local token = {}
	self.retry_token = token
	local generation = self.generation
	ports.defer("tap copy check", function()
		if self.generation ~= generation then return end
		local tap, threshold_ms = ports.key_config(released.key_id)
		if tap ~= COPY_ACTION then return end
		self.stats.sent = self.stats.sent + 1
		sample(self.stats.held_ms, released.held_ms)
		ports.log("debug",
			"Tap-hold copy: %s held %s ms (threshold %s ms); Cmd+C %s ms after its release, reached the tap %s ms late; changeCount %s.",
			released.key_id, ms_text(released.held_ms), ms_text(threshold_ms), ms_text(gap_ms),
			ms_text(lateness_ms), tostring(baseline))
		ports.checker:start(baseline, released.key_id, function()
			if self.retry_token ~= token or target == nil or type(ports.destination_current) ~= "function" then return false end
			local current = ports.destination_current(target)
			return current == true and self.retry_token == token
		end)
	end)
end

--- Forgets every press in flight and abandons a pending check.
function Owner:stop()
	self.generation = self.generation + 1
	self.down, self.candidate, self.released, self.retry_token = {}, nil, nil, nil
	self.ports.checker:stop()
end

return M
