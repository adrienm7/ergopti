--- tests/unit/modules/shortcuts/test_layer_scroll_zero_delta.lua

--- ==============================================================================
--- MODULE: Regression — a zero-delta scroll must not emit a volume-DOWN
--- DESCRIPTION:
--- bind_layer_scroll maps "layer key held + scroll wheel" to system volume. Its
--- delta guard rejected non-numbers but NOT zero:
---     if type(delta) ~= "number" then return false end
---     local key  = delta > 0 and "SOUND_UP" or "SOUND_DOWN"
---     local reps = math.max(1, math.floor(math.abs(delta)))
--- macOS brackets every scroll gesture with scrollWheel PHASE events (phase began,
--- phase ended, momentum ended) whose delta is exactly 0. For each of those,
--- `delta > 0` is false so the key became "SOUND_DOWN", and math.max(1, …) forced
--- one real repetition out of zero movement. Every upward scroll while the layer
--- key was held therefore ended one or more notches LOWER than it started.
--- The callback also returned true, consuming a phase event it had no business
--- swallowing.
---
--- ROOT CAUSE ENCODED HERE: a zero delta is a phase marker, not movement. It must
--- fall through untouched — no key event posted, and the event passed on.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================================================
-- ============================================================================
-- ======= 1/ Test harness ====================================================
-- ============================================================================
-- ============================================================================

local DELTA_PROPERTY = "scrollWheelEventDeltaAxis1"

--- Loads the system actions module with eventtap stubs that capture the two taps
--- bind_layer_scroll creates (the key tap that tracks the layer key, and the
--- scroll tap under test) plus every system key event posted.
--- @return table ctx {key_cb, scroll_cb, posted=array of {key, isDown}, f19=int}.
local function make_layer_scroll_ctx()
	package.loaded["lib.keycodes"] = nil
	package.loaded["modules.shortcuts.actions.system"] = nil

	local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")
	local hs  = _G.hs

	local ctx = { posted = {}, taps = {} }

	-- bind_layer_scroll calls eventtap.new twice: first the key tap, then the
	-- scroll tap. Capture both callbacks in creation order.
	hs.eventtap.new = function(_types, cb)
		ctx.taps[#ctx.taps + 1] = cb
		return { start = function() end, stop = function() end }
	end

	hs.eventtap.event.properties = { [DELTA_PROPERTY] = DELTA_PROPERTY }
	hs.eventtap.event.newSystemKeyEvent = function(key, isDown)
		return { post = function() ctx.posted[#ctx.posted + 1] = { key = key, isDown = isDown } end }
	end

	sys.bind_layer_scroll()
	ctx.key_cb    = ctx.taps[1]
	ctx.scroll_cb = ctx.taps[2]
	helpers.assert_true(type(ctx.key_cb) == "function",    "the key tap callback must be captured")
	helpers.assert_true(type(ctx.scroll_cb) == "function", "the scroll tap callback must be captured")

	ctx.f19 = require("lib.keycodes").F19_VOLUME_SCROLL_MODIFIER
	return ctx
end

--- Fires a fake F19 keyDown through the key tap so the scroll tap sees the layer
--- as held (otherwise every scroll short-circuits on `if not layer_held`).
--- @param ctx table The harness context.
local function hold_layer_key(ctx)
	ctx.key_cb({
		getKeyCode = function() return ctx.f19 end,
		getType    = function() return _G.hs.eventtap.event.types.keyDown end,
		getFlags   = function() return {} end,
	})
end

--- Builds a fake scrollWheel event reporting the given delta.
--- @param delta any The value getProperty returns for the axis-1 delta.
--- @return table Fake CGEvent.
local function fake_scroll_event(delta)
	return {
		getProperty = function(_self, _prop) return delta end,
		getType     = function() return _G.hs.eventtap.event.types.scrollWheel end,
		getFlags    = function() return {} end,
	}
end




-- ============================================================================
-- ============================================================================
-- ======= 2/ A zero delta is a phase event, not movement =====================
-- ============================================================================
-- ============================================================================

helpers.describe("shortcuts.bind_layer_scroll: a zero delta must not change the volume", function()

	helpers.it("posts no volume event at all for a zero-delta scroll", function()
		local ctx = make_layer_scroll_ctx()
		hold_layer_key(ctx)

		ctx.scroll_cb(fake_scroll_event(0))

		-- THE regression: `delta > 0` was false for 0, so the key resolved to
		-- SOUND_DOWN, and math.max(1, math.floor(0)) manufactured one real
		-- repetition — silently lowering the volume on every scroll gesture.
		helpers.assert_eq(#ctx.posted, 0,
			"a zero delta is a scroll-PHASE marker (phase began / ended / momentum ended), "
			.. "not movement — it must never emit SOUND_UP or SOUND_DOWN")
	end)

	helpers.it("lets the phase event pass through instead of consuming it", function()
		local ctx = make_layer_scroll_ctx()
		hold_layer_key(ctx)

		local consumed = ctx.scroll_cb(fake_scroll_event(0))

		helpers.assert_eq(consumed, false,
			"returning true would swallow a phase event the layer scroll never acted on")
	end)

	helpers.it("still ignores a non-numeric delta", function()
		local ctx = make_layer_scroll_ctx()
		hold_layer_key(ctx)

		local consumed = ctx.scroll_cb(fake_scroll_event(nil))

		helpers.assert_eq(#ctx.posted, 0, "a nil delta must not post a volume event")
		helpers.assert_eq(consumed, false, "a nil delta must not consume the event")
	end)
end)




-- ============================================================================
-- ============================================================================
-- ======= 3/ Real movement still works =======================================
-- ============================================================================
-- ============================================================================

helpers.describe("shortcuts.bind_layer_scroll: real movement still drives the volume", function()

	helpers.it("a +3 delta posts exactly three SOUND_UP down/up pairs and consumes the event", function()
		local ctx = make_layer_scroll_ctx()
		hold_layer_key(ctx)

		local consumed = ctx.scroll_cb(fake_scroll_event(3))

		helpers.assert_eq(#ctx.posted, 6, "three repetitions must post three down/up pairs")
		for i = 1, 6 do
			helpers.assert_eq(ctx.posted[i].key, "SOUND_UP",
				"a positive delta must raise the volume")
		end
		for i = 1, 6, 2 do
			helpers.assert_eq(ctx.posted[i].isDown, true,   "each pair must start with a key-down")
			helpers.assert_eq(ctx.posted[i + 1].isDown, false, "each pair must end with a key-up")
		end
		helpers.assert_eq(consumed, true,
			"a real volume adjustment must consume the scroll so the app does not also scroll")
	end)

	helpers.it("a negative delta still lowers the volume", function()
		local ctx = make_layer_scroll_ctx()
		hold_layer_key(ctx)

		local consumed = ctx.scroll_cb(fake_scroll_event(-2))

		helpers.assert_eq(#ctx.posted, 4, "two repetitions must post two down/up pairs")
		helpers.assert_eq(ctx.posted[1].key, "SOUND_DOWN", "a negative delta must lower the volume")
		helpers.assert_eq(consumed, true, "a real volume adjustment must consume the scroll")
	end)

	helpers.it("does nothing when the layer key is not held", function()
		local ctx = make_layer_scroll_ctx()
		-- Deliberately no hold_layer_key() call.

		local consumed = ctx.scroll_cb(fake_scroll_event(3))

		helpers.assert_eq(#ctx.posted, 0, "a plain scroll must never touch the volume")
		helpers.assert_eq(consumed, false, "a plain scroll must pass through untouched")
	end)
end)
