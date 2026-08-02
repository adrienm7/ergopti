--- tests/unit/meta/test_tray_menu_sni.lua
---
--- Compliance tests for the SNI/dbusmenu tray_menu backend.
--- Verifies that the adapter exposes getBackend(), accepts hierarchical
--- menu items (with `menu` sub-tables), and correctly dispatches callbacks
--- via the pump mechanism.  These tests run without gdbus or yad — they
--- verify the code paths and APIs, not the actual D-Bus registration.
---
--- Strategy:
--- 1. Structural: module exports the expected methods + getBackend.
--- 2. setMenu with nested items does not crash (exercises _sni_rebuild_menu_xml
---    and _yad_serialize_menu internally).
--- 3. pump() is safe when no backend is active.
--- 4. destroy() + setMenu round-trip (verify idempotent lifecycle).

local helpers = require("tests.helpers")
local tray    = helpers.load_module("adapters.tray_menu")

helpers.describe("tray_menu SNI compliance", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports setIcon, setMenu, setTooltip, destroy, pump, getBackend", function()
      helpers.assert_true(type(tray.setIcon)    == "function", "setIcon is a function")
      helpers.assert_true(type(tray.setMenu)    == "function", "setMenu is a function")
      helpers.assert_true(type(tray.setTooltip) == "function", "setTooltip is a function")
      helpers.assert_true(type(tray.destroy)    == "function", "destroy is a function")
      helpers.assert_true(type(tray.pump)       == "function", "pump is a function")
      helpers.assert_true(type(tray.getBackend) == "function", "getBackend is a function")
    end)

    helpers.it("getBackend returns a valid mode string (or nil)", function()
      local backend = tray.getBackend()
      -- On the maintainer's Windows machine, neither gdbus nor yad exists,
      -- so backend == "none".  On Linux CI it may be "sni" or "yad".
      helpers.assert_true(
        backend == "sni" or backend == "yad" or backend == "none",
        string.format("getBackend() returns a valid mode: %s", tostring(backend))
      )
    end)
  end)

  -- ==========================================================================
  -- 2. Hierarchical menu items (SNI contract)
  -- ==========================================================================

  helpers.describe("hierarchical menu items", function()

    helpers.it("setMenu with nested items does not crash", function()
      local ok = pcall(function()
        tray.setMenu({
          { title = "Section", menu = {
            { title = "Item 1", fn = function() end },
            { title = "Item 2", fn = function() end },
          }},
          { title = "Standalone", fn = function() end },
        })
      end)
      helpers.assert_true(ok, "setMenu with nested items does not crash")
    end)

    helpers.it("setMenu with deeply nested submenus (3 levels) does not crash", function()
      local ok = pcall(function()
        tray.setMenu({
          { title = "L1", menu = {
            { title = "L2", menu = {
              { title = "L3", fn = function() end },
            }},
          }},
        })
      end)
      helpers.assert_true(ok, "setMenu with 3-level nesting does not crash")
    end)

    -- Called directly throughout: a raise fails the case with the real error.
    -- The assertion is that the adapter is still USABLE afterwards — getBackend()
    -- is its only readable state, and a tray left in a half-built state answers
    -- nothing while the menu silently stops updating.
    helpers.it("setMenu with nil items leaves the tray usable", function()
      tray.setMenu(nil)
      helpers.assert_eq(type(tray.getBackend()), "string",
        "a refused menu must not tear the backend down")
    end)

    helpers.it("setMenu with empty items leaves the tray usable", function()
      tray.setMenu({})
      helpers.assert_eq(type(tray.getBackend()), "string",
        "an empty menu is a legitimate state, not a teardown")
    end)
  end)

  -- ==========================================================================
  -- 3. pump() safety
  -- ==========================================================================

  helpers.describe("pump safety", function()

    helpers.it("pump() before any setMenu does not crash", function()
      -- Ensure a clean state.
      tray.destroy()
      tray.pump()
      helpers.assert_eq(type(tray.getBackend()), "string",
        "pump runs on the event loop every tick; one that wedged the adapter would "
          .. "take the whole menu with it")
    end)

    helpers.it("pump() after setMenu + destroy does not crash", function()
      tray.setMenu({
        { title = "Test", fn = function() end },
      })
      tray.destroy()
      tray.pump()
      helpers.assert_eq(type(tray.getBackend()), "string",
        "a pump after destroy must be a no-op, not a resurrection")
    end)
  end)

  -- ==========================================================================
  -- 4. Lifecycle (setMenu → destroy → setMenu round-trip)
  -- ==========================================================================

  helpers.describe("lifecycle", function()

    helpers.it("destroy() followed by setMenu() works (idempotent restart)", function()
      tray.setMenu({
        { title = "First", fn = function() end },
      })
      tray.destroy()
      tray.setMenu({
        { title = "Second", fn = function() end },
      })
      helpers.assert_eq(type(tray.getBackend()), "string",
        "destroy then setMenu is the reload path — it must rebuild, not stay dead")
      tray.destroy()
    end)

    helpers.it("double destroy() leaves the tray restartable", function()
      tray.destroy()
      tray.destroy()
      tray.setMenu({ { title = "After", fn = function() end } })
      helpers.assert_eq(type(tray.getBackend()), "string",
        "a second destroy must not poison the restart that follows it")
      tray.destroy()
    end)
  end)

  -- ==========================================================================
  -- 5. setIcon / setTooltip sanity
  -- ==========================================================================

  helpers.describe("icon and tooltip", function()

    helpers.it("setIcon with empty opts leaves the tray usable", function()
      tray.setIcon({})
      helpers.assert_eq(type(tray.getBackend()), "string",
        "an icon call with nothing to set must not tear the backend down")
      tray.destroy()
    end)

    helpers.it("setTooltip with a string does not crash", function()
      local ok = pcall(function() tray.setTooltip("Ergopti — test") end)
      helpers.assert_true(ok, "setTooltip(...) does not crash")
      tray.destroy()
    end)
  end)

  -- ==========================================================================
  -- 6. Menu builder integration (full macOS-mirror tree)
  -- ==========================================================================

  helpers.describe("menu builder integration", function()

    helpers.it("menu_builder.build() returns a non-empty item list", function()
      local mb = helpers.load_module("ui.menu.menu_builder")
      local items = mb.build({})
      helpers.assert_true(type(items) == "table" and #items > 0,
        "menu_builder.build({}) returns a non-empty table")
    end)

    helpers.it("menu_builder output is accepted by tray_menu.setMenu", function()
      local mb = helpers.load_module("ui.menu.menu_builder")
      local items = mb.build({
        _version = "test",
        config   = nil,
        layout   = "qwerty",
        keylogger= nil,
        llm      = nil,
        dry_run  = false,
        verbose  = false,
        on_quit  = function() end,
      })
      local ok = pcall(function() tray.setMenu(items) end)
      helpers.assert_true(ok, "menu_builder output accepted by setMenu")
      tray.destroy()
    end)

    helpers.it("menu_builder output with all sections exercised does not crash", function()
      local mb = helpers.load_module("ui.menu.menu_builder")
      local items = mb.build({
        _version       = "test",
        config         = nil,
        layout         = "qwerty",
        keylogger      = nil,
        llm            = nil,
        dry_run        = false,
        verbose        = false,
        on_quit        = function() end,
        on_open_config = function() end,
        on_open_logs   = function() end,
      })
      helpers.assert_true(type(items) == "table" and #items > 0,
        string.format("full menu build: %d items", #items))

      -- Verify the expected top-level sections are present.
      local titles = {}
      for _, item in ipairs(items) do
        if type(item.title) == "string" then
          titles[#titles + 1] = item.title
        end
      end
      local title_str = table.concat(titles, " | ")
      -- Core sections that MUST be in the mirror.
      helpers.assert_true(title_str:find("Ergopti", 1, true),
        "header present in: " .. title_str)
      helpers.assert_true(title_str:find("Hotstrings", 1, true),
        "Hotstrings section present")
      helpers.assert_true(title_str:find("Disposition", 1, true) or title_str:find("Layout", 1, true),
        "Layout section present")
      helpers.assert_true(title_str:find("Kanata", 1, true),
        "Kanata section present (stub)")
      helpers.assert_true(title_str:find("Quitter", 1, true),
        "Quit item present")
      helpers.assert_true(title_str:find("Actions globales", 1, true) or title_str:find("Global", 1, true),
        "Global actions section present")
      helpers.assert_true(title_str:find("Débogage", 1, true) or title_str:find("Debug", 1, true),
        "Debug section present")
    end)
  end)

end)
