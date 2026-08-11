--- tests/unit/ui/test_tooltip_renderer_native_commit.lua

--- ==============================================================================
--- MODULE: Tooltip Renderer Native Commit Regression
--- DESCRIPTION:
--- Exercises the production renderer against a faithful canvas double whose
--- native writes and visibility transitions can throw, refuse an update, or
--- return an invalid result. The renderer must never report success unless the
--- requested canvas state can be read back exactly.
---
--- ROOT CAUSE:
--- The renderer wrapped element writes and hide calls in bare pcalls, discarded
--- their outcome, and returned nil. Higher layers could therefore commit their
--- logical hidden/updated state while a stale native canvas remained visible,
--- with no ERROR reaching the file logger.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ Faithful Canvas Double =======
-- =========================================
-- =========================================

--- Loads a fresh production renderer with an observable file-logger surface.
--- @return table renderer Fresh renderer module.
--- @return table errors Captured ERROR messages.
local function load_renderer()
	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_log, fmt, ...)
		local ok, message = pcall(string.format, tostring(fmt), ...)
		errors[#errors + 1] = ok and message or tostring(fmt)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["ui.tooltip.config"] = nil
	package.loaded["toml_codec.reader"] = nil
	package.loaded["infra.toml.reader"] = nil
	return helpers.load_with_stubs("ui.tooltip.renderer"), errors
end

--- Builds an element proxy that can reject or throw on one attribute write.
--- @param options table|nil Failure controls.
--- @return table element Canvas element proxy.
--- @return table values Backing values used for outcome assertions.
local function make_element(options)
	options = options or {}
	local values = {
		action = options.initial_action or "fill",
		text = options.initial_text or "old text",
	}
	local element = setmetatable({}, {
		__index = function(_, key)
			if options.throw_on_read == key then
				error("native " .. tostring(key) .. " read failed")
			end
			return values[key]
		end,
		__newindex = function(_, key, value)
			if options.throw_on_write == key then
				error("native " .. tostring(key) .. " write failed")
			end
			if options.refuse_write ~= key then values[key] = value end
		end,
	})
	return element, values
end

--- Builds a canvas double with the documented hide/isShowing contract.
--- @param options table|nil Failure controls.
--- @return table canvas Canvas double.
--- @return table model_values Backing values for the model-info element.
local function make_canvas(options)
	options = options or {}
	local canvas = { showing = options.showing ~= false }
	for index = 1, 7 do
		local element_options = index == 7 and options.model_element or nil
		canvas[index] = select(1, make_element(element_options))
	end
	local model_values
	canvas[7], model_values = make_element(options.model_element)

	function canvas:hide()
		if options.hide_mode == "throw" then error("native hide failed") end
		if options.hide_mode ~= "refuse" then self.showing = false end
		if options.hide_mode == "nil" then return nil end
		if options.hide_mode == "false" then return false end
		return self
	end

	function canvas:isShowing()
		if options.status_mode == "throw" then error("native status failed") end
		if options.status_mode == "nil" then return nil end
		return self.showing
	end

	return canvas, model_values
end

--- Asserts that at least one file ERROR contains the requested marker.
--- @param errors table Captured error messages.
--- @param marker string Literal marker.
local function assert_error_logged(errors, marker)
	for _, message in ipairs(errors) do
		if message:find(marker, 1, true) then return end
	end
	error(string.format("expected an ERROR containing %q, got: %s",
		marker, table.concat(errors, " | ")), 2)
end





-- =============================================
-- =============================================
-- ======= 2/ Partial Update Commit Gate =======
-- =============================================
-- =============================================

helpers.describe("tooltip renderer native commit: partial updates", function()
	helpers.it("returns true only after the element update is observable (renderer-native-commit)", function()
		local renderer = load_renderer()
		local canvas = make_canvas()
		renderer.canvas = canvas

		local updated = renderer.set_element_text(renderer.ELEM_INFO, "new timing")

		helpers.assert_eq(updated, true,
			"a committed native update must return strict true")
		helpers.assert_eq(canvas[renderer.ELEM_INFO].action, "fill")
		helpers.assert_eq(canvas[renderer.ELEM_INFO].text, "new timing")
	end)

	helpers.it("returns false and logs when a native element write throws (renderer-native-commit)", function()
		local renderer, errors = load_renderer()
		local canvas = make_canvas()
		canvas[renderer.ELEM_INFO] = select(1, make_element({ throw_on_write = "text" }))
		renderer.canvas = canvas

		local updated = renderer.set_element_text(renderer.ELEM_INFO, "new timing")

		helpers.assert_eq(updated, false,
			"a thrown native element write must fail closed")
		assert_error_logged(errors, "Failed to update canvas element")
	end)

	helpers.it("returns false and logs when a native element refuses the write (renderer-native-commit)", function()
		local renderer, errors = load_renderer()
		local canvas = make_canvas()
		local element, values = make_element({ refuse_write = "text" })
		canvas[renderer.ELEM_INFO] = element
		renderer.canvas = canvas

		local updated = renderer.set_element_text(renderer.ELEM_INFO, "new timing")

		helpers.assert_eq(updated, false,
			"an unobservable native element update must not be reported as committed")
		helpers.assert_eq(values.text, "old text",
			"the double must prove the native write was actually refused")
		assert_error_logged(errors, "did not commit")
	end)
end)





-- =========================================
-- =========================================
-- ======= 3/ Hide Commit Gate =============
-- =========================================
-- =========================================

helpers.describe("tooltip renderer native commit: hide transitions", function()
	helpers.it("returns true only after both canvases report hidden (renderer-native-commit)", function()
		local renderer = load_renderer()
		local standard, model_values = make_canvas()
		local stacked = make_canvas()
		renderer.canvas = standard
		renderer.stacked_canvas = stacked

		helpers.assert_eq(renderer.hide(), true)
		helpers.assert_eq(renderer.hide_stacked(), true)
		helpers.assert_eq(standard.showing, false)
		helpers.assert_eq(stacked.showing, false)
		helpers.assert_eq(model_values.action, "skip",
			"standard cleanup must also clear the stable model-info zone")
	end)

	helpers.it("returns false and logs when either native hide throws (renderer-native-commit)", function()
		local renderer, errors = load_renderer()
		renderer.canvas = make_canvas({ hide_mode = "throw" })
		renderer.stacked_canvas = make_canvas({ hide_mode = "throw" })

		helpers.assert_eq(renderer.hide(), false,
			"a thrown standard-canvas hide must fail closed")
		helpers.assert_eq(renderer.hide_stacked(), false,
			"a thrown stacked-canvas hide must fail closed")
		assert_error_logged(errors, "Failed to hide tooltip canvas")
		assert_error_logged(errors, "Failed to hide stacked tooltip canvas")
	end)

	helpers.it("rejects nil and false native hide results (renderer-native-commit)", function()
		local renderer, errors = load_renderer()
		renderer.canvas = make_canvas({ hide_mode = "nil" })
		renderer.stacked_canvas = make_canvas({ hide_mode = "false" })

		helpers.assert_eq(renderer.hide(), false,
			"nil violates the documented canvas:hide return contract")
		helpers.assert_eq(renderer.hide_stacked(), false,
			"false violates the documented canvas:hide return contract")
		assert_error_logged(errors, "invalid native result")
	end)

	helpers.it("rejects a hide that leaves the native surface showing (renderer-native-commit)", function()
		local renderer, errors = load_renderer()
		local standard = make_canvas({ hide_mode = "refuse" })
		local stacked = make_canvas({ hide_mode = "refuse" })
		renderer.canvas = standard
		renderer.stacked_canvas = stacked

		helpers.assert_eq(renderer.hide(), false,
			"a standard canvas still reporting visible must fail closed")
		helpers.assert_eq(renderer.hide_stacked(), false,
			"a stacked canvas still reporting visible must fail closed")
		helpers.assert_eq(standard.showing, true)
		helpers.assert_eq(stacked.showing, true)
		assert_error_logged(errors, "remained visible")
	end)

	helpers.it("returns true when an optional stacked canvas was never created (renderer-native-commit)", function()
		local renderer = load_renderer()
		renderer.stacked_canvas = nil

		helpers.assert_eq(renderer.hide_stacked(), true,
			"an absent lazy canvas has no native surface left to hide")
	end)
end)
