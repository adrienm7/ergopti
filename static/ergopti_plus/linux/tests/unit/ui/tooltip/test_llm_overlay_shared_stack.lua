--- tests/unit/ui/tooltip/test_llm_overlay_shared_stack.lua

--- ==============================================================================
--- MODULE: AI Suggestions And The Hotstring Preview In One Window
--- DESCRIPTION:
--- The preview and the suggestions draw into the one GTK window. The overlay's
--- hide hid a preview drawn over it, and an expiring preview hid the
--- suggestions while they still counted as shown. With
--- llm.trigger.while_hotstring_tooltip = "both" the suggestions come under the
--- preview rows in one stack; otherwise neither withdraws the other's rows.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A renderer recording what the window shows.
--- @return table renderer
--- @return table window { rows, hides, visible }
local function fake_renderer()
	local window = { rows = nil, hides = 0, visible = false }
	return {
		show = function(rows) window.rows = rows; window.visible = true; return true end,
		hide = function() window.hides = window.hides + 1; window.visible = false; window.rows = nil; return true end,
		is_visible = function() return window.visible end,
	}, window
end

--- The overlay wired to a preview stand-in, as the daemon wires the real one.
--- @param preview table { rows = table|nil, both = boolean }
--- @return table overlay
--- @return table window
--- @return table calls { covered, redraw }
local function overlay_with(preview)
	local renderer, window = fake_renderer()
	local calls = { covered = 0, redraw = 0 }
	package.loaded["ui.tooltip.llm"] = nil
	local overlay = helpers.load_module("ui.tooltip.llm")
	overlay.init({
		style = {},
		renderer = renderer,
		companion = {
			rows = function() return preview.both and preview.rows or nil end,
			showing = function() return preview.rows ~= nil end,
			covered = function() calls.covered = calls.covered + 1; preview.rows = nil end,
			redraw = function() calls.redraw = calls.redraw + 1; window.rows = preview.rows end,
		},
	})
	return overlay, window, calls
end

