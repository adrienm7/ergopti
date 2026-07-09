--- tests/unit/meta/test_graphics_renderer_adapter.lua

--- ==============================================================================
--- MODULE: GraphicsRenderer Adapter Tests (Linux)
--- DESCRIPTION:
--- Exercises adapters/graphics_renderer.lua, the lgi (GTK + cairo) overlay
--- renderer. The adapter has two runtime regimes and this suite pins both:
--- 1. lgi absent — every method gracefully no-ops and createWindow returns
---    INVALID_HANDLE (0). This is the state on the CI/test host, which has no
---    lgi/GTK.
--- 2. lgi present — createWindow allocates a real pool slot (handle > 0), wires
---    a GTK window + cairo drawing area, and drawBitmap routes a {ctx, w, h}
---    canvas through the on_draw signal.
---
--- ROOT CAUSE ENCODED:
--- The renderer was upgraded from a hardcoded no-op stub to a real lgi/cairo/GTK
--- pool, but this test kept asserting the stale "createWindow always returns 0"
--- contract. That assertion also passes against a fully gutted stub, so it could
--- no longer catch a regression that deleted the pool. Section 3 injects a mock
--- lgi via package.loaded and asserts the real pool actually allocates, tracks,
--- draws, destroys, and caps at MAX_WINDOWS — behaviour that is RED against the
--- old stub and GREEN against the real adapter.
--- ==============================================================================

local helpers = require("tests.helpers")
local gr      = helpers.load_module("adapters.graphics_renderer")

-- Pool ceiling mirrored from the adapter so the exhaustion test has no magic
-- number of its own; kept in sync by the "9th window" assertion below.
local MAX_WINDOWS = 8

--- Builds a mock lgi namespace (GTK + cairo) whose window/drawing-area objects
--- record the calls the adapter makes, so tests can assert real pool behaviour
--- without a display server. queue_draw() replays GTK's expose by invoking the
--- installed on_draw handler with a fake cairo context.
--- @return table, table The mock lgi table and a shared call-recording table.
local function make_mock_lgi()
	local calls = { show_all = 0, hide = 0, destroy = 0, queue_draw = 0 }
	local function make_window()
		local w = {}
		function w:set_default_size(a, b) calls.set_default_size = { a, b } end
		function w:move(a, b) calls.move = { a, b } end
		function w:add(child) w._child = child end
		function w:show_all() calls.show_all = calls.show_all + 1 end
		function w:hide() calls.hide = calls.hide + 1 end
		function w:destroy() calls.destroy = calls.destroy + 1 end
		function w:input_shape_combine_region() end
		return w
	end
	local function make_drawing_area()
		local da = {}
		function da:queue_draw()
			calls.queue_draw = calls.queue_draw + 1
			-- Replay a GTK expose so the adapter's draw_fn wrapper runs.
			if da.on_draw then da.on_draw(da, { fake_cr = true }) end
		end
		return da
	end
	local mock = {
		cairo = { Region = { create = function() return { destroy = function() end } end } },
		Gtk = {
			WindowType  = { POPUP = "POPUP" },
			Window      = function(_opts) return make_window() end,
			DrawingArea = function() return make_drawing_area() end,
		},
	}
	return mock, calls
end

--- Loads a FRESH copy of the adapter with a mock lgi installed, runs body(gr,
--- calls), then always restores the package cache to the lgi-absent state so a
--- failing assertion cannot leak the mock into later test files.
--- @param body function Receives (adapter, calls).
local function with_mock_lgi(body)
	local mock, calls = make_mock_lgi()
	package.loaded["lgi"] = mock
	-- load_module wipes only the adapter's cache entry, so the mock installed
	-- above survives the reload and _probe() picks it up at module load.
	local real = helpers.load_module("adapters.graphics_renderer")
	local ok, err = pcall(body, real, calls)
	package.loaded["lgi"] = nil
	-- Revert the cached adapter to its lgi-absent form for subsequent files.
	helpers.load_module("adapters.graphics_renderer")
	if not ok then error(err, 0) end
end

