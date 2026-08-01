--- tests/unit/meta/test_i18n_persistence.lua
---
--- Integration tests for i18n locale persistence and discovery.
--- Verifies that the i18n module loads, persists locale changes via storage,
--- discovers available locale files, and exposes the expected API surface.

local helpers = require("tests.helpers")

helpers.describe("i18n persistence", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("i18n exports the expected methods", function()
      local i18n = helpers.load_module("infra.i18n")
      helpers.assert_true(type(i18n.get)         == "function", "get")
      helpers.assert_true(type(i18n.get_locale)  == "function", "get_locale")
      helpers.assert_true(type(i18n.set_locale)  == "function", "set_locale")
      helpers.assert_true(type(i18n.list_locales)== "function", "list_locales")
      helpers.assert_true(type(i18n.display_name)== "function", "display_name")
      helpers.assert_true(type(i18n.set_trigger_provider) == "function", "set_trigger_provider")
      helpers.assert_true(type(i18n.init)        == "function", "init")
    end)

    helpers.it("locale module exports set_trigger_provider", function()
      local loc = helpers.load_module("infra.locale")
      helpers.assert_true(type(loc.set_trigger_provider) == "function", "locale.set_trigger_provider")
    end)
  end)

  -- ==========================================================================
  -- 2. Locale discovery
  -- ==========================================================================

  helpers.describe("locale discovery", function()
    helpers.it("list_locales returns at least fr and en", function()
      local i18n = helpers.load_module("infra.i18n")
      i18n.init()
      local codes = i18n.list_locales()
      helpers.assert_true(type(codes) == "table" and #codes >= 2,
        string.format("list_locales: at least 2 codes (got %d)", #codes))

      -- fr and en should always be present.
      local has_fr = false
      local has_en = false
      for _, c in ipairs(codes) do
        if c == "fr" then has_fr = true end
        if c == "en" then has_en = true end
      end
      helpers.assert_true(has_fr, "fr is in available locales")
      helpers.assert_true(has_en, "en is in available locales")
    end)

    helpers.it("display_name returns human-readable names for known codes", function()
      local i18n = helpers.load_module("infra.i18n")
      helpers.assert_eq(i18n.display_name("fr"), "Français", "fr → Français")
      helpers.assert_eq(i18n.display_name("en"), "English",  "en → English")
      helpers.assert_eq(i18n.display_name("de"), "Deutsch",  "de → Deutsch")
    end)

    helpers.it("display_name returns code as-is for unknown locales", function()
      local i18n = helpers.load_module("infra.i18n")
      helpers.assert_eq(i18n.display_name("xx_UNKNOWN"), "xx_UNKNOWN",
        "unknown code returned as-is")
    end)
  end)

  -- ==========================================================================
  -- 3. Locale persistence (storage adapter)
  -- ==========================================================================

  helpers.describe("locale persistence", function()
    helpers.it("set_locale + get_locale round-trips", function()
      local i18n = helpers.load_module("infra.i18n")
      i18n.init()
      local before = i18n.get_locale()
      helpers.assert_true(type(before) == "string" and #before > 0,
        string.format("initial locale: %s", tostring(before)))

      -- Switch to "en" and verify.
      i18n.set_locale("en")
      helpers.assert_eq(i18n.get_locale(), "en", "locale changed to en")

      -- Switch back to the original and ensure it persists.
      i18n.set_locale(before)
      helpers.assert_eq(i18n.get_locale(), before, "locale restored")
    end)

    -- Cleanup: ensure "fr" is the default for subsequent tests.
    helpers.it("_cleanup_reset_locale_to_fr", function()
      local i18n = helpers.load_module("infra.i18n")
      i18n.init()
      i18n.set_locale("fr")
    end)

    helpers.it("set_locale with unknown code is ignored", function()
      local i18n = helpers.load_module("infra.i18n")
      i18n.init()
      local before = i18n.get_locale()
      i18n.set_locale("xx_ZZ_INVALID")
      helpers.assert_eq(i18n.get_locale(), before,
        "locale unchanged after invalid code")
    end)

    helpers.it("set_locale with nil/empty is safe", function()
      local i18n = helpers.load_module("infra.i18n")
      i18n.init()
      local before = i18n.get_locale()
      i18n.set_locale(nil)
      helpers.assert_eq(i18n.get_locale(), before, "nil does not change locale")
      i18n.set_locale("")
      helpers.assert_eq(i18n.get_locale(), before, "empty string does not change locale")
    end)
  end)

  -- ==========================================================================
  -- 4. Trigger provider
  -- ==========================================================================

  helpers.describe("trigger provider", function()
    helpers.it("set_trigger_provider does not crash", function()
      local i18n = helpers.load_module("infra.i18n")
      local ok = pcall(function()
        i18n.set_trigger_provider(function() return "\\" end)
      end)
      helpers.assert_true(ok, "set_trigger_provider does not crash")
    end)

    helpers.it("set_trigger_provider with nil is safe", function()
      local loc = helpers.load_module("infra.locale")
      local ok = pcall(function()
        loc.set_trigger_provider(nil)
      end)
      helpers.assert_true(ok, "nil trigger provider is safe")
    end)
  end)

  -- ==========================================================================
  -- 5. Menu builder language submenu
  -- ==========================================================================

  helpers.describe("menu language submenu", function()
    helpers.it("language submenu items have callbacks and valid shape", function()
      local mb = helpers.load_module("modules.menu.menu_builder")
      local items = mb.build({ _version = "test", on_quit = function() end })

      local lang_section = nil
      for _, item in ipairs(items) do
        if type(item.title) == "string" and (
          item.title:find("Langue", 1, true) or item.title:find("Language", 1, true)
        ) then
          lang_section = item
          break
        end
      end

      helpers.assert_true(lang_section ~= nil, "Language section present")
      if lang_section then
        helpers.assert_true(type(lang_section.menu) == "table" and #lang_section.menu >= 2,
          string.format("Language submenu has %d items", #(lang_section.menu or {})))
        for _, sub in ipairs(lang_section.menu) do
          helpers.assert_true(type(sub.fn) == "function",
            "Language item '" .. (sub.title or "?") .. "' has callback")
        end
      end
    end)
  end)

end)
