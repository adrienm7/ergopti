--- tests/support/command_lines.lua

--- ==============================================================================
--- MODULE: Complete Command Output Reader
--- DESCRIPTION:
--- Publishes lines only after successful command completion and always attempts
--- to close the owned pipe, including when iteration throws.
--- ==============================================================================

local M = {}

--- Collects command output without accepting partial inventories as evidence.
--- @param command string Complete command supplied by the test caller.
--- @return table Lines from a successfully completed command.
function M.read(command)
	assert(type(command) == "string" and command ~= "", "command output requires a non-empty command")
	local pipe, reason = io.popen(command, "r")
	assert(pipe, "command output could not start: " .. tostring(reason))
	local lines = {}
	local outcome = table.pack(pcall(function()
		for line in pipe:lines() do lines[#lines + 1] = line end
	end))
	local closed = table.pack(pcall(pipe.close, pipe))
	if not outcome[1] then error(outcome[2], 0) end
	if not closed[1] then error(closed[2], 0) end
	assert(closed[2] == true, "command output did not complete: " .. tostring(closed[3]) .. " " .. tostring(closed[4]))
	return lines
end

return M
