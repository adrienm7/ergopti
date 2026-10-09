--- infra/personal_hotstrings.lua

--- ==============================================================================
--- MODULE: Personal Hotstrings Loader
--- DESCRIPTION:
--- Boot-time registration of the user's personal hotstring groups: the canonical
--- personal_hotstrings.toml plus every extra *.toml found recursively under the
--- personal hotstrings folder. Native adoption retains deterministic source order
--- while exact canonical identities separate additional personal-file owners.
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
---    native no-follow path classification is pcall-guarded. Unreadable folders
---    are skipped; linked/depth-limited routes retain read-only diagnostics.
--- ==============================================================================

local M = {}

local hs               = hs
local JsonCodec        = require("adapters.json_codec")
local Logger           = require("infra.logger")
local fs_dir           = require("infra.fs_dir")
local menu_paths       = require("infra.config_paths")
local keymap           = require("modules.keymap")
local hotstring_editor = require("ui.hotstring_editor")

local PersonalFiles = require("hotstrings.personal_files")
local Adoption = require("infra.personal_file_adoption")
local LOG = "personal_hotstrings"
local _inventory = {}
local _unavailable_directories = {}
local _cohort_probe, _probing

-- Hard cap on how deep the recursive extension-TOML scan descends. The scanned
-- tree is a user-writable folder, so a self-referential symlink would make a
-- naive recursion loop forever — Lua has no tail-call optimisation for this
-- call shape, so that ends in a stack overflow that aborts boot (F-LOW-4).
-- 16 levels mirrors the AHK driver's _HS_SCAN_MAX_DEPTH and is far deeper than
-- any real personal hotstrings layout; past it we stop descending and warn.
local SCAN_MAX_DEPTH = PersonalFiles.additional_scan_max_depth

-- Historical group prefix used only to recognize uniquely stored legacy choices.
local EXTENSION_GROUP_PREFIX = "personal_ext_"





--- ==============================================
--- ==============================================
--- ======= 1/ Personal Hotstrings Loading =======
--- ==============================================
--- ==============================================

