--- core/ui/adapters/styled_title.lua

--- ==============================================================================
--- MODULE: Styled Menu Title (Hammerspoon)
--- DESCRIPTION:
--- Builds the hs.styledtext a menu row's title may be: hs.menubar draws a
--- styled title with its own font and colours per span. The tray's shortcut
--- hints (menu/ui/builder/shortcut_hint.lua) name their spans as plain data and
--- this adapter is the one place that turns them into the native object.
--- ==============================================================================

local M = {}

local hs = hs

--- Concatenates styled spans into one title.
--- @param spans table Array of { text = string, attributes = table } (hs.styledtext attributes).
--- @return any title An hs.styledtext.
function M.compose(spans)
	assert(type(spans) == "table" and #spans > 0, "styled title: no span to draw")
	local title = nil
	for _, span in ipairs(spans) do
		assert(type(span.text) == "string" and type(span.attributes) == "table",
			"styled title: a span needs its text and its attributes")
		local piece = hs.styledtext.new(span.text, span.attributes)
		title = title == nil and piece or title .. piece
	end
	return title
end

return M
