--- ui/menu/hotstring_counter.lua

--- ==============================================================================
--- MODULE: Hotstring Counter
--- DESCRIPTION:
--- Counts hotstrings across all groups (standard, ergopti, personal, extensions)
--- by scanning TOML section metadata from the keymap module.
---
--- FEATURES & RATIONALE:
--- 1. Extracted from builder.lua to make the counting logic unit-testable.
--- 2. Returns a single structured result consumed by the menu builder.
--- 3. One source for every count: the sections the keymap registered. The
---    extension packs used to be counted from a second walk of the bundled
---    extensions folder that re-read and re-parsed every file, which could
---    disagree with the loader and never saw the packs of installed layouts or
---    of the user's folder. They are now counted from the boot's discovery
---    catalogue and their loaded groups, like every other category.
--- ==============================================================================

local M = {}
local PersonalFiles = require("hotstrings.personal_files")
local Logger = require("infra.logger")
local LOG    = "hotstring_counter"
local Labels = require("menu.labels")
local Extensions = require("hotstrings.extensions")

--- Invalidates the hotstring count cache.
--- Preserved for API compatibility (called by save_prefs in init.lua). Every
--- count is read from the live keymap sections, so there is nothing to drop.
function M.invalidate_cache()
	-- Intentionally left empty: counts are recomputed from live sections.
end




-- ===================================
-- ===================================
-- ======= 1/ Formatting Util ========
-- ===================================
-- ===================================

--- Formats a large number with space thousands separators (French style).
--- @param n number The number to format.
--- @return string Formatted string, e.g. "1 234 567".
--- Delegates to the shared menu.labels module.
function M.fmt_grand(n)
	return Labels.fmt_count(n)
end




-- ======================================
-- ======================================
-- ======= 2/ Extension Counting ========
-- ======================================
-- ======================================

--- Sums the enabled sections of one registered group.
--- @param keymap table Keymap owner (get_sections, is_group_enabled, is_section_enabled).
--- @param name string Group name.
--- @return number total Entries of the enabled sections; 0 when the group is off.
--- @return boolean active Whether at least one section is enabled.
local function active_group_total(keymap, name)
	local secs = keymap.get_sections(name)
	local group_on = type(keymap.is_group_enabled) ~= "function" or keymap.is_group_enabled(name)
	local total, active = 0, false
	for _, sec in ipairs(type(secs) == "table" and secs or {}) do
		if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder and sec.count ~= nil
			and group_on
			and (type(keymap.is_section_enabled) ~= "function" or keymap.is_section_enabled(name, sec.name)) then
			total, active = total + tonumber(sec.count), true
		end
	end
	return total, active
end

