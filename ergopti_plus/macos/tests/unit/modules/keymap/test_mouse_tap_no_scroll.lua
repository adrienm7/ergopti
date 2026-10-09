--- tests/unit/modules/keymap/test_mouse_tap_no_scroll.lua

--- ==============================================================================
--- MODULE: modules.keymap — mouse_tap scroll exclusion regression
--- DESCRIPTION:
--- Locks down the bug where the keymap mouse_tap eventtap intercepted
--- `scrollWheel` events and called `LLMBridge.check_nav_reset()` and
--- `LLMBridge.reset_predictions()` on every scroll frame (~60 Hz).
---
--- Root cause: scroll events do not move the text cursor — there is no reason
--- to reset the LLM buffer or predictions when the user scrolls. However, both
--- calls involve ObjC dispatch into Hammerspoon's event loop, adding severe
--- latency at 60 Hz: this caused both 2-finger scroll lag (gestures engine
--- blocked) and typing lag (LLM callbacks saturating the run loop) whenever
--- the LLM menu was active.
---
--- Fix: `scrollWheel` was removed from the eventtap type list in `mouse_tap`.
--- This test asserts the exclusion is permanent.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_source(module_name)
	local path = package.searchpath(module_name, package.path)
	helpers.assert_true(
		type(path) == "string" and path ~= "",
		"could not resolve " .. module_name .. " on package.path"
	)
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "could not open " .. module_name)
	local src = fh:read("*a")
	fh:close()
	return src
end




-- =================================================================
-- =================================================================
-- ======= 1/ scrollWheel excluded from mouse_tap ==================
-- =================================================================
-- =================================================================

helpers.describe("keymap.init — mouse_tap must not intercept scrollWheel", function()
	helpers.it("mouse_tap eventtap does not list scrollWheel", function()
		local src = read_source("modules.keymap.init")

		-- Find the mouse_tap block. We look for the `mouse_tap = eventtap.new(`
		-- assignment and extract a window of source around it large enough to
		-- contain its event type list.
		local start = src:find("mouse_tap = eventtap.new(", 1, true)
		helpers.assert_true(start ~= nil, "mouse_tap assignment not found in modules.keymap.init")

		-- Extract the next 400 bytes after the assignment — enough to cover the
		-- opening `{` … `}` block that lists event types.
		local window = src:sub(start, start + 400)

		-- The scrollWheel event type must NOT appear in the mouse_tap definition.
		-- It is allowed to appear in other eventtaps (e.g., the gesture primer),
		-- so we check only within the window around `mouse_tap = eventtap.new(`.
		helpers.assert_true(
			window:find("scrollWheel", 1, true) == nil,
			"mouse_tap must NOT include scrollWheel — intercepting scroll at 60 Hz " ..
			"fires ObjC LLM callbacks on every frame, causing severe scroll and typing lag " ..
			"when the LLM menu is active"
		)
	end)

	helpers.it("mouse_tap still covers left/right/middle mouse buttons", function()
		local src = read_source("modules.keymap.init")
		local start = src:find("mouse_tap = eventtap.new(", 1, true)
		helpers.assert_true(start ~= nil, "mouse_tap assignment not found")
		local window = src:sub(start, start + 400)

		helpers.assert_true(
			window:find("leftMouseDown", 1, true) ~= nil,
			"mouse_tap must still intercept leftMouseDown to reset the buffer on click"
		)
		helpers.assert_true(
			window:find("rightMouseDown", 1, true) ~= nil,
			"mouse_tap must still intercept rightMouseDown"
		)
		helpers.assert_true(
			window:find("middleMouseDown", 1, true) ~= nil,
			"mouse_tap must still intercept middleMouseDown"
		)
	end)
end)
