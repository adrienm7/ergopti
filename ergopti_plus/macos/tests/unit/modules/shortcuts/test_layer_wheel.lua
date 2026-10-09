--- tests/unit/modules/shortcuts/test_layer_wheel.lua

--- ==============================================================================
--- MODULE: Regression — the navigation layer's wheel runs only inside the layer
---         (layer-wheel-slots, shortcuts-layer-scroll-zero-delta)
--- DESCRIPTION:
--- The navigation layer's Scroll up / Scroll down keys are bindings of
--- layers.toml like any other (volume up and down by default). Karabiner takes
--- no wheel input, so Hammerspoon runs them: bind_layer_wheel tracks the layer
--- through the F20 (entered) and F19 (left) control sentinels and, while it is
--- held, turns a wheel turn in a bound direction into that binding's strokes.
---
--- ROOT CAUSES ENCODED HERE:
--- 1. The "Layer + Scroll = Volume" shortcut it replaces armed on a held F19
---    that no generated Karabiner rule emitted any more, so it never ran; the
---    layer's own sentinels are now what arms the wheel, and a wheel turn
---    outside the layer, or in a direction the layer leaves unbound, scrolls.
--- 2. A zero delta is a scroll-PHASE event (phase began / phase ended /
---    momentum ended), not movement: `delta > 0` read it as "down" and
---    math.max(1, …) manufactured a notch, so every upward scroll ended lower
---    than it started. It must pass untouched.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================================================
-- ============================================================================
-- ======= 1/ Test harness ====================================================
-- ============================================================================
-- ============================================================================

