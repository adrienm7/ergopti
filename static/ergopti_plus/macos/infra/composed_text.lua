--- infra/composed_text.lua
--- Common approximation of macOS composed-character movement for text actions
--- and the keymap's Backspace tracking. This is not a complete UAX #29 engine.
local M = {}

local function joins_previous(code)
	return (code >= 0x0300 and code <= 0x036F) or (code >= 0x1AB0 and code <= 0x1AFF)
		or (code >= 0x1DC0 and code <= 0x1DFF) or (code >= 0x20D0 and code <= 0x20FF)
		or (code >= 0xFE20 and code <= 0xFE2F) or (code >= 0xFE00 and code <= 0xFE0F)
		or (code >= 0xE0100 and code <= 0xE01EF) or (code >= 0x1F3FB and code <= 0x1F3FF)
		or (code >= 0xE0020 and code <= 0xE007F) or code == 0x200D
end

--- Walks text once, returning the number of cursor steps and the byte index of
--- the final composed sequence. Invalid UTF-8 raises to the caller's fence.
local function scan(text)
	local steps, previous, regional_open, last_start = 0, nil, false, nil
	for index, code in utf8.codes(text) do
		local joined = false
		if previous == nil then
			joined = false
		elseif joins_previous(code) or previous == 0x200D then
			joined = true
		elseif code == 0x0A and previous == 0x0D then
			joined = true
		elseif code >= 0x1F1E6 and code <= 0x1F1FF and regional_open then
			joined = true
		end
		if code >= 0x1F1E6 and code <= 0x1F1FF then
			regional_open = not joined
		elseif not joined then
			regional_open = false
		end
		if not joined then steps, last_start = steps + 1, index end
		previous = code
	end
	return steps, last_start
end

--- Number of cursor movements across the text.
function M.count(text)
	return (scan(text))
end

--- Byte index of the final composed sequence, or nil for empty text.
function M.last_start(text)
	-- Plain ASCII cannot join except CRLF, and is the common Backspace path.
	if not text:find("[\128-\255\r]") then return #text > 0 and #text or nil end
	local _, index = scan(text)
	return index
end

return M
