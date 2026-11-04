--- tests/support/e2e/child_capture.lua

--- Captures fixture output after a real wait, including LuaJIT 5.1 exit status.
local M = {}
local windows = package.config:sub(1, 1) == "\\"

local function quoted(path)
	if windows then
		assert(not path:find('[%%"\r\n]'), "unsafe temporary output path")
		return '"' .. path .. '"'
	end
	return "'" .. path:gsub("'", "'\\''") .. "'"
end

--- Runs a foreground fixture, retaining private output until the process exits.
--- LuaJIT's popen.close can report true for exit 23, so it is not a wait receipt.
--- @param command string Already quoted fixture command.
--- @return string output
--- @return integer|nil exit_code Nil means a signal or inconclusive wait.
function M.run(command)
	local path = os.tmpname()
	local ran, output, first, reason, code = pcall(function()
		local file = assert(io.open(path, "wb"))
		assert(file:close())
		local result, kind, status = os.execute("(" .. command .. ") >" .. quoted(path) .. " 2>&1")
		local reader = assert(io.open(path, "rb"))
		local bytes = reader:read("*a")
		assert(reader:close())
		return bytes, result, kind, status
	end)
	local removed = os.remove(path)
	assert(removed, "could not retire private child output")
	if not ran then error(output, 0) end
	if first == true and reason == "exit" and code == 0 then return output, 0 end
	if (first == nil or first == false) and reason == "exit" and type(code) == "number" then
		return output, code
	end
	if type(first) == "number" and first >= 0 and first % 1 == 0 then
		if windows then return output, first end
		if first % 256 == 0 then return output, first / 256 end
	end
	return output, nil
end

--- Distinguishes clean scenarios from the single deliberately broken Writer.
--- A known failed SYN remains debt: process exit does not certify wire cleanup.
--- @param output string
--- @param status integer|nil Actual wait status.
--- @param injected_failure boolean Whether this scenario deliberately refuses SYN.
--- @return boolean accepted
function M.accepted(output, status, injected_failure)
	if injected_failure then
		local settled = output:match("\nE2E_EXPECTED_FAILURE injection output_debt=true signals_settled=(%a+)\n$")
		return status == 1 and (settled == "true" or settled == "false")
	end
	return status == 0 and output:match("\nE2E_CLEAN_EXIT\n$") ~= nil
end

return M
