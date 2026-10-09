--- tests/support/tap_hold_fixture.lua

--- ==============================================================================
--- MODULE: Explicit Tap-Hold Preset Fixture
--- DESCRIPTION:
--- Functional engine scenarios select the shipped preset deliberately. Empty
--- configuration tests bypass this helper and exercise the neutral loader.
--- ==============================================================================

local M = {}

--- Selects the preset without replacing an explicit master choice in `text`.
--- @param text string|nil
--- @return string
function M.with_preset(text)
	text = text or ""
	local master = text:match("%[tap_hold%]([^%[]*)")
	local additions = ""
	for _, key in ipairs({ "enabled", "inherit_defaults" }) do
		if not master or not master:match("%f[%w_]" .. key .. "%s*=") then
			additions = additions .. key .. " = true\n"
		end
	end
	if master then return (text:gsub("(%[tap_hold%]%s*\n)", "%1" .. additions, 1)) end
	return "[tap_hold]\n" .. additions .. text
end

return M
