--- tests/unit/modules/keymap/registry/test_registry_owned_debt_recovery.lua

--- A refused settings inverse must keep the prior registry view and lease.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keymap.registry.registry_mutation_transactions_fixture")

helpers.describe("section settings owned rollback", function()
 helpers.it("retains the logical state and excludes same-value writers until retry", function()
  local _, registry = Fixture.fresh_registry()
  registry.register_lua_group("owned", "Owned", { { name = "section" } })
  local storage = require("adapters.storage")
  local key = registry.section_setting_key("owned", "section")
  helpers.assert_true(storage.set(key, false))
  local original_restore = storage.restore_owned
  local inverse_allowed = false
  storage.restore_owned = function(...)
   if not inverse_allowed then return false end
   return original_restore(...)
  end
  local changes = { { name = "owned", sections = { "section" } } }
  helpers.assert_eq(registry.set_groups_sections_enabled(changes, true, function() return false end), false)
  helpers.assert_eq(registry.is_section_enabled("owned", "section"), false,
   "failed publication must expose the prior logical choice while inverse is pending")
  helpers.assert_eq(storage.set(key, true), false, "another writer cannot claim the same value during rollback")
  helpers.assert_eq(registry.migrate_legacy_section_settings(), false, "another mutation waits for the inverse")
  inverse_allowed = true
  helpers.assert_true(registry.migrate_legacy_section_settings(), "the next mutation retries the exact inverse")
  helpers.assert_eq(storage.get(key), false)
  helpers.assert_eq(registry.is_section_enabled("owned", "section"), false)
  helpers.assert_true(registry.set_groups_sections_enabled(changes, true))
  helpers.assert_eq(registry.is_section_enabled("owned", "section"), true)
  storage.restore_owned = original_restore
 end)
 helpers.it("blocks batches while an interrupted legacy migration awaits its inverse", function()
  local _, registry = Fixture.fresh_registry()
  registry.register_lua_group("pack", "Pack", { { name = "section" } })
  local storage = require("adapters.storage")
  local key = registry.section_setting_key("pack", "section")
  helpers.assert_true(storage.set(registry.legacy_section_setting_key("pack", "section"), true))
  local publish, restore = storage.publish_owned, storage.restore_owned
  local allowed, fail_publish = false, true
  storage.publish_owned = function(...)
   local committed = publish(...)
   if committed and fail_publish then return false end
   return committed
  end
  storage.restore_owned = function(...)
   if not allowed then return false end
   return restore(...)
  end
  helpers.assert_eq(registry.migrate_legacy_section_settings(), false)
  helpers.assert_eq(registry.is_section_enabled("pack", "section"), true)
  helpers.assert_eq(storage.set(key, true), false, "another writer cannot claim the migrated value")
  helpers.assert_eq(registry.set_sections_enabled("pack", { "section" }, false), false)
  allowed = true
  fail_publish = false
  helpers.assert_true(registry.migrate_legacy_section_settings())
  helpers.assert_eq(registry.is_section_enabled("pack", "section"), true)
  storage.restore_owned = restore
  storage.publish_owned = publish
 end)

 helpers.it("preserves the prior projection while a failed group reload awaits rollback", function()
  local _, registry = Fixture.fresh_registry()
  registry.register_lua_group("owned", "Owned", { { name = "section" } })
  local storage = require("adapters.storage")
  local key = registry.section_setting_key("owned", "section")
  helpers.assert_true(storage.set(key, false))
  helpers.assert_true(registry.disable_group("owned"))
  registry.set_post_load_hook("owned", function() error("injected group reload failure") end)
  local original = storage.restore_owned
  local allowed = false
  storage.restore_owned = function(...) if not allowed then return false end; return original(...) end
  local saved = { hotstrings = { owned = true }, section_states = { owned = { section = true } } }
  helpers.assert_eq(registry.apply_hotstring_preferences(saved), false)
  helpers.assert_eq(registry.is_group_enabled("owned"), false)
  helpers.assert_eq(registry.is_section_enabled("owned", "section"), false)
  helpers.assert_eq(storage.set(key, true), false)
  helpers.assert_eq(registry.set_sections_enabled("owned", { "section" }, true), false)
  allowed = true
  helpers.assert_true(registry.migrate_legacy_section_settings())
  helpers.assert_eq(storage.get(key), false)
  helpers.assert_eq(registry.is_section_enabled("owned", "section"), false)
  storage.restore_owned = original
 end)

 helpers.it("retains committed state while cleanup is refused and retries it before another edit", function()
  local _, registry = Fixture.fresh_registry()
  registry.register_lua_group("owned", "Owned", { { name = "section" } })
  local storage = require("adapters.storage")
  local key = registry.section_setting_key("owned", "section")
  helpers.assert_true(storage.set(key, false))
  local original = storage.forget_owned
  local allowed = false
  storage.forget_owned = function(...) if not allowed then return false end; return original(...) end
  helpers.assert_true(registry.set_sections_enabled("owned", { "section" }, true),
   "post-commit cleanup failure cannot retract an accepted change")
  helpers.assert_eq(registry.is_section_enabled("owned", "section"), true)
  helpers.assert_eq(registry.set_sections_enabled("owned", { "section" }, false), false)
  helpers.assert_eq(registry.is_section_enabled("owned", "section"), true)
  allowed = true
  helpers.assert_true(registry.set_sections_enabled("owned", { "section" }, false))
  helpers.assert_eq(registry.is_section_enabled("owned", "section"), false)
  storage.forget_owned = original
 end)

end)
