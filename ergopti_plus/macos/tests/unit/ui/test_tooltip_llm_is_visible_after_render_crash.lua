--- tests/unit/ui/test_tooltip_llm_is_visible_after_render_crash.lua

--- ==============================================================================
--- MODULE: Regression — TooltipLLM.is_visible() after a show_predictions crash (F-MED-24)
--- DESCRIPTION:
--- show_predictions() set `_is_visible = true` BEFORE the width-calculation loop
--- and the Renderer.render() call, not after. Both of those steps can raise (the
--- whole body runs inside an internal pcall, so the crash never propagates out
--- of show_predictions, but it also never gets a chance to reset the flag). The
--- result: a render exception left is_visible() permanently stuck reporting
--- true even though no canvas was ever actually shown.
---
--- This matters because llm_bridge.lua reads tooltip.is_visible() to decide
--- whether to route keystrokes to the tooltip (arrow navigation, Tab accept,
--- Enter contextual behaviour) versus letting them fall through to the
--- focused application. A stuck-true flag silently misroutes every subsequent
--- keypress until the next successful show_predictions() or an explicit hide().
---
--- Fix: commit visibility only after the renderer invokes its post-show callback
--- and the complete dismissal-watcher set is verified active.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("tooltip_llm: is_visible() stays false after a show_predictions render crash (F-MED-24)", function()
	--- Loads tooltip_llm with a stubbed lib.logger so ERROR-level calls are
	--- observable, and returns the module plus the captured error messages.
	--- Installs an explicit failing renderer. The shared hs.canvas double must
	--- remain contract-faithful so E2E renders can detect real native-state bugs;
	--- using a deliberately broken global canvas stub as this test's fault
	--- injector made unrelated tooltip renders log errors while the suite passed.
	local function load_tooltip_llm_with_logger_spy()
		local logged_errors = {}
		package.loaded["ui.tooltip.renderer"] = {
			canvas = {
				minimumTextSize = function()
					error("simulated tooltip measurement failure")
				end,
			},
			ELEM_INFO = 6,
			hide = function() return true end,
			set_element_text = function() return true end,
			render = function() return false end,
		}
		package.loaded["infra.logger"] = nil
		local Tooltip = helpers.load_with_stubs("ui.tooltip.tooltip_llm")
		-- Tooltip captured the fault injector; release the cache slot so it cannot
		-- become another order-dependent fixture for later modules.
		package.loaded["ui.tooltip.renderer"] = nil
		package.loaded["infra.logger"].error = function(_log, fmt, ...)
			table.insert(logged_errors, string.format(tostring(fmt), ...))
		end
		-- tooltip_llm already bound its own upvalue to the real (mutated)
		-- module above — release the cache entry now so the monkey-patched
		-- .error doesn't leak into every later require("infra.logger") for the
		-- rest of the full-suite process.
		package.loaded["infra.logger"] = nil
		return Tooltip, logged_errors
	end

	helpers.it("show_predictions logs an ERROR when the render pipeline crashes", function()
		local Tooltip, logged_errors = load_tooltip_llm_with_logger_spy()
		local preds = { { chunks = {}, nw = "hello" } }

		Tooltip.show_predictions(preds, 1, true, "Model", "alt", 0, {}, nil, nil, 0)

		helpers.assert_true(#logged_errors > 0,
			"show_predictions must surface an ERROR-level log line when the render pipeline crashes")
	end)

	helpers.it("is_visible() stays false after a crashing show_predictions call", function()
		local Tooltip = load_tooltip_llm_with_logger_spy()
		local preds = { { chunks = {}, nw = "hello" } }

		Tooltip.show_predictions(preds, 1, true, "Model", "alt", 0, {}, nil, nil, 0)

		helpers.assert_true(Tooltip.is_visible() == false,
			"is_visible() must not get stuck true after show_predictions failed to render — " ..
			"llm_bridge.lua would otherwise keep routing keystrokes to a tooltip that was never shown")
	end)

	helpers.it("show_predictions reports a failed transaction when rendering crashes", function()
		local Tooltip = load_tooltip_llm_with_logger_spy()
		local preds = { { chunks = {}, nw = "hello" } }

		local shown = Tooltip.show_predictions(preds, 1, true, "Model", "alt", 0, {}, nil, nil, 0)

		helpers.assert_eq(shown, false,
			"a swallowed render exception must not be reported as a committed tooltip")
	end)
end)
