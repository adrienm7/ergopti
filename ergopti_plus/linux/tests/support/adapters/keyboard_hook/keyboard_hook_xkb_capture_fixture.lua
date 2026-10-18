--- tests/support/adapters/keyboard_hook/keyboard_hook_xkb_capture_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_keyboard_hook_xkb_capture
--- DESCRIPTION:
--- Prelude shared by the test_keyboard_hook_xkb_capture_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local function key(code, value)
	return { type = 1, code = code, value = value }
end

-- These actual Reader/Hook consumers use controlled FFI bytes, not kernel devices.
local function with_position_capture(options, body)
	local previous = package.loaded["adapters.xkb_capture"]
	package.loaded["adapters.xkb_capture"] = nil
	local Capture = require("adapters.xkb_capture")
	local state = { epoch = 7 }
	local backend = { create = function() return { identity = "controlled-position-map" } end,
		destroy = function() end, update_key = function() end, key_sym = function(_, code) return code end,
		sym_utf8 = function(code) return code == 30 and "a" or nil end,
		key_utf8 = function(_, code) return code == 30 and "a" or nil end,
		compose_feed = function() end, compose_status = function() return "nothing" end,
		compose_reset = function() end, modifier_role = function(code) return require("infra.evdev_codes").MODIFIER_OF[code] end }
	backend.source_group = function()
		local epoch = state.epoch
		return 0, epoch, function() return state.epoch == epoch end
	end
	Capture._set_backend(backend); assert(Capture.load("controlled-position-source", "C.UTF-8"))
	options = options or {}; options.position_bits, options.capture = true, Capture
	local called, detail = pcall(function()
		require("tests.support.input_owner_fixture").with_session(options, function(session) body(session, state, Capture) end)
	end)
	Capture._reset_backend(); package.loaded["adapters.xkb_capture"] = previous
	if not called then error(detail, 0) end
end

return {
	helpers = helpers,
	key = key,
	with_position_capture = with_position_capture,
}