--- Registers the personal hotstring group and all extra personal extension groups.
--- @param ctx table { bundled_hotstrings_dir: string, saved_preferences: table|nil }.
---   The bundled folder supplies priority.json; preferences identify old owners.
--- @return table[] Ordered list of { name = group_name, path = toml_path }: the
---   "personal" group first, then canonical descriptor groups in load order.
function M.load(ctx)
	local bundled_hotstrings_dir = ctx.bundled_hotstrings_dir
	local loaded = {}
	local discovered, blocked = {}, {}

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
			local parsed, decode_error = JsonCodec.decode(raw)
			if not decode_error and type(parsed) == "table" and type(parsed.personal) == "number" then
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
	-- Stage the complete discovery before assigning owners. Historical stem
	-- labels remain migration inputs only; exact relative components own groups.
	local function scan_recursive(dir, prefix, depth, components)
		if depth > SCAN_MAX_DEPTH then
			blocked[#blocked + 1] = { path = dir, label = table.concat(components, "/"), reason = "scan-depth" }
			Logger.warn(LOG, "Personal ext scan hit max depth %d at '%s' — not descending further (directory cycle?).",
				SCAN_MAX_DEPTH, dir)
			return
		end

		local observed, status, attr = pcall(require("adapters.file_system").path_status, dir)
		if observed and status == "present" and type(attr) == "table" and attr.mode == "link" then
			blocked[#blocked + 1] = { path = dir, label = #components > 0 and table.concat(components, "/") or dir:match("([^/]+)$"), reason = "linked-directory" }
			return
		end
		if not (observed and status == "present" and type(attr) == "table" and attr.mode == "directory") then return end

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
				local observed, status, a = pcall(require("adapters.file_system").path_status, fpath)
				if observed and status == "present" and type(a) == "table" then
					if a.mode == "link" and not fname:match("%.toml$") then
						local relative = {}; for index, component in ipairs(components) do relative[index] = component end
						relative[#relative + 1] = fname
						blocked[#blocked + 1] = { path = fpath, label = table.concat(relative, "/"), reason = "linked-directory" }
					elseif a.mode == "directory" then
						table.insert(items, { type = "dir", name = fname, path = fpath })
					elseif (a.mode == "file" or a.mode == "link") and fname:match("%.toml$") and (prefix ~= "" or fname ~= "personal_hotstrings.toml") then
						local stem = fname:match("^(.-)%.toml$")
						if stem then
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
				local source_components = {}
				for index, component in ipairs(components) do source_components[index] = component end
				source_components[#source_components + 1] = item.name
				local personal_source = PersonalFiles.describe(source_components)
				discovered[#discovered + 1] = { source = personal_source, path = item.path,
					legacy_name = EXTENSION_GROUP_PREFIX .. new_prefix }
			else
				-- Recurse into subdirectory
				local new_prefix = (prefix == "") and item.name or (prefix .. "__" .. item.name)
				local child_components = {}
				for index, component in ipairs(components) do child_components[index] = component end
				child_components[#child_components + 1] = item.name
				scan_recursive(item.path, new_prefix, depth + 1, child_components)
			end
		end
	end

	scan_recursive(hs_dir:gsub("[/\\]+$", ""), "", 1, {})
	_unavailable_directories = blocked
	_cohort_probe = function()
		if _probing then return nil end
		_probing = true
		local previous_discovered, previous_visited, previous_blocked = discovered, visited, blocked
		discovered, visited, blocked = {}, {}, {}
		local ok = pcall(scan_recursive, hs_dir:gsub("[/\\]+$", ""), "", 1, {})
		local fresh = discovered
		discovered, visited, blocked, _probing = previous_discovered, previous_visited, previous_blocked, false
		return ok and fresh or nil
	end
	local overrides = package.loaded["modules.hotstrings.hotstrings_config"]
	if overrides and overrides.common_autocorrection_admitted
		and overrides.common_autocorrection_admitted() ~= nil then
		local snapshot = overrides.scope_snapshot()
		if snapshot then
			for _, record in ipairs(discovered) do
				record.legacy_stored = snapshot.overrides[record.legacy_name] ~= nil
			end
		end
	end
	local inventory, refusal = Adoption.stage(discovered, ctx.saved_preferences or {}, personal_path)
	assert(inventory, "personal file adoption refused: " .. tostring(refusal))
	_inventory = inventory
	for _, record in ipairs(inventory) do
		local group_name = record.owner
		local source = PersonalFiles.copy(record.source)
		if keymap.load_toml(group_name, record.path, nil, source) ~= true then
			record.admitted, record.exclusive, record.reason = false, false, "native-registration-refused"
		end
		table.insert(loaded, { name = group_name, path = record.path, personal_source = PersonalFiles.copy(source),
			admitted = record.admitted, reason = record.reason })
		if record.admitted then
			Logger.info(LOG, "Loaded extra personal hotstrings group '%s' from '%s'.", group_name, record.path)
		else
			Logger.warn(LOG, "Personal source '%s' is read-only: %s.", group_name, record.reason)
			if record.reason == "ambiguous-legacy-owner" then
				Logger.warn(LOG, "Personal legacy owner collision: '%s' cannot identify one source.", record.legacy_name)
			end
		end
	end

	return loaded
end

--- Returns diagnostic-only skipped paths, never source or write capabilities.
--- @return table directories Detached blocked-directory labels and native routes.
function M.unavailable_directories()
	local rows = {}
	for index, record in ipairs(_unavailable_directories) do
		rows[index] = { path = record.path, label = record.label, reason = record.reason }
	end
	return rows
end

--- Returns the boot-owned canonical adoption record for one registered source.
--- @param name string
--- @return table|nil record
function M.adoption(name)
	for _, record in ipairs(_inventory) do
		if record.owner == name then
			local copied = {}
			for key, value in pairs(record) do copied[key] = value end
			copied.source = PersonalFiles.copy(record.source)
			return copied
		end
	end
end

--- Detached boot-owned sources for native configuration and menu views.
function M.adoptions()
	local records = {}
	for _, record in ipairs(_inventory) do records[#records + 1] = M.adoption(record.owner) end
	return records
end

local function discovery_current()
	if not _cohort_probe then return false end
	local fresh = _cohort_probe()
	if not fresh or #fresh ~= #_inventory then return false end
	local expected = {}
	for _, record in ipairs(_inventory) do expected[record.owner] = record.path end
	for _, record in ipairs(fresh) do
		if expected[record.source.id] ~= record.path then return false end
		expected[record.source.id] = nil
	end
	return next(expected) == nil
end

--- Rechecks a held canonical cohort without deriving authority from provenance.
--- @param selected table Captured source/owner/path binding.
--- @return boolean
function M.adoption_current(selected)
	return Adoption.current(_inventory, selected) == true and discovery_current()
end

--- Checks cleanup evidence without admitting candidate bytes to boot controls.
--- The controller separately verifies its exact native publication capability.
--- @param selected table Original boot-owned admitted binding.
--- @param content string Exact invocation-owned candidate bytes.
--- @return boolean current
function M.publication_current(selected, content)
	return Adoption.published_current(_inventory, selected, content) == true and discovery_current()
end

--- Refreshes the physical receipt after a successful source-owner publication.
function M.adopt_published_source(selected, content)
	return Adoption.advance(_inventory, selected, content)
end

--- Whether a registered hotstring group is the user's own: the personal file
--- or one of the extra files this loader registers beside it.
--- @param name string Registered group name.
--- @return boolean
function M.is_personal_group(name)
	return name == keymap.PERSONAL_GROUP_NAME
		or PersonalFiles.components(name) ~= nil
		or (type(name) == "string" and name:sub(1, #EXTENSION_GROUP_PREFIX) == EXTENSION_GROUP_PREFIX)
end

return M
