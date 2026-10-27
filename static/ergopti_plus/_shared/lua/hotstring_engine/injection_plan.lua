--- _shared/lua/hotstring_engine/injection_plan.lua

--- ==============================================================================
--- MODULE: Hotstring Injection Plan
--- DESCRIPTION:
--- The decision both hotstring engines used to take on their own: how many
--- codepoints to erase, what to type, which terminator to replay afterwards, and
--- what the rolling buffer holds once the edit has landed. Delivery stays with
--- the driver (Quartz batches on macOS, evdev/uinput on Linux); this module only
--- answers "what, and in which order".
---
--- ORDER OF EVERY PLAN: erase `erase` codepoints, type `text`, then replay `tail`
--- once the text has landed. Nothing else is ever sent.
---
--- WHAT DIFFERS PER DRIVER is one fact, `event_on_screen`: whether the key that
--- completed the match is already in the application. Linux always sees it
--- there. macOS holds the event back (it is not on screen) unless the window is
--- ignored, in which case the event has already been delivered. The erase count
--- follows from that fact alone, so the two drivers cannot drift apart.
---
--- Pure: no logger state, no clock, no I/O, no platform.
--- ==============================================================================

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Erase count =============
-- ====================================
-- ====================================

--- The path that completed the match.
M.PATH_AUTO       = "auto"
M.PATH_TERMINATOR = "terminator"

--- Codepoints to erase from the screen.
---
--- Auto path: the typed event is the trigger's last codepoint, so `trigger_len`
--- already counts it; it is subtracted when it never reached the screen. A
--- trigger shorter than its event (a composed character arriving as one event)
--- cannot need a negative erase, so the result is clamped at 0.
---
--- Terminator path: `trigger_len` excludes the terminator. A stripped no-break
--- space sits between the trigger and the terminator, so it is erased too, and
--- so is the terminator when it is on screen.
--- @param spec table { path, trigger_len, event_len, event_on_screen, nbsp_stripped }
--- @return integer erase
function M.erase_count(spec)
	if type(spec) ~= "table" then error("erase_count needs a spec table", 2) end
	local trigger_len, event_len = spec.trigger_len, spec.event_len
	if type(trigger_len) ~= "number" or trigger_len % 1 ~= 0 or trigger_len < 0 then
		error("trigger_len must be a non-negative integer", 2)
	end
	if type(event_len) ~= "number" or event_len % 1 ~= 0 or event_len < 0 then
		error("event_len must be a non-negative integer", 2)
	end
	if type(spec.event_on_screen) ~= "boolean" then error("event_on_screen must be a boolean", 2) end
	local nbsp = spec.nbsp_stripped == true and 1 or 0
	local erase
	if spec.path == M.PATH_AUTO then
		erase = trigger_len - (spec.event_on_screen and 0 or event_len)
		if erase < 0 then erase = 0 end
	elseif spec.path == M.PATH_TERMINATOR then
		erase = trigger_len + (spec.event_on_screen and event_len or 0) + nbsp
	else
		error("path must be 'auto' or 'terminator', got " .. tostring(spec.path), 2)
	end
	return erase
end





-- ====================================
-- ====================================
-- ======= 2/ Terminator replay =======
-- ====================================
-- ====================================

--- The terminator to replay after the replacement: the typed one, unless its
--- delimiter is consumed. Only the terminator path has one.
--- @param path string
--- @param consume_terminator boolean
--- @param terminator string|nil The typed terminator.
--- @return string|nil tail
function M.tail(path, consume_terminator, terminator)
	if path ~= M.PATH_TERMINATOR or consume_terminator == true then return nil end
	if terminator == nil or terminator == "" then return nil end
	return terminator
end

--- How a replayed terminator travels: Enter and Tab as raw keys, anything else
--- as text, because the key events and the text pipeline do not order themselves.
--- @param chars string
--- @return table spec { kind = "key", key, chars } or { kind = "text", chars }
function M.replay_spec(chars)
	if chars == "\r" or chars == "\n" then return { kind = "key", key = "return", chars = chars } end
	if chars == "\t" then return { kind = "key", key = "tab", chars = chars } end
	return { kind = "text", chars = chars }
end





-- ====================================
-- ====================================
-- ======= 3/ The whole plan ==========
-- ====================================
-- ====================================

--- Builds the plan of one expansion.
--- `cascade`, when the chain produced a net edit, replaces the first step's
--- replacement, trigger length, tail and final flag with the chain's own.
--- @param spec table { path, trigger_len, event_len, event_on_screen, nbsp_stripped,
---   replacement, terminator, consume_terminator, final_result,
---   cascade = { replacement, trigger_len, tail, final_result }|nil }
--- @return table plan { erase, text, tail, replay, buffer_suffix, final_result }
function M.build(spec)
	if type(spec) ~= "table" then error("build needs a spec table", 2) end
	if type(spec.replacement) ~= "string" then error("replacement must be a string", 2) end
	local text, trigger_len = spec.replacement, spec.trigger_len
	local tail = M.tail(spec.path, spec.consume_terminator, spec.terminator)
	local final = spec.final_result == true
	local cascade = spec.cascade
	if cascade ~= nil then
		text, trigger_len, tail = cascade.replacement, cascade.trigger_len, cascade.tail
		final = cascade.final_result == true
	end
	local erase = M.erase_count({
		path = spec.path, trigger_len = trigger_len, event_len = spec.event_len,
		event_on_screen = spec.event_on_screen, nbsp_stripped = spec.nbsp_stripped,
	})
	return {
		erase         = erase,
		text          = text,
		tail          = tail,
		replay        = tail ~= nil and M.replay_spec(spec.terminator or tail) or nil,
		buffer_suffix = text .. (tail or ""),
		final_result  = final,
	}
end

return M
