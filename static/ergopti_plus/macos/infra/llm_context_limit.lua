--- infra/llm_context_limit.lua
--- One explicit limit shared by context retention, runtime and settings UI.
local M = { MAX_CHARS = require("llm.context_buffer").MAX_CONTEXT_LENGTH }

--- @param value any User or persisted context length.
--- @return boolean valid
function M.valid(value)
	local number = tonumber(value)
	return number ~= nil and number == number and number ~= math.huge
		and number ~= -math.huge and number % 1 == 0 and number <= M.MAX_CHARS
end

return M
