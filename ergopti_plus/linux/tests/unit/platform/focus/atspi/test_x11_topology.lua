--- tests/unit/platform/focus/atspi/test_x11_topology.lua

--- ==============================================================================
--- MODULE: X11 Window Topology Query Tests
--- DESCRIPTION:
--- The window-topology rows read the focused window's geometry, its EWMH state
--- and its RandR monitor from the X server in this process, without forking.
--- The protocol logic is driven through a scripted transport; the libxcb calls
--- themselves need a real X server (tests/hardware/run_x11_focus_receipt.lua).
--- ==============================================================================

local helpers = require("tests.helpers")

local ATOMS = { _NET_ACTIVE_WINDOW = 301, _NET_WM_STATE = 310, _NET_WM_STATE_HIDDEN = 311,
	_NET_WM_STATE_MAXIMIZED_VERT = 312, _NET_WM_STATE_MAXIMIZED_HORZ = 313, _NET_WM_STATE_FULLSCREEN = 314 }

local function le32(value)
	return string.char(value % 256, math.floor(value / 256) % 256,
		math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

--- Loads a fresh module bound to a scripted transport.
--- @param state table { active, geometry = { x, y, w, h }, states = { atom names }, monitors }
--- @return table focus
local function bound(state)
	local focus = helpers.load_module("platform.focus.x11_focus")
	focus._set_transport({
		connect = function() return true end,
		disconnect = function() end,
		healthy = function() return true end,
		root = function() return 1 end,
		intern = function(name) return ATOMS[name] end,
		geometry = function(window)
			if window ~= state.active or not state.geometry then return nil end
			return (table.unpack or unpack)(state.geometry)
		end,
		monitors = function() return state.monitors end,
		property = function(window, property)
			if window == 1 and property == ATOMS._NET_ACTIVE_WINDOW then
				if not state.active then return nil end
				return { type = 33, format = 32, bytes = le32(state.active) }
			end
			if window == state.active and property == ATOMS._NET_WM_STATE and state.states then
				local packed = {}
				for _, name in ipairs(state.states) do packed[#packed + 1] = le32(ATOMS[name]) end
				return { type = 4, format = 32, bytes = table.concat(packed) }
			end
			return nil
		end,
	})
	return focus
end

local MONITORS = { { x = 0, y = 0, width = 1920, height = 1080 }, { x = 1920, y = 0, width = 2560, height = 1440 } }

helpers.describe("x11_focus: the focused window's topology", function()
	helpers.it("linux-x11-topology-geometry: root coordinates, size and the monitor holding the centre", function()
		local observation = bound({ active = 77, geometry = { 2000, 40, 900, 700 }, monitors = MONITORS }).active_topology()
		helpers.assert_eq(observation, { window = 77, x = 2000, y = 40, w = 900, h = 700, state = "normal",
			monitor = { id = "1920,0,4480,1440", width = 2560 } })
	end)

	helpers.it("linux-x11-topology-state: EWMH hidden is minimized, both axes or fullscreen is maximized", function()
		local function state_of(states)
			return bound({ active = 5, geometry = { 0, 0, 10, 10 }, states = states }).active_topology().state
		end
		helpers.assert_eq(state_of({ "_NET_WM_STATE_MAXIMIZED_VERT" }), "normal", "one axis is not maximized")
		helpers.assert_eq(state_of({ "_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ" }), "maximized")
		helpers.assert_eq(state_of({ "_NET_WM_STATE_FULLSCREEN" }), "maximized")
		helpers.assert_eq(state_of({ "_NET_WM_STATE_HIDDEN", "_NET_WM_STATE_FULLSCREEN" }), "minimized")
	end)

	helpers.it("linux-x11-topology-unanswered: no window, no geometry or no RandR is said, never invented", function()
		local none, reason = bound({ active = nil }).active_topology()
		helpers.assert_nil(none)
		helpers.assert_eq(reason, "no active window")
		helpers.assert_nil((bound({ active = 5 }).active_topology()), "a window without geometry is no observation")
		local alone = bound({ active = 5, geometry = { 0, 0, 10, 10 } }).active_topology()
		helpers.assert_nil(alone.monitor, "without RandR no monitor identity is guessed")
	end)
end)
