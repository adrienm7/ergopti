--- tests/unit/meta/test_tray_protocol.lua

local helpers = require("tests.helpers")
local TP      = helpers.load_module("linux.tray_protocol")

helpers.describe("linux.tray_protocol", function()

  -- ==========================================================================
  -- 1. build_menu_item_xml()
  -- ==========================================================================

  helpers.describe("build_menu_item_xml()", function()
    helpers.it("returns empty string for non-table input", function()
      helpers.assert_eq(TP.build_menu_item_xml(nil, 1), "")
    end)

    helpers.it("generates separator item", function()
      local xml = TP.build_menu_item_xml({ separator = true }, 5)
      helpers.assert_true(xml:find('id="5"'), "has id")
      helpers.assert_true(xml:find("separator"), "has separator type")
    end)

    helpers.it("generates standard item with title and enabled", function()
      local xml = TP.build_menu_item_xml({ title = "Options", enabled = true }, 1)
      helpers.assert_true(xml:find("Options"), "has title")
      helpers.assert_true(xml:find("standard"), "has standard type")
      helpers.assert_true(xml:find('value="true"'), "enabled = true")
    end)

    helpers.it("generates disabled item", function()
      local xml = TP.build_menu_item_xml({ title = "Greyed", enabled = false }, 1)
      helpers.assert_true(xml:find('value="false"'), "enabled = false")
    end)

    helpers.it("generates checked/checkmark item", function()
      local xml = TP.build_menu_item_xml({ title = "Toggle", checked = true }, 1)
      helpers.assert_true(xml:find("checkmark"), "has checkmark type")
      helpers.assert_true(xml:find("toggle-state", 1, true), "has toggle-state")
    end)

    helpers.it("generates item with sub-items (recursive)", function()
      local xml = TP.build_menu_item_xml({
        title = "Parent",
        items = {
          { title = "Child A", enabled = true },
          { title = "Child B", checked = true },
        },
      }, 1)
      helpers.assert_true(xml:find("Parent"), "has parent title")
      helpers.assert_true(xml:find("Child A"), "has child A")
      helpers.assert_true(xml:find("Child B"), "has child B")
      helpers.assert_true(xml:find("submenu"), "has children-display submenu")
      -- Child IDs are parent_id * 1000 + child_index
      helpers.assert_true(xml:find('id="1001"'), "child A has nested id")
      helpers.assert_true(xml:find('id="1002"'), "child B has nested id")
    end)

    helpers.it("escapes XML special characters in title", function()
      local xml = TP.build_menu_item_xml({ title = 'A & B < C > "D"' }, 1)
      helpers.assert_true(xml:find("A &amp; B &lt; C &gt; &quot;D&quot;"), "XML chars escaped")
    end)

    helpers.it("defaults title to empty string when missing", function()
      local xml = TP.build_menu_item_xml({}, 1)
      helpers.assert_true(xml:find('label') and xml:find('value=""'), "empty label")
    end)
  end)

  -- ==========================================================================
  -- 2. build_dbus_menu_xml()
  -- ==========================================================================

  helpers.describe("build_dbus_menu_xml()", function()
    helpers.it("returns empty string for non-table input", function()
      helpers.assert_eq(TP.build_dbus_menu_xml(nil), "")
    end)

    helpers.it("wraps items in D-Bus menu root XML", function()
      local xml = TP.build_dbus_menu_xml({
        { title = "Item 1", enabled = true },
      })
      helpers.assert_true(xml:find('<?xml version="1.0"'), "has XML declaration")
      helpers.assert_true(xml:find('/MenuBar'), "has MenuBar node")
      helpers.assert_true(xml:find("com.canonical.dbusmenu", 1, true), "has dbusmenu interface")
      helpers.assert_true(xml:find("Item 1"), "has item content")
    end)

    helpers.it("generates XML for multiple items", function()
      local xml = TP.build_dbus_menu_xml({
        { title = "Enable All", checked = true },
        { separator = true },
        { title = "Quit", enabled = true },
      })
      helpers.assert_true(xml:find("Enable All"), "has first item")
      helpers.assert_true(xml:find("separator"), "has separator")
      helpers.assert_true(xml:find("Quit"), "has last item")
    end)

    helpers.it("generates well-formed XML with proper nesting", function()
      local xml = TP.build_dbus_menu_xml({
        { title = "Settings", enabled = true },
      })
      -- Count opening/closing tags balance
      local open_menu   = select(2, xml:gsub("<menu", ""))
      local close_menu  = select(2, xml:gsub("</menu>", ""))
      helpers.assert_eq(open_menu, close_menu, "menu tags balanced")
    end)
  end)

  -- ==========================================================================
  -- 3. build_notify_send_cmd()
  -- ==========================================================================

  helpers.describe("build_notify_send_cmd()", function()
    helpers.it("builds a basic notify-send command", function()
      local cmd = TP.build_notify_send_cmd("Title", "Body text")
      helpers.assert_true(cmd:find("notify-send", 1, true), "starts with notify-send")
      helpers.assert_true(cmd:find("Title", 1, true), "has title")
      helpers.assert_true(cmd:find("Body text", 1, true), "has body")
      helpers.assert_true(cmd:find("--urgency=normal", 1, true), "default urgency is normal")
    end)

    helpers.it("uses correct urgency for warn", function()
      local cmd = TP.build_notify_send_cmd("T", "B", "warn")
      helpers.assert_true(cmd:find("--urgency=normal", 1, true), "warn → normal")
    end)

    helpers.it("uses critical urgency for error", function()
      local cmd = TP.build_notify_send_cmd("T", "B", "error")
      helpers.assert_true(cmd:find("--urgency=critical", 1, true), "error → critical")
    end)

    helpers.it("escapes single quotes in title and body", function()
      local cmd = TP.build_notify_send_cmd("It's broken", "Don't panic")
      -- The escaping should produce valid shell syntax
      helpers.assert_true(cmd:find("It", 1, true), "has title start")
      helpers.assert_true(cmd:find("panic", 1, true), "has body end")
      helpers.assert_true(cmd:find("'\\''s", 1, true), "has escaped 's")
    end)
  end)

  -- ==========================================================================
  -- 4. build_zenity_tooltip_cmd()
  -- ==========================================================================

  helpers.describe("build_zenity_tooltip_cmd()", function()
    helpers.it("builds a basic zenity --info command", function()
      local cmd = TP.build_zenity_tooltip_cmd("Hello tooltip")
      helpers.assert_true(cmd:find("zenity --info", 1, true), "starts with zenity")
      helpers.assert_true(cmd:find("ergopti", 1, true), "has title")
      helpers.assert_true(cmd:find("Hello tooltip", 1, true), "has text")
    end)

    helpers.it("respects custom timeout", function()
      local cmd = TP.build_zenity_tooltip_cmd("Hi", 5000)
      helpers.assert_true(cmd:find("--timeout=5", 1, true), "5000ms → 5s timeout")
    end)

    helpers.it("truncates text to 500 chars", function()
      local long = string.rep("x", 1000)
      local cmd = TP.build_zenity_tooltip_cmd(long, 2000)
      -- The text argument should be ≤ 500 chars
      -- Extract the text between single quotes after --text=
      local text = cmd:match("--text='([^']+)'")
      helpers.assert_true(text ~= nil and #text <= 505, "text is truncated")
    end)
  end)

  -- ==========================================================================
  -- 5. build_gdbus_set_cmd()
  -- ==========================================================================

  helpers.describe("build_gdbus_set_cmd()", function()
    helpers.it("builds a gdbus property set command", function()
      local cmd = TP.build_gdbus_set_cmd(
        "org.kde.StatusNotifierItem-1-1",
        "/StatusNotifierItem",
        "Title",
        "s",
        '"Ergopti"'
      )
      helpers.assert_true(cmd:find("gdbus call --session", 1, true), "has gdbus call")
      helpers.assert_true(cmd:find("StatusNotifierItem-1-1", 1, true), "has bus name")
      helpers.assert_true(cmd:find("/StatusNotifierItem", 1, true), "has object path")
      helpers.assert_true(cmd:find("Properties.Set", 1, true), "has Properties.Set method")
      helpers.assert_true(cmd:find("Title", 1, true), "has property name")
      helpers.assert_true(cmd:find('"Ergopti"', 1, true), "has value")
    end)
  end)

  -- ==========================================================================
  -- 6. build_sni_register_cmd()
  -- ==========================================================================

  helpers.describe("build_sni_register_cmd()", function()
    helpers.it("builds a RegisterStatusNotifierItem command", function()
      local cmd = TP.build_sni_register_cmd("ergopti.Service", "/StatusNotifierItem")
      helpers.assert_true(cmd:find("gdbus call --session", 1, true), "has gdbus call")
      helpers.assert_true(cmd:find("StatusNotifierWatcher", 1, true), "has watcher")
      helpers.assert_true(cmd:find("RegisterStatusNotifierItem", 1, true), "has register method")
      helpers.assert_true(cmd:find("ergopti.Service", 1, true), "has service name")
    end)
  end)

  -- ==========================================================================
  -- 7. resolve_tray_icon()
  -- ==========================================================================

  helpers.describe("resolve_tray_icon()", function()
    helpers.it("returns a string (even if empty)", function()
      local path = TP.resolve_tray_icon(".")
      helpers.assert_true(type(path) == "string", "returns string")
    end)

    helpers.it("returns empty when no icon files exist", function()
      -- /tmp should have no ergopti tray icons
      local path = TP.resolve_tray_icon("/tmp")
      helpers.assert_eq(path, "")
    end)

    helpers.it("normalizes separators in candidate paths", function()
      -- Just verify it doesn't crash with backslash paths
      local ok = pcall(TP.resolve_tray_icon, "C:\\nonexistent")
      helpers.assert_true(ok, "does not crash on Windows paths")
    end)
  end)

  -- ==========================================================================
  -- 8. KIND_URGENCY mapping
  -- ==========================================================================

  helpers.describe("KIND_URGENCY", function()
    helpers.it("maps known severity levels", function()
      helpers.assert_eq(TP.KIND_URGENCY.info, "normal")
      helpers.assert_eq(TP.KIND_URGENCY.warn, "normal")
      helpers.assert_eq(TP.KIND_URGENCY.error, "critical")
    end)
  end)

end)
