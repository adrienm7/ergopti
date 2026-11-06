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
			redraw = function() calls.redraw = calls.redraw + 1; window.rows = preview.rows; return true end,
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

	helpers.it("(llm-overlay-draw-failure) does not offer suggestions without a renderer", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay = require("ui.tooltip.llm")
		assert(overlay.init({ style = {}, renderer = { hide = function() return true end } }))
		helpers.assert_eq(overlay.show({ { to_type = "hello" } }, {}), false)
		helpers.assert_eq(overlay.is_showing(), false)
		package.loaded["ui.tooltip.llm"] = nil
	end)

	helpers.it("(llm-overlay-draw-failure) creates no cleanup debt when no renderer can draw", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay = require("ui.tooltip.llm")
		assert(overlay.init({ style = {}, renderer = {} }))
		helpers.assert_eq(overlay.show({ { to_type = "hello" } }, {}), false)
		helpers.assert_eq(overlay.is_showing(), false)
		helpers.assert_true(overlay.init({ style = {}, renderer = { show = function() return true end } }))
		helpers.assert_true(overlay.show({ { to_type = "hello" } }, {}))
		package.loaded["ui.tooltip.llm"] = nil
	end)

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
			destroy = function() destroyed = destroyed + 1; return true end,
		}
		assert(overlay.init({ style = {}, renderer = renderer, anchor_provider = function()
			helpers.assert_eq(overlay.init({ style = {}, renderer = {} }), false)
			helpers.assert_eq(overlay.destroy(), false)
		end }))
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

	helpers.it("(tooltip-shared-destroy) keeps the preview surface when detaching the LLM overlay", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, destroyed, showing = require("ui.tooltip.llm"), 0, true
		assert(overlay.init({ style = {}, renderer = {
			show = function() return true end, hide = function() return true end,
			destroy = function() destroyed = destroyed + 1; return true end,
		}, companion = {
			showing = function() return showing end, rows = function() return { { text = "preview" } } end,
			redraw = function() return true end,
		} }))
		assert(overlay.show({ { to_type = "suggestion" } }, {}))
		local detached = overlay.destroy()
		package.loaded["ui.tooltip.llm"] = nil
		helpers.assert_eq({ detached = detached, destroyed = destroyed, showing = showing },
			{ detached = true, destroyed = 0, showing = true })
	end)

	helpers.it("(tooltip-shared-destroy) retains the renderer if companion redraw refuses", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, showing, destroyed = require("ui.tooltip.llm"), true, 0
		assert(overlay.init({ style = {}, renderer = {
			show = function() return true end, hide = function() return true end,
			destroy = function() destroyed = destroyed + 1; return true end,
		}, companion = {
			showing = function() return showing end, rows = function() return { { text = "preview" } } end,
			redraw = function() showing = false; return false end,
		} }))
		assert(overlay.show({ { to_type = "suggestion" } }, {}))
		local detached = overlay.destroy()
		package.loaded["ui.tooltip.llm"] = nil
		helpers.assert_eq({ detached = detached, destroyed = destroyed }, { detached = false, destroyed = 0 })
	end)

	helpers.it("(tooltip-shared-destroy) refuses an unavailable or changing companion owner", function()
		for _, mode in ipairs({ "throw", "replace" }) do
			package.loaded["ui.tooltip.llm"] = nil
			local overlay, hidden, destroyed, revision = require("ui.tooltip.llm"), 0, 0, 1
			assert(overlay.init({ style = {}, renderer = {
				show = function() return true end,
				hide = function() hidden = hidden + 1; return true end,
				destroy = function() destroyed = destroyed + 1; return true end,
			}, companion = {
				revision = function() return revision end,
				showing = function() if mode == "throw" then error("unavailable") end; revision = revision + 1; return false end,
			} }))
			local detached = overlay.destroy()
			package.loaded["ui.tooltip.llm"] = nil
			helpers.assert_eq({ detached = detached, hidden = hidden, destroyed = destroyed },
				{ detached = false, hidden = 0, destroyed = 0 })
		end
	end)

	helpers.it("(tooltip-shared-destroy) fences reentrant overlay lifecycle calls", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, nested = require("ui.tooltip.llm"), nil
		local renderer = { show = function() return true end, hide = function() return true end }
		renderer.destroy = function()
			nested = { overlay.show({ { to_type = "replacement" } }, {}), overlay.init({ style = {}, renderer = renderer }), overlay.destroy() }
			return true
		end
		assert(overlay.init({ style = {}, renderer = renderer }))
		local detached = overlay.destroy()
		package.loaded["ui.tooltip.llm"] = nil
		helpers.assert_eq({ detached = detached, nested = nested },
			{ detached = true, nested = { false, false, false } })
	end)

	helpers.it("(tooltip-destroy-refusal) retains the overlay owner until native destruction succeeds", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, attempts = require("ui.tooltip.llm"), 0
		assert(overlay.init({ style = {}, renderer = {
			show = function() return true end, hide = function() return true end,
			destroy = function() attempts = attempts + 1; return attempts > 1 end,
		} }))
		assert(overlay.show({ { to_type = "text" } }, {}))
		local first, second = overlay.destroy(), overlay.destroy()
		package.loaded["ui.tooltip.llm"] = nil
		helpers.assert_eq({ first = first, second = second, attempts = attempts },
			{ first = false, second = true, attempts = 2 })
	end)

	helpers.it("(llm-overlay-draw-failure) retains the surface across refused cleanup and destruction", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, hides, destroyed = require("ui.tooltip.llm"), 0, 0
		local renderer = {
			show = function() return false end,
			hide = function() hides = hides + 1; return hides >= 4 end,
			destroy = function() destroyed = destroyed + 1; return true end,
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


	helpers.it("(llm-deferred-redraw) leaves a newer preview in control", function()
		local preview = { rows = nil, both = false }
		local overlay, window, calls = overlay_with(preview)
		assert(overlay.show({ { to_type = "suggestion" } }, {}))
		preview.rows = { { text = "new preview" } }
		window.rows = preview.rows
		local skipped = overlay.redraw_if_preview_hidden()
		local preserved, covered = window.rows == preview.rows, calls.covered
		preview.rows = nil
		local resumed = overlay.redraw_if_preview_hidden()
		package.loaded["ui.tooltip.llm"] = nil
		helpers.assert_eq({ skipped = skipped, preserved = preserved, covered = covered, resumed = resumed },
			{ skipped = false, preserved = true, covered = 0, resumed = true })
	end)

	helpers.it("(llm-deferred-redraw) rejects a stale overlay and an unavailable preview owner", function()
		package.loaded["ui.tooltip.llm"] = nil
		local overlay, draws = require("ui.tooltip.llm"), 0
		assert(overlay.init({ style = {}, renderer = { show = function() draws = draws + 1; return true end },
			companion = { showing = function() error("preview owner unavailable") end } }))
		assert(overlay.show({ { to_type = "suggestion" } }, {}))
		local refused = overlay.redraw_if_preview_hidden()
		package.loaded["ui.tooltip.llm"] = {}
		local stale = overlay.redraw_if_preview_hidden()
		package.loaded["ui.tooltip.llm"] = nil
		helpers.assert_eq({ refused = refused, stale = stale, draws = draws },
			{ refused = false, stale = false, draws = 1 })
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
	helpers.it("(preview-partial-draw) retains a draw across replacement of its module", function()
		local names = { "adapters.graphics_renderer", "adapters.timer_scheduler", "ui.tooltip.preview" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
		local replacement, preview, nested, hides = nil, nil, nil, 0
		local config = { resolve = function() return { delay = 0.25, show_tooltip = true } end }
		local candidate = { { replacement = "text", group = "rolls", fires = true } }
		local renderer = { is_available = function() return true end,
			show = function()
				package.loaded["ui.tooltip.preview"] = nil
				replacement = require("ui.tooltip.preview")
				replacement.init({ style = { positioning = { window_bottom_inset = 0 } }, config = config })
				nested = replacement.show(candidate, "autocorrect")
				return true
			end,
			hide = function() hides = hides + 1; return true end }
		package.loaded["adapters.graphics_renderer"] = renderer
		package.loaded["adapters.timer_scheduler"] = helpers.load_module("tests.fakes").timer_scheduler()
		package.loaded["ui.tooltip.preview"] = nil
		preview = require("ui.tooltip.preview")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } }, config = config })
		local accepted = preview.show(candidate, "autocorrect")
		local blocked = replacement.show(candidate, "autocorrect")
		package.loaded["ui.tooltip.preview"] = preview
		local settled = preview.retry_render_cleanup()
		for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
		helpers.assert_eq({ accepted = accepted, nested = nested, blocked = blocked, settled = settled, hides = hides },
			{ accepted = false, nested = false, blocked = false, settled = true, hides = 1 })
	end)

	helpers.it("(preview-partial-draw) revokes an old LLM offer covered by a failed preview", function()
		local names = { "adapters.graphics_renderer", "adapters.timer_scheduler", "ui.tooltip.preview", "ui.tooltip.llm" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
		local draws, hides, allow_hide = 0, 0, false
		local renderer = { is_available = function() return true end,
			show = function() draws = draws + 1; return draws ~= 2 end,
			hide = function() hides = hides + 1; return allow_hide end }
		package.loaded["adapters.graphics_renderer"] = renderer
		package.loaded["adapters.timer_scheduler"] = helpers.load_module("tests.fakes").timer_scheduler()
		package.loaded["ui.tooltip.preview"], package.loaded["ui.tooltip.llm"] = nil, nil
		local preview, overlay = require("ui.tooltip.preview"), require("ui.tooltip.llm")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end },
			on_render_failed = function() overlay.revoke_presentation() end })
		overlay.init({ style = {}, renderer = renderer, companion = {
			showing = preview.is_showing, rows = preview.showing_rows, covered = preview.note_covered,
			redraw = preview.redraw, prepare = preview.retry_render_cleanup, ready = preview.render_ready,
			revision = preview.render_revision,
		} })
		assert(overlay.show({ { to_type = "old offer" } }, {}))
		local accepted = preview.show({ { replacement = "text", group = "rolls", fires = true } }, "autocorrect")
		local blocked = overlay.is_showing()
		allow_hide = true
		local settled, still_showing = preview.retry_render_cleanup(), overlay.is_showing()
		for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
		helpers.assert_eq({ accepted = accepted, blocked = blocked, settled = settled, showing = still_showing },
			{ accepted = false, blocked = false, settled = true, showing = false })
	end)

	helpers.it("(preview-partial-draw) fences reentrant owners during the native draw", function()
		local names = { "adapters.graphics_renderer", "adapters.timer_scheduler", "ui.tooltip.preview", "ui.tooltip.llm" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
		local preview, overlay, hide_result, offer_result, hidden = nil, nil, nil, nil, 0
		local renderer = {
			is_available = function() return true end,
			show = function()
				hide_result = preview.hide()
				offer_result = overlay.show({ { to_type = "reentrant" } }, {})
				return true
			end,
			hide = function() hidden = hidden + 1; return true end,
		}
		package.loaded["adapters.graphics_renderer"] = renderer
		package.loaded["adapters.timer_scheduler"] = helpers.load_module("tests.fakes").timer_scheduler()
		package.loaded["ui.tooltip.preview"], package.loaded["ui.tooltip.llm"] = nil, nil
		preview, overlay = require("ui.tooltip.preview"), require("ui.tooltip.llm")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end } })
		overlay.init({ style = {}, renderer = renderer, companion = {
			showing = preview.is_showing, rows = preview.showing_rows, covered = preview.note_covered,
			redraw = preview.redraw, prepare = preview.retry_render_cleanup, revision = preview.render_revision,
		} })
		local accepted = preview.show({ { replacement = "text", group = "rolls", fires = true } }, "autocorrect")
		local observed = { accepted = accepted, showing = preview.is_showing(), hide = hide_result, offer = offer_result, hidden = hidden }
		for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
		helpers.assert_eq(observed, { accepted = true, showing = true, hide = false, offer = false, hidden = 0 })
	end)

	helpers.it("(preview-partial-draw) restores a preview published inside an older LLM draw", function()
		local names = { "adapters.graphics_renderer", "adapters.timer_scheduler", "ui.tooltip.preview", "ui.tooltip.llm" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
		local preview, draws, owner = nil, 0, nil
		local renderer = {
			is_available = function() return true end,
			show = function()
				draws = draws + 1
				if draws == 1 then
					assert(preview.show({ { replacement = "new", group = "rolls", fires = true } }, "autocorrect"))
					owner = "stale LLM"; return true
				end
				owner = "preview"; return true
			end,
			hide = function() owner = nil; return true end,
		}
		package.loaded["adapters.graphics_renderer"] = renderer
		package.loaded["adapters.timer_scheduler"] = helpers.load_module("tests.fakes").timer_scheduler()
		package.loaded["ui.tooltip.preview"], package.loaded["ui.tooltip.llm"] = nil, nil
		preview = require("ui.tooltip.preview")
		local overlay = require("ui.tooltip.llm")
		preview.init({ style = { positioning = { window_bottom_inset = 0 } },
			config = { resolve = function() return { delay = 0.25, show_tooltip = true } end } })
		overlay.init({ style = {}, renderer = renderer, companion = {
			showing = preview.is_showing, rows = preview.showing_rows, covered = preview.note_covered,
			redraw = preview.redraw, prepare = preview.retry_render_cleanup, revision = preview.render_revision,
		} })
		local accepted = overlay.show({ { to_type = "old" } }, {})
		local observed = { accepted = accepted, showing = overlay.is_showing(), preview = preview.is_showing(), owner = owner }
		for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
		helpers.assert_eq(observed, { accepted = false, showing = false, preview = true, owner = "preview" })
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("(preview-partial-draw) fences the shared surface after " .. mode, function()
			local names = { "adapters.graphics_renderer", "adapters.timer_scheduler", "ui.tooltip.preview", "ui.tooltip.llm" }
			local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
			local draws, hides, visible, allow_hide = 0, 0, false, false
			local preview, overlay, nested_offer = nil, nil, nil
			local renderer = {
				is_available = function() return true end,
				show = function()
					draws = draws + 1; visible = true
					if draws == 1 then if mode == "throw" then error("partial") end; return false end
					return true
				end,
				hide = function()
					hides = hides + 1
					if not allow_hide then return false end
					nested_offer = overlay.show({ { to_type = "during cleanup" } }, {})
					visible = false; return true
				end,
			}
			package.loaded["adapters.graphics_renderer"] = renderer
			package.loaded["adapters.timer_scheduler"] = helpers.load_module("tests.fakes").timer_scheduler()
			package.loaded["ui.tooltip.preview"], package.loaded["ui.tooltip.llm"] = nil, nil
			preview, overlay = require("ui.tooltip.preview"), require("ui.tooltip.llm")
			preview.init({ style = { positioning = { window_bottom_inset = 0 } },
				config = { resolve = function() return { delay = 0.25, show_tooltip = true } end } })
			overlay.init({ style = {}, renderer = renderer, companion = {
				showing = preview.is_showing, rows = preview.showing_rows, covered = preview.note_covered,
				redraw = preview.redraw, prepare = preview.retry_render_cleanup, revision = preview.render_revision,
			} })
			local ok, accepted = pcall(preview.show, { { replacement = "text", group = "rolls", fires = true } }, "autocorrect")
			local offered = overlay.show({ { to_type = "suggestion" } }, {})
			local before = { ok = ok, accepted = accepted, offered = offered, draws = draws, visible = visible }
			allow_hide = true
			local original_hide, replacement_calls = renderer.hide, 0
			renderer.hide = function() replacement_calls = replacement_calls + 1; return true end
			local replaced_method = preview.retry_render_cleanup()
			renderer.hide = original_hide
			local before_stale = hides
			package.loaded["ui.tooltip.preview"] = nil
			local replacement = require("ui.tooltip.preview")
			replacement.init({ style = { positioning = { window_bottom_inset = 0 } },
				config = { resolve = function() return { delay = 0.25, show_tooltip = true } end } })
			local replacement_allowed = replacement.show({ { replacement = "new", group = "rolls", fires = true } }, "autocorrect")
			local stale = preview.retry_render_cleanup()
			local stale_hides = hides - before_stale
			package.loaded["ui.tooltip.preview"] = preview
			local recovered = overlay.show({ { to_type = "suggestion" } }, {})
			local after = { recovered = recovered, draws = draws, visible = visible, stale = stale, stale_hides = stale_hides, nested_offer = nested_offer, replacement_allowed = replacement_allowed,
				replaced_method = replaced_method, replacement_calls = replacement_calls }
			for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
			helpers.assert_eq(before, { ok = true, accepted = false, offered = false, draws = 1, visible = true })
			helpers.assert_eq(after, { recovered = true, draws = 2, visible = true, stale = false, stale_hides = 0, nested_offer = false, replacement_allowed = false, replaced_method = false, replacement_calls = 0 })
		end)
	end


	--- The preview module over a fake renderer and scheduler.
	--- @return table preview
	--- @return table window
	--- @return table state { hidden }
	local function preview_with(color)
		local renderer, window = fake_renderer()
		renderer.is_available = function() return true end
		renderer.destroy = function() return true end
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
			config = { resolve = function() return { delay = 0.25, color = color or "#1e88e5", show_tooltip = true } end },
			on_hidden = function() state.hidden = state.hidden + 1 end,
		})
		local function restore()
			package.loaded["ui.tooltip.preview"] = nil
			for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
		end
		return preview, window, state, restore, renderer
	end

	helpers.it("uses short and alpha CSS colors for preview accents (tooltip-css-hex)", function()
		for _, color in ipairs({ "#f80", "#f80a", "#ff8800", "#ff880080" }) do
			local preview, window, _, restore = preview_with(color)
			local ok, err = xpcall(function()
				helpers.assert_true(preview.show({ { trigger = "btw", replacement = "by the way", group = "rolls", fires = true } }, "autocorrect"))
				helpers.assert_eq(window.rows[1].accent, { red = 1, green = 136 / 255, blue = 0 })
			end, debug.traceback)
			restore()
			if not ok then error(err, 0) end
		end
	end)

	helpers.it("(tooltip-destroy-refusal) retains the preview owner until destruction succeeds", function()
		local preview, _, _, restore, renderer = preview_with()
		local attempts = 0
		renderer.destroy = function() attempts = attempts + 1; return attempts > 1 end
		local shown = preview.show({ { replacement = "text", group = "rolls", fires = true } }, "autocorrect")
		local first, second = preview.destroy(), preview.destroy()
		restore()
		helpers.assert_eq({ shown = shown, first = first, second = second, attempts = attempts },
			{ shown = true, first = false, second = true, attempts = 2 })
	end)

	helpers.it("(preview-covered-owner) does not hide a replacement on a late hide", function()
		local preview, window, _, restore = preview_with()
		local shown = preview.show({ { replacement = "text", group = "rolls", fires = true } }, "autocorrect")
		preview.note_covered()
		preview.hide()
		local hides = window.hides
		restore()
		helpers.assert_true(shown)
		helpers.assert_eq(hides, 0, "the covered preview no longer owns the shared surface")
	end)

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