--- Loads the system actions with an eventtap stub that captures the scroll
--- tap's callback, every system key event posted, and every key stroke sent.
--- @param slots table|nil axis -> direction -> slot; the default binds volume
---   up on a turn up and volume down on a turn down.
--- @return table ctx { scroll, posted, strokes, asked, owner, hs }.
local function make_ctx(slots)
	package.loaded["infra.keycodes"] = nil
	package.loaded["modules.shortcuts.actions.system"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_provenance"] = nil

	local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")
	local hs  = _G.hs
	local ctx = { posted = {}, strokes = {}, asked = {}, taps = {}, hs = hs }

	hs.eventtap.new = function(_types, cb)
		ctx.taps[#ctx.taps + 1] = cb
		local tap = { enabled = false }
		function tap:start() self.enabled = true; return self end
		function tap:stop() self.enabled = false; return self end
		function tap:isEnabled() return self.enabled end
		return tap
	end
	hs.eventtap.event.newSystemKeyEvent = function(key, is_down)
		return {
			post = function(self)
				ctx.posted[#ctx.posted + 1] = { key = key, is_down = is_down }
				return self
			end,
		}
	end
	-- The same module table system.lua holds, so the spy sees its calls.
	require("adapters.synthetic_input").emit_key_stroke = function(mods, keycode)
		ctx.strokes[#ctx.strokes + 1] = { mods = mods, keycode = keycode }
		return true
	end

	slots = slots or {
		vertical = {
			[1]  = { code = "WheelUp", strokes = { { system = "SOUND_UP" } } },
			[-1] = { code = "WheelDown", strokes = { { system = "SOUND_DOWN" } } },
		},
	}
	ctx.owner = sys.bind_layer_wheel(nil, function(axis, direction)
		ctx.asked[#ctx.asked + 1] = { axis = axis, direction = direction }
		return (slots[axis] or {})[direction]
	end)
	helpers.assert_not_nil(ctx.owner, "the wheel binding must publish its owner")
	helpers.assert_eq(#ctx.taps, 1, "the layer's wheel takes one scroll tap and no key tap")
	ctx.scroll = ctx.taps[1]
	return ctx
end

--- Drains the retained FIFO that runs the strokes after the eventtap returns.
--- @param ctx table Harness context.
local function fire_post_callback_actions(ctx)
	for _, candidate in ipairs(ctx.hs.timer.__timers or {}) do
		if candidate.running and candidate.delay == 0 and type(candidate.fire) == "function" then
			candidate:fire()
			return
		end
	end
	error("no retained post-eventtap dispatcher is running", 2)
end

--- Publishes one navigation-layer sentinel as the keymap tap that claims it.
--- @param name string "F20_LAYER_NAV_ENTERED" or "F19_LAYER_NAV_EXITED".
local function sentinel(name)
	local keycode = require("infra.keycodes")[name]
	helpers.assert_true(require("modules.keymap.control_sentinels").claim_key(keycode, true, {}),
		name .. " must be a claimed control sentinel")
end

--- Builds a physical scrollWheel event.
--- @param vertical any What the vertical delta reads.
--- @param horizontal any|nil What the horizontal delta reads (0 when nil).
--- @return table Fake CGEvent.
local function scroll_event(vertical, horizontal)
	local properties = _G.hs.eventtap.event.properties
	return {
		getProperty = function(_self, property)
			if property == properties.scrollWheelEventDeltaAxis1 then return vertical end
			if property == properties.scrollWheelEventDeltaAxis2 then return horizontal or 0 end
			return 0
		end,
		getType  = function() return _G.hs.eventtap.event.types.scrollWheel end,
		getFlags = function() return {} end,
	}
end




-- ============================================================================
-- ============================================================================
-- ======= 2/ Only inside the layer ===========================================
-- ============================================================================
-- ============================================================================

helpers.describe("shortcuts.bind_layer_wheel: the layer's sentinels arm the wheel", function()

	helpers.it("scrolls as usual before the layer is entered", function()
		local ctx = make_ctx()
		local consumed = ctx.scroll(scroll_event(3))
		helpers.assert_eq(consumed, false, "a plain scroll must pass through untouched")
		helpers.assert_eq(#ctx.asked, 0, "outside the layer no binding is even looked up")
		ctx.owner:delete()
	end)

	helpers.it("runs the bound action once per notch while the layer is held", function()
		local ctx = make_ctx()
		sentinel("F20_LAYER_NAV_ENTERED")

		local consumed = ctx.scroll(scroll_event(3))
		helpers.assert_eq(consumed, true, "a bound turn must consume the scroll so the app does not also scroll")
		helpers.assert_eq(#ctx.posted, 0, "the strokes must not run inside the CGEventTap callback")
		fire_post_callback_actions(ctx)

		helpers.assert_eq(#ctx.posted, 6, "three notches must post three down/up pairs")
		for i = 1, 6, 2 do
			helpers.assert_eq(ctx.posted[i].key, "SOUND_UP")
			helpers.assert_eq(ctx.posted[i].is_down, true, "each pair must start with a key-down")
			helpers.assert_eq(ctx.posted[i + 1].is_down, false, "each pair must end with a key-up")
		end
		ctx.owner:delete()
	end)

	helpers.it("runs the other direction's binding on a turn down", function()
		local ctx = make_ctx()
		sentinel("F20_LAYER_NAV_ENTERED")
		helpers.assert_eq(ctx.scroll(scroll_event(-2)), true)
		fire_post_callback_actions(ctx)
		helpers.assert_eq(#ctx.posted, 4, "two notches must post two down/up pairs")
		helpers.assert_eq(ctx.posted[1].key, "SOUND_DOWN")
		ctx.owner:delete()
	end)

	helpers.it("scrolls again once the layer is left", function()
		local ctx = make_ctx()
		sentinel("F20_LAYER_NAV_ENTERED")
		sentinel("F19_LAYER_NAV_EXITED")
		helpers.assert_eq(ctx.scroll(scroll_event(1)), false,
			"the F19 exit sentinel must disarm the wheel synchronously")
		helpers.assert_eq(#ctx.asked, 0)
		ctx.owner:delete()
	end)

	helpers.it("scrolls in a direction the layer leaves unbound", function()
		local ctx = make_ctx({
			vertical = { [1] = { code = "WheelUp", strokes = { { system = "SOUND_UP" } } } },
		})
		sentinel("F20_LAYER_NAV_ENTERED")
		helpers.assert_eq(ctx.scroll(scroll_event(-1)), false,
			"an unbound direction must keep scrolling inside the layer")
		helpers.assert_eq(ctx.asked[1].axis, "vertical")
		helpers.assert_eq(ctx.asked[1].direction, -1)
		ctx.owner:delete()
	end)

	helpers.it("sends a keystroke binding with its modifiers", function()
		local ctx = make_ctx({
			vertical = { [1] = { code = "WheelUp", strokes = { { mods = { "cmd" }, keycode = 126 } } } },
		})
		sentinel("F20_LAYER_NAV_ENTERED")
		helpers.assert_eq(ctx.scroll(scroll_event(2)), true)
		fire_post_callback_actions(ctx)
		helpers.assert_eq(#ctx.strokes, 2, "one stroke per notch")
		helpers.assert_eq(ctx.strokes[1].keycode, 126)
		helpers.assert_eq(ctx.strokes[1].mods, { "cmd" })
		helpers.assert_eq(#ctx.posted, 0, "a keystroke is no system key event")
		ctx.owner:delete()
	end)

	helpers.it("asks the horizontal slots for a sideways turn, a positive delta being a turn left", function()
		local ctx = make_ctx({
			horizontal = { [-1] = { code = "WheelLeft", strokes = { { system = "MUTE" } } } },
		})
		sentinel("F20_LAYER_NAV_ENTERED")
		helpers.assert_eq(ctx.scroll(scroll_event(0, 1)), true)
		helpers.assert_eq(ctx.asked[1].axis, "horizontal")
		helpers.assert_eq(ctx.asked[1].direction, -1)
		fire_post_callback_actions(ctx)
		helpers.assert_eq(ctx.posted[1].key, "MUTE")
		ctx.owner:delete()
	end)

	helpers.it("drops its layer listener when deleted", function()
		local ctx = make_ctx()
		local Sentinels = require("modules.keymap.control_sentinels")
		local real_set_listener = Sentinels.set_listener
		local dropped = {}
		Sentinels.set_listener = function(name, callback)
			if callback == nil then dropped[#dropped + 1] = name end
			return real_set_listener(name, callback)
		end
		local deleted = ctx.owner:delete()
		Sentinels.set_listener = real_set_listener
		helpers.assert_eq(deleted, true)
		helpers.assert_eq(#dropped, 1, "the deleted binding must stop listening to the layer")
	end)

	helpers.it("refuses a missing slot lookup", function()
		package.loaded["modules.shortcuts.actions.system"] = nil
		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")
		local ok = pcall(sys.bind_layer_wheel, nil, nil)
		helpers.assert_eq(ok, false, "a wheel with no bindings to read is a caller bug")
	end)
end)




-- ============================================================================
-- ============================================================================
-- ======= 3/ A zero delta is a phase event, not movement =====================
-- ============================================================================
-- ============================================================================

helpers.describe("shortcuts.bind_layer_wheel: a zero delta must not run a binding", function()

	helpers.it("passes a zero-delta phase event and posts nothing", function()
		local ctx = make_ctx()
		sentinel("F20_LAYER_NAV_ENTERED")

		local consumed = ctx.scroll(scroll_event(0))

		helpers.assert_eq(consumed, false,
			"returning true would swallow a phase event the layer never acted on")
		helpers.assert_eq(#ctx.posted, 0,
			"a zero delta is a scroll-PHASE marker, not movement: it must never run a binding")
		helpers.assert_eq(#ctx.asked, 0, "a phase event has no direction to look up")
		ctx.owner:delete()
	end)

	helpers.it("still ignores a non-numeric delta", function()
		local ctx = make_ctx()
		sentinel("F20_LAYER_NAV_ENTERED")
		local consumed = ctx.scroll(scroll_event(nil))
		helpers.assert_eq(consumed, false, "a nil delta must not consume the event")
		helpers.assert_eq(#ctx.posted, 0, "a nil delta must not run a binding")
		ctx.owner:delete()
	end)
end)
