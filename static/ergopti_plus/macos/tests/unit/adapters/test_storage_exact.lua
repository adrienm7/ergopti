--- tests/unit/adapters/test_storage_exact.lua

--- ==============================================================================
--- MODULE: Exact Storage Operation Behavioral Tests
--- DESCRIPTION:
--- Verifies that transactional callers can distinguish an absent setting from
--- a native read failure, and can observe whether a native delete completed.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Exact Storage Operations =======
-- ===========================================
-- ===========================================

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
		local store = { ["ergopti.present"] = "value" }
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function(key) store[key] = nil end,
				get = function(key) return store[key] end,
			},
		})

		helpers.assert_true(adapter.delete_exact("present"),
			"a completed native delete must report success")
		helpers.assert_eq(nil, store["ergopti.present"],
			"the exact delete must remove the stored value")
		helpers.assert_true(adapter.delete_exact("already_missing"),
			"deleting an absent key must remain idempotent")

		local noop_store = { ["ergopti.present"] = "value" }
		local noop_adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function() end,
				get = function(key) return noop_store[key] end,
			},
		})
		helpers.assert_eq(false, noop_adapter.delete_exact("present"),
			"a no-op native clear must fail exact readback")
		helpers.assert_eq("value", noop_store["ergopti.present"],
			"the causal fixture must prove that the key remained present")

		local failing_adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				clear = function() error("synthetic settings delete failure") end,
			},
		})
		helpers.assert_eq(false, failing_adapter.delete_exact("present"),
			"a thrown native delete must be observable")
	end)

	helpers.it("treats explicit native false as a refused write or delete", function()
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function() return false end,
				clear = function() return false end,
				get = function() return "unchanged" end,
			},
		})
		helpers.assert_eq(adapter.set("owned", "candidate"), false)
		helpers.assert_eq(adapter.delete("owned"), false)
		helpers.assert_eq(adapter.delete_exact("owned"), false)
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 2/ Physical Namespace Isolation =======
-- ===============================================
-- ===============================================

