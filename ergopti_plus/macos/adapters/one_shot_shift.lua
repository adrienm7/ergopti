--- adapters/one_shot_shift.lua

--- ==============================================================================
--- MODULE: One-shot Shift Native Event Adapter
--- DESCRIPTION:
--- Translates fresh keyboard events without posting probes. Native Shift flags
--- stay attached to repeatable physical input; special results use the existing
--- ordered Unicode serializer and retain exact repeat/release ownership.
--- ==============================================================================

local M = {}
local State = require("modules.keymap.one_shot_shift")
local Keycodes = require("keycodes")
local Timer = require("adapters.timer_scheduler")
local SyntheticInput = require("adapters.synthetic_input")
local CONTROL = {
	[Keycodes.BACKSPACE] = "backspace", [Keycodes.FORWARD_DELETE] = "delete",
	[Keycodes.RETURN] = "enter", [Keycodes.ENTER] = "enter",
	[Keycodes.TAB] = "tab", [Keycodes.ESCAPE] = "escape",
}

--- Builds an owner before event taps start; configuration I/O occurs only here.
--- @param deps table { magic, data?, event?, now?, emit?, translate? }
--- @return table
function M.new(deps)
	local data = deps.data
	if data == nil then
		local path = require("infra.paths").shared("tap_hold/one_shot_shift.json")
		local raw = assert(require("adapters.file_system").read(path), "one-shot Shift results are unreadable")
		data = assert(require("adapters.json_codec").decode(raw), "one-shot Shift results are malformed")
	end
	local owner = State.new(data)
	local event_api = deps.event or hs.eventtap.event
	local now = deps.now or function() return Timer.now_ns() / 1e9 end
	local emit = deps.emit or SyntheticInput.emit_key_strokes
	local translated = deps.translate or SyntheticInput.keyboard_characters
	assert(type(deps.magic) == "function", "one-shot Shift requires the live magic-key reader")
	local adapter = {}
	local pending = nil

	local function add_shift(event, code, raw_flags)
		local shifted_flags = raw_flags | event_api.rawFlagMasks.shift
		local text = translated(code, shifted_flags)
		event:rawFlags(shifted_flags)
		if type(text) == "string" and text ~= "" then event:setUnicodeString(text) end
	end

	--- Arms only from a configured timeout supplied by the remap owner.
	function adapter.arm(timeout)
		owner:arm(now(), timeout)
	end

	--- Cancels activation while preserving already-consumed release debt.
	function adapter.disarm()
		owner:disarm()
	end

	--- Retires all physical identities after a tap outage or complete stop.
	function adapter.reset()
		owner:reset()
		pending = nil
	end

	--- Claims repeats of an already consumed press, including while paused.
	function adapter.claim_repeat(event)
		return next(owner.absorbed) ~= nil and owner.absorbed[event:getKeyCode()] == true
	end

	--- Changes or consumes one proven physical key-down inside the serializer.
	function adapter.key_down(event, code)
		assert(pending == nil, "one-shot callback ownership was not settled")
		if not owner:active() then return false end
		if owner.absorbed[code] then return true end
		local control = CONTROL[code]
		local flags = event:getFlags()
		if control == nil and (flags.cmd or flags.ctrl) then control = "shortcut" end
		local text = control == nil and event:getCharacters(false) or ""
		if control == nil and type(text) == "string" and text ~= "" then
			local first = utf8.codepoint(text)
			-- AppKit encodes arrows and function keys in its private-use range.
			if first < 32 or first == 127 or (first >= 0xF700 and first <= 0xF8FF) then control = "nontext" end
		end
		local raw_flags = event:rawFlags()
		local kind, result = owner:take(code, control, text, now(), deps.magic(), function(title)
			return translated(code, raw_flags) == text
				and translated(code, event_api.rawFlagMasks.shift) == title
		end)
		if kind == "text" then
			assert(emit(result), "one-shot Shift text emission was refused")
			pending = { key = code, kind = kind }
			return true
		elseif kind == "shift" or kind == "shift-held" then
			pending = { key = code, kind = kind, event = event, raw = raw_flags, text = event:getCharacters(false) }
			add_shift(event, code, raw_flags)
		end
		return kind == "consume"
	end

	--- Publishes physical ownership only after the callback handoff settles.
	--- A failed collector passes the original through, so it must own no repeats.
	function adapter.finish(accepted)
		local current = pending
		pending = nil
		if not current then return end
		if accepted then
			if current.kind ~= "shift-held" then owner:commit(current.key, current.kind) end
		elseif current.event then
			current.event:rawFlags(current.raw)
			current.event:setUnicodeString(current.text)
		end
	end

	--- Settles a proven physical release without emitting another keystroke.
	function adapter.key_up(event, code)
		local kind = owner:release(code)
		if kind == "shift" then add_shift(event, code, event:rawFlags()) end
		return kind == "consume"
	end

	return adapter
end

return M
