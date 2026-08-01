--- _shared/lua/hotstring_priority/init.lua

--- ==============================================================================
--- MODULE: Hotstring Collision Priority (shared)
--- DESCRIPTION:
--- Resolves the collision priority of a hotstring entry. When two triggers of
--- equal length both match, the higher priority wins; this module owns the
--- cascade that produces that number.
---
--- FEATURES & RATIONALE:
--- 1. One cascade: individual > section > file > source default. It existed
---    twice in Lua (macOS) and once in AutoHotkey, and the Linux driver had none
---    at all — so the same two colliding entries elected different winners
---    depending on the OS, with nothing comparing them.
--- 2. Tiers are DATA: _shared/modules/hotstrings/priority.json is the single
---    source of truth, and it is injected rather than read here, so this module
---    stays pure and usable from a test with no filesystem.
--- 3. The source default is not decoration. An entry with no explicit priority
---    still scores its tier, so a personal hotstring (50) outranks a bundled one
---    (10) without either declaring anything. A driver that defaulted to 0
---    instead would let a deliberately LOW individual priority beat an
---    undeclared personal entry — the exact inversion the tiers exist to
---    prevent.
--- ==============================================================================

local M = {}




-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

--- Fallback tiers, used only when the caller injects none. They mirror
--- _shared/modules/hotstrings/priority.json, which is the canonical copy and is
--- locked to the AutoHotkey constants by tools/test/test-priority-parity.cjs.
M.DEFAULT_TIERS = {
	common   = 10,
	package  = 30,
	personal = 50,
}




-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- Source-default priority for a category (the group a mapping was loaded from).
--- @param category string|nil Category name, e.g. "personal", "ext.demo", "rolls".
--- @param tiers table|nil Tier table; defaults to M.DEFAULT_TIERS.
--- @return number The source-default priority.
function M.source_priority(category, tiers)
	local t = type(tiers) == "table" and tiers or M.DEFAULT_TIERS
	local c = type(category) == "string" and category:lower() or ""
	if c == "personal" then return t.personal end
	-- "custom" is the group the hotstring editor reloads personal_hotstrings.toml
	-- into on a live save, while boot loads the same file as "personal". Scoring it
	-- at the personal tier keeps an edited personal hotstring at the priority it
	-- had at startup instead of silently dropping to common.
	if c == "custom" then return t.personal end
	if c:sub(1, 13) == "personal_ext_" then return t.package end
	if c:sub(1, 4) == "ext." then return t.package end
	return t.common
end

--- Resolves the effective priority through the cascade
--- individual > section > file > source default. The first numeric level wins.
--- @param individual number|nil Per-hotstring priority (from the TOML entry).
--- @param section number|nil Section-level priority ([_meta.section_priorities]).
--- @param file number|nil File-level priority ([_meta.priority]).
--- @param category string|nil Category name, for the source-default fallback.
--- @param tiers table|nil Tier table; defaults to M.DEFAULT_TIERS.
--- @return number The resolved priority.
function M.resolve(individual, section, file, category, tiers)
	if type(individual) == "number" then return individual end
	if type(section)    == "number" then return section end
	if type(file)       == "number" then return file end
	return M.source_priority(category, tiers)
end

return M
