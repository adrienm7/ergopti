--- tests/unit/ui/menu/test_menu_tap_holds_isolation.lua

--- ==============================================================================
--- MODULE: The Tap-Holds Menu Is Externally Inert And Has No Engine Controls
--- DESCRIPTION:
--- Building or prewarming the macOS Tap-Holds submenu may read local settings
--- only. It must not probe, launch, signal or stop the user's shared Karabiner
--- runtime, and — the engine being an implementation detail — it offers no row
--- that starts, stops, opens or reports on that engine.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Minimal platform.remap double consumed by the menu builders. Every method
--- that would reach the engine raises, so a build that calls one fails loudly.
--- @param enabled boolean Value reported by get_enabled.
--- @return table remap_double
local function remap_double(enabled)
	return {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Special", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS = { { id = "left_shift", label = "Left Shift" } },
		MOD_COMBOS = { { id = "shift_pair", label = "Shift pair", group = "Shift" } },
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return enabled end,
		set_enabled = function() error("the tap-holds menu has no enable toggle") end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "none" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_combo_combo_action = function() return "none" end,
		get_combo_tap_action = function() return "none" end,
		get_combo_hold_action = function() return "none" end,
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
		open_gui = function() error("the tap-holds menu never opens the engine's GUI") end,
		open_guardian_settings = function() error("guardian approval is a notification, not a row") end,
		regenerate = function() error("building the menu must not regenerate") end,
		stop_lease = function() error("building the menu must not stop the exact lease") end,
	}
end

--- Collects every rendered title, at every depth.
--- @param rows table
--- @param out table|nil
--- @return table
local function all_titles(rows, out)
	out = out or {}
	for _, row in ipairs(rows or {}) do
		if type(row) == "table" then
			if type(row.title) == "string" then out[#out + 1] = row.title end
			if type(row.menu) == "table" then all_titles(row.menu, out) end
		end
	end
	return out
end

helpers.describe("the macOS Tap-Holds menu is inert and has no engine controls", function()
	helpers.it("build and prime perform zero lease, shell, GUI, start or stop actions", function()
		local calls = { status = 0, start = 0, stop = 0, execute = 0, gui = 0 }
		package.loaded["platform.remap.lease_controller"] = {
			status = function()
				calls.status = calls.status + 1
				return "idle", { phase = "idle" }
			end,
			start = function() calls.start = calls.start + 1 return true end,
			stop = function() calls.stop = calls.stop + 1 return true end,
		}
		package.loaded["ui.menu.menu_tap_holds"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {
			execute = function()
				calls.execute = calls.execute + 1
				return "", true
			end,
			application = {
				launchOrFocus = function()
					calls.gui = calls.gui + 1
					return true
				end,
			},
		})
		for _, enabled in ipairs({ true, false }) do
			local ctx = { karabiner = remap_double(enabled), updateMenu = function() end }
			local built = menu.build(ctx)
			menu.prime(ctx)
			helpers.assert_true(type(built) == "table" and type(built.submenu) == "table",
				"the Tap-Holds submenu must render (enabled=" .. tostring(enabled) .. ")")
		end
		helpers.assert_eq(calls.status, 0, "the menu no longer reports the lease, so it never reads it")
		helpers.assert_eq(calls.start, 0)
		helpers.assert_eq(calls.stop, 0)
		helpers.assert_eq(calls.execute, 0)
		helpers.assert_eq(calls.gui, 0)
	end)

	helpers.it("offers no start, stop, status or open-engine row", function()
		package.loaded["ui.menu.menu_tap_holds"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local built = menu.build({ karabiner = remap_double(true), updateMenu = function() end })
		helpers.assert_true(type(built) == "table", "the Tap-Holds submenu must render")
		helpers.assert_eq(built.label, "menu.tapholds.title", "the row carries the Windows tap-holds title")
		helpers.assert_nil(built.action, "the row toggles nothing: the engine is always on")
		local titles = all_titles(built.submenu)
		helpers.assert_true(#titles > 0, "the submenu must not be empty")
		for _, title in ipairs(titles) do
			helpers.assert_nil(title:lower():find("karabiner", 1, true),
				"no row may name the engine: " .. title)
			for _, retired in ipairs({ ".start", ".stop", ".status_", ".open_gui" }) do
				helpers.assert_nil(title:find(retired, 1, true), "retired engine-control row came back: " .. title)
			end
		end
	end)
end)
