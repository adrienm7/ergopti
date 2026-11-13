--- modules/keymap/one_shot_shift.lua

--- ==============================================================================
--- MODULE: One-shot Shift State Owner
--- DESCRIPTION:
--- Tracks an armed deadline and the exact physical keys whose repeats/releases
--- belong to a transformed press. Native event translation and emission stay in
--- the adapter; deciding a result never claims a key before emission succeeds.
--- ==============================================================================

local M = {}
local Policy = require("tap_hold.engine.one_shot_shift_core")
local Owner = {}
Owner.__index = Owner

--- Constructs an independent owner from the shared result catalogue.
--- @param data table Decoded one_shot_shift.json.
--- @return table
function M.new(data)
	assert(type(data) == "table" and type(data.results) == "table"
		and type(data.magic_key_result) == "string", "invalid one-shot result catalogue")
	local results = {}
	for _, entry in ipairs(data.results) do
		assert(type(entry.char) == "string" and entry.char ~= ""
			and type(entry.result) == "string" and entry.result ~= ""
			and results[entry.char] == nil, "invalid or duplicate one-shot result")
		results[entry.char] = entry.result
	end
	return setmetatable({ results = results, magic = data.magic_key_result,
		absorbed = {}, shifted = {}, deadline = nil }, Owner)
end

--- Arms or refreshes the deadline without inventing a timeout default.
--- @param now number Monotonic seconds.
--- @param timeout number User-configured seconds; 0 is no time limit.
function Owner:arm(now, timeout)
	assert(type(now) == "number" and type(timeout) == "number" and timeout >= 0 and timeout < math.huge,
		"one-shot Shift requires a valid configured timeout")
	self.deadline = require("tap_hold.engine.one_shot_timeout").deadline(now, timeout)
end

--- Cancels activation while retaining release debt for transformed keys.
function Owner:disarm()
	self.deadline = nil
end

--- Drops identities after observation stops; a later press is a new owner.
function Owner:reset()
	self:disarm()
	self.absorbed = {}
	self.shifted = {}
end

--- Whether the owner can change the next event.
--- @return boolean
function Owner:active()
	return self.deadline ~= nil or next(self.absorbed) ~= nil or next(self.shifted) ~= nil
end

--- Returns a decision without claiming a new physical press.
--- @param key number Physical keycode.
--- @param control string|nil Canonical control name; nil for textual keys.
--- @param text string Text produced by the active input layout.
--- @param now number Monotonic seconds.
--- @param magic string Current user-selected magic key.
--- @param can_shift function Whether this key with Shift alone types the title.
--- The Shift a shifted press carries belongs to that press alone (its repeats
--- and its release): a key pressed while it is still down is typed as it is,
--- as on Windows, where the one-shot capture ends at the first character.
--- Lending it to every key pressed meanwhile capitalised a fast roll
--- (« abc » gave « ABc » or « ABC »).
--- @return string|nil kind "consume", "shift", "shift-held", "text", or nil.
--- @return string|nil result
function Owner:take(key, control, text, now, magic, can_shift)
	if self.absorbed[key] then return "consume" end
	if self.shifted[key] then return "shift-held" end
	if self.deadline == nil then return nil end
	if Policy.spends_unshifted(control) then self.deadline = nil; return nil end
	-- Modifiers, navigation, function keys and dead keys do not spend it. The
	-- native adapter classifies them before interpreting AppKit control strings.
	if control ~= nil or type(text) ~= "string" or text == "" then return nil end
	local armed = now <= self.deadline
	self.deadline = nil
	if not armed then return nil end
	return Policy.resolve(text, function(character)
		if character == magic then return self.magic end
		return self.results[character]
	end, can_shift)
end

--- Records ownership only after the native event or text output is accepted.
--- @param key number
--- @param kind string
function Owner:commit(key, kind)
	if kind == "text" then self.absorbed[key] = true
	elseif kind == "shift" then self.shifted[key] = true
	else error("invalid one-shot ownership kind") end
end

--- Whether this key still holds a claim from an earlier press.
--- @param key number
--- @return boolean
function Owner:claims(key)
	return self.absorbed[key] == true or self.shifted[key] == true
end

--- Drops the claim of a press whose release never arrived (a tap outage lets
--- it pass unseen); without this, the key's next press would be swallowed.
--- @param key number
function Owner:forget(key)
	self.absorbed[key] = nil
	self.shifted[key] = nil
end

--- Settles a physical release and reports its required treatment.
--- @param key number
--- @return string|nil kind
function Owner:release(key)
	if self.absorbed[key] then self.absorbed[key] = nil; return "consume" end
	local shifted = self.shifted[key] == true
	self.shifted[key] = nil
	return shifted and "shift" or nil
end

return M
