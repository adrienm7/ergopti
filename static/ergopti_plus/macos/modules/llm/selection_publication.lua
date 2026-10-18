--- modules/llm/selection_publication.lua

--- ==============================================================================
--- MODULE: Selection Translation Publication Receipt
--- DESCRIPTION:
--- Retains the classified native text destination for delayed translation output.
--- Full checks revalidate AX outside the input callback; cached checks compare
--- only retained RAM identity and the caller's generation at the final handoff.
--- ==============================================================================

local Utils = require("modules.keymap.utils")
local WindowInfo = require("adapters.window_info")
local M = {}

--- Captures one classified destination without manufacturing an unknown context.
--- @param focus string Native pid:window identity captured before selection copy.
--- @param alive function RAM-only translation generation predicate.
--- @return table|nil publication Full and cached SyntheticInput guards.
function M.capture(focus, alive)
	local receipt = Utils.capture_text_destination()
	if not receipt then return nil end
	local function cached()
		local current = Utils.capture_text_destination()
		return alive() == true and current ~= nil
			and current.generation == receipt.generation and current.pid == receipt.pid
			and current.window_id == receipt.window_id and current.element == receipt.element
	end
	local function current()
		if not cached() or Utils.owns_text_destination(receipt) ~= true then return false end
		local actual_focus = WindowInfo.focused_identity()
		return actual_focus == focus and cached()
	end
	return { current = current, cached = cached }
end

return M
