--- tests/unit/modules/llm/test_profiles.lua

--- ==============================================================================
--- MODULE: llm.profiles Unit Tests
--- DESCRIPTION:
--- Validates the profile registry: built-in profile shape, user profile merging,
--- legacy id auto-migration, and resolve_system_prompt placeholder substitution
--- (including the {min_words}/{max_words} settings injection).
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- Stub lib.i18n: profiles.lua calls i18n.get() at module load time to
-- decorate each built-in profile with its label. The real lib.i18n depends
-- on hs.settings and locale JSON files that are unavailable in unit tests.
package.loaded["lib.i18n"] = {
	get        = function(key) return key end,
	get_locale = function() return "fr" end,
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
		-- ``shared/llm/profiles.json``. Only the batch profile defines it.
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
end)





-- =====================================
--- ========================================
--- ======= 4/ resolve_system_prompt =======
--- ========================================
-- =====================================

helpers.describe("Profiles.resolve_system_prompt", function()
	helpers.it("substitutes {min_words} and {max_words} from settings", function()
		_G.hs.settings.set("llm_min_words", 7)
		_G.hs.settings.set("llm_max_words", 13)
		local profile = { system_single = "min={min_words} max={max_words}" }
		local prompt = Profiles.resolve_system_prompt(profile, 1)
		helpers.assert_true(prompt:find("min=7") ~= nil)
		helpers.assert_true(prompt:find("max=13") ~= nil)
	end)

	helpers.it("uses 'illimité' when max_words is 0", function()
		_G.hs.settings.set("llm_min_words", 5)
		_G.hs.settings.set("llm_max_words", 0)
		local profile = { system_single = "max={max_words}" }
		local prompt = Profiles.resolve_system_prompt(profile, 1)
		helpers.assert_true(prompt:find("illimité") ~= nil)
	end)

	helpers.it("clamps max_words below min_words to min_words", function()
		_G.hs.settings.set("llm_min_words", 10)
		_G.hs.settings.set("llm_max_words", 5)
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

	helpers.it("invokes system_multi when n > 1", function()
		local profile = {
			system_single = "ignored",
			system_multi = function(n) return "MULTI " .. tostring(n) end,
		}
		local prompt = Profiles.resolve_system_prompt(profile, 3)
		helpers.assert_true(prompt:find("MULTI 3") ~= nil)
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
end)
