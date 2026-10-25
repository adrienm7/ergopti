--- _shared/lua/hotstrings/delay_resolver.lua

--- ==============================================================================
--- MODULE: Hotstring Delay & Colour Cascade (Shared)
--- DESCRIPTION:
--- The precedence rule that decides how long a hotstring waits before firing,
--- what colour its preview is tinted, whether it shows one at all, and which
--- collision priority it carries.
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
---   default_priority number   Source fallback collision priority.
--- @return table { delay, color, show_tooltip, priority, has_override }
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

	local priority = M.first_set(
		user_sec.priority,
		user_cat.priority,
		meta_sec.priority,
		meta_cat.priority,
		inputs.default_priority)

	-- Whether the USER changed anything, which is what a menu shows as "(default)"
	-- versus a value. Deliberately excludes the TOML rungs: a category shipping a
	-- delay is not the user having set one, and conflating them makes "reset to
	-- defaults" look like it did nothing.
	local has_override =
		user_sec.delay ~= nil or user_sec.color ~= nil or user_sec.show_tooltip ~= nil
			or user_sec.priority ~= nil
		or user_cat.delay ~= nil or user_cat.color ~= nil or user_cat.show_tooltip ~= nil
			or user_cat.priority ~= nil

	return {
		delay        = delay,
		color        = color,
		show_tooltip = show_tooltip,
		priority     = priority,
		has_override = has_override,
	}
end


-- =============================================
-- =============================================
-- ======= 2/ Delays as offsets of the base ====
-- =============================================
-- =============================================

--- Decimal places of a delay in seconds: whole milliseconds, as every driver
--- quantises and writes it.
M.DELAY_DECIMALS = 3

local DELAY_SCALE = 10 ^ M.DELAY_DECIMALS

--- The shortest delay an offset can leave: one millisecond. 0 means "unlimited"
--- everywhere, so an offset that cancels the base must not become it.
M.DELAY_STEP = 1 / DELAY_SCALE

--- Rounds seconds to the millisecond grid.
--- @param seconds number
--- @return number
local function quantise(seconds)
	return math.floor(seconds * DELAY_SCALE + 0.5) / DELAY_SCALE
end

--- The offset a delay override is stored as: seconds added to the base
--- expansion delay (`hotstrings.expansion_delay`), so an override keeps its
--- distance from the base when the base changes. 0 (unlimited) has no offset;
--- it is the `delay_unlimited` flag.
--- @param delay number Effective delay in seconds, above 0.
--- @param base number Base expansion delay in seconds.
--- @return number offset Signed seconds, on the millisecond grid.
function M.offset_for(delay, base)
	assert(type(delay) == "number" and delay > 0, "an offset describes a finite, positive delay")
	assert(type(base) == "number" and base >= 0, "the base expansion delay is a non-negative number")
	return quantise(delay - base)
end

--- The effective delay a stored override describes.
--- @param rung table|nil A user override rung: `delay_offset` (number) or
---   `delay_unlimited` (true), as the override file stores them; `legacy_delay`
---   (seconds) is the absolute spelling of earlier builds, applied as it stands
---   until it is migrated.
--- @param base number Base expansion delay in seconds.
--- @return number|nil seconds nil when the rung holds no delay; 0 is unlimited.
function M.effective_delay(rung, base)
	if type(rung) ~= "table" then return nil end
	if rung.delay_unlimited == true then return 0 end
	if type(rung.delay_offset) == "number" then
		return math.max(quantise(base + rung.delay_offset), M.DELAY_STEP)
	end
	-- The absolute delay of earlier builds applies as it was until the boot
	-- migration has rewritten it as an offset: nothing changes for the user meanwhile.
	if type(rung.legacy_delay) == "number" then return rung.legacy_delay end
	return nil
end

--- A copy of a user override rung whose `delay` is the effective seconds, which
--- is the field M.resolve reads. Every other field passes through.
--- @param rung table|nil
--- @param base number Base expansion delay in seconds.
--- @return table|nil
function M.with_effective_delay(rung, base)
	if type(rung) ~= "table" then return rung end
	local out = {}
	for key, value in pairs(rung) do out[key] = value end
	out.delay_offset, out.delay_unlimited = nil, nil
	out.delay = M.effective_delay(rung, base)
	return out
end

--- The key an earlier build used for the menu-set default delay: a category
--- named like this held only that one delay.
M.LEGACY_GLOBAL_CATEGORY = "_global"

--- Removes the default-delay record of earlier builds from an override tree and
--- returns its delay, which becomes the base expansion delay.
--- @param tree table Override tree { [category] = rung, ... } (mutated).
--- @return number|nil delay Seconds, nil when the tree held none.
function M.take_legacy_global(tree)
	local record = tree[M.LEGACY_GLOBAL_CATEGORY]
	if type(record) ~= "table" then return nil end
	tree[M.LEGACY_GLOBAL_CATEGORY] = nil
	return type(record.legacy_delay) == "number" and record.legacy_delay or nil
end

--- Converts the absolute `legacy_delay` of every rung of an override tree to the
--- stored form, keeping its effective delay: an offset of `base`, or the
--- `delay_unlimited` flag for 0. A delay already stored in the current form wins.
--- @param tree table Override tree { [category] = rung with sections } (mutated).
--- @param base number Base expansion delay in effect.
--- @return boolean changed Whether any rung held a legacy delay.
function M.adopt_legacy_delays(tree, base)
	local changed = false
	local function adopt(rung)
		if type(rung) ~= "table" or rung.legacy_delay == nil then return end
		changed = true
		if rung.delay_offset == nil and rung.delay_unlimited ~= true then
			if rung.legacy_delay == 0 then
				rung.delay_unlimited = true
			else
				rung.delay_offset = M.offset_for(rung.legacy_delay, base)
			end
		end
		rung.legacy_delay = nil
	end
	for _, category in pairs(tree) do
		adopt(category)
		for _, section in pairs(type(category) == "table" and category.sections or {}) do adopt(section) end
	end
	return changed
end

--- The override-file leaves that store a delay, in the order a writer clears
--- them. `delay` is the absolute spelling of earlier builds, kept here so a
--- clear and a migration remove it.
M.DELAY_LEAVES = { "delay_offset", "delay_unlimited", "delay" }

return M
