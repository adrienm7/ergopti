--- tests/unit/modules/llm/test_streaming_warn_fires_for_all_backends.lua

--- ==============================================================================
--- MODULE: streaming_handler — Backend-Agnostic Failure Warning Regression Test
--- DESCRIPTION:
--- Static source-scan guard for M-14: asserts that the consecutive-failure
--- Logger.warn in streaming_handler.lua fires for ALL backends, not just MLX.
---
--- Before the fix, the Logger.warn and hs.notify calls were nested inside an
--- `if backend == "mlx"` guard, so Ollama and remote backends silently absorbed
--- repeated failures with no developer-visible warning. This test scans the
--- source text and asserts that Logger.warn appears BEFORE (outside) the mlx
--- guard block — a structural invariant that makes a regression immediately
--- visible without requiring an async HTTP integration test.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ===========================================================================
-- ===========================================================================
-- ======= 1/ Source-Scan Helpers ============================================
-- ===========================================================================
-- ===========================================================================

--- Reads the streaming_handler.lua source relative to this test file.
--- @return string Raw file content.
local function read_source()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	-- This file is under tests/unit/modules/llm/; the module is at modules/llm/
	local test_dir = src:match("^(.*)[/\\]tests[/\\]") or "."
	local path = test_dir .. "/modules/llm/streaming_handler.lua"
	local fh = io.open(path, "r")
	if not fh then
		-- Fallback: search relative to the driver root
		fh = io.open(helpers.driver_root() .. "modules/llm/streaming_handler.lua", "r")
	end
	if not fh then error("Cannot read streaming_handler.lua for source scan") end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Extracts the body of the local on_fail function from the source.
--- @param src string Full file content.
--- @return string Function body text, or empty string if not found.
local function extract_on_fail_body(src)
	-- Find the `local on_fail` declaration and collect until the closing `end`
	local start_idx = src:find("function on_fail")
	if not start_idx then return "" end
	-- Walk from there to find the matching `end` at the same nesting depth
	local pos = start_idx
	local depth = 0
	local started = false
	while pos <= #src do
		local token, token_end = src:match("([%w_]+)()", pos)
		if not token then break end
		-- Count all Lua block openers that require a closing `end`; without
		-- this, an inline `if … then return end` on the first line of on_fail
		-- would drop depth back to 0 immediately, cutting off the rest of the body.
		if token == "function" or token == "if" or token == "for" or token == "while" then
			depth = depth + 1
			started = true
		elseif token == "end" and started then
			depth = depth - 1
			if depth == 0 then
				return src:sub(start_idx, token_end - 1)
			end
		end
		pos = token_end
	end
	return src:sub(start_idx)
end




-- ===========================================================================
-- ===========================================================================
-- ======= 2/ Structural Assertions ==========================================
-- ===========================================================================
-- ===========================================================================

helpers.describe("streaming_handler — consecutive-failure warning is backend-agnostic", function()

	local src = read_source()
	local body = extract_on_fail_body(src)

	helpers.it("on_fail body exists and is non-empty", function()
		helpers.assert_true(#body > 50,
			"on_fail function body must be extractable from the source for subsequent checks")
	end)


	helpers.it("Logger.warn fires before the 'if … == mlx' guard (M-14)", function()
		-- The warn must appear before the MLX-specific notification guard so that
		-- Ollama / remote backends also receive the consecutive-failure warning.
		local warn_pos = body:find("Logger%.warn")
		local mlx_guard_pos = body:find('== "mlx"') or body:find("== 'mlx'")
		helpers.assert_true(warn_pos ~= nil,
			"Logger.warn must be present in on_fail (consecutive-failure warning)")
		if mlx_guard_pos then
			helpers.assert_true(warn_pos < mlx_guard_pos,
				"Logger.warn must appear BEFORE the 'if backend == mlx' guard so it fires for all backends (M-14 regression)")
		end
	end)


	helpers.it("hs.notify remains inside the MLX-specific guard", function()
		-- The MLX desktop notification is intentionally backend-specific (the
		-- i18n key says 'MLX'). It must stay inside the mlx guard.
		local notify_pos = body:find("hs%.notify")
		local mlx_guard_pos = body:find('== "mlx"') or body:find("== 'mlx'")
		if notify_pos and mlx_guard_pos then
			helpers.assert_true(notify_pos > mlx_guard_pos,
				"hs.notify must remain inside the MLX guard — it references MLX-specific notification text")
		end
	end)

end)
