--- infra/personal_hotstrings.lua

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
--- 3. Throw-safe scan: directory walking goes through infra/fs_dir and every
---    hs.fs.attributes call is pcall-guarded, so an unreadable folder is skipped,
---    not fatal.
--- ==============================================================================

local M = {}

local hs               = hs
local Logger           = require("infra.logger")
local fs_dir           = require("infra.fs_dir")
local menu_paths       = require("ui.menu.menu_paths")
local keymap           = require("modules.keymap")
local hotstring_editor = require("ui.hotstring_editor")

local LOG = "personal_hotstrings"

-- Hard cap on how deep the recursive extension-TOML scan descends. The scanned
-- tree is a user-writable folder, so a self-referential symlink would make a
-- naive recursion loop forever — Lua has no tail-call optimisation for this
-- call shape, so that ends in a stack overflow that aborts boot (F-LOW-4).
-- 16 levels mirrors the AHK driver's _HS_SCAN_MAX_DEPTH and is far deeper than
-- any real personal hotstrings layout; past it we stop descending and warn.
local SCAN_MAX_DEPTH = 16





--- ==============================================
--- ==============================================
--- ======= 1/ Personal Hotstrings Loading =======
--- ==============================================
--- ==============================================

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
	keymap.load_toml(keymap.PERSONAL_GROUP_NAME, personal_path)
	table.insert(loaded, { name = "personal", path = personal_path })

	-- Recursively scan for extra TOML files in the hotstrings folder.
	-- ``depth`` caps descent and ``visited`` is a set of canonical (lowercased,
	-- trailing-slash-stripped) absolute directory paths already entered —
	-- together they guarantee the walk terminates even on a self-referential
	-- symlink cycle in the user's folder (F-LOW-4).
	local hs_dir = menu_paths.get("PersonalHotstringsDir")
	local visited = {}
	-- Maps a derived group_name to the FIRST source path that produced it, so a
	-- second file resolving to the same name can be flagged instead of silently
	-- overwriting the first one's registration (F-LOW-5). This collision is real:
	-- a flat "a__b.toml" and a nested "a/b.toml" both derive "personal_ext_a__b",
	-- because "__" is used both as a literal character allowed in a stem AND as
	-- the path-segment join separator.
	local group_name_sources = {}
	local function scan_recursive(dir, prefix, depth)
		if depth > SCAN_MAX_DEPTH then
			Logger.warn(LOG, "Personal ext scan hit max depth %d at '%s' — not descending further (directory cycle?).",
				SCAN_MAX_DEPTH, dir)
			return
		end

		local ok_attr, attr = pcall(hs.fs.attributes, dir)
		if not (ok_attr and type(attr) == "table" and attr.mode == "directory") then return end

		-- Canonicalise so two spellings of the same directory collapse to one key;
		-- a re-visit means we are inside a cycle and must stop.
		local canonical = dir:gsub("[/\\]+$", ""):lower()
		if visited[canonical] then
			Logger.warn(LOG, "Personal ext scan revisited '%s' — skipping to break a directory cycle.", dir)
			return
		end
		visited[canonical] = true

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
				local prior_path = group_name_sources[group_name]
				if prior_path then
					-- F-LOW-5: e.g. a flat "a__b.toml" and a nested "a/b.toml" both derive
					-- "personal_ext_a__b". Warn loudly instead of silently overwriting the
					-- first file's path metadata with the second's — the two are unrelated
					-- source files that happen to collide onto the same keymap group name.
					Logger.warn(LOG,
						"Personal ext group name collision: '%s' already loaded from '%s' — '%s' resolves to the same group name and will overwrite it.",
						group_name, prior_path, item.path)
				end
				group_name_sources[group_name] = item.path
				keymap.load_toml(group_name, item.path)
				table.insert(loaded, { name = group_name, path = item.path })
				Logger.info(LOG, "Loaded extra personal hotstrings group '%s' from '%s'.", group_name, item.path)
			else
				-- Recurse into subdirectory
				local new_prefix = (prefix == "") and item.name or (prefix .. "__" .. item.name)
				scan_recursive(item.path, new_prefix, depth + 1)
			end
		end
	end

	scan_recursive(hs_dir:gsub("[/\\]+$", ""), "", 1)

	return loaded
end

return M
