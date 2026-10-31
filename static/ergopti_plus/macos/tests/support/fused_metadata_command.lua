--- tests/support/fused_metadata_command.lua

--- ==============================================================================
--- MODULE: Fused Metadata Command Double
--- DESCRIPTION:
--- The atomic writer seeds a staging inode in one forked command: the source's
--- ACL listing, a NUL, the metadata-preserving copy and a second listing, joined
--- by " && " (adapters/file_system.lua, seed_staging_metadata). The hs.execute
--- doubles answer each segment with their single-command handler, in order, and
--- stop at the first failure as the shell does, so the fixtures keep modelling
--- one ls and one cp at a time.
--- ==============================================================================

local M = {}

M.SEPARATOR = " && printf '\\000' && "

--- Whether a command is the fused metadata command.
--- @param command string
--- @return boolean
function M.is_fused(command)
	return type(command) == "string" and command:find(M.SEPARATOR, 1, true) ~= nil
end

--- Answers a fused command through a single-command handler.
--- @param command string The fused command.
--- @param execute_one function(segment) -> output, success, exit_type, rc
--- @return string output
--- @return boolean success
--- @return string exit_type
--- @return integer rc
function M.run(command, execute_one)
	local at = command:find(M.SEPARATOR, 1, true)
	local first, rest = command:sub(1, at - 1), command:sub(at + #M.SEPARATOR)
	local segments = { first, false }
	local from = 1
	while true do
		local next_at = rest:find(" && ", from, true)
		segments[#segments + 1] = rest:sub(from, (next_at or 0) - 1)
		if not next_at then break end
		from = next_at + 4
	end
	local outputs = {}
	for _, segment in ipairs(segments) do
		if segment == false then
			outputs[#outputs + 1] = "\0"
		else
			local output, success, exit_type, rc = execute_one(segment)
			if success ~= true then return table.concat(outputs) .. tostring(output or ""), success, exit_type, rc end
			outputs[#outputs + 1] = output or ""
		end
	end
	return table.concat(outputs), true, "exit", 0
end

--- Wraps a single-command handler into an hs.execute double that also answers
--- the fused command.
--- @param execute_one function(command) -> output, success, exit_type, rc
--- @return function execute
function M.answering(execute_one)
	return function(command, ...)
		if M.is_fused(command) then return M.run(command, execute_one) end
		return execute_one(command, ...)
	end
end

return M
