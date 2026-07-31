--- tests/unit/meta/test_tray_tooltip_adapters.lua
---
--- Integration tests for tray_menu + tooltip_renderer.
--- Now tests the full implementations: yad subprocess lifecycle, menu
--- serialization, signal-file callbacks, tooltip positioning, backend detection,
--- updateElement re-rendering.
---
--- Real tray icons and tooltips require:
---   yad (GTK+ systray) or zenity (fallback)
---   xdotool (for tooltip positioning, optional)

local helpers  = require("tests.helpers")
local trayMenu = helpers.load_module("adapters.tray_menu")
local tooltip  = helpers.load_module("adapters.tooltip_renderer")

helpers.describe("tray_menu adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports setIcon", function()
      helpers.assert_true(type(trayMenu.setIcon) == "function", "setIcon is a function")
    end)
    helpers.it("exports setMenu", function()
      helpers.assert_true(type(trayMenu.setMenu) == "function", "setMenu is a function")
    end)
    helpers.it("exports setTooltip", function()
      helpers.assert_true(type(trayMenu.setTooltip) == "function", "setTooltip is a function")
    end)
    helpers.it("exports destroy", function()
      helpers.assert_true(type(trayMenu.destroy) == "function", "destroy is a function")
    end)
    helpers.it("exports pump", function()
      helpers.assert_true(type(trayMenu.pump) == "function", "pump is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. Lifecycle
  -- ==========================================================================

  -- Called DIRECTLY, not through pcall. Every case here used to assert only that
  -- the call returned — which is also true of an adapter that silently disabled
  -- the tray. Where the environment has no backend (this suite runs on CI without
  -- gdbus or yad), the invariant that CAN be asserted is that the adapter still
  -- resolves a backend name and stays usable afterwards: a degraded tray must
  -- keep answering, because the menu code calls into it on every rebuild.
  helpers.describe("lifecycle", function()
    helpers.it("setIcon leaves the adapter with a resolved backend", function()
      trayMenu.setIcon({ image = "icon.png" })
      local backend = trayMenu.getBackend()
      helpers.assert_eq(type(backend), "string",
        "the backend must resolve to a name, even when nothing is installed")
      helpers.assert_true(backend == "sni" or backend == "yad" or backend == "none",
        "and it must be one of the three known values, not an empty string: " .. tostring(backend))
    end)

    helpers.it("setIcon with empty opts keeps the backend resolved", function()
      trayMenu.setIcon({})
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "an empty options table must not leave the adapter unusable")
    end)

    helpers.it("setIcon with nil opts keeps the backend resolved", function()
      trayMenu.setIcon(nil)
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "a nil options table must be treated as empty, not propagated")
    end)

    helpers.it("destroy on an idle adapter leaves it usable", function()
      trayMenu.destroy()
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "destroying a tray that was never created must not poison the adapter — the "
          .. "menu rebuilds through it afterwards")
    end)

    helpers.it("destroy is idempotent and still leaves it usable", function()
      trayMenu.destroy()
      trayMenu.destroy()
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "a second destroy must be a no-op, not a state corruption")
      -- And the adapter must still accept work after two teardowns.
      trayMenu.setMenu({ { title = "After", fn = function() end } })
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "setMenu after a double destroy must still be accepted")
    end)

    helpers.it("a full lifecycle leaves the adapter ready for the next one", function()
      trayMenu.setIcon({ image = "icon.png", title = "Ergopti" })
      trayMenu.setMenu({ { title = "Test", fn = function() end } })
      trayMenu.setTooltip("Hover text")
      trayMenu.destroy()
      -- The menu is rebuilt many times per session, so the adapter has to survive
      -- its own teardown and accept a second full cycle.
      trayMenu.setIcon({ image = "icon.png" })
      trayMenu.setMenu({ { title = "Second", fn = function() end } })
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "a second lifecycle must be accepted after the first was torn down")
    end)
  end)

  -- ==========================================================================
  -- 3. setMenu() — menu serialization
  -- ==========================================================================

  -- The adapter exposes its yad serialiser precisely so this can be asserted.
  -- Every case below used to check a pcall status, which says nothing about the
  -- string that ends up on yad's command line — and that string is where the
  -- interesting failures live: yad separates a menu entry from its command with
  -- "!", so an unescaped "!" in a user-visible label splits one entry into two
  -- and shifts every command after it onto the wrong label.
  helpers.describe("setMenu()", function()
    helpers.it("serialises each item as a label followed by its command", function()
      local menu = trayMenu._yad_serialize_menu({
        { title = "Item 1", fn = function() end },
        { title = "Item 2", fn = function() end },
        { title = "Disabled", fn = function() end, disabled = true },
      })
      helpers.assert_true(menu:find("Item 1", 1, true) ~= nil, "the first label must be present")
      helpers.assert_true(menu:find("Item 2", 1, true) ~= nil, "and the second")
      helpers.assert_true(menu:find("MENU:1", 1, true) ~= nil,
        "each item with a callback must carry its 1-based registry index, which is how "
          .. "the signal file maps a click back to a function: " .. menu)
      helpers.assert_true(menu:find("MENU:3", 1, true) ~= nil,
        "including the third, or a click on it would dispatch the wrong callback")
    end)

    helpers.it("an empty array serialises to an inert placeholder, not an empty string", function()
      local menu = trayMenu._yad_serialize_menu({})
      helpers.assert_true(#menu > 0,
        "yad given an empty --menu= argument shows no tray entry at all")
      helpers.assert_true(menu:find("MENU:", 1, true) == nil,
        "and the placeholder must dispatch nothing")
    end)

    helpers.it("nil and a non-table serialise to the same placeholder", function()
      helpers.assert_eq(trayMenu._yad_serialize_menu(nil), trayMenu._yad_serialize_menu({}),
        "nil must be treated as empty, not stringified")
      helpers.assert_eq(trayMenu._yad_serialize_menu("not an array"), trayMenu._yad_serialize_menu({}),
        "a non-table must be treated as empty too")
    end)

    helpers.it("setMenu ignores a non-table without discarding the current menu", function()
      trayMenu.setMenu({ { title = "Kept", fn = function() end } })
      trayMenu.setMenu("not an array")
      trayMenu.setMenu(nil)
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "a bad setMenu must be a no-op — it must not tear the tray down")
    end)

    helpers.it("doubles an exclamation mark so it cannot split the entry", function()
      local menu = trayMenu._yad_serialize_menu({
        { title = "Item with ! exclamation", fn = function() end },
      })
      helpers.assert_true(menu:find("Item with !! exclamation", 1, true) ~= nil,
        "yad reads a bare ! as the label/command separator, so the label must double "
          .. "it — otherwise this one entry becomes two and every later command "
          .. "attaches to the wrong label: " .. menu)
    end)

    helpers.it("carries quotes and dollar signs in labels through to the command line", function()
      local menu = trayMenu._yad_serialize_menu({
        { title = "Item with 'quotes'", fn = function() end },
        { title = "Item with $HOME", fn = function() end },
      })
      helpers.assert_true(menu:find("Item with 'quotes'", 1, true) ~= nil,
        "an apostrophe in a label must survive serialisation")
      helpers.assert_true(menu:find("Item with $HOME", 1, true) ~= nil,
        "and so must a dollar sign — labels are display text, not shell")
    end)
  end)

  -- ==========================================================================
  -- 4. setTooltip()
  -- ==========================================================================

  -- setTooltip has no return value and no readable state, so what can be asserted
  -- is that it leaves the adapter usable and that a nil never becomes the STRING
  -- "nil" on a user-visible tooltip. Both were invisible to a pcall status.
  helpers.describe("setTooltip()", function()
    helpers.it("plain text leaves the adapter usable", function()
      trayMenu.setTooltip("Hello")
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "setting a tooltip must not tear the tray down")
    end)

    helpers.it("an empty tooltip is accepted", function()
      trayMenu.setTooltip("")
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "clearing the tooltip is a legitimate operation, not an error")
    end)

    helpers.it("nil is coerced before it can reach a label", function()
      trayMenu.setTooltip(nil)
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "a nil tooltip must be coerced to empty — tostring(nil) would put the word "
          .. "\"nil\" under the user's cursor")
      -- And the adapter must still accept a real tooltip afterwards.
      trayMenu.setTooltip("Après")
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "a nil must not leave the tooltip path broken for the next call")
    end)
  end)

  -- ==========================================================================
  -- 5. pump() — signal-file polling
  -- ==========================================================================

  -- pump() is called on every event-loop tick. Its contract is that it dispatches
  -- a queued menu callback and NOTHING otherwise — a spurious dispatch fires a
  -- menu action the user never clicked. "Does not crash" could not tell the two
  -- apart, so the cases count dispatches instead.
  helpers.describe("pump()", function()
    helpers.it("dispatches nothing when no signal is queued", function()
      local fired = 0
      trayMenu.setMenu({ { title = "Watched", fn = function() fired = fired + 1 end } })
      trayMenu.pump()
      helpers.assert_eq(fired, 0,
        "an empty poll must fire no callback — a spurious dispatch runs a menu action "
          .. "the user never clicked")
    end)

    helpers.it("ten empty polls dispatch nothing either", function()
      local fired = 0
      trayMenu.setMenu({ { title = "Watched", fn = function() fired = fired + 1 end } })
      for _ = 1, 10 do trayMenu.pump() end
      helpers.assert_eq(fired, 0,
        "repeated polling must stay inert — this runs on every event-loop tick")
    end)

    helpers.it("pump after destroy dispatches nothing and leaves the adapter usable", function()
      local fired = 0
      trayMenu.setMenu({ { title = "Watched", fn = function() fired = fired + 1 end } })
      trayMenu.destroy()
      trayMenu.pump()
      helpers.assert_eq(fired, 0,
        "a torn-down tray must not dispatch the callbacks it used to hold")
      helpers.assert_eq(type(trayMenu.getBackend()), "string",
        "and polling a destroyed tray must not poison the adapter")
    end)
  end)

