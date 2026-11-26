--- tests/unit/adapters/layout/test_keyboard_layout_active_group.lua

--- ==============================================================================
--- MODULE: Keyboard Layout — the layout KDE has active
--- DESCRIPTION:
--- KWin compiles every layout of kxkbrc into the one keymap it sends and
--- switches its group itself. `xkbcli dump-keymap-wayland` prints that keymap
--- with no state, and a fresh XKB state sits in group 1: with « us, fr » and
--- the French layout active, the daemon resolved every key on the US one, so
--- the field report of 2026-11-25 read a↔q and m↔, swapped. These cases load a
--- real two-group keymap into the real libxkbcommon capture and pin that
--- capture, injection and the diagnostics follow the group the KDE keyboard
--- daemon reports (active-group).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Two layouts, US first, as kxkbrc lists them; libxkbcommon resolves the
-- includes from the system XKB tree.
local TWO_GROUPS = table.concat({
	"xkb_keymap {",
	"\txkb_keycodes { include \"evdev+aliases(qwerty)\" };",
	"\txkb_types { include \"complete\" };",
	"\txkb_compat { include \"complete\" };",
	"\txkb_symbols { include \"pc+us+fr:2+inet(evdev)\"",
	"\t\tname[Group1]=\"English (US)\";",
	"\t\tname[Group2]=\"French\";",
	"\t};",
	"};",
	"",
}, "\n")

local KEY_Q, KEY_A = 16, 30

--- Loads keyboard_layout over the real capture, a Wayland KDE session and a
--- shell that answers the dump and the KDE daemon's active layout.
--- @param active string|nil The daemon's getLayout reply; nil when gdbus is absent.
--- @return table layout, table shell
local function load_kde(active)
	package.loaded["adapters.xkb_capture"] = nil
	local Shell = helpers.load_module("core.process.adapters.shell_runner")
	Shell._set_runner(function(cmd)
		if cmd:match("^command %-v") then return cmd:find("gdbus", 1, true) ~= nil and active ~= nil end
		if cmd:find("dump-keymap-wayland", 1, true) then return TWO_GROUPS end
		if cmd:find("org.kde.KeyboardLayouts.getLayout", 1, true) then return active or "" end
		return ""
	end)
	helpers.load_module("core.ui.engine.display_server")._set_for_test("wayland", "KDE")
	return helpers.load_module("adapters.keyboard_layout"), Shell
end

local function cleanup(Shell)
	Shell._reset_runner()
	require("core.ui.engine.display_server")._set_for_test(nil, nil)
	local capture = package.loaded["adapters.xkb_capture"]
	if capture and capture.clear then capture.clear() end
	package.loaded["adapters.xkb_capture"] = nil
	package.loaded["adapters.keyboard_layout"] = nil
end

--- Runs body over a loaded layout and always cleans up.
local function with_kde(active, body)
	local layout, Shell = load_kde(active)
	local ok, err = pcall(function()
		local real = os.getenv
		os.getenv = function(name) if name == "DISPLAY" then return nil end return real(name) end
		local refreshed = layout.refresh(nil)
		os.getenv = real
		body(layout, refreshed)
	end)
	cleanup(Shell)
	if not ok then error(err, 0) end
end

helpers.describe("keyboard_layout: follows the layout KDE has active (active-group)", function()
	helpers.it("types on the second layout when KDE reports it active (active-group)", function()
		with_kde("(uint32 1,)", function(layout, refreshed)
			helpers.assert_true(refreshed, "the two-group keymap must load")
			helpers.assert_eq(layout.layout_name(), "French", "the diagnostics name the active layout")
			helpers.assert_eq(layout.resolve("a").keycode, KEY_Q, "on AZERTY « a » is the key QWERTY calls Q")
			helpers.assert_eq(layout.resolve("q").keycode, KEY_A)
			helpers.assert_true(layout.resolve("é") ~= nil, "« é » is typable on the French layout")
		end)
	end)

	helpers.it("stays on the first layout when KDE reports it active (active-group)", function()
		with_kde("(uint32 0,)", function(layout, refreshed)
			helpers.assert_true(refreshed)
			helpers.assert_eq(layout.layout_name(), "English (US)")
			helpers.assert_eq(layout.resolve("a").keycode, KEY_A)
		end)
	end)

	helpers.it("keeps the active layout across a capture state reset (active-group)", function()
		with_kde("(uint32 1,)", function(layout)
			local capture = require("adapters.xkb_capture")
			helpers.assert_true(capture.reset_state(), "the reset recreates the state")
			helpers.assert_true(layout.publish_current_capture(nil), "the reset capture publishes again")
			helpers.assert_eq(layout.resolve("a").keycode, KEY_Q, "the reset state is still on the French layout")
		end)
	end)

	helpers.it("publishes a fresh refresh without a capture reset (layout-change-publisher)", function()
		-- A tray layout change refreshes the map, then the hook asks the same
		-- publisher a device reacquisition uses. With no capture reset between
		-- them, the republish refused the fresh receipt's provenance
		-- (« inverse-reset-provenance-refused ») and the change was reported
		-- as « Layout 'azerty' refused ». The current inverse is already
		-- published: there is nothing to republish.
		with_kde("(uint32 1,)", function(layout, refreshed)
			helpers.assert_true(refreshed)
			helpers.assert_true(layout.publish_current_capture(nil), "the fresh map is the current capture")
			helpers.assert_true(layout.is_ready())
			helpers.assert_eq(layout.resolve("a").keycode, KEY_Q, "the published inverse is still the French one")
			local capture = require("adapters.xkb_capture")
			helpers.assert_true(capture.reset_state(), "the reset recreates the state")
			helpers.assert_true(layout.publish_current_capture(nil), "a later reset still republishes")
		end)
	end)

	helpers.it("refuses a layout index the keymap does not have (active-group)", function()
		with_kde("(uint32 5,)", function(layout, refreshed)
			helpers.assert_eq(refreshed, false, "an index past the keymap's layouts is refused, not group 1")
			helpers.assert_eq(layout.resolve("a"), nil)
		end)
	end)
end)
