--- modules/llm/bootstrap_output.lua

--- ==============================================================================
--- MODULE: Bootstrap Output Framing
--- DESCRIPTION:
--- Reassembles the two native task streams before interpreting installer
--- markers or presenting diagnostics. Read callbacks do not delimit lines;
--- each task owns its partial lines until completion flushes them.
--- ==============================================================================

local M = {}

--- Creates one framer for one bootstrap task.
--- @return function frame Accepts stdout, stderr and a terminal flag; returns complete output for each stream.
function M.new()
	local pending = { stdout = "", stderr = "" }

	local function consume(chunk, stream, terminal)
		local text = pending[stream] .. (chunk or "")
		if terminal == true then
			pending[stream] = ""
			return text
		end
		local complete, partial = text:match("^(.*[\r\n])(.-)$")
		pending[stream] = partial or text
		return complete or ""
	end

	return function(stdout, stderr, terminal)
		return consume(stdout, "stdout", terminal), consume(stderr, "stderr", terminal)
	end
end

return M
