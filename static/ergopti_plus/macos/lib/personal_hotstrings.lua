--- lib/personal_hotstrings.lua

--- ==============================================================================
--- MODULE: Personal Hotstrings Loader
--- DESCRIPTION:
--- Boot-time registration of the user's personal hotstring groups: the canonical
--- personal_hotstrings.toml plus every extra *.toml found recursively under the
--- personal hotstrings folder. Extracted verbatim from init.lua Section 5.1 so the
--- boot orchestrator stays thin; load order and behaviour are unchanged.
---
--- FEATURES & RATIONALE:
--- 1. Priority single-source: the personal group's default priority comes from the
---    bundled priority.json (kept identical to the engine value by the parity gate)
---    so the editor placeholder is never hardcoded here.
--- 2. Deterministic order: the personal group is registered FIRST (lowest
---    group_order = highest priority), then extension groups in alphabetical order
---    by stem, recursing into sub-folders depth-first. The returned list preserves
---    that exact order so the caller can splice it into its hotfiles registry.
--- 3. Throw-safe scan: directory walking goes through lib/fs_dir and every
---    hs.fs.attributes call is pcall-guarded, so an unreadable folder is skipped,
---    not fatal.
--- ==============================================================================

local M = {}

local hs               = hs
local Logger           = require("lib.logger")
local fs_dir           = require("lib.fs_dir")
local menu_paths       = require("ui.menu.menu_paths")
local keymap           = require("modules.keymap")
local hotstring_editor = require("ui.hotstring_editor")

local LOG = "personal_hotstrings"





-- ===============================================
--- ==============================================
--- ======= 1/ Personal Hotstrings Loading =======
--- ==============================================
-- ===============================================

--- Registers the personal hotstring group and all extra personal extension groups.
--- @param ctx table { bundled_hotstrings_dir: string } — path to the bundled
---   hotstrings folder, used as the source of priority.json.
--- @return table[] Ordered list of { name = group_name, path = toml_path }: the
---   "personal" group first, then "personal_ext_*" groups in load order, ready for
---   the caller to splice into its hotfiles / hotfile_paths registries.
function M.load(ctx)
	local bundled_hotstrings_dir = ctx.bundled_hotstrings_dir
	local loaded = {}

	local personal_path = menu_paths.get("PersonalTomlPath")
	-- Personal source-default priority, read from the shared single source
	-- (_shared/modules/hotstrings/priority.json, copied into the bundle) so the editor
	-- shows it as the priority field placeholder without hardcoding it. Falls back
	-- to the engine value (kept identical to that file by the parity gate).
	local personal_default_priority = keymap.source_priority and keymap.source_priority("personal") or nil
	do
		local fh = io.open(bundled_hotstrings_dir .. "priority.json", "r")
		if fh then
			local raw = fh:read("*a")
			fh:close()
			local ok, parsed = pcall(hs.json.decode, raw)
			if ok and type(parsed) == "table" and type(parsed.personal) == "number" then
				personal_default_priority = parsed.personal
			end
		end
	end
	hotstring_editor.init(personal_path, keymap, nil, personal_default_priority)
	keymap.load_toml("personal", personal_path)
	table.insert(loaded, { name = "personal", path = personal_path })

	-- Recursively scan for extra TOML files in the hotstrings folder
	local hs_dir = menu_paths.get("PersonalHotstringsDir")
	local function scan_recursive(dir, prefix)
		local ok_attr, attr = pcall(hs.fs.attributes, dir)
		if not (ok_attr and type(attr) == "table" and attr.mode == "directory") then return end

		local items = {}
		for _, fname in ipairs(fs_dir.entries(dir)) do
			if fname ~= "." and fname ~= ".." and not fname:match("^_") then
				local fpath = dir .. "/" .. fname
				local ok_a, a = pcall(hs.fs.attributes, fpath)
				if ok_a and type(a) == "table" then
					if a.mode == "directory" then
						table.insert(items, { type = "dir", name = fname, path = fpath })
					elseif a.mode == "file" and fname:match("%.toml$") and (prefix ~= "" or fname ~= "personal_hotstrings.toml") then
						local stem = fname:match("^(.-)%.toml$")
						if stem and stem ~= "" then
							table.insert(items, { type = "file", name = fname, stem = stem, path = fpath })
						end
					end
				end
			end
		end

		table.sort(items, function(a, b) return a.name < b.name end)

		for _, item in ipairs(items) do
			if item.type == "file" then
				local new_prefix = (prefix == "") and item.stem or (prefix .. "__" .. item.stem)
				local group_name = "personal_ext_" .. new_prefix
				keymap.load_toml(group_name, item.path)
				table.insert(loaded, { name = group_name, path = item.path })
				Logger.info(LOG, "Loaded extra personal hotstrings group '%s' from '%s'.", group_name, item.path)
			else
				-- Recurse into subdirectory
				local new_prefix = (prefix == "") and item.name or (prefix .. "__" .. item.name)
				scan_recursive(item.path, new_prefix)
			end
		end
	end

	scan_recursive(hs_dir:gsub("[/\\]+$", ""), "")

	return loaded
end

return M
