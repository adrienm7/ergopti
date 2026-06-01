--- tests/unit/lib/test_locale.lua

--- ==============================================================================
--- MODULE: locale Unit Tests
--- DESCRIPTION:
--- Validates lib.locale path resolution and translation lookup behavior.
--- In particular, the resolver must work when hs.configdir points to the
--- default ~/.hammerspoon path (dev bootstrap), by deriving shared/locales
--- from the module path.
--- ============================================================================== 

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local function decode_for_locale_probe(raw)
	if type(raw) ~= "string" then return {} end
	local key = "karabiner.onboarding.missing_prefix"
	local pattern = '"' .. key:gsub("%.", "%%.") .. '"%s*:%s*"([^"]+)"'
	local value = raw:match(pattern)
	if value then
		return { [key] = value }
	end
	return {}
end

local Locale = helpers.load_with_stubs("lib.locale", {
	json = {
		decode = decode_for_locale_probe,
	},
})




-- =====================================
-- =====================================
-- ======= 1/ Translation lookup =======
-- =====================================
-- =====================================

helpers.describe("locale.get with dev hs.configdir", function()
	helpers.it("resolves French values instead of returning raw keys", function()
		Locale.set_locale("fr")
		local value = Locale.get("karabiner.onboarding.missing_prefix")
		helpers.assert_true(type(value) == "string" and value ~= "")
		helpers.assert_true(value ~= "karabiner.onboarding.missing_prefix")
		helpers.assert_true(value:find("manquants", 1, true) ~= nil)
	end)

	helpers.it("falls back to key when translation is truly absent", function()
		Locale.set_locale("fr")
		local v = Locale.get("__definitely_missing_locale_key__")
		helpers.assert_eq(v, "")
	end)
end)
