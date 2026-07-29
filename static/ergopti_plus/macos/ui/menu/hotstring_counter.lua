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
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")
local fs_dir       = require("lib.fs_dir")
local LOG    = "hotstring_counter"
local Labels = require("menu.labels")

-- Per-file TOML entry counts, keyed by absolute path.
-- Never cleared on toggle: TOML files do not change at runtime. The counts
-- reflect raw entries in the files, independent of the enabled/disabled state
-- that the menu builder applies when summing visible totals.
local _count_cache    = {}

-- Extension directory metadata (names, paths, per-file counts).
-- Populated once on first use and kept for the session; extensions are
-- installed/removed only on disk changes that require hs.reload() anyway.
local _ext_meta_cache = nil

--- Invalidates the hotstring count cache.
--- Preserved for API compatibility (called by save_prefs in init.lua).
--- Both caches are now session-stable: file content does not change on
--- toggles, and extensions are not installed/uninstalled at runtime.
--- A full hs.reload() resets the Lua state and thus implicitly clears them.
function M.invalidate_cache()
	-- Intentionally left empty: caches are stable for the session lifetime.
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




-- =====================================
-- =====================================
-- ======= 2/ Extension Counting ========
-- =====================================
-- =====================================

--- Counts hotstring entries in a TOML file by scanning for quoted keys.
--- Each line starting with `"` inside a [[section]] block is one hotstring.
--- @param path string Absolute path to the TOML file.
--- @return number total Total hotstring count.
--- @return table sections List of { name, count } per section.
local function count_toml_hotstrings(path)
	if _count_cache[path] then return _count_cache[path].total, _count_cache[path].sections end

	local total = 0
	local sections = {}
	local current = nil
	local fh = io.open(path, "r")
	if not fh then return 0, {} end
	for line in fh:lines() do
		local sec = line:match("^%[%[([A-Za-z0-9_%-]+)%]%]")
		if sec then
			current = sec
			table.insert(sections, { name = sec, count = 0 })
		elseif line:match('^"') and current then
			sections[#sections].count = sections[#sections].count + 1
			total = total + 1
		end
	end
	fh:close()

	_count_cache[path] = { total = total, sections = sections }
	return total, sections
end

--- Reads the extension display name from its manifest.toml.
--- @param manifest_path string Absolute path to the manifest.toml file.
--- @return string|nil Parsed name, or nil if unavailable.
local function read_ext_name(manifest_path)
	local fh = io.open(manifest_path, "r")
	if not fh then return nil end
	for line in fh:lines() do
		local v = line:match('^name%s*=%s*"(.-)"')
		if v then fh:close(); return v end
	end
	fh:close()
	return nil
end




-- ==================================
-- ==================================
-- ======= 3/ Main Count API ========
-- ==================================
-- ==================================

--- Counts all hotstrings across standard, ergopti, personal, and extension groups.
--- @param ctx table Menu context (hotfiles, keymap, get_group_name, base_dir).
--- @param ergopti_groups table<string,boolean> Set of group names specific to Ergopti layout.
--- @return table Counts: { common, ergopti, personal, ext, grand, has_common, has_ergopti, has_personal, has_ext, group_counts }.
function M.count_all(ctx, ergopti_groups)
	local fmt_grand = M.fmt_grand
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
			if name ~= "custom" and name ~= "personal" and name:sub(1, 13) ~= "personal_ext_" then
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
				if n:sub(1, 13) == "personal_ext_" then
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

	-- Count extension hotstrings
	local ext_total, ext_has_count = 0, false
	local ext_details = {}

	if _ext_meta_cache then
		ext_total     = _ext_meta_cache.total
		ext_has_count = _ext_meta_cache.has_count
		ext_details   = _ext_meta_cache.details
	else
		local ext_root = ctx.base_dir and (ctx.base_dir .. "../../extensions/")
		-- `x and pcall(...) or false` truncates pcall to ONE value, so the second
		-- local was always nil and the type(attr) == "table" test below could never
		-- pass: the whole extensions surface was unreachable. Call pcall directly.
		local ok_attr, attr = false, nil
		if ext_root then ok_attr, attr = pcall(hs.fs.attributes, ext_root) end
		if ok_attr and type(attr) == "table" and attr.mode == "directory" then
			local ext_ids = {}
			for _, fname in ipairs(fs_dir.entries(ext_root)) do
				if fname ~= "." and fname ~= ".." then
					local fpath = ext_root .. fname
					local ok_a2, a2 = pcall(hs.fs.attributes, fpath)
					if ok_a2 and type(a2) == "table" and a2.mode == "directory" then
						table.insert(ext_ids, fname)
					end
				end
			end
			table.sort(ext_ids)

			for _, ext_id in ipairs(ext_ids) do
				local ext_dir    = ext_root .. ext_id .. "/"
				local hs_dir     = ext_dir .. "hotstrings/"
				local manifest   = ext_dir .. "manifest.toml"
				local ok_m, am   = pcall(hs.fs.attributes, manifest)
				if not (ok_m and type(am) == "table" and am.mode == "file") then goto continue_ext end

				local ok_hd, ahd = pcall(hs.fs.attributes, hs_dir)
				if not (ok_hd and type(ahd) == "table" and ahd.mode == "directory") then goto continue_ext end

				local toml_stems = {}
				for _, fname in ipairs(fs_dir.entries(hs_dir)) do
					if fname:match("%.toml$") and not fname:match("^_") then
						local stem = fname:match("^(.-)%.toml$")
						if stem and stem ~= "" then table.insert(toml_stems, stem) end
					end
				end
				table.sort(toml_stems)

				local ext_name = read_ext_name(manifest) or ext_id
				local ext_hs_total = 0
				local ext_files = {}

				for _, stem in ipairs(toml_stems) do
					local toml_path = hs_dir .. stem .. ".toml"
					local total, sections = count_toml_hotstrings(toml_path)
					ext_hs_total = ext_hs_total + total
					table.insert(ext_files, {
						stem     = stem,
						path     = toml_path,
						total    = total,
						sections = sections
					})
				end

				if ext_hs_total > 0 then
					ext_has_count = true
					table.insert(ext_details, {
						id    = ext_id,
						name  = ext_name,
						total = ext_hs_total,
						files = ext_files
					})
				end
				ext_total = ext_total + ext_hs_total
				::continue_ext::
			end
		end
		_ext_meta_cache = { total = ext_total, has_count = ext_has_count, details = ext_details }
	end

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
