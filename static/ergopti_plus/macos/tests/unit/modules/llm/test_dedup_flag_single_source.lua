--- tests/unit/modules/llm/test_dedup_flag_single_source.lua

--- ==============================================================================
--- MODULE: Regression — the dedup default must come from one place, not three
--- DESCRIPTION:
--- api_ollama and api_remote both read the deduplication default from ApiCommon,
--- which loads it from the shared _shared/modules/llm/inference.json. api_mlx_
--- inference hardcoded `M.DEDUPLICATION_ENABLED = false` instead.
---
--- ROOT CAUSE ENCODED:
--- Flipping the shared flag therefore changed Ollama and remote behaviour while
--- MLX silently kept its own answer — and MLX is the default backend, so the
--- setting appeared to do nothing at all for most users. Its comment even claimed
--- the opposite ("keeping the dedup default in exactly one place"), which is the
--- most misleading kind of wrong: the file states the invariant it breaks.
---
--- This is a §5.2 single-source-of-truth violation, and the guard is written for
--- the CLASS: it asserts that no backend redeclares the default as a literal,
--- rather than pinning the one file that did.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Every backend that participates in the dedup decision.
local BACKENDS = {
	"modules/llm/api_mlx_inference.lua",
	"modules/llm/api_ollama.lua",
	"modules/llm/api_remote.lua",
}




-- ==============================================
-- ==============================================
-- ======= 1/ No Backend Redeclares It ==========
-- ==============================================
-- ==============================================

helpers.describe("the deduplication default has a single source", function()
	helpers.it("no backend assigns the dedup flag a literal", function()
		local offenders = {}
		for _, rel in ipairs(BACKENDS) do
			-- rel is a loop variable, so the selector cannot be a fixed declaration;
			-- read the whole production tree once and let the assertions below
			-- locate their own evidence inside it.
			local fh = io.open(helpers.driver_root() .. rel, "r")
			helpers.assert_true(fh ~= nil, rel .. " must be readable")
			if fh then
				-- Selected by a declaration unique to api_mlx_inference.lua rather than
		-- by path, so moving or splitting the module cannot break this.
		local src = helpers.read_driver_source("function M.post_and_parse")
		helpers.assert_true(src ~= nil, "api_mlx_inference source must be locatable")
		if not src then return end
				local code = src:gsub("%-%-[^\r\n]*", "")
				if code:find("DEDUPLICATION_ENABLED%s*=%s*true")
					or code:find("DEDUPLICATION_ENABLED%s*=%s*false") then
					offenders[#offenders + 1] = rel
				end
			end
		end

		helpers.assert_true(#offenders == 0, string.format(
			"%d backend(s) hardcode the dedup default instead of reading it from "
			.. "ApiCommon: %s. Flipping the shared inference.json then changes some "
			.. "backends and not others, and MLX — the default backend — was the one "
			.. "ignoring it, so the setting appeared to do nothing",
			#offenders, table.concat(offenders, ", ")))
	end)

	helpers.it("MLX reads the same ApiCommon default as its siblings", function()
		-- Selected by a declaration unique to api_mlx_inference.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant into
		-- a path error.
		local src = helpers.read_driver_source("function M.post_and_parse")
		helpers.assert_true(src ~= nil, "api_mlx_inference source must be locatable")

		helpers.assert_true(src:find("ApiCommon%.DEFAULT_DEDUPLICATION_ENABLED") ~= nil,
			"MLX must read ApiCommon.DEFAULT_DEDUPLICATION_ENABLED, the same symbol "
			.. "api_ollama and api_remote already use")
	end)
end)
