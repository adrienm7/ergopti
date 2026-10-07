--- _shared/lua/tooltip/shortcut_column.lua

--- ==============================================================================
--- MODULE: Prediction Shortcut Column Geometry
--- DESCRIPTION:
--- Keeps shortcut labels outside prediction bodies and against one inner right
--- edge. Native adapters supply measured widths and the shared configured gap.
--- ==============================================================================

local M = {}

--- Reserves both independently measured columns, with no gap for an empty label.
--- @param body_width number Measured prediction body width.
--- @param label_width number Measured shortcut label width.
--- @param gap number Shared minimum column separation.
--- @return number The required content width.
function M.width(body_width, label_width, gap)
	return body_width + (label_width > 0 and (gap + label_width) or 0)
end

--- Positions a label against the content's inner right edge.
--- @param right_edge number The content's inner right edge.
--- @param label_width number Measured shortcut label width.
--- @return number The label's left edge.
function M.left(right_edge, label_width)
	return right_edge - label_width
end

return M
