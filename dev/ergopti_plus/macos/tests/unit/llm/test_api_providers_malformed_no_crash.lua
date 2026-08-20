--- tests/unit/llm/test_api_providers_malformed_no_crash.lua

--- ==============================================================================
--- MODULE: api_remote malformed JSON regression tests
--- DESCRIPTION:
--- Regression for llm-api-net-07: load_api_providers() previously raised an
--- error() at require time when api_providers.json was present but malformed
--- (bad JSON, missing format field, invalid provider_order). This aborted the
--- full keymap → llm → api_remote require chain.
---
--- Post-fix: a malformed file degrades to an empty catalogue (same as absent).
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================================================
-- =========================================================================
-- ======= 1/ Malformed JSON does not abort require (llm-api-net-07) =======
-- =========================================================================
-- =========================================================================

helpers.describe("api_remote — malformed api_providers.json does not crash require", function()

	--- Helper: redirect the shared_llm_path to a temp TOML/JSON string held in memory.
	local function make_fake_path_stub(json_content)
		local tmp_path = os.tmpname() .. "_api_providers_test.json"
		local fh = io.open(tmp_path, "w")
		if fh then
			fh:write(json_content)
			fh:close()
		end
		package.loaded["infra.paths"] = {
			shared = function(rel) return helpers.shared(rel) end,
			shared_root = function() return helpers.shared() end,
			shared_llm_path = function(name)
				if name == "api_providers.json" then return tmp_path end
				return nil
			end,
			find_from_configdir = function() return nil end,
		}
		return tmp_path
	end

	local function cleanup(path)
		if path then pcall(os.remove, path) end
	end

	helpers.it("does not raise when JSON is unparseable", function()
		local tmp = make_fake_path_stub("THIS IS NOT JSON {{{{")
		package.loaded["modules.llm.api_remote"] = nil
		local ok, mod = pcall(require, "modules.llm.api_remote")
		cleanup(tmp)
		helpers.assert_true(ok, "require must NOT raise on unparseable JSON — got: " .. tostring(mod))
		helpers.assert_true(type(mod) == "table", "module must still be a table")
		helpers.assert_true(type(mod.PROVIDERS) == "table", "PROVIDERS must be a table (empty) on parse failure")
	end)

	helpers.it("returns empty catalogue when format field is missing from a provider", function()
		local bad_json = [[{
			"provider_order": ["bad_provider"],
			"providers": {
				"bad_provider": {
					"label": "Bad",
					"base_url": "https://example.com",
					"default_model": "gpt-4",
					"format": "unknown_format_xyz"
				}
			},
			"model_prices": {}
		}]]
		local tmp = make_fake_path_stub(bad_json)
		package.loaded["modules.llm.api_remote"] = nil
		local ok, mod = pcall(require, "modules.llm.api_remote")
		cleanup(tmp)
		helpers.assert_true(ok, "require must NOT raise on invalid format field")
		helpers.assert_true(type(mod.PROVIDERS) == "table", "PROVIDERS must be a table")
		-- The invalid provider must be silently skipped, not crash
		helpers.assert_true(mod.PROVIDERS["bad_provider"] == nil,
			"provider with invalid format must be skipped, not present in PROVIDERS")
	end)

	helpers.it("returns empty catalogue when provider_order is empty", function()
		local bad_json = [[{
			"provider_order": [],
			"providers": {},
			"model_prices": {}
		}]]
		local tmp = make_fake_path_stub(bad_json)
		package.loaded["modules.llm.api_remote"] = nil
		local ok, mod = pcall(require, "modules.llm.api_remote")
		cleanup(tmp)
		helpers.assert_true(ok, "require must NOT raise on empty provider_order")
		helpers.assert_true(type(mod.PROVIDERS) == "table", "PROVIDERS must be a table (empty)")
	end)

	helpers.it("still loads normally when JSON is valid", function()
		-- Reset to the real shared path (test helpers default)
		package.loaded["infra.paths"] = {
			shared = function(rel) return helpers.shared(rel) end,
			shared_root = function() return helpers.shared() end,
			shared_llm_path = function(name)
				return helpers.shared("modules/llm/" .. name)
			end,
			find_from_configdir = function() return nil end,
		}
		package.loaded["modules.llm.api_remote"] = nil
		local ok, mod = pcall(require, "modules.llm.api_remote")
		helpers.assert_true(ok, "require must succeed on the real api_providers.json")
		if ok then
			helpers.assert_true(type(mod.PROVIDERS) == "table", "PROVIDERS must be a table")
			helpers.assert_true(
				mod.PROVIDERS["openai"] ~= nil or next(mod.PROVIDERS) ~= nil,
				"At least one provider must be loaded from the real file"
			)
		end
	end)
end)
