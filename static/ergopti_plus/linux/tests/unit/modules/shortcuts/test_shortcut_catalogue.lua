--- tests/unit/modules/shortcuts/test_shortcut_catalogue.lua

--- ==============================================================================
--- MODULE: Shortcut Catalogue Tests (Linux)
--- DESCRIPTION:
--- Pins the shared tap-key list and action-catalogue lookup
--- (_shared/lua/shortcuts/catalogue.lua): a missing, empty or malformed list
--- raises instead of showing no key, an entry without this platform's keycodes
--- is refused, the identity is withdrawn until the owner is registered, the
--- list is cached by identity until reset, and an unavailable action catalogue
--- is logged and answered with nil.
--- ==============================================================================

local helpers = require("tests.helpers")
local Catalogue = require("shortcuts.catalogue")

local function list_over(text, owner)
	return Catalogue.new_tap_keys({
		keys_rel_path = "tap_keys.json",
		resolve_path = function(rel) return "/shared/" .. rel end,
		read = function() return text end,
		decode = function(raw)
			local ok, decoded = pcall(require("json").decode, raw)
			return ok and decoded or nil
		end,
		valid_entry = function(entry) return type(entry.id) == "string" and type(entry.code) == "number" end,
		invalid_entry_message = "lacks its id or code",
		owner = owner or {},
	})
end

helpers.describe("shortcut catalogue (Linux)", function()
	helpers.it("reads the key list once and returns the same table", function()
		local list = list_over('{"keys":[{"id":"a","code":1},{"id":"b","code":2}]}')
		local first = list.keys()
		helpers.assert_eq(#first, 2)
		helpers.assert_true(rawequal(first, list.keys()))
		helpers.assert_true(rawequal(first, list.loaded_keys()))
		list.reset()
		helpers.assert_eq(list.loaded_keys(), nil)
	end)

	for label, text in pairs({
		["malformed JSON"] = "not json",
		["an empty list"] = '{"keys":[]}',
		["no keys field"] = '{}',
	}) do
		helpers.it("raises on " .. label, function()
			local list = list_over(text)
			helpers.assert_contains(tostring(helpers.assert_throws(function() list.keys() end)), "is malformed")
		end)
	end

	helpers.it("raises on an entry without this platform's code", function()
		local list = list_over('{"keys":[{"id":"a"}]}')
		helpers.assert_contains(tostring(helpers.assert_throws(function() list.keys() end)), "lacks its id or code")
	end)

	helpers.it("names the binding of a key", function()
		local list = list_over('{"keys":[{"id":"a","code":1}]}')
		helpers.assert_eq(list.binding_id("grave"), "tap_key__grave")
	end)

	helpers.it("publishes nothing for an owner that was never registered", function()
		local list = list_over('{"keys":[{"id":"a","code":1}]}')
		list.keys()
		helpers.assert_eq(list.published_binding_catalogue(), nil)
	end)

	helpers.it("refuses a list built without its ports", function()
		helpers.assert_contains(tostring(helpers.assert_throws(function() Catalogue.new_tap_keys({}) end)), "needs the port")
	end)

	helpers.it("logs and answers nil when the action catalogue cannot load", function()
		local original = package.loaded["modules.gestures.manager"]
		package.loaded["modules.gestures.manager"] = {}
		local logged
		local ok, failure = pcall(function()
			helpers.assert_eq(Catalogue.action_catalogue({ error = function(_, fmt) logged = fmt end }, "t"), nil)
		end)
		package.loaded["modules.gestures.manager"] = original
		assert(ok, failure)
		helpers.assert_contains(logged, "action catalogue is unavailable")
	end)
end)