helpers.describe("Storage physical namespace isolation", function()
	helpers.it("maps logical keys into ergopti.* and never exposes foreign settings", function()
		local store = {
			["ergopti.owned"] = "old",
			foreign_extension = "must-survive",
		}
		local clears = {}
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function(key, value) store[key] = value end,
				get = function(key) return store[key] end,
				clear = function(key)
					clears[#clears + 1] = key
					store[key] = nil
				end,
				getKeys = function()
					return {
						[1] = "ergopti.owned",
						[2] = "foreign_extension",
						["ergopti.owned"] = true,
						foreign_extension = true,
					}
				end,
			},
		})

		helpers.assert_true(adapter.set("owned", "new"))
		helpers.assert_eq(store["ergopti.owned"], "new",
			"the native store must receive only the namespaced physical key")
		helpers.assert_nil(store.owned,
			"the logical key must never leak into Hammerspoon's global domain")
		helpers.assert_eq(adapter.get("owned"), "new")
		local keys = adapter.keys()
		helpers.assert_eq(#keys, 1,
			"the hybrid native key list must be deduplicated and foreign keys filtered")
		helpers.assert_eq(keys[1], "owned")
		helpers.assert_true(adapter.clear(), "owned settings must clear exactly")
		helpers.assert_eq(#clears, 1)
		helpers.assert_eq(clears[1], "ergopti.owned")
		helpers.assert_eq(store.foreign_extension, "must-survive",
			"clear() must not erase another Hammerspoon configuration's setting")
	end)

	helpers.it("rejects physical keys and reports a refused owned clear", function()
		local store = { ["ergopti.owned"] = "value" }
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function(key, value) store[key] = value end,
				get = function(key) return store[key] end,
				clear = function() end,
				getKeys = function() return { "ergopti.owned" } end,
			},
		})

		helpers.assert_eq(adapter.set("ergopti.escape", "bad"), false,
			"callers must not bypass the logical namespace boundary")
		helpers.assert_eq(adapter.read_exact("ergopti.escape"), false)
		helpers.assert_eq(adapter.delete_exact("ergopti.escape"), false)
		helpers.assert_eq(adapter.clear(), false,
			"clear must fail closed when exact native readback refuses deletion")
		helpers.assert_eq(store["ergopti.owned"], "value")
	end)

	helpers.it("migrates only allowlisted legacy owners and commits the marker last", function()
		local store = {
			i18n_locale = "fr",
			keyboard_shortcut_cmd_a = "open_app",
			foreign_extension = "must-survive",
			["ergopti.llm_backend"] = "mlx",
			llm_backend = "ollama",
		}
		local writes = {}
		local adapter = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function(key, value)
					writes[#writes + 1] = key
					store[key] = value
				end,
				get = function(key) return store[key] end,
				clear = function(key) store[key] = nil end,
				getKeys = function()
					local keys = {}
					for key in pairs(store) do keys[#keys + 1] = key end
					return keys
				end,
			},
		})

		helpers.assert_true(adapter.migrate_legacy_namespace())
		helpers.assert_eq(store["ergopti.i18n_locale"], "fr")
		helpers.assert_eq(store["ergopti.keyboard_shortcut_cmd_a"], "open_app")
		helpers.assert_eq(store["ergopti.llm_backend"], "mlx",
			"an existing namespaced value must win over its legacy twin")
		helpers.assert_nil(store.i18n_locale)
		helpers.assert_nil(store.keyboard_shortcut_cmd_a)
		helpers.assert_nil(store.llm_backend)
		helpers.assert_eq(store.foreign_extension, "must-survive")
		helpers.assert_eq(writes[#writes], "ergopti.settings_namespace_migration_v1",
			"the migration marker must publish only after every legacy owner settles")
	end)

	helpers.it("keeps migration debt retryable until write and clear readback settle", function()
		local function native_keys(store)
			local keys = {}
			for key in pairs(store) do keys[#keys + 1] = key end
			return keys
		end

		local refused_write_store = { i18n_locale = "fr" }
		local refused_write = helpers.load_with_stubs("adapters.storage", {
			settings = {
				set = function(key, value)
					if key ~= "ergopti.i18n_locale" then refused_write_store[key] = value end
				end,
				get = function(key) return refused_write_store[key] end,
				clear = function(key) refused_write_store[key] = nil end,
				getKeys = function() return native_keys(refused_write_store) end,
			},
		})
		helpers.assert_eq(refused_write.migrate_legacy_namespace(), false)
		helpers.assert_eq(refused_write_store.i18n_locale, "fr")
		helpers.assert_nil(refused_write_store["ergopti.i18n_locale"])
		helpers.assert_nil(refused_write_store["ergopti.settings_namespace_migration_v1"],
			"a refused target write must not publish the migration marker")

		local refused_clear_store = { i18n_locale = "fr" }
		local settings = {
			set = function(key, value) refused_clear_store[key] = value end,
			get = function(key) return refused_clear_store[key] end,
			clear = function() end,
			getKeys = function() return native_keys(refused_clear_store) end,
		}
		local refused_clear = helpers.load_with_stubs("adapters.storage", { settings = settings })
		helpers.assert_eq(refused_clear.migrate_legacy_namespace(), false)
		helpers.assert_eq(refused_clear_store.i18n_locale, "fr")
		helpers.assert_eq(refused_clear_store["ergopti.i18n_locale"], "fr")
		helpers.assert_nil(refused_clear_store["ergopti.settings_namespace_migration_v1"],
			"a refused legacy clear must leave the migration retryable")

		settings.clear = function(key) refused_clear_store[key] = nil end
		helpers.assert_true(refused_clear.migrate_legacy_namespace())
		helpers.assert_nil(refused_clear_store.i18n_locale)
		helpers.assert_eq(refused_clear_store["ergopti.i18n_locale"], "fr")
		helpers.assert_eq(refused_clear_store["ergopti.settings_namespace_migration_v1"], true)
	end)
end)
