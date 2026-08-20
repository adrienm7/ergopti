--- tests/unit/adapters/test_storage_exact.lua

--- ==============================================================================
--- MODULE: Exact Storage Operation Behavioral Tests
--- DESCRIPTION:
--- Verifies that transactional callers can distinguish an absent setting from
--- a native read failure, and can observe whether a native delete completed.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ Exact Storage Operations =====
-- =========================================
-- =========================================

helpers.describe("Storage exact operations", function()
	helpers.it("read_exact preserves an absent value without reporting failure", function()
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				get = function() return nil end,
			},
		})

		local ok, value = adapter.read_exact("missing")
		helpers.assert_true(ok, "a native read of an absent key must succeed")
		helpers.assert_eq(nil, value, "an absent key must remain distinguishable as nil")
	end)

	helpers.it("read_exact reports a native read failure", function()
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				get = function() error("synthetic settings read failure") end,
			},
		})

		local ok, value = adapter.read_exact("unreadable")
		helpers.assert_eq(false, ok, "a thrown native read must be observable")
		helpers.assert_eq(nil, value, "a failed read must not manufacture a value")
	end)

	helpers.it("delete_exact distinguishes native success from failure", function()
		local store = { present = "value" }
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function(key) store[key] = nil end,
				get = function(key) return store[key] end,
			},
		})

		helpers.assert_true(adapter.delete_exact("present"),
			"a completed native delete must report success")
		helpers.assert_eq(nil, store.present, "the exact delete must remove the stored value")
		helpers.assert_true(adapter.delete_exact("already_missing"),
			"deleting an absent key must remain idempotent")

		local noop_store = { present = "value" }
		local noop_adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function() end,
				get = function(key) return noop_store[key] end,
			},
		})
		helpers.assert_eq(false, noop_adapter.delete_exact("present"),
			"a no-op native clear must fail exact readback")
		helpers.assert_eq("value", noop_store.present,
			"the causal fixture must prove that the key remained present")

		local failing_adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function() error("synthetic settings delete failure") end,
			},
		})
		helpers.assert_eq(false, failing_adapter.delete_exact("present"),
			"a thrown native delete must be observable")
	end)
end)
