--- tests/support/source_read_fixture.lua

--- ==============================================================================
--- MODULE: Source Read Failure Fixture
--- DESCRIPTION:
--- Models a successful two-file inventory whose second file can fail at any
--- I/O boundary. Restores global I/O hooks even when an assertion fails.
--- ==============================================================================

local M = {}

--- Runs a source collector against controlled file failures and a repair.
--- @param root string Driver root with its trailing separator.
--- @param mode string Open/read/close failure mode or empty_success.
--- @param callback function Receives paths, counters and the repaired flag.
--- @return ... Callback results.
function M.with_fault(root, mode, callback)
	local state = { paths = { root .. "a_source.lua", root .. "z_source.lua" },
		opens = {}, closes = 0, enumerations = 0, repaired = false }
	local open, popen = io.open, io.popen
	io.popen = function()
		state.enumerations = state.enumerations + 1
		local index = 0
		return {
			lines = function() return function()
				index = index + 1
				return state.paths[index]
			end end,
			close = function() return true, "exit", 0 end,
		}
	end
	io.open = function(path)
		assert(path == state.paths[1] or path == state.paths[2], "unexpected source fixture path")
		state.opens[path] = (state.opens[path] or 0) + 1
		local failing = path == state.paths[2] and not state.repaired
		local reason = "controlled " .. mode
		if failing and mode == "open_refusal" then return nil, reason end
		if failing and mode == "open_throw" then error(reason) end
		return {
			read = function()
				if failing and mode == "read_refusal" then return nil, reason end
				if failing and mode == "read_throw" then error(reason) end
				if path == state.paths[1] then return "first source" end
				return mode == "empty_success" and "" or "second source"
			end,
			close = function()
				state.closes = state.closes + 1
				if failing and mode == "close_refusal" then return nil, reason end
				if failing and mode == "close_throw" then error(reason) end
				return true
			end,
		}
	end
	local outcome = table.pack(pcall(callback, state))
	io.open, io.popen = open, popen
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return M
