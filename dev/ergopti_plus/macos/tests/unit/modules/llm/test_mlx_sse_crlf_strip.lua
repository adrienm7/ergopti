--- tests/unit/modules/llm/test_mlx_sse_crlf_strip.lua

--- ==============================================================================
--- MODULE: Regression — MLX SSE parser strips a trailing CR before the guard
--- DESCRIPTION:
--- Audit finding F-L3. flush_lines splits the SSE byte stream only on "\n", so a
--- CRLF-emitting mlx-lm/uvicorn build (or a proxy) delivers "data: {...}\r" to
--- process_sse_line. The early "structurally complete" guard checks the LAST char
--- is "}" or "]"; a trailing "\r" defeats it, so every chunk is dropped (DEBUG only)
--- and the stream yields no prediction. Fix: strip a trailing CR from json_str.
--- The streaming parser is a deep local; the CR-strip is pinned at source.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("MLX SSE line parser tolerates CRLF", function()
	helpers.it("strips a trailing CR from the data payload before the structural guard", function()
		local fh = assert(io.open(helpers.driver_root() .. "modules/llm/api_mlx_inference.lua", "r"))
		local src = fh:read("*a"); fh:close()
		-- The data extraction must remove a trailing CR so a CRLF line is not rejected.
		helpers.assert_true(src:find('line:sub(7):gsub("\\r$", "")', 1, true) ~= nil
			or src:find(':gsub("\\r$", "")', 1, true) ~= nil,
			"process_sse_line must strip a trailing CR (gsub) so CRLF-terminated chunks are not dropped")
	end)
end)
