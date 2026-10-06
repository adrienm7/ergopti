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
    -- process_frame was retired on 2026-08-05. dispatch_gesture replaced it:
    -- it takes an already-classified gesture whose finger count is the one the
    -- KERNEL reported, rather than inferring it from how many contacts it was
    -- handed — which libinput says is wrong on most touchpads.
    helpers.assert_true(type(M.dispatch_gesture) == "function", "dispatch_gesture")
    helpers.assert_true(type(M.pump) == "function", "pump")
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
    M._test_begin_reading({})
    M.enable()
    helpers.assert_true(M.is_enabled())
    M.disable()
  end)

  helpers.it("disable sets enabled to false", function()
    M._test_begin_reading({})
    M.enable()
    M.disable()
    helpers.assert_eq(M.is_enabled(), false)
  end)

  helpers.it("toggle flips state", function()
    M.disable()
    M._test_begin_reading({})
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
    M.set_action("swipe_3_left", "none")  -- restore
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
		M._test_begin_reading({})
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
		-- `[gestures]`, not `[linux.gestures]`. The driver-namespaced form was this
		-- driver answering a question the shared manifest had already answered:
		-- the manifest declares `gestures.swipe_3_up` and every feature under it,
		-- and a second key space meant those features could never be declared for
		-- Linux without the declaration being false.
		helpers.assert_eq(decoded.gestures.tap_3, "open_url")
		helpers.assert_eq(decoded.gesture_parameters.tap_3__open_url, "https://saved.example/path")
		-- The legacy block this fixture starts with is LEFT in the file. A writer
		-- that deleted sections it did not write would eat unrelated
		-- configuration, and leaving it costs nothing: the reader applies the new
		-- section last, so the stale copy can never win.
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

  helpers.it("the workspace actions are the catalogue's desktop_* ids", function()
    local i18n = require("infra.i18n")
    -- This driver used private ws_prev / ws_next ids labelled through the
    -- catalogue's desktop_* keys, so no other driver's binding and no picker
    -- entry could name them. They are the shared ids now.
    for _, id in ipairs({ "desktop_prev", "desktop_next", "desktop_prev_wrap", "desktop_next_wrap" }) do
      local label = M.get_action_label(id)
      helpers.assert_eq(label, i18n.get("sg_actions." .. id), id .. " must resolve through sg_actions." .. id)
      helpers.assert_true(label ~= id and label ~= "sg_actions." .. id,
        id .. " resolved to a raw identifier — the catalogue entry was not found")
      helpers.assert_true(M.is_runnable(id), id .. " must reach the workspace switcher")
    end
    helpers.assert_true(not M.is_assignable("ws_prev"), "the private id is gone")
  end)

  helpers.it("get_action_label returns fallback for unknown action", function()
    local label = M.get_action_label("bogus_action")
    helpers.assert_true(type(label) == "string")
  end)

  helpers.it("renders the complete shared modifier matrix with universal labels", function()
    helpers.assert_eq(M.get_action_label("ctrl_a"), "Ctrl + A")
    helpers.assert_eq(M.get_action_label("ctrl_alt_super_enter"), "Ctrl + Alt + Super + Enter")
  end)

  helpers.it("get_action_names follows the catalogue order", function()
    -- It used to sort a hard-coded table alphabetically; the order is now the
    -- catalogue's, the one the other two drivers show.
    local names = M.get_action_names()
    helpers.assert_true(type(names) == "table")
    helpers.assert_true(#names > 10, "should have many actions")
    helpers.assert_eq(names[1], "none", "the catalogue opens with the empty binding")
    local position = {}
    for index, name in ipairs(names) do position[name] = index end
    helpers.assert_true(position.left_click_toggle < position.tab_new
      and position.tab_new < position.lock_screen,
      "mouse, then windows, then system — the catalogue's grouping, not the alphabet")
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

  -- ==========================================================================
  -- 8. Init
  -- ==========================================================================

  helpers.it("init with empty opts leaves gestures disabled", function()
    M.init({})
    helpers.assert_eq(M.is_enabled(), false,
      "no opts means no enable — an init that turned gestures on by default would "
        .. "start reading the trackpad the user never opted into")
  end)

  helpers.it("init with enabled=true enables only over a live reader", function()
    -- The dedicated transaction suite exercises a real start attempt through
    -- fakes. This seam keeps this broad manager suite independent of hardware
    -- while pinning init to the same enabled-implies-reading invariant.
    M._test_begin_reading({})
    M.init({ enabled = true })
    helpers.assert_true(M.is_enabled(), "enabled=true must enable")
    helpers.assert_true(M.is_reading(),
      "init must not publish enabled=true before a reader is live")
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

    M._test_begin_reading({})
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

  helpers.it("does not hardcode the slot arrays (they come from the generated catalogue)", function()
    local fh = io.open(helpers.driver_root() .. "/modules/gestures/manager.lua", "r")
    helpers.assert_true(fh ~= nil, "manager source must be readable")
    local src = fh:read("*a"); fh:close()
    helpers.assert_true(src:find('require, "_generated.action_catalogue"', 1, true) ~= nil,
      "manager must load the generated action catalogue")
    helpers.assert_true(src:find("M.SINGLE_SLOTS = copy_list(Catalogue.slots.single)", 1, true) ~= nil,
      "SINGLE_SLOTS must come from the catalogue's slot-space")
    helpers.assert_true(src:find("M.SINGLE_SLOTS = {", 1, true) == nil,
      "SINGLE_SLOTS must be derived, not re-hardcoded as a literal array")
  end)

end)




-- =========================================================================
-- 8. The rename does not lose an existing user's bindings
-- =========================================================================

helpers.describe("gestures: a config written before the rename", function()

	local M = helpers.load_module("modules.gestures.manager")

	helpers.it("still applies its bindings", function()
		local tmp = os.tmpname()
		local fh = assert(io.open(tmp, "w"))
		fh:write([[
[linux.gestures]
tap_3 = "open_url"
]])
		fh:close()

		M.init({ persist = true, config_path = tmp })
		local action = M.get_action("tap_3")
		M.reset_defaults()
		pcall(os.remove, tmp)
		M.init({ persist = false })

		helpers.assert_eq(action, "open_url",
			"a rename that silently drops a user's bindings is worse than the "
				.. "divergence it fixes — every gesture they configured would come "
				.. "back as 'none' with nothing saying why")
	end)

	helpers.it("lets the new section win when both are present", function()
		local tmp = os.tmpname()
		local fh = assert(io.open(tmp, "w"))
		fh:write([[
[linux.gestures]
tap_3 = "open_url"

[gestures]
tap_3 = "none"
]])
		fh:close()

		M.init({ persist = true, config_path = tmp })
		local action = M.get_action("tap_3")
		M.reset_defaults()
		pcall(os.remove, tmp)
		M.init({ persist = false })

		helpers.assert_eq(action, "none",
			"once a change has been written under the new name, whatever the old "
				.. "section still says is stale — reading it last would undo the "
				.. "user's most recent choice on every start")
	end)

end)

-- Actual native catalogue identity, not runtime assignment presence, owns
-- retirement. Every file fixture is retained until explicit caller cleanup.
local function binding_source_fixture(source, test)
	local path = os.tmpname()
	local function write(content)
		local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
	end
	local function read()
		local file = assert(io.open(path, "rb")); local content = file:read("*a"); assert(file:close()); return content
	end
	write(source)
	local manager = helpers.load_module("modules.gestures.manager")
	local okay, detail = xpcall(function() test(manager, path, read, write) end, debug.traceback)
	pcall(os.remove, path)
	if not okay then error(detail, 0) end
end

helpers.describe("gesture parameter binding publication", function()
	local source = [[# Independent source: ignored entries must remain on disk.
[linux.action_parameters]
removed_gesture_slot__open_url = "https://retired-legacy.example"
tap_3__open_url = "https://legacy.example"
keyboard__ctrl_k__open_url = "https://keyboard.example"
[gesture_parameters]
removed_gesture_slot__open_url = "https://retired-canonical.example"
tap_3__open_url = "https://canonical.example"
swipe_3_horiz__open_url = "https://axis.example"
script__script_altgr_enter__open_url = "https://script.example"
]]
	helpers.it("binding-identity: real source ignores both retired leaves and preserves full source bytes", function()
		binding_source_fixture(source, function(manager, path, read)
			manager.init({ persist = true, config_path = path, enabled = false })
			helpers.assert_eq(manager.get_action_parameter("removed_gesture_slot", "open_url"), "")
			helpers.assert_nil(manager.get_all_action_parameters().removed_gesture_slot__open_url)
			helpers.assert_eq(manager.get_action_parameter("tap_3", "open_url"), "https://canonical.example")
			helpers.assert_eq(manager.get_action_parameter("swipe_3_horiz", "open_url"), "https://axis.example")
			helpers.assert_eq(manager.get_action_parameter("keyboard__ctrl_k", "open_url"), "https://keyboard.example")
			helpers.assert_eq(manager.get_action_parameter("script__script_altgr_enter", "open_url"), "https://script.example")
			helpers.assert_eq(read(), source)
		end)
	end)
	helpers.it("binding-identity: actual reporter and cleanup marks agree for both namespaces", function()
		local manager = helpers.load_module("modules.gestures.manager")
		local outdated = require("config_outdated"); outdated.reset_for_tests()
		local logger = require("logger.shim"); local warn, messages = logger.warn, {}
		logger.warn = function(tag, text, ...) messages[#messages + 1] = string.format(text, ...) end
		local marks, reports
		local okay, detail = pcall(function()
			marks = {}
			reports = outdated.collect_reports(function()
				manager.mark_config_reads(TomlCodec.decode(source), function(...)
					marks[table.concat({ ... }, ".")] = true
				end)
			end)
		end)
		logger.warn = warn
		helpers.assert_true(okay, detail)
		helpers.assert_eq(reports, {
			["linux.action_parameters.removed_gesture_slot__open_url"] = true,
			["gesture_parameters.removed_gesture_slot__open_url"] = true,
		})
		helpers.assert_eq(marks, {
			["linux.action_parameters.tap_3__open_url"] = true,
			["linux.action_parameters.keyboard__ctrl_k__open_url"] = true,
			["gesture_parameters.tap_3__open_url"] = true,
			["gesture_parameters.swipe_3_horiz__open_url"] = true,
			["gesture_parameters.script__script_altgr_enter__open_url"] = true,
		})
		helpers.assert_eq(#messages, 2)
		for _, message in ipairs(messages) do
			helpers.assert_true(message:find("no gesture slot of this build has this name", 1, true) ~= nil)
		end
	end)
	helpers.it("binding-identity: scoped legacy deletion owns only consumed current native slots", function()
		local manager = helpers.load_module("modules.gestures.manager")
		helpers.assert_eq(manager.scope_legacy_operations(TomlCodec.decode(source)), {
			{ section = "linux.action_parameters", key = "tap_3__open_url", delete = true },
		})
	end)
	helpers.it("binding-identity: ordinary setter refuses retired binding before invoking its writer", function()
		binding_source_fixture(source, function(manager, path, read)
			manager.init({ persist = true, config_path = path, enabled = false })
			local native_writer, calls = manager._persist_updates, 0
			manager._persist_updates = function(...) calls = calls + 1; return native_writer(...) end
			helpers.assert_eq(manager.set_action_parameter("removed_gesture_slot", "open_url", "https://new.example"), false)
			helpers.assert_eq(calls, 0); helpers.assert_eq(read(), source)
			helpers.assert_eq(manager.get_action_parameter("removed_gesture_slot", "open_url"), "")
			helpers.assert_nil(manager.get_all_action_parameters().removed_gesture_slot__open_url)
			helpers.assert_true(manager.set_action_parameter("tap_3", "open_url", "https://saved.example"))
			helpers.assert_eq(calls, 1)
			local parsed = TomlCodec.decode(read())
			helpers.assert_eq(parsed.linux.action_parameters.removed_gesture_slot__open_url, "https://retired-legacy.example")
			helpers.assert_eq(parsed.gesture_parameters.removed_gesture_slot__open_url, "https://retired-canonical.example")
			helpers.assert_eq(parsed.gesture_parameters.tap_3__open_url, "https://saved.example")
			local restarted = helpers.load_module("modules.gestures.manager")
			restarted.init({ persist = true, config_path = path, enabled = false })
			helpers.assert_eq(restarted.get_action_parameter("removed_gesture_slot", "open_url"), "")
			helpers.assert_nil(restarted.get_all_action_parameters().removed_gesture_slot__open_url)
			helpers.assert_eq(restarted.get_action_parameter("tap_3", "open_url"), "https://saved.example")
		end)
	end)
	helpers.it("binding-identity: current and qualified domains retain ordinary setters and exact compensation", function()
		local manager = helpers.load_module("modules.gestures.manager")
		manager.init({ persist = false, enabled = false })
		for _, binding in ipairs({ "tap_3", "swipe_3_horiz", "keyboard__ctrl_k", "tap_hold__caps_lock", "script__script_altgr_enter" }) do
			helpers.assert_true(manager.set_action_parameter(binding, "open_url", "https://valid.example"))
		end
		local owner = {}; helpers.assert_true(manager.acquire_parameter_configuration(owner))
		local prior = { removed_gesture_slot__open_url = "https://inverse.example" }
		helpers.assert_true(manager.apply_parameter_configuration(owner, prior))
		helpers.assert_eq(manager.parameter_configuration_snapshot(owner), prior)
		helpers.assert_true(manager.release_parameter_configuration(owner))
	end)

	local original = require("_generated.action_catalogue")
	local invalid = {
		{ label = "missing single", single = false, axis = original.slots.axis },
		{ label = "missing axis", single = original.slots.single, axis = false },
		{ label = "empty single", single = {}, axis = original.slots.axis },
		{ label = "empty axis", single = original.slots.single, axis = {} },
		{ label = "sparse", single = { [1] = "tap_3", [3] = "tap_4" }, axis = original.slots.axis },
		{ label = "map", single = { slot = "tap_3" }, axis = original.slots.axis },
		{ label = "nontext", single = { "tap_3", false }, axis = original.slots.axis },
		{ label = "empty id", single = { "" }, axis = original.slots.axis },
		{ label = "qualified id", single = { "keyboard__cmd_k" }, axis = original.slots.axis },
		{ label = "duplicate", single = { "tap_3", "tap_3" }, axis = original.slots.axis },
		{ label = "cross-family duplicate", single = { "tap_3" }, axis = { "tap_3" } },
	}
	for _, vector in ipairs(invalid) do
		helpers.it("binding-identity: rejects incomplete native catalogue " .. vector.label, function()
			local catalogue = {}
			for key, value in pairs(original) do catalogue[key] = value end
			catalogue.slots = { single = vector.single or nil, axis = vector.axis or nil }
			helpers.assert_throws(function()
				helpers.load_module_with_dependency("modules.gestures.manager", "_generated.action_catalogue", catalogue)
			end)
		end)
	end
end)

helpers.describe("gesture parameter binding source authority", function()
	helpers.it("binding-identity: mutable public defaults and slot copies cannot declare a retired parameter current", function()
		local manager = helpers.load_module("modules.gestures.manager")
		manager.init({ persist = false, enabled = false })
		manager.DEFAULT_GESTURES.removed_gesture_slot = "none"
		manager.SINGLE_SLOTS[#manager.SINGLE_SLOTS + 1] = "removed_gesture_slot"
		helpers.assert_eq(manager.set_action_parameter("removed_gesture_slot", "open_url", "https://retired.example"), false)
		helpers.assert_nil(manager.get_all_action_parameters().removed_gesture_slot__open_url)
		helpers.assert_eq(manager.set_action_parameter("Tap_3", "open_url", "https://wrong-case.example"), false)
		helpers.assert_true(manager.set_action_parameter("tap_3", "open_url", "https://current.example"))
	end)
	helpers.it("binding-identity: genuine unused-key scan offers only retired parameters and explicit removal preserves neighbors", function()
		local source = [[# Native marker and actual cleanup scanner
[linux.action_parameters]
removed_gesture_slot__open_url = "https://legacy-retired.example"
tap_3__open_url = "https://current-legacy.example"
[gesture_parameters]
removed_gesture_slot__open_url = "https://canonical-retired.example"
swipe_3_horiz__open_url = "https://current-axis.example"
keyboard__ctrl_k__open_url = "https://other-owner.example"
]]
		binding_source_fixture(source, function(manager, path, read)
			local cleanup = require("config_unused_keys")
			local scan = cleanup.find_in_source(source, function(decoded, mark) manager.mark_config_reads(decoded, mark) end)
			helpers.assert_eq(scan.status, "ok"); helpers.assert_eq(#scan.keys, 2)
			local paths = {}
			for _, entry in ipairs(scan.keys) do paths[#paths + 1] = table.concat(entry.path, ".") end
			table.sort(paths)
			helpers.assert_eq(paths, { "gesture_parameters.removed_gesture_slot__open_url", "linux.action_parameters.removed_gesture_slot__open_url" })
			helpers.assert_eq(read(), source)
			local cleaned = cleanup.remove_from_source(source, scan.keys)
			helpers.assert_eq(TomlCodec.decode(cleaned), {
				linux = { action_parameters = { tap_3__open_url = "https://current-legacy.example" } },
				gesture_parameters = { swipe_3_horiz__open_url = "https://current-axis.example", keyboard__ctrl_k__open_url = "https://other-owner.example" },
			})
		end)
	end)
end)

-- Independently authored shared identity vectors, also consumed by macOS and
-- Windows. This native registration never regenerates their expectations.
do
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/config_binding_identity/vectors.json", "rb"))
	local source = assert(handle:read("*a")); assert(handle:close())
	require("test.config_binding_identity_contract").register(helpers, require("json").decode(source))
end


require("test.script_binding_publication_contract").register(require("tests.helpers"), "linux")

helpers.describe("gesture parameter binding publication with the real script owner", function()
	helpers.it("binding-identity: actual script publication distinguishes current and retired qualified domains", function()
		local owner = require("modules.shortcuts.script_chords")
		owner.catalogue()
		local publication = owner.published_binding_catalogue()
		helpers.assert_true(type(publication) == "table")
		helpers.assert_eq(publication.slots.script_altgr_enter, true)
		helpers.assert_nil(publication.slots.reload)
		local manager = helpers.load_module("modules.gestures.manager")
		helpers.assert_eq(manager.action_parameter_binding_fits("script__script_altgr_enter"), true)
		helpers.assert_eq(manager.action_parameter_binding_fits("script__reload"), false)
		helpers.assert_nil(manager.action_parameter_binding_fits("tap_hold__future_unjudged"))
		manager.init({ persist = false, enabled = false })
		helpers.assert_true(manager.set_action_parameter("script__script_altgr_enter", "open_url", "https://current.example"))
		helpers.assert_eq(manager.set_action_parameter("script__reload", "open_url", "https://must-not-activate.example"), false)
		helpers.assert_eq(manager.get_action_parameter("script__script_altgr_enter", "open_url"), "https://current.example")
		helpers.assert_eq(manager.get_action_parameter("script__reload", "open_url"), "")
	end)
end)

require("test.tap_binding_publication_contract").register(require("tests.helpers"), "linux")

require("test.binding_publication_authority_contract").register(require("tests.helpers"), "linux")

require("test.keyboard_binding_publication_contract").register(require("tests.helpers"), "linux")
