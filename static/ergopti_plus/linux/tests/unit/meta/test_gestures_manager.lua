--- tests/unit/meta/test_gestures_manager.lua

--- ==============================================================================
--- MODULE: Gestures Manager Tests
--- Tests the Linux gestures module — action registry, slot management,
--- enable/disable, menu integration.
--- ==============================================================================

local helpers = require("tests.helpers")
local TomlCodec = require("toml_codec")

helpers.describe("modules/gestures/manager.lua", function()

  -- ==========================================================================
  -- 1. Module structural
  -- ==========================================================================

  helpers.it("module loads without error", function()
    local ok, mod = pcall(require, "modules.gestures.manager")
    helpers.assert_true(ok, "require should succeed")
    helpers.assert_true(type(mod) == "table", "should return a table")
  end)

  local M = helpers.load_module("modules.gestures.manager")

  helpers.it("exports public API surface", function()
    helpers.assert_true(type(M.is_enabled) == "function", "is_enabled")
    helpers.assert_true(type(M.enable) == "function", "enable")
    helpers.assert_true(type(M.disable) == "function", "disable")
    helpers.assert_true(type(M.toggle) == "function", "toggle")
    helpers.assert_true(type(M.get_action) == "function", "get_action")
    helpers.assert_true(type(M.set_action) == "function", "set_action")
    helpers.assert_true(type(M.get_all_actions) == "function", "get_all_actions")
    helpers.assert_true(type(M.reset_defaults) == "function", "reset_defaults")
    helpers.assert_true(type(M.start_reading) == "function", "start_reading")
    helpers.assert_true(type(M.stop_reading) == "function", "stop_reading")
    helpers.assert_true(type(M.is_reading) == "function", "is_reading")
    helpers.assert_true(type(M.get_action_label) == "function", "get_action_label")
    helpers.assert_true(type(M.get_action_names) == "function", "get_action_names")
    helpers.assert_true(type(M.process_frame) == "function", "process_frame")
    helpers.assert_true(type(M.init) == "function", "init")
    helpers.assert_true(type(M.DEFAULT_GESTURES) == "table", "DEFAULT_GESTURES")
    helpers.assert_true(type(M.SINGLE_SLOTS) == "table", "SINGLE_SLOTS")
    helpers.assert_true(type(M.AXIS_SLOTS) == "table", "AXIS_SLOTS")
  end)

  -- ==========================================================================
  -- 2. Defaults
  -- ==========================================================================

  helpers.it("DEFAULT_GESTURES has expected slots", function()
    helpers.assert_true(M.DEFAULT_GESTURES.tap_2 ~= nil, "has tap_2")
    helpers.assert_true(M.DEFAULT_GESTURES.tap_3 ~= nil, "has tap_3")
    helpers.assert_true(M.DEFAULT_GESTURES.swipe_3_left ~= nil, "has swipe_3_left")
    helpers.assert_true(M.DEFAULT_GESTURES.swipe_4_right ~= nil, "has swipe_4_right")
  end)

  helpers.it("SINGLE_SLOTS has at least 30 entries", function()
    helpers.assert_true(#M.SINGLE_SLOTS >= 30, "should have 30+ single slots")
  end)

  helpers.it("AXIS_SLOTS has 3 entries", function()
    helpers.assert_eq(#M.AXIS_SLOTS, 3)
  end)

  -- ==========================================================================
  -- 3. Enable / disable / toggle
  -- ==========================================================================

  helpers.it("is_enabled returns false initially", function()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  helpers.it("enable sets enabled to true", function()
    M.enable()
    helpers.assert_true(M.is_enabled())
    M.disable()
  end)

  helpers.it("disable sets enabled to false", function()
    M.enable()
    M.disable()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  helpers.it("toggle flips state", function()
    M.disable()
    M.toggle()
    helpers.assert_true(M.is_enabled())
    M.toggle()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  -- ==========================================================================
  -- 4. Gesture slot management
  -- ==========================================================================

  helpers.it("get_action returns default for known slot", function()
    local action = M.get_action("swipe_3_left")
    helpers.assert_true(type(action) == "string")
    helpers.assert_true(#action > 0, "action should not be empty")
  end)

  helpers.it("set_action updates a slot", function()
    M.set_action("swipe_3_left", "vol_up")
    helpers.assert_eq(M.get_action("swipe_3_left"), "vol_up")
    M.set_action("swipe_3_left", "ws_prev")  -- restore
  end)

  helpers.it("set_action works for tap slots too", function()
    M.set_action("tap_3", "enter")
    helpers.assert_eq(M.get_action("tap_3"), "enter")
    M.set_action("tap_3", "left_click_toggle")  -- restore
  end)

  helpers.it("get_all_actions returns full mapping", function()
    local all = M.get_all_actions()
    helpers.assert_true(type(all) == "table")
    helpers.assert_true(all.swipe_3_left ~= nil)
    helpers.assert_true(all.tap_4 ~= nil)
  end)

  helpers.it("reset_defaults returns every slot to unbound", function()
    -- This asserted `ws_prev`, which was the shipped default until 2026-08-05.
    -- Linux now ships no bindings at all: the touchpad is read WITHOUT a grab
    -- (grabbing it kills the cursor), evdev is broadcast, and every desktop that
    -- claims 3- and 4-finger swipes — GNOME 47+, KWin, Hyprland, cosmic-comp —
    -- would fire its action alongside ours on a fresh install.
    M.set_action("swipe_3_left", "vol_up")
    M.reset_defaults()
    helpers.assert_eq(M.get_action("swipe_3_left"), "none",
      "reset must return the slot to unbound, not to a binding the user never chose")
  end)

  helpers.it("keeps parameterized action values isolated per gesture binding", function()
    helpers.assert_eq(M.get_action_parameter_spec("open_url"), "url")
    helpers.assert_eq(M.get_action_parameter_spec("search_web"), "search_url")
    helpers.assert_true(M.set_action_parameter("tap_3", "open_url", "https://one.example/path"))
    helpers.assert_true(M.set_action_parameter("swipe_3_left", "open_url", "https://two.example/path"))
		helpers.assert_eq(M.get_action_parameter("tap_3", "open_url"), "https://one.example/path")
		helpers.assert_eq(M.get_action_parameter("swipe_3_left", "open_url"), "https://two.example/path")
		local binding, action = M.split_action_parameter_key("keyboard__cmd_k__search_web")
		helpers.assert_eq(binding, "keyboard__cmd_k", "scoped bindings must not be split at their first separator")
		helpers.assert_eq(action, "search_web")
		helpers.assert_eq(M.set_action_parameter("tap_3", "open_url", "not-a-url"), false)
    helpers.assert_true(M.set_action_parameter("tap_3", "search_web", "https://search.example/?q=%s"))
    helpers.assert_eq(M.set_action_parameter("tap_3", "search_web", "https://search.example/?q=%s&again=%s"), false)
  end)

	helpers.it("disable_all_actions clears every binding but not the master toggle", function()
		M.enable()
		M.disable_all_actions()
    for slot in pairs(M.DEFAULT_GESTURES) do
      helpers.assert_eq(M.get_action(slot), "none", "slot should be empty: " .. slot)
    end
    helpers.assert_true(M.is_enabled(), "clearing actions must not disable the gesture feature")
		M.reset_defaults()
		M.disable()
	end)

	helpers.it("persists parameters and assignments in the user TOML", function()
		local tmp = os.tmpname()
		pcall(os.remove, tmp)
		local fh = io.open(tmp, "w")
		helpers.assert_true(fh ~= nil, "must create a temporary user TOML")
		fh:write("[linux.gestures]\n")
		fh:write("tap_3 = \"none\"\n\n")
		fh:write("[linux.action_parameters]\n")
		fh:write("tap_3__open_url = \"https://restored.example\"\n")
		fh:close()

		M.init({ persist = true, config_path = tmp })
		helpers.assert_eq(M.get_action("tap_3"), "none")
		helpers.assert_eq(M.get_action_parameter("tap_3", "open_url"), "https://restored.example")
		helpers.assert_true(M.set_action_parameter("tap_3", "open_url", "https://saved.example/path"))
		M.set_action("tap_3", "open_url")

		local out = io.open(tmp, "r")
		helpers.assert_true(out ~= nil, "the user TOML must be writable")
		local decoded = TomlCodec.decode(out:read("*a"))
		out:close()
		helpers.assert_eq(decoded.linux.gestures.tap_3, "open_url")
		helpers.assert_eq(decoded.linux.action_parameters.tap_3__open_url, "https://saved.example/path")
		M.reset_defaults()
		pcall(os.remove, tmp)
		M.init({ persist = false })
	end)

  -- ==========================================================================
  -- 5. Action labels
  -- ==========================================================================

  helpers.it("get_action_label returns label for known action", function()
    local label = M.get_action_label("vol_up")
    helpers.assert_true(type(label) == "string")
    helpers.assert_true(#label > 0, "label should not be empty")
  end)

  -- The registry used to hold hardcoded FRENCH labels, described in the source
  -- as a "fallback when i18n is absent" that nothing ever replaced — so every
  -- user of the other 20 locales read French gesture names. "not empty" above
  -- could never have caught that, and neither could it catch the raw key being
  -- echoed back, which is what i18n.get returns on a miss.
  helpers.it("labels come from the shared sg_actions catalogue, not from a local table", function()
    local i18n = require("infra.i18n")
    local label = M.get_action_label("vol_up")
    helpers.assert_eq(label, i18n.get("sg_actions.vol_up"),
      "the label must be whatever the shared catalogue says for the active locale")
    helpers.assert_true(label ~= "sg_actions.vol_up",
      "i18n.get echoes the raw key back on a miss — an echoed key means the catalogue was never reached")
  end)

  helpers.it("the workspace ids resolve through their desktop_* catalogue entries", function()
    local i18n = require("infra.i18n")
    -- This driver says "workspace", the shared catalogue says "desktop". The
    -- alias is what lets an existing user's config.toml keep resolving, so it
    -- has to be exercised rather than assumed.
    for id, suffix in pairs({ ws_prev = "desktop_prev", ws_next = "desktop_next" }) do
      local label = M.get_action_label(id)
      helpers.assert_eq(label, i18n.get("sg_actions." .. suffix),
        id .. " must resolve through sg_actions." .. suffix)
      helpers.assert_true(label ~= id and label ~= "sg_actions." .. suffix,
        id .. " resolved to a raw identifier — the catalogue entry was not found")
    end
  end)

  helpers.it("get_action_label returns fallback for unknown action", function()
    local label = M.get_action_label("bogus_action")
    helpers.assert_true(type(label) == "string")
  end)

  helpers.it("renders the complete shared modifier matrix with universal labels", function()
    helpers.assert_eq(M.get_action_label("ctrl_a"), "Ctrl + A")
    helpers.assert_eq(M.get_action_label("ctrl_alt_super_enter"), "Ctrl + Alt + Super + Enter")
  end)

  helpers.it("get_action_names returns sorted list", function()
    local names = M.get_action_names()
    helpers.assert_true(type(names) == "table")
    helpers.assert_true(#names > 10, "should have many actions")
    helpers.assert_true(names[1] ~= nil)
  end)

  -- ==========================================================================
  -- 6. Reading state
  -- ==========================================================================

  helpers.it("is_reading returns false initially", function()
    helpers.assert_eq(M.is_reading(), false)
  end)

  helpers.it("start_reading refuses, and says so, when there is no touchpad", function()
    -- This asserted that start_reading always reports itself as reading, which
    -- was true of the stub it tested: the old body set the flag and logged. It
    -- reads a real device now, so on a machine without one — every CI runner, and
    -- every desktop — the honest answer is false.
    --
    -- Claiming to read a device that was never opened is the failure mode worth
    -- pinning: the daemon would pump a closed slot for ever and the user would
    -- see gestures silently do nothing.
    local started = M.start_reading()
    helpers.assert_eq(started, M.is_reading(),
      "what it RETURNS and what is_reading() says must agree — a reader that "
        .. "reports success and is not reading is worse than one that fails")
    if not started then
      helpers.assert_eq(M.is_reading(), false,
        "and a refused start must leave nothing behind to pump")
    end
    M.stop_reading()
  end)

  helpers.it("stop_reading sets reading to false", function()
    M.start_reading()
    M.stop_reading()
    helpers.assert_eq(M.is_reading(), false)
  end)

  -- ==========================================================================
  -- 7. Process frame (no-op stub)
  -- ==========================================================================

  helpers.it("process_frame with no touches fires no gesture", function()
    -- Called directly: a raise fails with the real error. The claim is that an
    -- empty frame recognises nothing — a frame loop that fired on emptiness would
    -- trigger an action every tick the user is not touching the trackpad.
    local before = M.get_last_gesture and M.get_last_gesture() or nil
    M.process_frame({})
    helpers.assert_eq(M.get_last_gesture and M.get_last_gesture() or nil, before,
      "an empty frame must not recognise a gesture")
  end)

  helpers.it("process_frame with a single touch fires no gesture", function()
    local before = M.get_last_gesture and M.get_last_gesture() or nil
    M.process_frame({ { x = 100, y = 200 } })
    helpers.assert_eq(M.get_last_gesture and M.get_last_gesture() or nil, before,
      "one finger is not a gesture — every slot needs three or more")
  end)

  helpers.it("process_frame does nothing when disabled", function()
    M.disable()
    local before = M.get_last_gesture and M.get_last_gesture() or nil
    M.process_frame({ { x = 100, y = 200 } })
    helpers.assert_eq(M.get_last_gesture and M.get_last_gesture() or nil, before,
      "a disabled manager must not recognise anything — the menu toggle is the only "
        .. "thing standing between the user and an action they turned off")
  end)

  -- ==========================================================================
  -- 8. Init
  -- ==========================================================================

  helpers.it("init with empty opts leaves gestures disabled", function()
    M.init({})
    helpers.assert_eq(M.is_enabled(), false,
      "no opts means no enable — an init that turned gestures on by default would "
        .. "start reading the trackpad the user never opted into")
  end)

  helpers.it("init with enabled=true turns gestures on and attempts to read", function()
    -- The enable half is unconditional and is what this case is really about.
    -- Whether reading STARTS depends on the machine having a touchpad, which no
    -- CI runner does, so asserting it here would pin the stub's behaviour again.
    M.init({ enabled = true })
    helpers.assert_true(M.is_enabled(), "enabled=true must enable")
    helpers.assert_eq(M.is_reading(), M.touchpad() ~= nil,
      "and it reads exactly when a touchpad was found — never one without the other")
    M.disable()
    M.stop_reading()
  end)

  -- ==========================================================================
  -- 9. Menu builder integration
  -- ==========================================================================

  helpers.it("menu_builder renders gestures section when context present", function()
    local ok_mb, menu_builder = pcall(require, "ui.menu.menu_builder")
    -- Asserted, not skipped. ui/menu/menu_builder.lua ships with this driver, so
    -- "not available" can only mean it stopped loading — and the skip made that
    -- indistinguishable from a pass in six cases across three files.
    helpers.assert_true(ok_mb and menu_builder ~= nil,
      "ui.menu.menu_builder must load: " .. tostring(menu_builder))

    M.enable()
    local items = menu_builder.build({
      _version = "3.0.0",
      gestures = M,
    })

    local found = false
    for _, item in ipairs(items) do
      if type(item) == "table" and item.title and (item.title:find("Gestes") or item.title:find("gestures") or item.title:find("🖐")) then
        found = true
        helpers.assert_true(type(item.menu) == "table", "gestures should have a submenu")
        helpers.assert_true(#item.menu > 0, "gestures submenu should have items")
        break
      end
    end
    helpers.assert_true(found, "menu should contain a gestures section")
    M.disable()
  end)

  helpers.it("menu_builder handles nil gestures gracefully", function()
    local ok_mb, menu_builder = pcall(require, "ui.menu.menu_builder")
    -- Asserted, not skipped. ui/menu/menu_builder.lua ships with this driver, so
    -- "not available" can only mean it stopped loading — and the skip made that
    -- indistinguishable from a pass in six cases across three files.
    helpers.assert_true(ok_mb and menu_builder ~= nil,
      "ui.menu.menu_builder must load: " .. tostring(menu_builder))

    local items = menu_builder.build({
      _version = "3.0.0",
      gestures = nil,
    })

    local found = false
    for _, item in ipairs(items) do
      if type(item) == "table" and item.title and (item.title:find("Gestes") or item.title:find("gestures") or item.title:find("🖐")) then
        found = true
        break
      end
    end
    helpers.assert_true(found, "menu should contain a gestures stub when module absent")
  end)

  -- ==========================================================================
  -- 10. Full recognition pipeline (frame sequence -> slot -> action dispatch)
  -- ==========================================================================

  helpers.it("3-finger tap sequence resolves tap_3 and dispatches its action", function()
    -- Stub os.execute so we observe WHICH command the pipeline dispatched. This
    -- proves slot resolution + action dispatch, not merely no-crash (sections 7-8).
    local captured = {}
    local real_execute = os.execute
    os.execute = function(cmd) captured[#captured + 1] = cmd; return true end

    M.reset_defaults()
    M.enable()
    -- Bind a distinctive action so the captured command is unambiguous.
    M.set_action("tap_3", "enter")  -- "enter" maps to `xdotool key Return`

    -- Full gesture: three fingers down at one spot, then all lifted (n = 0).
    M.process_frame({ { x = 100, y = 100 }, { x = 100, y = 100 }, { x = 100, y = 100 } })
    M.process_frame({})

    os.execute = real_execute  -- Restore before any assertion can abort the test.

    helpers.assert_eq(#captured, 1, "exactly one action should fire for a single tap")
    helpers.assert_contains(captured[1], "xdotool key Return",
      "3-finger tap must resolve tap_3 and dispatch its bound action")

    M.reset_defaults()
    M.disable()
  end)

  helpers.it("3-finger swipe-left sequence resolves swipe_3_left and dispatches its action", function()
    local captured = {}
    local real_execute = os.execute
    os.execute = function(cmd) captured[#captured + 1] = cmd; return true end

    M.reset_defaults()
    M.enable()
    M.set_action("swipe_3_left", "escape")  -- "escape" maps to `xdotool key Escape`

    -- Three fingers travel left far enough to beat both TAP_MAX_DELTA and SWIPE_MIN,
    -- forcing the swipe branch (a tap requires travel below TAP_MAX_DELTA).
    M.process_frame({ { x = 200, y = 100 }, { x = 200, y = 100 }, { x = 200, y = 100 } })
    M.process_frame({ { x = 140, y = 100 }, { x = 140, y = 100 }, { x = 140, y = 100 } })
    M.process_frame({})

    os.execute = real_execute

    helpers.assert_eq(#captured, 1, "exactly one action should fire for a single swipe")
    helpers.assert_contains(captured[1], "xdotool key Escape",
      "3-finger left swipe must resolve swipe_3_left and dispatch its bound action")

    M.reset_defaults()
    M.disable()
  end)

  helpers.it("a slow near-stationary hold is not misclassified as a tap (wall clock, not CPU time)", function()
    -- The bug: process_frame timed gestures with os.clock() (CPU time). In an
    -- I/O-bound daemon CPU time barely advances, so a gesture held for seconds
    -- reported elapsed ~= 0 and was wrongly fired as a tap. With an injected
    -- wall clock a long hold exceeds the tap ceiling and must NOT fire.
    local captured = {}
    local real_execute = os.execute
    os.execute = function(cmd) captured[#captured + 1] = cmd; return true end

    local fake_t = 0
    M.init({ now_sec = function() return fake_t end })
    M.reset_defaults()
    M.enable()
    M.set_action("tap_3", "enter")

    -- Three fingers down, essentially stationary, held for 2 s of wall time
    -- (far beyond the tap ceiling), then lifted.
    fake_t = 100.0
    M.process_frame({ { x = 100, y = 100 }, { x = 100, y = 100 }, { x = 100, y = 100 } })
    fake_t = 102.0
    M.process_frame({ { x = 100, y = 100 }, { x = 100, y = 100 }, { x = 100, y = 100 } })
    M.process_frame({})

    os.execute = real_execute

    helpers.assert_eq(#captured, 0,
      "a 2 s near-stationary hold exceeds the tap ceiling and must not dispatch a tap")

    M.reset_defaults()
    M.disable()
  end)

  -- ==========================================================================
  -- 11. Slot-space is derived from the shared actions.toml (single source)
  -- ==========================================================================

  helpers.it("derives SINGLE_SLOTS / AXIS_SLOTS from the shared actions.toml in order", function()
    local codec = require("toml_codec")
    local path = helpers.driver_root() .. "/../_shared/modules/actions/actions.toml"
    local fh = io.open(path, "r")
    helpers.assert_true(fh ~= nil, "shared actions.toml must be readable")
    local content = fh:read("*a"); fh:close()
    local data = codec.decode(content)
    helpers.assert_true(data ~= nil and type(data.slots) == "table",
      "actions.toml must decode with a [slots] section")

    local single, axis = data.slots.single, data.slots.axis
    helpers.assert_true(#single > 0 and #axis > 0,
      "the [slots] arrays must be non-empty — proves multi-line array decode works")

    helpers.assert_eq(#M.SINGLE_SLOTS, #single, "derived SINGLE_SLOTS length must match the TOML")
    for i = 1, #single do
      helpers.assert_eq(M.SINGLE_SLOTS[i], single[i], "SINGLE_SLOTS must be derived in TOML order")
    end
    helpers.assert_eq(#M.AXIS_SLOTS, #axis, "derived AXIS_SLOTS length must match the TOML")
    for i = 1, #axis do
      helpers.assert_eq(M.AXIS_SLOTS[i], axis[i], "AXIS_SLOTS must be derived in TOML order")
    end

    -- DEFAULT_GESTURES key-space is exactly the union of single + axis.
    local union, nunion = {}, 0
    for _, s in ipairs(single) do if not union[s] then union[s] = true; nunion = nunion + 1 end end
    for _, s in ipairs(axis) do if not union[s] then union[s] = true; nunion = nunion + 1 end end
    local nkeys = 0
    for k in pairs(M.DEFAULT_GESTURES) do
      nkeys = nkeys + 1
      helpers.assert_true(union[k] == true, "DEFAULT_GESTURES has a key outside the slot-space: " .. tostring(k))
    end
    helpers.assert_eq(nkeys, nunion, "DEFAULT_GESTURES key-space must equal single + axis")
  end)

  helpers.it("ships no binding at all — every slot arrives unbound", function()
    -- This locked three specific default VALUES so the table "cannot silently
    -- regress to all-none". All-none is now the deliberate answer, so the
    -- assertion is inverted — and made stronger: it covers all 39 slots rather
    -- than three, so a default reintroduced anywhere is caught, not just in the
    -- three that happened to be named.
    --
    -- Why none: the touchpad is read WITHOUT a grab, because grabbing it takes
    -- the pointer from the compositor and leaves a dead cursor. evdev is
    -- broadcast, so the desktop acts on the same gesture — GNOME 47+, KWin,
    -- Hyprland and cosmic-comp all claim 3- and 4-finger swipes, and two-finger
    -- motion is scrolling everywhere. A shipped binding means two things happen
    -- for one gesture, on a fresh install, with nothing to explain it.
    local bound = {}
    for slot, action in pairs(M.DEFAULT_GESTURES) do
      if action ~= "none" then bound[#bound + 1] = slot .. "=" .. tostring(action) end
    end
    helpers.assert_eq(#bound, 0,
      "Linux ships no gesture bindings; found: " .. table.concat(bound, ", "))
  end)

  helpers.it("still offers every slot the other two drivers offer", function()
    -- The half that must NOT change with the above. Parity is about the slots
    -- existing and being configurable, not about what they arrive bound to, and
    -- an empty default table must never be mistaken for an empty key-space.
    for _, slot in ipairs({ "tap_2", "tap_5", "swipe_2_left", "swipe_5_right_down", "swipe_5_horiz" }) do
      helpers.assert_eq(M.DEFAULT_GESTURES[slot], "none",
        slot .. " must be present and unbound, not absent")
    end
  end)

  helpers.it("does not hardcode the slot arrays (they are derived at load)", function()
    local fh = io.open(helpers.driver_root() .. "/modules/gestures/manager.lua", "r")
    helpers.assert_true(fh ~= nil, "manager source must be readable")
    local src = fh:read("*a"); fh:close()
    helpers.assert_true(src:find("load_slot_space(", 1, true) ~= nil,
      "manager must derive the slot-space via load_slot_space()")
    helpers.assert_true(src:find("_shared/modules/actions/actions.toml", 1, true) ~= nil,
      "manager must read the shared actions.toml")
    helpers.assert_true(src:find("M.SINGLE_SLOTS = {", 1, true) == nil,
      "SINGLE_SLOTS must be derived, not re-hardcoded as a literal array")
  end)

end)