helpers.describe("AI overlay: one window shared with the hotstring preview", function()

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("(llm-overlay-draw-failure) retires an undisplayed suggestion after " .. mode, function()
			package.loaded["ui.tooltip.llm"] = nil
			local overlay = require("ui.tooltip.llm")
			local window = { visible = false, hides = 0 }
			local renderer = {
				show = function() window.visible = true; if mode == "throw" then error("partial draw") end; return false end,
				hide = function() window.visible = false; window.hides = window.hides + 1; return true end,
			}
			assert(overlay.init({ style = {}, renderer = renderer }))
			local ok, result = pcall(overlay.show, { { to_type = "secret", deletes = 0 } }, {})
			helpers.assert_true(ok); helpers.assert_eq(result, false)
			helpers.assert_eq(overlay.is_showing(), false)
			helpers.assert_eq(window.visible, false); helpers.assert_eq(window.hides, 1)
			package.loaded["ui.tooltip.llm"] = nil
		end)
	end

	helpers.it("(llm-overlay-draw-failure) keeps the rendering owner through reentrant lifecycle calls", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, destroyed = require("ui.tooltip.llm"), 0
		local renderer = {
			show = function()
				helpers.assert_eq(overlay.init({ style = {}, renderer = {} }), false)
				helpers.assert_eq(overlay.destroy(), false)
				return true
			end,
			hide = function() return true end,
			destroy = function() destroyed = destroyed + 1 end,
		}
		assert(overlay.init({ style = {}, renderer = renderer }))
		helpers.assert_true(overlay.show({ { to_type = "hello" } }, {}))
		helpers.assert_true(overlay.is_showing())
		helpers.assert_eq(destroyed, 0)
		helpers.assert_true(overlay.destroy()); helpers.assert_eq(destroyed, 1)
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("(llm-overlay-draw-failure) revokes an offer when its anchor provider throws", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, draws = require("ui.tooltip.llm"), 0
		assert(overlay.init({ style = {}, renderer = { show = function() draws = draws + 1; return true end },
			anchor_provider = function() error("anchor failure") end }))
		helpers.assert_eq(overlay.show({ { to_type = "hello" } }, {}), false)
		helpers.assert_eq(overlay.is_showing(), false); helpers.assert_eq(draws, 0)
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("(llm-overlay-draw-failure) retains cleanup until the owner acknowledges it", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, draws, hides = require("ui.tooltip.llm"), 0, 0
		assert(overlay.init({ style = {}, renderer = {
			show = function() draws = draws + 1; return draws > 1 end,
			hide = function() hides = hides + 1; return hides >= 3 end,
		} }))
		local candidate = { { to_type = "hello", deletes = 0 } }
		helpers.assert_eq(overlay.show(candidate, {}), false)
		helpers.assert_eq(overlay.is_showing(), false)
		helpers.assert_eq(overlay.show(candidate, {}), false)
		helpers.assert_eq(draws, 1, "an unresolved native surface must not receive a new draw")
		helpers.assert_true(overlay.show(candidate, {}))
		helpers.assert_eq(draws, 2); helpers.assert_eq(hides, 3)
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("(llm-overlay-draw-failure) revokes the offer if selection redraw fails", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, draws, hides = require("ui.tooltip.llm"), 0, 0
		assert(overlay.init({ style = {}, renderer = {
			show = function() draws = draws + 1; return draws == 1 end,
			hide = function() hides = hides + 1; return true end,
		} }))
		assert(overlay.show({ { to_type = "first" }, { to_type = "second" } }, {}))
		helpers.assert_eq(overlay.select(2), false)
		helpers.assert_eq(overlay.is_showing(), false)
		helpers.assert_eq(hides, 1)
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("(llm-overlay-draw-failure) retains the surface across refused cleanup and destruction", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, hides, destroyed = require("ui.tooltip.llm"), 0, 0
		local renderer = {
			show = function() return false end,
			hide = function() hides = hides + 1; return hides >= 4 end,
			destroy = function() destroyed = destroyed + 1 end,
		}
		assert(overlay.init({ style = {}, renderer = renderer }))
		helpers.assert_eq(overlay.show({ { to_type = "hello", deletes = 0 } }, {}), false)
		helpers.assert_eq(overlay.init({ style = {}, renderer = {} }), false)
		helpers.assert_eq(overlay.destroy(), false)
		helpers.assert_eq(destroyed, 0)
		helpers.assert_true(overlay.destroy())
		helpers.assert_eq(destroyed, 1)
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("(llm-overlay-draw-failure) preserves a replacement published during a failed draw", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, draws, hides, owner = require("ui.tooltip.llm"), 0, 0, nil
		local replacement = { { to_type = "replacement", deletes = 0 } }
		assert(overlay.init({ style = {}, renderer = {
			show = function()
				draws = draws + 1
				if draws == 1 then
					helpers.assert_eq(overlay.is_showing(), false, "an unfinished draw is not an offer")
					assert(overlay.show(replacement, {}))
					owner = "stale"
					return false
				end
				owner = "replacement"
				return true
			end,
			hide = function() hides = hides + 1; return true end,
		} }))
		helpers.assert_eq(overlay.show({ { to_type = "old", deletes = 0 } }, {}), false)
		helpers.assert_true(overlay.is_showing()); helpers.assert_eq(hides, 0)
		helpers.assert_eq(owner, "replacement", "the stale native completion must not cover the replacement")
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("(llm-overlay-draw-failure) restores the companion after a partial draw", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay = require("ui.tooltip.llm")
		local window = { owner = "preview", redraws = 0, covered = 0 }
		assert(overlay.init({ style = {}, renderer = {
			show = function() window.owner = "partial"; return false end,
			hide = function() window.owner = nil; return true end,
		}, companion = {
			rows = function() return nil end, showing = function() return true end,
			covered = function() window.covered = window.covered + 1 end,
			redraw = function() window.redraws = window.redraws + 1; window.owner = "preview"; return true end,
		} }))
		helpers.assert_eq(overlay.show({ { to_type = "secret", deletes = 0 } }, {}), false)
		helpers.assert_eq(overlay.is_showing(), false)
		helpers.assert_eq(window.owner, "preview"); helpers.assert_eq(window.redraws, 1); helpers.assert_eq(window.covered, 0)
		package.loaded["ui.tooltip.llm"] = nil
	end)


	helpers.it("draws the suggestions under the preview rows when both are shown", function()
		local preview = { rows = { { text = "by the way", label = "★" } }, both = true }
		local overlay, window = overlay_with(preview)
		helpers.assert_true(overlay.show({ { to_type = "que tout va bien", deletes = 0 } }, {}))
		helpers.assert_eq(window.rows[1].text, "by the way", "the hotstring row heads the stack")
		helpers.assert_true(#window.rows >= 2, "the suggestion follows it")
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("leaves the preview alone on screen when the shared suggestion goes", function()
		local preview = { rows = { { text = "by the way", label = "★" } }, both = true }
		local overlay, window, calls = overlay_with(preview)
		overlay.show({ { to_type = "que tout va bien", deletes = 0 } }, {})
		helpers.assert_true(overlay.hide())
		helpers.assert_eq(window.hides, 0, "the preview rows that can still expand stay")
		helpers.assert_eq(calls.redraw, 1, "the preview is drawn again alone")
		helpers.assert_eq(overlay.is_showing(), false)
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("never hides a preview drawn over the suggestions", function()
		local preview = { rows = nil, both = false }
		local overlay, window = overlay_with(preview)
		overlay.show({ { to_type = "que tout va bien", deletes = 0 } }, {})
		-- The next keystroke's preview takes the window before the suggestion is dismissed
		preview.rows = { { text = "by the way", label = "★" } }
		window.rows = preview.rows
		helpers.assert_true(overlay.hide())
		helpers.assert_eq(window.hides, 0, "dismissing the suggestion keeps the newer preview")
		helpers.assert_eq(window.rows[1].text, "by the way")
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("takes the window from a preview it is drawn over alone", function()
		local preview = { rows = { { text = "by the way", label = "★" } }, both = false }
		local overlay, window, calls = overlay_with(preview)
		overlay.show({ { to_type = "que tout va bien", deletes = 0 } }, {})
		helpers.assert_eq(calls.covered, 1, "the preview no longer owns the window")
		helpers.assert_true(overlay.hide())
		helpers.assert_eq(window.hides, 1, "so the suggestion's hide clears the window")
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("redraws a shown suggestion and ignores a redraw without one", function()
		local preview = { rows = nil, both = true }
		local overlay, window = overlay_with(preview)
		helpers.assert_eq(overlay.redraw(), false, "nothing shown, nothing drawn")
		overlay.show({ { to_type = "que tout va bien", deletes = 0 } }, {})
		window.rows = nil
		helpers.assert_true(overlay.redraw())
		helpers.assert_true(window.rows ~= nil, "the suggestion is drawn again")
		package.loaded["ui.tooltip.llm"] = nil
	end)

end)

helpers.describe("Hotstring preview: its own rows, not the shared window", function()

	--- The preview module over a fake renderer and scheduler.
	--- @return table preview
	--- @return table window
	--- @return table state { hidden }
	local function preview_with()
		local renderer, window = fake_renderer()
		renderer.is_available = function() return true end
		renderer.destroy = function() end
		local held = {
			["adapters.graphics_renderer"] = package.loaded["adapters.graphics_renderer"] or false,
			["adapters.timer_scheduler"] = package.loaded["adapters.timer_scheduler"] or false,
		}
		local Fakes = helpers.load_module("tests.fakes")
		package.loaded["adapters.graphics_renderer"] = renderer
		package.loaded["adapters.timer_scheduler"] = Fakes.timer_scheduler()
		package.loaded["ui.tooltip.preview"] = nil
		local preview = require("ui.tooltip.preview")
		local state = { hidden = 0 }
		preview.init({
			style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, color = "#1e88e5", show_tooltip = true } end },
			on_hidden = function() state.hidden = state.hidden + 1 end,
		})
		local function restore()
			package.loaded["ui.tooltip.preview"] = nil
			for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
		end
		return preview, window, state, restore
	end

	helpers.it("reports its rows while shown and forgets them once hidden or covered", function()
		local preview, window, state, restore = preview_with()
		helpers.assert_eq(preview.is_showing(), false)
		helpers.assert_true(preview.show({
			{ trigger = "btw", replacement = "by the way", group = "rolls", fires = true },
		}, "autocorrect"))
		helpers.assert_true(preview.is_showing())
		helpers.assert_eq(preview.showing_rows()[1].text, "by the way")
		window.rows = nil
		helpers.assert_true(preview.redraw(), "the rows are drawn again alone")
		helpers.assert_eq(window.rows[1].text, "by the way")
		preview.note_covered()
		helpers.assert_eq(preview.is_showing(), false, "covered rows are no longer the preview's")
		helpers.assert_eq(preview.showing_rows(), nil)
		preview.hide()
		helpers.assert_eq(state.hidden, 0, "hiding rows that were covered tells nobody")
		preview.show({ { trigger = "btw", replacement = "by the way", group = "rolls", fires = true } }, "autocorrect")
		preview.hide()
		helpers.assert_eq(state.hidden, 1, "hiding its own rows tells the shared suggestion")
		helpers.assert_eq(preview.is_showing(), false)
		restore()
	end)

end)
