--- _shared/lua/hotstrings/delay_resolver.lua

--- ==============================================================================
--- MODULE: Hotstring Delay & Colour Cascade (Shared)
--- DESCRIPTION:
--- The precedence rule that decides how long a hotstring waits before firing,
--- what colour its preview is tinted, and whether it shows one at all.
---
--- WHY THIS IS SHARED AND PURE:
--- The cascade is five rungs deep and every driver has to walk it identically —
--- a user who sets a delay on one machine and reads it on another is reading the
--- same TOML. It was written once in AutoHotkey and once in Lua, and the two had
--- already drifted in what an explicit `false` means. Extracting the rule leaves
--- each driver with only the part that genuinely differs: where its override
--- file lives and how it reads TOML.
---
--- THE PRECEDENCE, from strongest to weakest:
---   1. the user's override for this SECTION
---   2. the user's override for the CATEGORY
---   3. [_meta.section_delays] in the category's own TOML
---   4. [_meta] in the category's own TOML
---   5. the shared defaults in _shared/modules/hotstrings/defaults.toml
--- A per-category default colour sits between 4 and 5 for colour only, because a
--- category with no declared colour still wants its own rather than the global.
---
--- WHY `nil` AND `false` ARE NOT THE SAME THING HERE:
--- show_tooltip is a boolean, so "unset" cannot be spelled as falsy. A rung that
--- tested truthiness would make `show_tooltip = false` — the single most common
--- override, and what rolls.toml ships — indistinguishable from not having said
--- anything, and the preview would come back on. Every rung is tested against
--- nil explicitly, and that is the whole reason first_set() exists.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ The cascade ======================
-- =============================================
-- =============================================

--- Returns the first argument that is not nil, or nil when all are.
---
--- Not `a or b`: false is a legitimate value at every rung of this cascade, and
--- `or` would skip past it to the default.
--- @vararg any
--- @return any
function M.first_set(...)
	local n = select("#", ...)
	for i = 1, n do
		local value = select(i, ...)
		if value ~= nil then return value end
	end
	return nil
end

--- Resolves the effective settings for one (category, section) pair.
---
--- Every input is supplied by the caller rather than read here, because where
--- the overrides live and how a TOML is parsed are the two things that genuinely
--- differ between drivers. What must NOT differ is the order below.
---
--- @param inputs table
---   user_category  table|nil  The user's override table for the category.
---   user_section   table|nil  The user's override table for the section.
---   meta_category  table|nil  [_meta] from the category's TOML.
---   meta_section   table|nil  The section's entry in [_meta.section_delays].
---   default_delay  number     Shared fallback, in seconds.
---   default_color  string     Shared fallback colour.
---   category_color string|nil Per-category default colour, if the driver has one.
--- @return table { delay, color, show_tooltip, has_override }
function M.resolve(inputs)
	inputs = inputs or {}
	local user_cat = inputs.user_category or {}
	local user_sec = inputs.user_section or {}
	local meta_cat = inputs.meta_category or {}
	local meta_sec = inputs.meta_section or {}

	local delay = M.first_set(
		user_sec.delay,
		user_cat.delay,
		meta_sec.delay,
		meta_cat.delay,
		inputs.default_delay)

	local color = M.first_set(
		user_sec.color,
		user_cat.color,
		meta_sec.color,
		meta_cat.color,
		inputs.category_color,
		inputs.default_color)

	-- Defaults to shown. A category that wants no preview says so explicitly, and
	-- that `false` has to survive four rungs of cascade to get here.
	local show_tooltip = M.first_set(
		user_sec.show_tooltip,
		user_cat.show_tooltip,
		meta_sec.show_tooltip,
		meta_cat.show_tooltip)
	if show_tooltip == nil then show_tooltip = true end

	-- Whether the USER changed anything, which is what a menu shows as "(default)"
	-- versus a value. Deliberately excludes the TOML rungs: a category shipping a
	-- delay is not the user having set one, and conflating them makes "reset to
	-- defaults" look like it did nothing.
	local has_override =
		user_sec.delay ~= nil or user_sec.color ~= nil or user_sec.show_tooltip ~= nil
		or user_cat.delay ~= nil or user_cat.color ~= nil or user_cat.show_tooltip ~= nil

	return {
		delay        = delay,
		color        = color,
		show_tooltip = show_tooltip,
		has_override = has_override,
	}
end

return M
