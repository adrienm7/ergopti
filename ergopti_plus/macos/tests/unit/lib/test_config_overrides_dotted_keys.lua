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
local test_settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

package.loaded["adapters.storage"] = nil
local Overrides = helpers.load_with_stubs("infra.config_overrides", {settings = test_settings})
-- helpers.load_with_stubs may call __reset() which reinstalls the canonical
-- hs.settings stub; re-apply the inspectable override so the suites below
-- still write into the local `stored` table.
_G.hs.settings = test_settings





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
			helpers.assert_eq(stored["ergopti.llm.enabled"], true, "stored value for llm.enabled")
		end)
	end)


	helpers.it("applies multiple dotted keys in a single [features] block", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		with_tmp("[features]\nllm.enabled = true\nllm.temperature = 0.7\n", function(path)
			local applied = Overrides.apply(path)

			helpers.assert_eq(applied, 2, "applied count for two dotted keys")
			helpers.assert_eq(stored["ergopti.llm.enabled"],     true, "llm.enabled")
			helpers.assert_eq(stored["ergopti.llm.temperature"], 0.7,  "llm.temperature")
		end)
	end)


	helpers.it("does not apply dotted keys that belong to an unknown section", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		-- [unknown] must be silently ignored; [features] entry must still land
		with_tmp("[unknown]\nllm.enabled = false\n\n[features]\nllm.debug = true\n", function(path)
			local applied = Overrides.apply(path)

			helpers.assert_eq(applied, 1, "only the [features] entry is counted")
			helpers.assert_eq(stored["ergopti.llm.debug"], true, "llm.debug written")
			helpers.assert_eq(stored["ergopti.llm.enabled"], nil, "unknown section entry ignored")
		end)
	end)

end)


helpers.describe("semantic legacy feature projection", function()
	local Codec = require("toml_codec")
	local Cleanup = require("config_unused_keys")
	local function test(name, body) helpers.it(name .. " (dotted-override-projection)", body) end
	local function with_owned_file(source, body)
		local path = os.tmpname()
		local file = assert(io.open(path, "wb"))
		assert(file:write(source)); assert(file:close())
		local ok, detail = xpcall(function() body(path) end, debug.traceback)
		os.remove(path)
		if not ok then error(detail, 0) end
	end
	test("reads and marks exact semantic feature paths for actual cleanup", function()
		stored = {}
		_G.hs.settings.set = function(key, value) stored[key] = value end
		local retained = '[features.llm]\nenabled = true\n[features."literal.dot"]\nvalue = false\n'
		local source = retained .. '[unknown]\ndrop = 1\n'
		with_owned_file(source, function(path)
			helpers.assert_eq(Overrides.apply(path), 2)
			helpers.assert_eq(stored["ergopti.llm.enabled"], true)
			helpers.assert_eq(stored["ergopti.literal.dot.value"], false)
			local observed = {}
			Overrides.mark_config_reads(Codec.decode(source), function(...) observed[#observed + 1] = { ... } end)
			helpers.assert_eq(observed, { { "features", "literal.dot", "value" }, { "features", "llm", "enabled" } })
			local consumption = Cleanup.new_consumption()
			Overrides.mark_config_reads(Codec.decode(source), consumption.mark)
			helpers.assert_eq(consumption.touches({ "features", "literal.dot", "value" }), true)
			helpers.assert_eq(consumption.touches({ "features", "literal", "dot", "value" }), false)
			local scan = Cleanup.find_in_source(source, Overrides.mark_config_reads)
			helpers.assert_eq(scan.status, "ok")
			local unused = scan.keys
			helpers.assert_eq(#unused, 1)
			helpers.assert_eq(unused[1].section, "unknown")
			helpers.assert_eq(unused[1].key, "drop")
			local candidate, removed = Cleanup.remove_from_source(source, unused)
			helpers.assert_eq(removed, 1)
			helpers.assert_eq(candidate, retained)
			local check = assert(io.open(path, "rb")); local content = check:read("*a"); check:close()
			helpers.assert_eq(content, source, "read and cleanup planning never publish")
		end)
	end)
	test("refuses projected literal and nested aliases before any setting write", function()
		for _, source in ipairs({
			'[script]\nordinary = "kept"\n[features]\nllm.enabled = true\n"llm.enabled" = false\n',
			'[script]\nordinary = "kept"\n[features]\n"llm.enabled" = false\nllm.enabled = true\n',
		}) do
			local writes, marks = {}, {}
			_G.hs.settings.set = function(key, value) writes[#writes + 1] = { key, value } end
			with_owned_file(source, function(path)
				helpers.assert_true(type(Codec.decode(source)) == "table", "TOML identities are distinct and valid")
				helpers.assert_eq(Overrides.apply(path), 0)
				Overrides.mark_config_reads(Codec.decode(source), function(...) marks[#marks + 1] = { ... } end)
				helpers.assert_eq(writes, {}, "even the earlier script section cannot publish")
				helpers.assert_eq(marks, {}, "the loader claims no refused override")
			end)
		end
	end)
	test("keeps flat script, arrays and unknown sections outside nested feature projection", function()
		stored = {}
		_G.hs.settings.set = function(key, value) stored[key] = value end
		local source = '[script]\nordinary="001"\nchild={enabled=true}\n[features]\nllm.enabled=false\nitems=[{enabled=true}]\n[unknown]\nllm.enabled=true\n'
		with_owned_file(source, function(path)
			helpers.assert_eq(Overrides.apply(path), 2)
			helpers.assert_eq(stored, { ["ergopti.ordinary"] = "001", ["ergopti.llm.enabled"] = false })
			local observed = {}
			Overrides.mark_config_reads(Codec.decode(source), function(...) observed[#observed + 1] = { ... } end)
			helpers.assert_eq(observed, { { "script", "ordinary" }, { "features", "llm", "enabled" } })
		end)
	end)
end)


package.loaded["adapters.storage"] = nil
package.loaded["infra.config_overrides"] = nil
if _ORIGINAL_SETTINGS then _G.hs.settings = _ORIGINAL_SETTINGS end
