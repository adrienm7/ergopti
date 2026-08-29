--- tests/unit/modules/llm/test_profiles.lua

--- ==============================================================================
--- MODULE: llm.profiles Unit Tests
--- DESCRIPTION:
--- Validates the profile registry: built-in profile shape, user profile merging,
--- legacy id auto-migration, and resolve_system_prompt placeholder substitution
--- (including the {min_words}/{max_words} settings injection).
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- Stub lib.i18n: profiles.lua calls i18n.get() at module load time to
-- decorate each built-in profile with its label. The real lib.i18n depends
-- on hs.settings and locale JSON files that are unavailable in unit tests.
package.loaded["infra.i18n"] = {
	get        = function(key) return key end,
	get_locale = function() return "fr" end,
}

--- Stub Paths so that any load of api_remote (or catalogue users) can resolve
--- _shared/modules/llm/*.json from the real source tree during headless test runs.
package.loaded["infra.paths"] = {
	shared = function(rel) return helpers.shared(rel) end,
	shared_root = function() return helpers.shared() end,
	shared_llm_path = function(name)
		return helpers.shared("modules/llm/" .. name)
	end,
}

--- Provide a minimal llm.init stub with the DEFAULT_STATE the resolve code expects
--- (some test paths + dynamic require inside resolve_system_prompt hit it).
package.loaded["modules.llm.init"] = {
	DEFAULT_STATE = {
		llm_min_words = 4,
		llm_max_words = 20,
	},
}

local Profiles = helpers.load_with_stubs("modules.llm.profiles")




-- =====================================
-- =====================================
-- ======= 1/ Built-in registry =========
-- =====================================
-- =====================================

helpers.describe("Profiles.BUILTIN_PROFILES", function()
	helpers.it("contains the four canonical built-ins", function()
		local ids = {}
		for _, p in ipairs(Profiles.BUILTIN_PROFILES) do ids[p.id] = true end
		helpers.assert_true(ids.raw)
		helpers.assert_true(ids.basic)
		helpers.assert_true(ids.advanced)
		helpers.assert_true(ids.batch_advanced)
	end)

	helpers.it("each built-in has the required shape", function()
		for _, p in ipairs(Profiles.BUILTIN_PROFILES) do
			helpers.assert_true(type(p.id) == "string" and p.id ~= "")
			helpers.assert_true(type(p.label) == "string" and p.label ~= "")
			helpers.assert_true(p.batch == true or p.batch == false)
		end
	end)

	helpers.it("only batch_advanced carries a multi-prediction template", function()
		-- The legacy ``system_multi`` function field was replaced by the
		-- JSON-shaped ``system_multi_template`` string (with a ``{n}``
		-- placeholder) when profiles.lua started loading the shared
		-- ``_shared/modules/llm/profiles.json``. Only the batch profile defines it.
		for _, p in ipairs(Profiles.BUILTIN_PROFILES) do
			if p.id == "batch_advanced" then
				helpers.assert_eq(type(p.system_multi_template), "string")
				helpers.assert_true(p.system_multi_template:find("{n}", 1, true) ~= nil)
			else
				helpers.assert_true(p.system_multi_template == nil)
			end
		end
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ get_all_profiles =========
-- =====================================
-- =====================================

helpers.describe("Profiles.get_all_profiles", function()
	helpers.it("returns built-ins when no user profiles", function()
		local all = Profiles.get_all_profiles(nil)
		helpers.assert_eq(#all, #Profiles.BUILTIN_PROFILES)
	end)

	helpers.it("appends user profiles after built-ins", function()
		local user = { { id = "myprof", label = "Mine" } }
		local all = Profiles.get_all_profiles(user)
		helpers.assert_eq(#all, #Profiles.BUILTIN_PROFILES + 1)
		helpers.assert_eq(all[#all].id, "myprof")
	end)

	helpers.it("ignores non-table user input", function()
		local all = Profiles.get_all_profiles("not a table")
		helpers.assert_eq(#all, #Profiles.BUILTIN_PROFILES)
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 3/ get_active_profile ============
-- ==========================================
-- ==========================================

helpers.describe("Profiles.get_active_profile", function()
	helpers.it("returns the matching built-in by id", function()
		local p = Profiles.get_active_profile("advanced", nil)
		helpers.assert_eq(p.id, "advanced")
	end)

	helpers.it("falls back to basic when id is unknown", function()
		local p = Profiles.get_active_profile("nonexistent", nil)
		helpers.assert_eq(p.id, "basic")
	end)

	helpers.it("auto-migrates legacy 'parallel' to 'basic'", function()
		local p = Profiles.get_active_profile("parallel", nil)
		helpers.assert_eq(p.id, "basic")
	end)

	helpers.it("auto-migrates legacy 'batch' to 'batch_advanced'", function()
		local p = Profiles.get_active_profile("batch", nil)
		helpers.assert_eq(p.id, "batch_advanced")
	end)

	helpers.it("auto-migrates legacy 'parallel_advanced' to 'advanced'", function()
		local p = Profiles.get_active_profile("parallel_advanced", nil)
		helpers.assert_eq(p.id, "advanced")
	end)

	helpers.it("auto-migrates legacy 'base_completion' to 'raw'", function()
		local p = Profiles.get_active_profile("base_completion", nil)
		helpers.assert_eq(p.id, "raw")
	end)

	helpers.it("returns user profile when id matches a user one", function()
		local user = { { id = "custom", label = "C", system_single = "X" } }
		local p = Profiles.get_active_profile("custom", user)
		helpers.assert_eq(p.id, "custom")
	end)

	-- Profiles resolve prompt text from configuration; nothing here decides
	-- whether a request is made. All three cases below stated that with
	-- assert_true(true) and a sentence, one of them around a 120-iteration loop
	-- whose results were discarded.
	helpers.it("resolves without consulting pause state (project_suspend_pause_invariant)", function()
		-- A pause check here would mean the profile a resumed session gets depends
		-- on when it was asked, which is exactly the kind of state a pure resolver
		-- must not carry.
		local src = helpers.read_driver_source("function M.resolve_system_prompt")
		helpers.assert_true(src ~= nil, "modules/llm/profiles.lua source must be locatable")
		helpers.assert_true(src:find("paus") == nil,
			"profile resolution must stay pure — the gate belongs to the caller that would send")
		helpers.assert_true(src:find("suspend") == nil, "same for suspend")
	end)

	helpers.it("resolution is referentially transparent over 120 calls", function()
		-- The loop is the point of the original case; what it was missing is
		-- reading the answers. A resolver that drifted after N calls — a cache
		-- keyed on the wrong thing, a mutated default — would have passed before.
		local first = Profiles.get_active_profile("basic", nil)
		helpers.assert_true(first ~= nil, "the basic profile must resolve")
		for _ = 1, 120 do
			local p = Profiles.get_active_profile("basic", nil)
			helpers.assert_eq(p.id, first.id,
				"asking 120 times must give the same profile — a resolver that drifts changes what "
					.. "the model is told mid-session, with nothing in the logs to say so")
		end
	end)

	helpers.it("reuses the loaded catalogue without reopening profiles.json", function()
		local original_open = io.open
		local open_calls = 0
		local ok, detail = xpcall(function()
			io.open = function(...)
				open_calls = open_calls + 1
				return original_open(...)
			end

			local first = Profiles.get_active_profile("basic", nil)
			helpers.assert_eq(first.id, "basic")
			local calls_after_first = open_calls

			local second = Profiles.get_active_profile("basic", nil)
			helpers.assert_eq(second.id, "basic")
			helpers.assert_eq(open_calls, calls_after_first,
				"a repeated hot-path lookup must not reopen profiles.json")
			helpers.assert_eq(open_calls, 0,
				"the module-load catalogue must serve every active-profile lookup")
		end, debug.traceback)
		io.open = original_open
		if not ok then error(detail, 0) end
	end)

	helpers.it("an unknown profile id resolves to something usable rather than nil", function()
		-- The old case claimed legacy-id migration was "idempotent and leaks no
		-- PII" and asserted true. What the caller actually depends on is that an
		-- id it no longer recognises still yields a profile: the prompt builder
		-- indexes the result immediately.
		local p = Profiles.get_active_profile("a_profile_id_from_two_versions_ago", nil)
		helpers.assert_true(p ~= nil, "an unknown id must fall back to a real profile, not nil")
		helpers.assert_eq(type(p.id), "string", "and it must carry an id the caller can log")
	end)
end)





--- ========================================
--- ========================================
--- ======= 4/ resolve_system_prompt =======
--- ========================================
--- ========================================

helpers.describe("Profiles.resolve_system_prompt", function()
	helpers.it("substitutes {min_words} and {max_words} from settings", function()
		_G.hs.settings.set("ergopti.llm_min_words", 7)
		_G.hs.settings.set("ergopti.llm_max_words", 13)
		local profile = { system_single = "min={min_words} max={max_words}" }
		local prompt = Profiles.resolve_system_prompt(profile, 1)
		helpers.assert_true(prompt:find("min=7") ~= nil)
		helpers.assert_true(prompt:find("max=13") ~= nil)
	end)

	helpers.it("uses 'illimité' when max_words is 0", function()
		_G.hs.settings.set("ergopti.llm_min_words", 5)
		_G.hs.settings.set("ergopti.llm_max_words", 0)
		local profile = { system_single = "max={max_words}" }
		local prompt = Profiles.resolve_system_prompt(profile, 1)
		helpers.assert_true(prompt:find("illimité") ~= nil)
	end)

	helpers.it("clamps max_words below min_words to min_words", function()
		_G.hs.settings.set("ergopti.llm_min_words", 10)
		_G.hs.settings.set("ergopti.llm_max_words", 5)
		local profile = { system_single = "min={min_words} max={max_words}" }
		local prompt = Profiles.resolve_system_prompt(profile, 1)
		helpers.assert_true(prompt:find("min=10") ~= nil)
		helpers.assert_true(prompt:find("max=10") ~= nil)
	end)

	helpers.it("uses raw_prompt verbatim when present and non-empty", function()
		local profile = { raw_prompt = "JUST CONTEXT" }
		local prompt = Profiles.resolve_system_prompt(profile, 1)
		helpers.assert_eq(prompt, "JUST CONTEXT")
	end)

	helpers.it("uses shared selector for multi-template n>1", function()
		-- The shared selector's batch/footer path requires batch = true (its
		-- documented contract, matching the JS + Lua self-test vectors); the
		-- macOS wrapper passes the profile through verbatim without synthesising it.
		local profile = {
			batch = true,
			system_single = "BASE",
			system_multi_template = "FOOTER n={n}",
		}
		local prompt = Profiles.resolve_system_prompt(profile, 3)
		helpers.assert_true(prompt:find("BASE") ~= nil)
		helpers.assert_true(prompt:find("FOOTER n=3") ~= nil)
	end)

	helpers.it("uses system_single when n = 1", function()
		local profile = {
			system_single = "SINGLE",
			system_multi = function() return "SHOULD NOT FIRE" end,
		}
		local prompt = Profiles.resolve_system_prompt(profile, 1)
		helpers.assert_eq(prompt, "SINGLE")
	end)

	helpers.it("falls back when profile is not a table", function()
		local prompt = Profiles.resolve_system_prompt(nil, 1)
		helpers.assert_true(type(prompt) == "string" and prompt ~= "")
	end)

	helpers.it("resolves every placeholder and warns on degraded fallback", function()
		local Logger = require("infra.logger")
		local original_warn = Logger.warn
		local warnings = {}
		local ok, detail = xpcall(function()
			Logger.warn = function(module_name, message)
				warnings[#warnings + 1] = {
					module_name = module_name,
					message = message,
				}
			end

			local profile = Profiles.get_active_profile("basic", {
				{ id = "basic", batch = false },
			})
			local prompt = Profiles.resolve_system_prompt(profile, 1)
			helpers.assert_true(type(prompt) == "string" and prompt ~= "",
				"a malformed user override must still produce a usable fallback")
			helpers.assert_nil(prompt:find("{", 1, true),
				"the model must never receive a literal fallback placeholder")
		end, debug.traceback)
		Logger.warn = original_warn
		if not ok then error(detail, 0) end

		helpers.assert_eq(#warnings, 1,
			"the degraded prompt branch must emit one warning")
		helpers.assert_eq(warnings[1].module_name, "llm.profiles")
		helpers.assert_contains(warnings[1].message, "degraded prompt fallback")
	end)
end)





--- =================================================
--- =================================================
--- ======= 5/ word-bound single-source guard =======
--- =================================================
--- =================================================

helpers.describe("Profiles._resolve_word_bounds (single source, no divergent fallback)", function()
	local function no_setting() return nil end

	helpers.it("reads min/max from DEFAULT_STATE (the canonical source)", function()
		local min_w, max_w = Profiles._resolve_word_bounds(
			{ llm_min_words = 3, llm_max_words = 15 }, no_setting)
		helpers.assert_eq(min_w, 3)
		helpers.assert_eq(max_w, 15)
	end)

	helpers.it("a live user setting overrides the canonical default", function()
		local get = function(k) return (k == "llm_min_words") and "5" or nil end
		local min_w, max_w = Profiles._resolve_word_bounds(
			{ llm_min_words = 3, llm_max_words = 15 }, get)
		helpers.assert_eq(min_w, 5)
		helpers.assert_eq(max_w, 15)
	end)

	-- Regression: when DEFAULT_STATE is missing the keys (e.g. the LLM module
	-- failed to load defaults.json), the resolver MUST NOT invent the old
	-- divergent literals 4/20 — it returns nil and logs an error (fail loud).
	helpers.it("never substitutes the divergent 4/20 literals when DEFAULT_STATE is empty", function()
		local min_w, max_w = Profiles._resolve_word_bounds({}, no_setting)
		helpers.assert_true(min_w ~= 4, "min_w must not be the old hardcoded 4")
		helpers.assert_true(max_w ~= 20, "max_w must not be the old hardcoded 20")
		helpers.assert_nil(min_w, "min_w should be nil when no canonical source is available")
		helpers.assert_nil(max_w, "max_w should be nil when no canonical source is available")
	end)
end)
