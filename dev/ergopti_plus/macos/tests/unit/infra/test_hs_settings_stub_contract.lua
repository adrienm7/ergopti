--- tests/unit/infra/test_hs_settings_stub_contract.lua

--- ==============================================================================
--- MODULE: Hammerspoon Settings Stub Snapshot Contract
--- DESCRIPTION:
--- Models valid acyclic settings values converted through Hammerspoon 1.1.1's
--- LuaSkin bridge. Writes snapshot Lua values; each read returns a new graph,
--- sharing equal native arrays or objects only inside that read.
--- ==============================================================================

local helpers = require("tests.helpers")

local function settings()
	local stub = dofile("tests/stubs/hs.lua")
	return stub.settings
end

helpers.describe("hs.settings stub: native snapshot ownership", function()
	helpers.it("snapshots writes and returns independent reads with native void set", function()
		local store = settings()
		local source = { nested = { "saved" }, enabled = true, count = 3 }
		helpers.assert_eq(select("#", store.set("snapshot", source)), 0,
			"native settings.set returns no values")
		source.nested[1] = "unsaved source change"
		source.extra = "not saved"
		local first = store.get("snapshot")
		helpers.assert_eq(first.nested[1], "saved", "set owns the persisted snapshot")
		helpers.assert_nil(first.extra)
		local second = store.get("snapshot")
		helpers.assert_true(first ~= second and first.nested ~= second.nested,
			"every native read converts into a fresh Lua graph")
		first.nested[1] = "unsaved read change"
		first.count = 9
		helpers.assert_eq(second.nested[1], "saved")
		helpers.assert_eq(store.get("snapshot").count, 3)
		store.set("snapshot", nil)
		helpers.assert_nil(store.get("snapshot"), "nil clears the stored value")
	end)

	helpers.it("acknowledges clear only when an ordinary stored key existed", function()
		local store = settings()
		helpers.assert_eq(store.clear("missing"), false, "native clear distinguishes absence")
		store.set("false_value", false)
		helpers.assert_eq(store.clear("false_value"), true, "a stored false is still an existing key")
		helpers.assert_nil(store.get("false_value"))
		helpers.assert_eq(store.clear("false_value"), false, "the second clear reports absence")
	end)

	helpers.it("shares equal arrays and objects within a read, never across reads", function()
		local store = settings()
		store.set("equal", {
			first = { options = { "same", 1 } },
			second = { options = { "same", 1.0 } },
			different = { options = { "other", 1 } },
		})
		local first, second = store.get("equal"), store.get("equal")
		helpers.assert_true(first.first == first.second,
			"LuaSkin's native-object equality cache reuses equal objects")
		helpers.assert_true(first.first.options == first.second.options,
			"equal integer and floating-point values share their native array")
		helpers.assert_true(first.first ~= first.different)
		helpers.assert_true(first.first ~= second.first)
		first.first.options[1] = "changed"
		helpers.assert_eq(first.second.options[1], "changed", "within-read aliasing remains visible")
		helpers.assert_eq(second.first.options[1], "same")
		helpers.assert_eq(store.get("equal").first.options[1], "same")
	end)
end)
