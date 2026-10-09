--- tests/unit/modules/gestures/test_click_drag_is_not_a_gesture.lua

--- ==============================================================================
--- MODULE: A click-drag is never a gesture (click-drag-selection)
--- DESCRIPTION:
--- Drives the real gesture engine with trackpad frames while a mouse button is
--- held, as a click-drag text selection produces them, and checks that no
--- gesture action fires and nothing blocks the pointer's events.
---
--- ROOT CAUSE ENCODED:
--- The engine read every set of two or more contacts as a gesture. Pressing the
--- trackpad with one finger and sliding another, or dragging after a tap to
--- click, is two moving contacts: the engine fired the two-finger swipe action
--- (arrow_up in the recommended preset) or a three-finger tap during the drag,
--- and the text selection was lost. A held button now hands the contacts to the
--- pointer until the last finger lifts.
--- ==============================================================================

local helpers = require("tests.helpers")

local INJECTED = { "modules.gestures.engine", "adapters.mouse_control", "infra.timings", "infra.logger" }

local current_time = 0

--- Contacts at one horizontal offset, in trackpad units.
--- @param count number Number of contacts.
--- @param x number Horizontal position of the first contact.
--- @return table touches
local function contacts(count, x)
	local touches = {}
	for index = 1, count do
		touches[index] = { absoluteVector = { position = { x = x + index, y = 50 } } }
	end
	return touches
end

--- Runs body with a fresh engine whose button state the test controls.
--- @param body function body(engine, fired, buttons)
local function with_engine(body)
	local saved = {}
	for _, name in ipairs(INJECTED) do saved[name] = package.loaded[name] end
	local buttons = { down = false }
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["infra.logger"] = nil
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			if key == "tap_max_ms" then return 0.5 end
			if key == "finger_confirm_ms" then return 0.05 end
			if key == "finger_drop_confirm_ms" then return 0.2 end
			if key == "finger_count_stable_ms" then return 0.06 end
			return 0.05
		end,
	}
	package.loaded["adapters.mouse_control"] = {
		any_button_down = function() return buttons.down end,
	}
	local ok, err = xpcall(function()
		local _ = helpers.load_with_stubs("infra.logger")
		local engine = helpers.load_with_stubs("modules.gestures.engine")
		_G.hs.timer.secondsSinceEpoch = function() return current_time end
		local fired = {}
		engine.init({
			enabled = true,
			ga = { swipe_2_left = "arrow_up", swipe_3_left = "word_prev", tap_3 = "left_click_toggle" },
			modes = {},
			sensitivities = {},
		}, {
			execute_single = function(action)
				fired[#fired + 1] = action
				return true
			end,
			execute_axis = function() return false end,
			set_gesture_in_progress = function() end,
		})
		body(engine, fired, buttons)
		engine.stop()
	end, debug.traceback)
	for _, name in ipairs(INJECTED) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Slides a contact set to the left, one frame every 20 ms, then lifts it.
--- @param engine table Gesture engine.
--- @param count number Number of contacts.
--- @param on_frame function|nil on_frame(index) runs before each moving frame.
local function slide_left(engine, count, on_frame)
	current_time = 0
	for step = 0, 10 do
		if on_frame then on_frame(step) end
		current_time = step * 0.02
		engine.process_frame(contacts(count, 60 - step * 2))
	end
	current_time = 0.3
	engine.process_frame({})
end

--- @return boolean True when a tap the engine created subscribes to a mouse button.
local function engine_taps_watch_buttons()
	local types = _G.hs.eventtap.event.types
	local buttons = {
		[types.leftMouseDown] = true, [types.leftMouseUp] = true,
		[types.rightMouseDown] = true, [types.rightMouseUp] = true,
	}
	for _, tap in ipairs(_G.hs.eventtap.__taps) do
		for _, event_type in ipairs(tap.types or {}) do
			if buttons[event_type] then return true end
		end
	end
	return false
end

helpers.describe("a click-drag is never a gesture (click-drag-selection)", function()
	helpers.it("(click-drag-selection) the same frames without a held button are a swipe", function()
		-- The control: these frames do fire, so the silence below is the button's.
		with_engine(function(engine, fired)
			slide_left(engine, 2)
			helpers.assert_eq(fired, { "arrow_up" })
		end)
	end)

	helpers.it("(click-drag-selection) two contacts sliding with a button held fire nothing", function()
		with_engine(function(engine, fired, buttons)
			slide_left(engine, 2, function(step) buttons.down = step >= 1 end)
			helpers.assert_eq(fired, {},
				"pressing with one finger and sliding another selects text, it is no swipe")
		end)
	end)

	helpers.it("(click-drag-selection) three contacts dragging do not block the pointer's scrolling", function()
		with_engine(function(engine, fired, buttons)
			buttons.down = true
			current_time = 0
			engine.process_frame(contacts(3, 60))
			helpers.assert_eq(engine.is_blocking_scroll(), false,
				"a drag must leave every pointer event to macOS")
			slide_left(engine, 3)
			helpers.assert_eq(fired, {})
			helpers.assert_eq(engine_taps_watch_buttons(), false,
				"no engine tap may see, delay or consume a button or drag event")
		end)
	end)

	helpers.it("(click-drag-selection) a tap during a held click is no tap", function()
		with_engine(function(engine, fired, buttons)
			buttons.down = true
			current_time = 0
			engine.process_frame(contacts(3, 60))
			current_time = 0.05
			engine.process_frame({})
			helpers.assert_eq(fired, {}, "tap_3 would have held a synthetic left click mid-drag")
		end)
	end)

	helpers.it("(click-drag-selection) contacts stay the pointer's until the last lift", function()
		with_engine(function(engine, fired, buttons)
			-- The button comes up before the fingers leave: the rest of the slide
			-- is still the drag's.
			slide_left(engine, 2, function(step) buttons.down = step >= 1 and step <= 3 end)
			helpers.assert_eq(fired, {})
			-- The next contact set is a gesture again.
			buttons.down = false
			slide_left(engine, 2)
			helpers.assert_eq(fired, { "arrow_up" })
		end)
	end)
end)

helpers.describe("the mouse button read (click-drag-selection)", function()
	helpers.it("(click-drag-selection) any held button reads as down, none as up", function()
		local saved = package.loaded["adapters.mouse_control"]
		package.loaded["adapters.mouse_control"] = nil
		local ok, err = xpcall(function()
			local MouseControl = helpers.load_with_stubs("adapters.mouse_control")
			_G.hs.eventtap.checkMouseButtons = function() return {} end
			helpers.assert_eq(MouseControl.any_button_down(), false)
			_G.hs.eventtap.checkMouseButtons = function() return { left = true, [1] = true } end
			helpers.assert_eq(MouseControl.any_button_down(), true)
		end, debug.traceback)
		package.loaded["adapters.mouse_control"] = saved
		if not ok then error(err, 0) end
	end)
end)
