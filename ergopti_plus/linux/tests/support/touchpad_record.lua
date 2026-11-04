--- tests/support/touchpad_record.lua

--- ==============================================================================
--- MODULE: libinput record Touchpad Traces
--- DESCRIPTION:
--- Reads and writes the evdev part of a `libinput record` file, the format the
--- libinput project uses to capture a real device. The decoder's fixtures were
--- written by hand from the kernel's documentation; a trace in this format comes
--- from a kernel instead, so the decoder can be replayed on what a touchpad
--- actually sent.
---
--- FEATURES & RATIONALE:
--- 1. Only what the decoder reads is kept: each `[sec, usec, type, code, value]`
---    row of the `events:` list, in order, stamped as the reader stamps them.
--- 2. A file with several devices is refused: which device's frames feed the
---    decoder would be a guess.
--- 3. A trace may carry its expected gestures as `# ergopti-expect:` comments,
---    which YAML and `libinput replay` both ignore.
--- ==============================================================================

local M = {}

-- A record's stamps start at 0, and the decoder reads a 0 stamp as "unstamped"
-- and times that frame by the wall clock instead: every decoded stamp is moved
-- one second later, which keeps every interval exact.
local STAMP_BASE_US = 1000000

local ROW_PATTERN = "^%s*%-%s*%[%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%-?%d+)%s*%]"

--- Parses the text of a `libinput record` file.
--- @param text string
--- @return table|nil trace { name, events, expected }, string|nil reason
function M.decode(text)
	if type(text) ~= "string" then return nil, "record text missing" end
	if not text:match("^%s*version:%s*1%s*\n") and not text:match("\nversion:%s*1%s*\n") then
		return nil, "not a version 1 libinput record"
	end
	local devices = text:match("\nndevices:%s*(%d+)")
	if devices ~= "1" then return nil, "a record must hold exactly one device" end
	local trace = { name = text:match("\n%s+name:%s*\"([^\"]*)\""), events = {}, expected = {} }
	local in_events = false
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local expect = line:match("^%s*#%s*ergopti%-expect:%s*(.-)%s*$")
		if expect then
			local gesture = {}
			for key, value in expect:gmatch("(%w+)=(%w+)") do gesture[key] = value end
			gesture.fingers = tonumber(gesture.fingers)
			gesture.tap = gesture.tap == "true"
			trace.expected[#trace.expected + 1] = gesture
		elseif line:match("^%s*events:%s*$") then
			in_events = true
		elseif in_events and line:match("^%s*%-%s*%[") then
			local sec, usec, kind, code, value = line:match(ROW_PATTERN)
			if not sec then return nil, "malformed evdev row: " .. line end
			trace.events[#trace.events + 1] = {
				type = tonumber(kind), code = tonumber(code), value = tonumber(value),
				timestamp_us = STAMP_BASE_US + tonumber(sec) * 1000000 + tonumber(usec),
			}
		end
	end
	if #trace.events == 0 then return nil, "the record holds no evdev event" end
	return trace, nil
end

--- Writes events as a one-device `libinput record` file, one frame per block.
--- @param name string Device name.
--- @param events table { type, code, value, timestamp_us }
--- @param expected table|nil Gestures to write as `# ergopti-expect:` lines.
--- @return string text
function M.encode(name, events, expected)
	assert(type(name) == "string" and not name:find("[\"\n]"), "record device name must be plain")
	assert(type(events) == "table" and #events > 0, "a record needs events")
	local lines = { "version: 1", "ndevices: 1", "libinput:", "  version: \"ergopti\"", "  git: \"unknown\"" }
	for _, gesture in ipairs(expected or {}) do
		lines[#lines + 1] = string.format("# ergopti-expect: fingers=%d direction=%s tap=%s",
			gesture.fingers, tostring(gesture.direction), tostring(gesture.tap == true))
	end
	lines[#lines + 1] = "devices:"
	lines[#lines + 1] = "- node: /dev/input/event0"
	lines[#lines + 1] = "  evdev:"
	lines[#lines + 1] = "    name: \"" .. name .. "\""
	lines[#lines + 1] = "  events:"
	local first = events[1].timestamp_us or 0
	local open = false
	for _, event in ipairs(events) do
		if not open then lines[#lines + 1] = "  - evdev:"; open = true end
		local relative = math.max(0, (event.timestamp_us or first) - first)
		lines[#lines + 1] = string.format("    - [%3d, %6d, %3d, %3d, %7d]",
			math.floor(relative / 1000000), relative % 1000000, event.type, event.code, event.value)
		if event.type == 0 and event.code == 0 then open = false end
	end
	return table.concat(lines, "\n") .. "\n"
end

--- Feeds a decoded trace to a decoder and returns every gesture it produced.
--- @param decoder table An mt_decoder instance.
--- @param trace table A decoded trace.
--- @return table gestures
function M.replay(decoder, trace)
	local gestures = {}
	for _, event in ipairs(trace.events) do
		local gesture = decoder:feed({ type = event.type, code = event.code, value = event.value,
			timestamp_us = event.timestamp_us })
		if gesture then gestures[#gestures + 1] = gesture end
	end
	return gestures
end

return M