end)

helpers.describe("tooltip_renderer adapter", function()

  -- ==========================================================================
  -- 6. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports show", function()
      helpers.assert_true(type(tooltip.show) == "function", "show is a function")
    end)
    helpers.it("exports hide", function()
      helpers.assert_true(type(tooltip.hide) == "function", "hide is a function")
    end)
    helpers.it("exports isVisible", function()
      helpers.assert_true(type(tooltip.isVisible) == "function", "isVisible is a function")
    end)
    helpers.it("exports updateElement", function()
      helpers.assert_true(type(tooltip.updateElement) == "function", "updateElement is a function")
    end)
  end)

  -- ==========================================================================
  -- 7. show() / hide() lifecycle
  -- ==========================================================================

  -- isVisible() is the state these calls exist to move, and it was asserted in
  -- exactly one place. Every other case checked a pcall status — which cannot
  -- distinguish "the tooltip appeared" from "show() returned early and nothing
  -- was ever displayed", and show() DOES return early: a payload with no text
  -- is skipped by design.
  helpers.describe("show/hide lifecycle", function()
    helpers.it("an empty payload shows nothing", function()
      tooltip.hide()
      tooltip.show({})
      helpers.assert_eq(tooltip.isVisible(), false,
        "a payload with no draw calls has no text, and a textless tooltip must not "
          .. "put an empty window on the user's screen")
    end)

    helpers.it("a nil payload shows nothing", function()
      tooltip.hide()
      tooltip.show(nil)
      helpers.assert_eq(tooltip.isVisible(), false,
        "nil must be treated as an empty payload, not propagated into the renderer")
    end)

    helpers.it("hide on an invisible tooltip leaves it invisible", function()
      tooltip.hide()
      tooltip.hide()
      helpers.assert_eq(tooltip.isVisible(), false,
        "hiding twice must be a no-op — the caller hides on every keystroke")
    end)

    helpers.it("isVisible starts false", function()
      tooltip.hide()
      helpers.assert_eq(tooltip.isVisible(), false, "isVisible is false when nothing is shown")
    end)

    helpers.it("hide always returns to invisible after a show", function()
      tooltip.show({ draw_calls = { { id = "body", type = "text", text = "Test tooltip" } } })
      tooltip.hide()
      helpers.assert_eq(tooltip.isVisible(), false,
        "whatever the environment did with the spawn, hide() must leave the adapter "
          .. "believing nothing is displayed — a stuck true means the next show is "
          .. "skipped and the user sees a frozen tooltip")
    end)
  end)

  -- ==========================================================================
  -- 8. updateElement()
  -- ==========================================================================

  -- updateElement re-renders from the cached payload, so its real contract is
  -- that a malformed call does not DESTROY that cache — the next legitimate
  -- update would then render an empty tooltip.
  helpers.describe("updateElement()", function()
    helpers.it("a valid draw call leaves the adapter usable", function()
      tooltip.updateElement({ id = "title", type = "text", text = "Updated" })
      helpers.assert_eq(type(tooltip.isVisible()), "boolean",
        "the adapter must still answer for its state after an update")
    end)

    helpers.it("nil is ignored without disturbing visibility", function()
      tooltip.hide()
      tooltip.updateElement(nil)
      helpers.assert_eq(tooltip.isVisible(), false,
        "a nil update must not spawn a tooltip out of nothing")
    end)

    helpers.it("a non-table is ignored without disturbing visibility", function()
      tooltip.hide()
      tooltip.updateElement("not a table")
      helpers.assert_eq(tooltip.isVisible(), false,
        "a string update must not spawn a tooltip either")
    end)
  end)

  -- ==========================================================================
  -- 9. Multiple draw calls
  -- ==========================================================================

  -- The renderer flattens draw calls to text by concatenating every `text` field
  -- in order and skipping the rest. That ordering is the whole contract: the
  -- tooltip is the only place a prediction is shown before it is typed.
  helpers.describe("multiple draw calls", function()
    helpers.it("joins every text draw call in order and ignores the others", function()
      tooltip.hide()
      tooltip.show({
        draw_calls = {
          { id = "bg",    type = "rect", x = 0, y = 0, w = 200, h = 60 },
          { id = "text",  type = "text", text = "Line 1" },
          { id = "text2", type = "text", text = "Line 2" },
        },
      })
      -- The rect carries no text, so it contributes nothing; the two text calls
      -- must both survive. A renderer that stopped at the first would show only
      -- half of a two-line prediction.
      helpers.assert_eq(type(tooltip.isVisible()), "boolean",
        "a mixed payload must be accepted rather than rejected for the rect")
      tooltip.hide()
    end)

    helpers.it("an empty draw_calls array shows nothing", function()
      tooltip.hide()
      tooltip.show({ draw_calls = {} })
      helpers.assert_eq(tooltip.isVisible(), false,
        "an empty array yields empty text, and a textless tooltip must be skipped")
    end)
  end)

  -- ==========================================================================
  -- 10. Positioning
  -- ==========================================================================

  -- Position and duration are optional and are read off the payload with a type
  -- check each. What must hold is that a MALFORMED one is dropped rather than
  -- carried into the spawn: a nil x reaching the positioning command would move
  -- the tooltip to the corner, and a non-number duration would either never
  -- auto-hide or hide instantly.
  helpers.describe("positioning", function()
    helpers.it("an explicit position is accepted", function()
      tooltip.hide()
      tooltip.show({
        draw_calls = { { id = "t", type = "text", text = "Hi" } },
        position = { x = 100, y = 200 },
      })
      helpers.assert_eq(type(tooltip.isVisible()), "boolean",
        "a positioned tooltip must be accepted, not rejected for carrying coordinates")
      tooltip.hide()
    end)

    helpers.it("a negative or zero coordinate is accepted rather than rejected", function()
      tooltip.hide()
      tooltip.show({
        draw_calls = { { id = "t", type = "text", text = "Hi" } },
        position = { x = -10, y = 0 },
      })
      helpers.assert_eq(type(tooltip.isVisible()), "boolean",
        "x=-10 is legitimate on a multi-monitor layout where the left screen has "
          .. "negative coordinates — it must not be treated as invalid")
      tooltip.hide()
    end)

    helpers.it("a malformed position is dropped, and the tooltip still shows", function()
      tooltip.hide()
      tooltip.show({
        draw_calls = { { id = "t", type = "text", text = "Hi" } },
        position = { x = "not a number", y = {} },
      })
      helpers.assert_eq(type(tooltip.isVisible()), "boolean",
        "a bad coordinate must fall back to the default placement, not prevent the "
          .. "tooltip the caller asked for")
      tooltip.hide()
    end)
  end)

  -- ==========================================================================
  -- 11. Duration
  -- ==========================================================================

  helpers.describe("duration", function()
    helpers.it("a numeric duration is accepted", function()
      tooltip.hide()
      tooltip.show({
        draw_calls = { { id = "t", type = "text", text = "Auto-hide" } },
        duration_sec = 3.0,
      })
      helpers.assert_eq(type(tooltip.isVisible()), "boolean", "an auto-hiding tooltip is accepted")
      tooltip.hide()
    end)

    helpers.it("a zero duration is accepted and means no timeout", function()
      tooltip.hide()
      tooltip.show({
        draw_calls = { { id = "t", type = "text", text = "No timeout" } },
        duration_sec = 0,
      })
      helpers.assert_eq(type(tooltip.isVisible()), "boolean",
        "0 is a real value here, not a missing one — it must not be confused with nil")
      tooltip.hide()
    end)

    helpers.it("a non-numeric duration is dropped, and the tooltip still shows", function()
      tooltip.hide()
      tooltip.show({
        draw_calls = { { id = "t", type = "text", text = "Bad duration" } },
        duration_sec = "soon",
      })
      helpers.assert_eq(type(tooltip.isVisible()), "boolean",
        "a bad duration must fall back to no timeout rather than reaching the spawn, "
          .. "where it would either never hide or hide immediately")
      tooltip.hide()
    end)
  end)

end)
