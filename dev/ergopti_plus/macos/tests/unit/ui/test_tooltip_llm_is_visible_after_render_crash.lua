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
--- Fix: move the `_is_visible = true` assignment to after Renderer.render()
--- returns without raising, inside the same internal pcall.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("tooltip_llm: is_visible() stays false after a show_predictions render crash (F-MED-24)", function()
	--- Loads tooltip_llm with a stubbed lib.logger so ERROR-level calls are
	--- observable, and returns the module plus the captured error messages.
	--- The stock hs.canvas stub used by tests/stubs/hs.lua returns a callable
	--- from any :method() call on the mock canvas — `minimumTextSize(...)`.w
	--- therefore yields a function value, and comparing it against a number in
	--- show_predictions' width-calc loop raises. That is a genuine crash deep
	--- inside the pcall-wrapped body, which is exactly the failure mode this
	--- regression covers — no additional stubbing is needed to trigger it.
	local function load_tooltip_llm_with_logger_spy()
		local logged_errors = {}
		package.loaded["lib.logger"] = nil
		local Tooltip = helpers.load_with_stubs("ui.tooltip.tooltip_llm")
		package.loaded["lib.logger"].error = function(_log, fmt, ...)
			table.insert(logged_errors, string.format(tostring(fmt), ...))
		end
		-- tooltip_llm already bound its own upvalue to the real (mutated)
		-- module above — release the cache entry now so the monkey-patched
		-- .error doesn't leak into every later require("lib.logger") for the
		-- rest of the full-suite process.
		package.loaded["lib.logger"] = nil
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
end)

helpers.describe("tooltip_llm: _is_visible is set after Renderer.render(), not before (F-MED-24)", function()
	local function read_src()
		local path = helpers.driver_root() .. "ui/tooltip/tooltip_llm.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open tooltip_llm.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("the _is_visible = true assignment appears after the Renderer.render call", function()
		local src = read_src()
		local render_call_pos = src:find("Renderer.render(assemble_blocks(_state, render_count), _state, start_watchers)", 1, true)
		local visible_flag_pos = src:find("_is_visible = true", 1, true)
		helpers.assert_true(render_call_pos ~= nil, "show_predictions must call Renderer.render(...)")
		helpers.assert_true(visible_flag_pos ~= nil, "show_predictions must set _is_visible = true")
		helpers.assert_true(visible_flag_pos > render_call_pos,
			"_is_visible = true must come AFTER the Renderer.render() call so a render crash cannot leave it stuck true")
	end)
end)
