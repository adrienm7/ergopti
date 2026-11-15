--- modules/keystats/clipboard_telemetry.lua

--- ==============================================================================
--- MODULE: Clipboard Copy/Paste Bursts (macOS)
--- DESCRIPTION:
--- Turns the physical Cmd+C, Cmd+X and Cmd+V the keystats event tap admits into
--- the events_clipboard rows Windows writes (clipboard_copy, clipboard_paste,
--- paste_burst), through the shared rule in keystats.clipboard_events.
---
--- FEATURES & RATIONALE:
--- 1. Physical chords only: the event tap returns before the shortcut branch
---    for every event this process posted (EventProvenance), so the driver's
---    own paste-backed replacements are never counted as the user's pastes.
--- 2. Privacy: the pasteboard is never read. A copy refused by the pause, the
---    privacy filters or an excluded application clears the provenance a later
---    paste would carry, so no row names an application whose copy was not kept.
--- 3. One tracker per driver run, created on first use from the shared timings,
---    and dropped by reset() when keystats stops.
--- ==============================================================================

local M = {}

local ClipboardEvents = require("metrics.engine.capture.clipboard_events")
local Timings = require("core.timing.engine.timings")

local _tracker = nil

local function tracker()
	_tracker = _tracker or ClipboardEvents.new({ window_ms = Timings.ms("keystats", "paste_burst_window_ms") })
	return _tracker
end

--- Classifies one key-down from its unmodified characters and its flags.
--- @param chars string|nil event:getCharacters(true).
--- @param flags table hs.eventtap flags { cmd, shift, alt, ctrl, fn }.
--- @return string|nil action "copy", "paste" or nil.
function M.action(chars, flags)
	if type(chars) ~= "string" or type(flags) ~= "table" then return nil end
	return ClipboardEvents.classify_chord(chars:lower(), {
		primary = flags.cmd == true, shift = flags.shift == true, alt = flags.alt == true,
		other = flags.ctrl == true or flags.fn == true,
	})
end

--- Records one admitted chord and the burst it completes.
--- @param action string "copy" or "paste".
--- @param app string Foreground application name.
--- @param now_ms number Monotonic milliseconds.
--- @param sink fun(kind:string, app:string, meta:table) The log manager's appender.
function M.record(action, app, now_ms, sink)
	assert(action == "copy" or action == "paste", "not a clipboard chord: " .. tostring(action))
	assert(type(sink) == "function", "clipboard telemetry needs its sink")
	local rows = action == "copy" and tracker().copy(now_ms, app) or tracker().paste(now_ms, app)
	for _, row in ipairs(rows) do sink(row.kind, app, row.meta) end
end

--- Notes one refused key-down: a refused copy clears the copy provenance.
--- @param chars string|nil event:getCharacters(true).
--- @param flags table hs.eventtap flags.
function M.refuse(chars, flags)
	if M.action(chars, flags) == "copy" then tracker().invalidate() end
end

--- Drops the tracker: the next run starts with no copy and an empty ring.
function M.reset()
	_tracker = nil
end

return M
