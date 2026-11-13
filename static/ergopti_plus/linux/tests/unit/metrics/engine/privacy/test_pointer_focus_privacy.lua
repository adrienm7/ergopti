--- tests/unit/metrics/engine/privacy/test_pointer_focus_privacy.lua

--- ==============================================================================
--- MODULE: Native Privacy And Pointer Selection Regression Tests
--- DESCRIPTION:
--- Executes the daemon's original pointer callback with the real secure detector
--- and guard. A strictly unknown navigation epoch must not erase the PRIMARY
--- baseline before it is captured, nor authorize wrapping a later password field.
--- ==============================================================================

local helpers = require("tests.helpers")
local Guard = require("metrics.engine.focus_guard")
local Wrap = require("modules.shortcuts.wrap_on_type")
local Engine = require("hotstrings.engine.engine")

--- Runs the original daemon callback against strict ordinary/password fields.
--- @param initial_role number Initial native role.
--- @return table state
local function fixture(initial_role)
	local previous = package.loaded["platform.focus.secure_field_detector"]
	package.loaded["platform.focus.secure_field_detector"] = nil
	local detector = require("platform.focus.secure_field_detector")
	package.loaded["platform.focus.secure_field_detector"] = previous
	local now, role, primary, reads = 1000, initial_role, "", 0
	local listener, secure, discards = nil, true, 0
	local watch = {
		on_change = function(callback) listener = callback end,
		pump = function() return true end,
		invalidate = function() listener(nil); return true end,
		barrier = function()
			local receipt = { role = role, bus = ":1.1", path = "/owned/field" }
			listener(receipt)
			return receipt
		end,
	}
	local engine, output = Engine.new(), {}
	local guard = Guard.new({ detector = detector, watch = watch,
		keystats = { set_secure_field = function(value) secure = value end },
		now_ms = function() return now end, settle_ms = 250, reset_text = function() engine:reset() end })
	guard.prime()
	local wrap = Wrap.new({
		is_active = function() return not guard.blocks_text() end,
		get_pair = function() return { left = "(", right = ")" } end,
		read_primary = function()
			helpers.assert_eq(discards, 1, "ROI fragments are retired before reading a pointer selection")
			reads = reads + 1; return true, primary
		end,
		type_text = function(text) output[#output + 1] = text; return true end,
	})
	local source = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local body = assert(source:read("*a"):match("local function on_click%(code%)(.-)\n\tend"), "native pointer callback missing")
	source:close()
	local factory = assert((loadstring or load)("return function(secure_focus_guard,wrap_on_type,prediction_engine,WordReset,engine,Logger,LOG,TapHold,keystats) "
		.. "return function() " .. body .. " end end"))()
	local click = factory(guard, wrap, nil, { click_resets_word = function() return true end }, engine,
		helpers.make_logger_stub(), "fixture", { observe_copy_activity = function() end },
		{ discard_roi = function() discards = discards + 1 end })
	return {
		click = click, guard = guard, detector = detector, output = output,
		discards = function() return discards end, reads = function() return reads end, secure = function() return secure end,
		select = function(next_role) primary = "OWNED_SELECTION"; role = next_role; now = now + 250; guard.refresh(false) end,
		wrap = function() return wrap.on_key({ code = 10, char = "(", mods = { shift = true } }) end,
	}
end





-- =========================================
-- =========================================
-- ======= 1/ Pointer Privacy Epochs =======
-- =========================================
-- =========================================

helpers.describe("pointer selection with strict native privacy", function()
	helpers.it("captures the pre-click baseline before the real detector enters unknown", function()
		local state = fixture(61)
		state.click()
		helpers.assert_eq(state.discards(), 1, "each real click retires the ROI fragment")
		helpers.assert_eq(state.reads(), 1, "pointer selection must retain the pre-navigation PRIMARY baseline")
		helpers.assert_eq(state.detector.getVerdict(), "unknown")
		helpers.assert_true(state.secure())
		helpers.assert_true(state.guard.blocks_text(), "navigation remains closed during settling")
		state.select(61)
		helpers.assert_true(state.wrap())
		helpers.assert_eq(state.output[1], "(OWNED_SELECTION)")
	end)

	helpers.it("refuses a password role reached after an ordinary pre-click baseline", function()
		local state = fixture(61)
		state.click()
		helpers.assert_eq(state.discards(), 1, "each real click retires the ROI fragment")
		state.select(40)
		helpers.assert_eq(state.wrap(), false)
		helpers.assert_eq(#state.output, 0)
		helpers.assert_true(state.secure())
	end)

	helpers.it("reads no PRIMARY baseline when the original field is already secure", function()
		local state = fixture(40)
		state.click()
		helpers.assert_eq(state.discards(), 1, "each real click retires the ROI fragment")
		helpers.assert_eq(state.reads(), 0)
		state.select(40)
		helpers.assert_eq(state.wrap(), false)
		helpers.assert_eq(#state.output, 0)
	end)
end)
