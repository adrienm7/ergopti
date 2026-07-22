--- tests/unit/ui/menu/test_canvas_badge_no_leak.lua

--- ==============================================================================
--- MODULE: canvas_badge — canvas handle leak regression
--- DESCRIPTION:
--- Guards against NSWindow handle leaks introduced by canvas_badge.M.prepend_to().
--- The function creates an hs.canvas object to render the pill badge, captures the
--- result as an image via :imageFromCanvas(), then MUST call :delete() before
--- returning to release the underlying NSWindow resource. A missing :delete() call
--- would accumulate one leaked handle per menu rebuild, which on a menu that
--- refreshes every few seconds would exhaust the process window limit over hours.
---
--- ROOT CAUSE ENCODED: the production code has exactly one canvas:delete() call
--- (line 116 of canvas_badge.lua). If a refactor introduces a second code path
--- that returns early, or moves the :delete() call after an error, the counter
--- assertion below will catch it immediately.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ========================================================
-- ========================================================
-- ======= 1/ Canvas Stub and Instrumentation Setup =======
-- ========================================================
-- ========================================================

--- Number of times M.prepend_to() will be called in the battery test.
local CALL_COUNT = 5

--- Dummy image sentinel returned by the mock canvas :imageFromCanvas().
local DUMMY_IMAGE = {}

--- Builds a fresh canvas stub that intercepts hs.canvas.new() and all
--- :delete() calls on the objects it creates. The counters are shared so that
--- the test suite can assert the create/delete balance after any number of
--- M.prepend_to() invocations.
--- @return table canvas_stub  The hs.canvas replacement to pass to load_with_stubs.
--- @return table counters     Shared {create_count, delete_count} tally table.
local function make_canvas_stub()
	local counters = { create_count = 0, delete_count = 0 }

	local canvas_stub = {
		-- Expose level/behavior constant tables so canvas:level() / :behavior()
		-- calls inside the module do not crash on nil indexing.
		windowLevels    = setmetatable({}, { __index = function() return 0 end }),
		windowBehaviors = setmetatable({}, { __index = function() return 0 end }),

		new = function(_frame)
			counters.create_count = counters.create_count + 1

			-- Build a minimal mock canvas object that satisfies the surface the
			-- module calls: appendElements(), imageFromCanvas(), and delete().
			local mock = {}

			function mock:appendElements(...)
				-- Accept any number of element tables; no-op for test purposes
				local _ = { ... }
			end

			function mock:imageFromCanvas()
				-- Return a stable sentinel so the calling code can store it as `img`
				return DUMMY_IMAGE
			end

			function mock:delete()
				counters.delete_count = counters.delete_count + 1
			end

			return mock
		end,
	}

	return canvas_stub, counters
end





-- ===============================================================
-- ===============================================================
-- ======= 2/ Shared Drawing Stub and Module Instantiation =======
-- ===============================================================
-- ===============================================================

--- Minimal hs.drawing stub: getTextDrawingSize is the only entry point called
--- by canvas_badge. Returning a fixed size keeps the pill geometry deterministic
--- and avoids nil-index crashes from an absent function.
local function make_drawing_stub()
	return {
		getTextDrawingSize = function(_text, _attrs)
			return { w = 60, h = 18 }
		end,
		windowLevels = setmetatable({}, { __index = function() return 0 end }),
	}
end





-- ========================================
-- ========================================
-- ======= 3/ Regression Test Suite =======
-- ========================================
-- ========================================

helpers.describe("canvas_badge: prepend_to deletes every canvas it creates", function()

	helpers.it("delete_count equals create_count after a single call", function()
		local canvas_stub, counters = make_canvas_stub()

		local M = helpers.load_with_stubs("ui.menu.canvas_badge", {
			canvas  = canvas_stub,
			drawing = make_drawing_stub(),
		})

		local items = { { title = "Option A" }, { title = "Option B" } }
		M.prepend_to(items, {}, function() end)

		helpers.assert_eq(
			counters.create_count,
			1,
			"prepend_to must create exactly one canvas per call"
		)
		helpers.assert_eq(
			counters.delete_count,
			counters.create_count,
			"every created canvas must be deleted before prepend_to returns"
		)
	end)


	helpers.it("delete_count equals create_count after " .. CALL_COUNT .. " successive calls", function()
		local canvas_stub, counters = make_canvas_stub()

		-- Re-use the same stub across all calls to accumulate totals. The module
		-- is reloaded fresh for this test so there is no cross-test pollution.
		local M = helpers.load_with_stubs("ui.menu.canvas_badge", {
			canvas  = canvas_stub,
			drawing = make_drawing_stub(),
		})

		local items = { { title = "Option A" }, { title = "Option B" }, { title = "Option C" } }

		for i = 1, CALL_COUNT do
			-- Pass a fresh copy each time; prepend_to inserts at index 1
			local fresh = {}
			for _, v in ipairs(items) do fresh[#fresh + 1] = v end
			-- Alternate paused state to exercise both pill rendering branches
			local ctx = { paused = (i % 2 == 0) }
			M.prepend_to(fresh, ctx, function() end)
		end

		helpers.assert_eq(
			counters.create_count,
			CALL_COUNT,
			"expected exactly one canvas per prepend_to call"
		)
		helpers.assert_eq(
			counters.delete_count,
			counters.create_count,
			"canvas handle leak detected: delete_count must equal create_count"
		)
	end)


	helpers.it("image captured before delete is available to the caller", function()
		local canvas_stub, _counters = make_canvas_stub()

		local M = helpers.load_with_stubs("ui.menu.canvas_badge", {
			canvas  = canvas_stub,
			drawing = make_drawing_stub(),
		})

		local items = { { title = "Option A" } }
		M.prepend_to(items, {}, function() end)

		-- prepend_to inserts the badge at index 1; the image field must be the
		-- sentinel returned by our mock :imageFromCanvas()
		helpers.assert_true(
			#items >= 1,
			"prepend_to must insert at least one item into the list"
		)
		helpers.assert_eq(
			items[1].image,
			DUMMY_IMAGE,
			"the image stored on the badge item must be the one from imageFromCanvas"
		)
	end)


	helpers.it("prepend_to inserts badge at position 1 followed by a separator", function()
		local canvas_stub, _counters = make_canvas_stub()

		local M = helpers.load_with_stubs("ui.menu.canvas_badge", {
			canvas  = canvas_stub,
			drawing = make_drawing_stub(),
		})

		local items = { { title = "Option A" }, { title = "Option B" } }
		M.prepend_to(items, {}, function() end)

		helpers.assert_eq(items[1].title, "",       "badge item title must be an empty string")
		helpers.assert_eq(items[2].title, "-",      "badge item must be followed by a separator")
		helpers.assert_eq(items[3].title, "Option A", "original items must follow the badge + separator")
	end)

end)
