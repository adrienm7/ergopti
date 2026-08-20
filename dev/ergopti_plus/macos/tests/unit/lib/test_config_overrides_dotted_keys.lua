--- tests/unit/lib/test_config_overrides_dotted_keys.lua

--- ==============================================================================
--- MODULE: Config Overrides — Dotted Keys Regression Test
--- DESCRIPTION:
--- Regression test asserting that bare dotted keys under [features] (e.g.
--- `llm.enabled = true`) are accepted by M.apply() and forwarded verbatim to
--- hs.settings.set. Before the fix, the key pattern rejected dots and silently
--- dropped every dotted entry; this test encodes that exact failure mode so the
--- bug can never silently return.
---
--- FEATURES & RATIONALE:
--- 1. Isolated Store: Overrides hs.settings with an in-memory table to make the
---    calls from M.apply() fully observable without touching real hs.settings.
--- 2. Targeted Assertion: Checks both the returned count and the stored value so
---    any regression in either the parsing step or the write step is caught.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Override hs.settings with a local in-memory store so we can inspect exactly
-- what M.apply() passed to hs.settings.set without touching the canonical stub.
-- The canonical SETTINGS_STORE is restored at the end of this file.
local stored = {}
_G.hs = _G.hs or {}
local _ORIGINAL_SETTINGS = _G.hs.settings
_G.hs.settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

local Overrides = helpers.load_with_stubs("infra.config_overrides")
-- helpers.load_with_stubs may call __reset() which reinstalls the canonical
-- hs.settings stub; re-apply the inspectable override so the suites below
-- still write into the local `stored` table.
_G.hs.settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}





-- ===========================================================
-- ===========================================================
-- ======= 1/ Dotted-Key Regression (features section) =======
-- ===========================================================
-- ===========================================================

helpers.describe("config_overrides.apply — dotted keys in [features]", function()

	-- Helper: write content to a temp file, run apply(), then clean up
	local function with_tmp(content, fn)
		local path = os.tmpname()
		local fh = io.open(path, "w")
		fh:write(content)
		fh:close()
		fn(path)
		os.remove(path)
	end

	helpers.it("applies a bare dotted key under [features] to hs.settings", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		with_tmp("[features]\nllm.enabled = true\n", function(path)
			local applied = Overrides.apply(path)

			-- The return value must reflect at least one applied override
			helpers.assert_true(applied >= 1, "applied count")

			-- The exact key must be forwarded verbatim — no stripping of dots
			helpers.assert_eq(stored["llm.enabled"], true, "stored value for llm.enabled")
		end)
	end)


	helpers.it("applies multiple dotted keys in a single [features] block", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		with_tmp("[features]\nllm.enabled = true\nllm.temperature = 0.7\n", function(path)
			local applied = Overrides.apply(path)

			helpers.assert_eq(applied, 2, "applied count for two dotted keys")
			helpers.assert_eq(stored["llm.enabled"],     true, "llm.enabled")
			helpers.assert_eq(stored["llm.temperature"], 0.7,  "llm.temperature")
		end)
	end)


	helpers.it("does not apply dotted keys that belong to an unknown section", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		-- [unknown] must be silently ignored; [features] entry must still land
		with_tmp("[unknown]\nllm.enabled = false\n\n[features]\nllm.debug = true\n", function(path)
			local applied = Overrides.apply(path)

			helpers.assert_eq(applied, 1, "only the [features] entry is counted")
			helpers.assert_eq(stored["llm.debug"],   true, "llm.debug written")
			helpers.assert_eq(stored["llm.enabled"], nil,  "unknown section entry ignored")
		end)
	end)

end)


-- Restore the canonical hs.settings so subsequent test files loaded in the
-- same runner process do not observe the local `stored` table instead of the
-- shared SETTINGS_STORE from the canonical stub.
if _ORIGINAL_SETTINGS then
	_G.hs.settings = _ORIGINAL_SETTINGS
end
