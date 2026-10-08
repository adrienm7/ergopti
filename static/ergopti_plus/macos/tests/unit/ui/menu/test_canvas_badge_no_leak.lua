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


--- Reads canonical source translations or independently frozen prior captions.
--- @param relative string Shared-tree resource.
--- @return table
local function badge_json(relative)
	local file = assert(io.open(helpers.shared(relative), "rb"))
	local value = require("json").decode(file:read("*a"))
	file:close()
	return value
end

--- Exercises the real badge producer with controlled native drawing boundaries.
--- @param body function Receives actual module, native effects, renderer and i18n.
local function with_badge_frame(body)
	return helpers.with_stub_scope({ "ui.menu.canvas_badge", "infra.manifest_menu", "menu.renderer",
		"infra.i18n", "infra.logger" }, function()
		local canvas, counters = make_canvas_stub()
		counters.draws, counters.texts, counters.events = 0, {}, {}
		local new_canvas = canvas.new
		canvas.new = function(frame)
			local native = new_canvas(frame)
			local append, image, delete = native.appendElements, native.imageFromCanvas, native.delete
			native.appendElements = function(self, ...)
				for _, element in ipairs({ ... }) do
					if element.type == "text" then counters.texts[#counters.texts + 1] = element.text end
				end
				return append(self, ...)
			end
			native.imageFromCanvas = function(self)
				counters.events[#counters.events + 1] = "image"
				return image(self)
			end
			native.delete = function(self)
				counters.events[#counters.events + 1] = "delete"
				return delete(self)
			end
			return native
		end
		local drawing = make_drawing_stub()
		local measure = drawing.getTextDrawingSize
		drawing.getTextDrawingSize = function(...)
			counters.draws = counters.draws + 1
			return measure(...)
		end
		local module = helpers.load_with_stubs("ui.menu.canvas_badge", { canvas = canvas, drawing = drawing })
		return body(module, counters, require("infra.manifest_menu"), require("infra.i18n"))
	end)
end

helpers.describe("canvas badge consumes declared captions and boundary before native rendering", function()
	for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
		"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("preserves the independently frozen active and paused canvas captions: " .. locale, function()
			with_badge_frame(function(module, effects, _, i18n)
				local prior = badge_json("tests/corpus/menus/macos_canvas_badge_captions.json").captions[locale]
				local strings = badge_json("data/locales/" .. locale .. ".json")
				i18n.get = function(key) return strings[key] or key end
				for _, state in ipairs({ { paused = false, caption = "active" }, { paused = true, caption = "paused" } }) do
					local body = { title = "Independent native root row" }
					local items = { body }
					module.prepend_to(items, { paused = state.paused }, function() return false end)
					helpers.assert_eq(effects.texts[#effects.texts], prior[state.caption])
					helpers.assert_eq(items[1].title, "")
					helpers.assert_eq(items[1].image, DUMMY_IMAGE)
					helpers.assert_eq(items[2].title, "-")
					helpers.assert_true(rawequal(items[3], body), "native root row identity and placement survive")
				end
				helpers.assert_eq(effects.create_count, 2)
				helpers.assert_eq(effects.delete_count, 2)
				helpers.assert_eq(effects.events, { "image", "delete", "image", "delete" })
				helpers.assert_true(effects.draws > 0, "the real native draw counter is armed")
			end)
		end)
	end

	for _, section in ipairs({ "macos_canvas_badge_frame", "macos_canvas_badge_active", "macos_canvas_badge_paused" }) do
		helpers.it("refuses withdrawn " .. section .. " before text/canvas reads or item mutation", function()
			with_badge_frame(function(module, effects, renderer)
				renderer.get_root()[section] = {}
				local calls = 0
				local items = { { title = "Independent native root row" } }
				local before = items[1]
				local accepted = module.prepend_to(items, {}, function() calls = calls + 1 end)
				helpers.assert_eq(effects.draws, 0)
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(effects.create_count, 0)
				helpers.assert_eq(effects.events, {})
				helpers.assert_eq(#items, 1)
				helpers.assert_true(rawequal(items[1], before))
				helpers.assert_eq(calls, 0)
			end)
		end)
	end

	for _, predicate in ipairs({ "macos_badge_is_paused", "macos_badge_is_active" }) do
		for _, control in ipairs({ "missing", "non_boolean", "throw" }) do
			helpers.it("refuses " .. control .. " actual badge predicate " .. predicate .. " before native reads", function()
				with_badge_frame(function(module, effects, renderer)
					local template = renderer.template_rows
					renderer.template_rows = function(key, commands, getters, children)
						if key == "macos_canvas_badge_frame" then
							if control == "missing" then getters[predicate] = nil
							elseif control == "non_boolean" then getters[predicate] = function() return "false" end
							else getters[predicate] = function() error("independent badge predicate refusal", 0) end end
						end
						return template(key, commands, getters, children)
					end
					local items = { { title = "Independent native root row" } }
					local accepted = module.prepend_to(items, {}, function() end)
					helpers.assert_eq(effects.draws, 0)
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(effects.create_count, 0)
					helpers.assert_eq(#items, 1)
				end)
			end)
		end
	end

	helpers.it("refuses malformed badge content before native reads", function()
		with_badge_frame(function(module, effects, renderer)
			local root = renderer.get_root()
			root.macos_canvas_badge_active[1].type = "unsupported_badge_content"
			local items = { { title = "Independent native root row" } }
			local accepted = module.prepend_to(items, {}, function() end)
			helpers.assert_eq(effects.draws, 0)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(effects.create_count, 0)
			helpers.assert_eq(#items, 1)
		end)
	end)

	helpers.it("refuses a missing root frame before any native measurement", function()
		with_badge_frame(function(module, effects, renderer)
			renderer.get_root().macos_canvas_badge_frame = nil
			local items = { { title = "Independent native root row" } }
			local accepted = module.prepend_to(items, {}, function() end)
			helpers.assert_eq(effects.draws, 0)
			helpers.assert_eq(effects.create_count, 0)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#items, 1)
		end)
	end)

	helpers.it("refuses a replaced declared boundary before native measurement", function()
		with_badge_frame(function(module, effects, renderer)
			renderer.get_root().macos_canvas_badge_frame[3] = {
				type = "label", id = "malformed_badge_boundary", i18n = "button.ok", platforms = { "hs" }, unavailable = "hide",
			}
			local items = { { title = "Independent native root row" } }
			local accepted = module.prepend_to(items, {}, function() end)
			helpers.assert_eq(effects.draws, 0)
			helpers.assert_eq(effects.create_count, 0)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#items, 1)
		end)
	end)

	helpers.it("retains the exact native callback identity and refusal", function()
		with_badge_frame(function(module, effects)
			local calls = 0
			local clicked = function(value) calls = calls + 1; return value == "accept" end
			local items = { { title = "Independent native root row" } }
			module.prepend_to(items, { paused = true }, clicked)
			helpers.assert_true(rawequal(items[1].fn, clicked))
			helpers.assert_eq(items[1].fn("refuse"), false)
			helpers.assert_eq(items[1].fn("accept"), true)
			helpers.assert_eq(calls, 2)
			helpers.assert_eq(effects.create_count, 1)
			helpers.assert_eq(effects.delete_count, 1)
		end)
	end)
end)