helpers.describe("graphics_renderer adapter", function()




	-- ===================================
	-- ===================================
	-- ======= 1/ Module Structure =======
	-- ===================================
	-- ===================================

	helpers.describe("module structure", function()
		helpers.it("exports createWindow", function()
			helpers.assert_true(type(gr.createWindow) == "function", "createWindow is a function")
		end)
		helpers.it("exports destroyWindow", function()
			helpers.assert_true(type(gr.destroyWindow) == "function", "destroyWindow is a function")
		end)
		helpers.it("exports drawBitmap", function()
			helpers.assert_true(type(gr.drawBitmap) == "function", "drawBitmap is a function")
		end)
		helpers.it("exports show", function()
			helpers.assert_true(type(gr.show) == "function", "show is a function")
		end)
		helpers.it("exports hide", function()
			helpers.assert_true(type(gr.hide) == "function", "hide is a function")
		end)
	end)




	-- ====================================================
	-- ====================================================
	-- ======= 2/ Graceful Degradation (lgi Absent) =======
	-- ====================================================
	-- ====================================================

	helpers.describe("lgi absent — graceful no-op", function()
		helpers.it("createWindow returns 0 (INVALID_HANDLE) when lgi is unavailable", function()
			local handle = gr.createWindow({ x = 0, y = 0, w = 200, h = 60 })
			helpers.assert_eq(handle, 0, "returns 0 (INVALID_HANDLE)")
		end)

		helpers.it("createWindow returns a number, never nil, with any opts", function()
			helpers.assert_true(type(gr.createWindow({})) == "number", "empty opts returns a number")
			helpers.assert_true(type(gr.createWindow(nil)) == "number", "nil opts returns a number")
			helpers.assert_true(type(gr.createWindow()) == "number", "missing opts returns a number")
		end)

		helpers.it("every method is a safe no-op over a full lifecycle", function()
			local ok = pcall(function()
				local h = gr.createWindow({ x = 10, y = 20, w = 300, h = 80 })
				gr.drawBitmap(h, function() end)
				gr.drawBitmap(0, nil)
				gr.show(h)
				gr.hide(h)
				gr.destroyWindow(h)
				gr.destroyWindow(nil)
				gr.destroyWindow(42)
			end)
			helpers.assert_true(ok, "full lifecycle does not crash without lgi")
		end)
	end)




	-- ============================================
	-- ============================================
	-- ======= 3/ Real Pool With Mocked lgi =======
	-- ============================================
	-- ============================================

	helpers.describe("lgi present — real pool", function()
		helpers.it("createWindow allocates a real handle (> 0) and wires the GTK window", function()
			with_mock_lgi(function(real, calls)
				local handle = real.createWindow({ x = 10, y = 20, w = 300, h = 80 })
				helpers.assert_true(handle > 0, "real pool returns a positive handle")
				helpers.assert_eq(calls.set_default_size, { 300, 80 }, "window sized from opts")
				helpers.assert_eq(calls.move, { 10, 20 }, "window positioned from opts")
				helpers.assert_eq(calls.show_all, 1, "window shown once on create")
			end)
		end)

		helpers.it("drawBitmap stores draw_fn and repaints with a {ctx, w, h} canvas", function()
			with_mock_lgi(function(real, calls)
				local handle = real.createWindow({ x = 0, y = 0, w = 120, h = 40 })
				local seen
				real.drawBitmap(handle, function(canvas) seen = canvas end)
				helpers.assert_eq(calls.queue_draw, 1, "drawBitmap queues one repaint")
				helpers.assert_not_nil(seen, "draw_fn received a canvas")
				helpers.assert_eq(seen.w, 120, "canvas width from window")
				helpers.assert_eq(seen.h, 40, "canvas height from window")
				helpers.assert_true(seen.ctx ~= nil and seen.ctx.fake_cr == true, "canvas carries the cairo context")
			end)
		end)

		helpers.it("destroyWindow tears down the GTK window and keeps the pool usable", function()
			with_mock_lgi(function(real, calls)
				local handle = real.createWindow({})
				real.destroyWindow(handle)
				helpers.assert_eq(calls.destroy, 1, "GTK window destroyed once")
				-- Freeing a slot leaves the pool functional for a fresh allocation.
				helpers.assert_true(real.createWindow({}) > 0, "pool still allocates after a destroy")
			end)
		end)

		helpers.it("caps the pool at MAX_WINDOWS and returns 0 on overflow", function()
			with_mock_lgi(function(real)
				local last
				for _ = 1, MAX_WINDOWS do last = real.createWindow({}) end
				helpers.assert_true(last > 0, "MAX_WINDOWS-th allocation still succeeds")
				helpers.assert_eq(real.createWindow({}), 0, "overflow returns INVALID_HANDLE")
			end)
		end)
	end)

end)