--- Counts the discovered extension packs from their registered groups.
--- @param ctx table Menu context carrying `extension_packs` and `keymap`.
--- @param group_counts table Per-group counts, filled for every pack group.
--- @return number total, boolean has_count, table details
local function count_extensions(ctx, group_counts)
	-- A partial context without the catalogue counts no extension, as one
	-- without hotfiles counts no category; the boot always supplies it.
	local packs = type(ctx) == "table" and ctx.extension_packs or nil
	if packs == nil then return 0, false, {} end
	if type(packs) ~= "table" then
		error("The menu context carries a malformed extension catalogue", 0)
	end
	local total, has_count, details = 0, false, {}
	for _, pack in ipairs(packs) do
		-- A pack made only of bound geometry files supplies bundled categories
		-- and has no group of its own to list here.
		if #pack.toml_files > 0 then
			local detail = { id = pack.id, name = pack.name, total = 0, groups = {} }
			for _, file in ipairs(pack.toml_files) do
				local name = Extensions.category_key(pack.id, file.stem)
				local group_total, active = 0, false
				if ctx.keymap and type(ctx.keymap.get_sections) == "function" then
					group_total, active = active_group_total(ctx.keymap, name)
				end
				group_counts[name] = group_total
				detail.groups[#detail.groups + 1] = name
				detail.total = detail.total + group_total
				has_count = has_count or active
			end
			total = total + detail.total
			details[#details + 1] = detail
		end
	end
	return total, has_count, details
end




-- ==================================
-- ==================================
-- ======= 3/ Main Count API ========
-- ==================================
-- ==================================

--- Counts all hotstrings across standard, ergopti, personal, and extension groups.
--- @param ctx table Menu context (hotfiles, keymap, get_group_name, extension_packs).
--- @param ergopti_groups table<string,boolean> Set of group names specific to Ergopti layout.
--- @return table Counts: { common, ergopti, personal, ext, ext_details, grand, has_common,
---   has_ergopti, has_personal, has_ext, has_grand, group_counts }; each ext_details entry
---   is { id, name, total, groups } with groups the pack's registered group names.
function M.count_all(ctx, ergopti_groups)
	local group_counts = {}

	-- Count hotstrings for common groups split into "communs" and "ergopti"
	local common_total, ergopti_total = 0, 0
	local common_has_count, ergopti_has_count = false, false
	if ctx and ctx.hotfiles and type(ctx.hotfiles) == "table"
	and ctx.keymap and type(ctx.keymap.get_sections) == "function" then
		local is_sec_enabled = type(ctx.keymap.is_section_enabled) == "function"
			and ctx.keymap.is_section_enabled or nil
		local is_grp_enabled = type(ctx.keymap.is_group_enabled) == "function"
			and ctx.keymap.is_group_enabled or nil
		for _, f in ipairs(ctx.hotfiles) do
			local name = ctx.get_group_name and ctx.get_group_name(f) or f
			-- Extension packs are counted apart, under their extension, below.
			if name ~= "custom" and name ~= "personal" and name:sub(1, 13) ~= "personal_ext_"
				and not PersonalFiles.components(name)
				and not Extensions.parse_category_key(name) then
				local secs = ctx.keymap.get_sections(name)
				-- A gated-off group contributes 0 (the menu shows active hotstrings,
				-- not "what would reactivate") — mirrors the per-section rule below.
				local group_on = not is_grp_enabled or is_grp_enabled(name)
				local g_total = 0
				if type(secs) == "table" then
					for _, sec in ipairs(secs) do
						if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder
						and sec.count ~= nil then
							-- Only count sections that are currently enabled
							local active = group_on and (not is_sec_enabled or is_sec_enabled(name, sec.name))
							if active then
								local cnt = tonumber(sec.count)
								g_total = g_total + cnt
								-- Support both underscored and flattened IDs for classification
								local flattened_name = name:gsub("_", "")
								if ergopti_groups[name] or ergopti_groups[flattened_name] then
									ergopti_has_count = true
									ergopti_total = ergopti_total + cnt
								else
									common_has_count = true
									common_total = common_total + cnt
								end
							end
						end
					end
				end
				group_counts[name] = g_total
			end
		end
	end

	-- Count hotstrings for personal/custom groups (includes personal_ext_* extensions)
	local personal_total, personal_has_count = 0, false
	if ctx and ctx.keymap and type(ctx.keymap.get_sections) == "function" then
		local is_sec_enabled = type(ctx.keymap.is_section_enabled) == "function"
			and ctx.keymap.is_section_enabled or nil
		local is_grp_enabled = type(ctx.keymap.is_group_enabled) == "function"
			and ctx.keymap.is_group_enabled or nil
		local personal_group_names = {"personal", "custom"}
		if ctx.hotfiles then
			for _, f in ipairs(ctx.hotfiles) do
				local n = ctx.get_group_name and ctx.get_group_name(f) or f
				if n:sub(1, 13) == "personal_ext_" or PersonalFiles.components(n) then
					table.insert(personal_group_names, n)
				end
			end
		end
		for _, gname in ipairs(personal_group_names) do
			local secs = ctx.keymap.get_sections(gname)
			-- A gated-off personal group contributes 0, like the common groups above.
			local group_on = not is_grp_enabled or is_grp_enabled(gname)
			local g_total = 0
			if type(secs) == "table" then
				for _, sec in ipairs(secs) do
					if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder
					and sec.count ~= nil then
						-- Only count sections that are currently enabled
						local active = group_on and (not is_sec_enabled or is_sec_enabled(gname, sec.name))
						if active then
							personal_has_count = true
							local cnt = tonumber(sec.count)
							personal_total = personal_total + cnt
							g_total = g_total + cnt
						end
					end
				end
			end
			group_counts[gname] = g_total
		end
	end

	local grand_total     = common_total + ergopti_total + personal_total
	local grand_has_count = common_has_count or ergopti_has_count or personal_has_count

	local ext_total, ext_has_count, ext_details = count_extensions(ctx, group_counts)

	Logger.debug(LOG, "Counted: common=%d ergopti=%d personal=%d ext=%d.", common_total, ergopti_total, personal_total, ext_total)

	return {
		common       = common_total,
		ergopti      = ergopti_total,
		personal     = personal_total,
		ext          = ext_total,
		ext_details  = ext_details,
		grand        = grand_total + ext_total,
		has_common   = common_has_count,
		has_ergopti  = ergopti_has_count,
		has_personal = personal_has_count,
		has_ext      = ext_has_count,
		has_grand    = grand_has_count or ext_has_count,
		group_counts = group_counts,
	}
end

return M
