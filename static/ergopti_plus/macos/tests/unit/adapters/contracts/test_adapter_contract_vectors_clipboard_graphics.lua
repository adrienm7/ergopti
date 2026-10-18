--- tests/unit/adapters/contracts/test_adapter_contract_vectors_clipboard_graphics.lua

--- ==============================================================================
--- MODULE: Adapter Contract Behaviour Tests
--- DESCRIPTION:
--- Executes the contractTestVectors() scenarios defined in each
--- _shared/core/ports/*.spec.js — translated into Lua so they run under the
--- standard hs-stub test runner without a Node.js dependency.
---
--- RATIONALE:
--- test_adapter_compliance.lua already verifies *structural* compliance
--- (method names + arities). This file verifies *behavioural* compliance:
--- that each adapter actually does what its port contract promises — correct
--- return values, error-safe paths, side-effects captured by the hs stub.
---
--- APPROACH:
--- Each port section hard-codes the relevant contractTestVectors() inputs and
--- expected outputs, mirroring the JS source. The adapters themselves are REAL —
--- loaded through load_with_stubs and called directly — so these are behavioural
--- tests, not a reimplementation.
---
--- DRIFT, HONESTLY:
--- This file reads no .spec.js, so a vector changed on the JS side leaves the
--- Lua mirror passing against the old expectation. An earlier version of this
--- docstring claimed the opposite — "the tests will fail until they are
--- synchronised, making drift immediately visible" — and nothing made that true.
--- Measured: 138 vectors across 20 ports, 61 of them referenced here by id.
---
--- tools/test/test-port-vector-traceability.cjs ratchets that number, so the
--- link can only get better. Naming a vector id in a test is what makes that
--- test traceable — prefer including the id in the assertion message when adding
--- one.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.adapters.contracts.adapter_contract_vectors_fixture"] = nil
local Fixture = require("tests.support.adapters.contracts.adapter_contract_vectors_fixture")





-- Clipboard vectors (Clipboard.spec.js). Backed by an in-memory hs.pasteboard
-- stub so the round-trip never touches the real macOS pasteboard.
helpers.describe("Adapter contract vectors: Clipboard", function()
	local pb = { text = nil, data = nil }
	local adapter = helpers.load_with_stubs("adapters.clipboard", {
		pasteboard = {
			getContents = function() return pb.text end,
			setContents = function(t) pb.text = t ; pb.data = { text = t } ; return true end,
			readAllData = function() return pb.data end,
			clearContents = function() pb.text = nil ; pb.data = nil end,
			writeAllData = function(d) pb.data = d ; pb.text = d and d.text or nil ; return true end,
		},
	})

	helpers.it("write returns true (write_returns_true)", function()
		helpers.assert_eq(true, adapter.write("test"), "write() must return true")
	end)

	helpers.it("read returns what write wrote (read_after_write)", function()
		adapter.write("ergopti_clipboard_test_42")
		helpers.assert_eq("ergopti_clipboard_test_42", adapter.read(), "read() must return the written content")
	end)

	helpers.it("save returns an opaque snapshot restore() accepts (save_returns_snapshot_or_null)", function()
		-- The old assertion was "did not throw", and it hid a real divergence.
		-- Clipboard.spec.js documents save() as {string|null}; macOS returns the
		-- readAllData() TABLE, deliberately, so a paste of non-text survives an
		-- injection — i.e. macOS's save() behaves like the Windows adapter's
		-- separate save_all(). Neither is wrong, but they are not the same
		-- contract, and only the pcall was standing where that should have been
		-- noticed. What both honour is that save() yields a value restore() takes
		-- back, so that is what this asserts.
		local saved = adapter.save()
		helpers.assert_true(saved == nil or type(saved) == "string" or type(saved) == "table",
			"save() must answer a snapshot restore() accepts, or nil for an empty clipboard")
		adapter.restore(saved)
	end)

	helpers.it("restore(nil) returns true (restore_null_clears)", function()
		helpers.assert_eq(true, adapter.restore(nil), "restore(nil) must return true")
	end)

	helpers.it("read returns nil when the clipboard is empty (read_empty_returns_null)", function()
		adapter.restore(nil)
		helpers.assert_eq(nil, adapter.read(), "read() must return nil when empty")
	end)
end)


-- GraphicsRenderer vectors (GraphicsRenderer.spec.js). hs.canvas is stubbed, so
-- create/show/hide/destroy never put a real surface on screen — this is the one
-- port whose show() vector is exercised here only (the AHK twin keeps the window
-- hidden to avoid flashing the real desktop).
helpers.describe("Adapter contract vectors: GraphicsRenderer", function()
	local adapter = helpers.load_with_stubs("adapters.graphics_renderer")

	helpers.it("createWindow returns a non-zero handle (create_returns_nonzero_handle)", function()
		local h = adapter.createWindow({ x = 100, y = 100, w = 200, h = 200 })
		helpers.assert_true(h ~= nil and h ~= 0, "createWindow() must return a non-zero handle")
		adapter.destroyWindow(h)
	end)

	helpers.it("destroy/show/hide/drawBitmap on a zero handle are no-ops (zero_is_noop)", function()
		-- Called directly: a raise fails with the real error, which names which of
		-- the four calls broke.
		adapter.destroyWindow(0)
		adapter.show(0)
		adapter.hide(0)
		adapter.drawBitmap(0, function() end)
		helpers.assert_eq(type(adapter.createWindow), "function",
			"and must leave the adapter usable — a zero handle is what every caller has "
				.. "before its first createWindow")
	end)

	helpers.it("drawBitmap calls the draw function (draw_bitmap_calls_draw_fn)", function()
		local h = adapter.createWindow({ x = 0, y = 0, w = 64, h = 64 })
		local called = false
		adapter.drawBitmap(h, function() called = true end)
		adapter.destroyWindow(h)
		helpers.assert_true(called, "drawBitmap() must invoke the draw function")
	end)

	helpers.it("show then hide then destroy do not throw (show/hide/destroy lifecycle)", function()
		local h = adapter.createWindow({ x = 0, y = 0, w = 64, h = 64 })
		adapter.show(h)
		adapter.hide(h)
		adapter.destroyWindow(h)
		helpers.assert_eq(type(adapter.createWindow), "function",
			"and a destroyed window must leave the adapter able to create another")
	end)
end)
