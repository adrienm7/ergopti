--- _shared/lua/hotstrings/extensions.lua

--- ==============================================================================
--- MODULE: Hotstring Extension Packs (shared)
--- DESCRIPTION:
--- Discovers installed extension packs and the hotstring files they carry.
---
--- An extension is a directory holding a `manifest.toml` that names it and a
--- `hotstrings/` folder of TOML packs. It is how a user ships a set of hotstrings
--- as a unit — their employer's abbreviations, a medical vocabulary, another
--- language — without editing the packs this project bundles.
---
--- WHY THIS IS SHARED AND NOT PER-DRIVER:
--- The mechanism was implemented once, in AHK, and the menu manifest recorded
--- that as `platforms = ["ahk"]` with the reason "scans a Windows extensions
--- directory". That reason described the implementation, not the feature: the
--- directory it scans is `static/ergopti_plus/extensions`, which is part of this
--- repository and ships to all three drivers, and the demo extension in it has
--- carried a `shortcuts/menu.lua` next to its `menu.ahk` since it was written.
--- The format was cross-platform from the start; only the reader was not.
---
--- FEATURES & RATIONALE:
--- 1. Injected I/O: the caller supplies `list_dirs`, `list_files` and `read_file`
---    because the three drivers have nothing in common there — Hammerspoon has
---    `hs.fs`, the Linux daemon shells out, and a test has neither. Keeping the
---    parsing pure is what lets one suite cover the behaviour for both drivers.
--- 2. Localised names: the manifest carries `description` per locale and `name`
---    plain. The menu shows the name; the description is what a future extension
---    browser would show.
--- 3. Missing is not broken: an extension directory with no manifest is still an
---    extension, named after its folder. Refusing to list it would hide packs
---    that work perfectly, and the id is a usable name.
--- ==============================================================================

local M = {}
local TomlCodec = require("toml_codec.codec")

-- The file naming an extension, at the root of its directory.
local MANIFEST_NAME = "manifest.toml"

-- The subdirectory holding its hotstring packs. A flat layout was considered and
-- rejected: an extension also ships `shortcuts/`, so the packs need their own
-- folder to stay distinguishable from everything else it carries.
local HOTSTRINGS_SUBDIR = "hotstrings"

-- The only fields a hotstring binding may carry. Anything else is refused: a
-- binding says where a historical section's rules live, never whether they are
-- on, so an `enabled` key would smuggle activation into discovery.
local BINDING_FIELDS = { category = true, feature_section = true, sections = true, source = true }

-- The source tiers a binding may claim. Only "common": a bound file replaces the
-- bundled source of a historical category, so it keeps that category's priority
-- tier instead of the package tier an ordinary extension pack receives.
local BINDING_SOURCES = { common = true }

-- Identifier shapes, the ones the bundled catalogue already uses: a pack stem
-- may carry a dash (ergopti-demo), a runtime category or section may not.
local STEM_PATTERN = "^[a-z][a-z0-9_-]*$"
local IDENTIFIER_PATTERN = "^[a-z][a-z0-9_]*$"
local FEATURE_SECTION_PATTERN = "^hotstrings%.[a-z][a-z0-9_]*$"

-- The one field of [extension.magic_key]: the physical key, named by its W3C
-- KeyboardEvent.code as in _shared/data/keycodes/physical_keys.json, that types
-- the magic key on the extension's layout. The shape is checked here; whether
-- the registry knows the code is checked where a driver resolves it to its own
-- key identifier, and by the registry index builder for published layouts.
local MAGIC_KEY_FIELDS = { key = true }
local KEY_CODE_PATTERN = "^[A-Z][A-Za-z0-9]*$"

-- Characters a pack id or hotstring file stem may not carry: a dot splits the
-- configuration path (hotstrings.groups.<category>) that addresses the pack's
-- preference, and a colon splits the ext:<id>:<stem> category key. A pack named
-- com.acme or a backup words.old.toml would register a group no preference can
-- name, and the projection that enables groups would refuse the whole catalogue.
local UNADDRESSABLE_PATTERN = "[%.:]"





-- =======================================
-- =======================================
-- ======= 1/ Parsing the manifest =======
-- =======================================
-- =======================================

--- Validates one binding's section selection: a non-empty array of distinct names.
--- @param sections any Declared `sections` value.
local function validate_binding_sections(sections)
	if type(sections) ~= "table" or #sections == 0 then
		error("Invalid extension section selection (content withheld)", 0)
	end
	local seen, count = {}, 0
	for index, section in pairs(sections) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #sections
			or type(section) ~= "string" or not section:match(IDENTIFIER_PATTERN) or seen[section] then
			error("Invalid extension section selection (content withheld)", 0)
		end
		seen[section], count = true, count + 1
	end
	if count ~= #sections then error("Invalid extension section selection (content withheld)", 0) end
end

--- Validates the physical magic key a layout extension declares.
--- @param magic_key any The [extension.magic_key] table, or nil.
--- @return string|nil The declared KeyboardEvent.code; nil when none is declared.
local function validate_magic_key(magic_key)
	if magic_key == nil then return nil end
	if type(magic_key) ~= "table" then error("Invalid extension magic key (content withheld)", 0) end
	for field in pairs(magic_key) do
		if not MAGIC_KEY_FIELDS[field] then error("Unknown extension magic key field (content withheld)", 0) end
	end
	if type(magic_key.key) ~= "string" or not magic_key.key:match(KEY_CODE_PATTERN) then
		error("Invalid extension magic key code (content withheld)", 0)
	end
	return magic_key.key
end

--- Validates the historical source bindings of a manifest.
---
--- A binding attaches one of the extension's hotstring files to the runtime
--- category, feature section and source tier the rules had before they moved
--- into a layout extension, so existing preferences keep addressing them.
--- @param bindings any The `[extension.hotstring_bindings]` table, or nil.
--- @return table Bindings keyed by hotstring file stem; empty when none.
local function validate_bindings(bindings)
	if bindings == nil then return {} end
	if type(bindings) ~= "table" then error("Invalid extension hotstring bindings (content withheld)", 0) end
	for stem, binding in pairs(bindings) do
		if type(stem) ~= "string" or not stem:match(STEM_PATTERN) or type(binding) ~= "table" then
			error("Invalid extension hotstring binding (content withheld)", 0)
		end
		for key in pairs(binding) do
			if not BINDING_FIELDS[key] then error("Unknown extension hotstring binding field (content withheld)", 0) end
		end
		if type(binding.category) ~= "string" or not binding.category:match(IDENTIFIER_PATTERN)
			or type(binding.feature_section) ~= "string"
			or not binding.feature_section:match(FEATURE_SECTION_PATTERN)
			or not BINDING_SOURCES[binding.source] then
			error("Invalid historical extension hotstring binding (content withheld)", 0)
		end
		if binding.sections ~= nil then validate_binding_sections(binding.sections) end
	end
	return bindings
end

--- Decodes and validates metadata without exposing manifest content on failure.
--- @param text string|nil Manifest contents, or nil for an absent manifest.
--- @return string|nil name Declared display name.
--- @return table descriptions Localized descriptions.
--- @return table bindings Historical source bindings keyed by file stem.
--- @return string|nil magic_key Declared physical magic key (KeyboardEvent.code).
local function parse_manifest(text)
	if text == nil then return nil, {}, {}, nil end
	if type(text) ~= "string" then error("Invalid extension manifest input (content withheld)", 0) end
	local document = TomlCodec.decode(text)
	if type(document) ~= "table" then error("Invalid extension manifest TOML (content withheld)", 0) end
	local extension = document.extension
	if extension == nil then return nil, {}, {}, nil end
	if type(extension) ~= "table" then error("Invalid extension metadata (content withheld)", 0) end
	for key in pairs(extension) do
		if type(key) ~= "string" then error("Invalid extension metadata (content withheld)", 0) end
	end
	local name = extension.name
	if name ~= nil and type(name) ~= "string" then error("Invalid extension name (content withheld)", 0) end
	local descriptions = extension.description
	if descriptions == nil then descriptions = {} end
	if type(descriptions) ~= "table" then error("Invalid extension descriptions (content withheld)", 0) end
	for locale, value in pairs(descriptions) do
		if type(locale) ~= "string" or type(value) ~= "string" then
			error("Invalid localized extension description (content withheld)", 0)
		end
	end
	return name ~= "" and name or nil, descriptions, validate_bindings(extension.hotstring_bindings),
		validate_magic_key(extension.magic_key)
end

--- Extracts the canonical display name from the extension section.
--- @param text string|nil The manifest contents.
--- @return string|nil The declared name, or nil when it carries none.
function M.parse_name(text)
	local name = parse_manifest(text)
	return name
end

--- Extracts the localised descriptions from an extension manifest.
---
--- The value is an inline table of locale → string. Returned as a map so a caller
--- can pick the active locale and fall back to English without re-parsing.
--- @param text string|nil The manifest contents.
--- @return table Map of locale code to description; empty when there is none.
function M.parse_descriptions(text)
	local _, descriptions = parse_manifest(text)
	return descriptions
end




-- =====================================
-- =====================================
-- ======= 2/ Discovering packs ========
-- =====================================
-- =====================================

--- Reads one extension directory into its catalogue record.
--- @param dir string Extension directory.
--- @param id string Extension id, the directory name.
--- @param list_files function Injected file listing.
--- @param read_file function|nil Injected manifest reader.
--- @param skip_file function|nil Receives (path, err) for a file left out; raises when nil.
--- @return table Record { id, name, dir, descriptions, toml_files, bound_files, magic_key }.
local function read_pack(dir, id, list_files, read_file, skip_file)
	if id:find(UNADDRESSABLE_PATTERN) then
		error("Extension id cannot carry a dot or a colon (content withheld)", 0)
	end
	local manifest_text = nil
	if type(read_file) == "function" then
		manifest_text = read_file(dir .. "/" .. MANIFEST_NAME)
	end

	local name, descriptions, bindings, magic_key = parse_manifest(manifest_text)
	local toml_files, bound_files = {}, {}
	local bound_found = {}
	for _, path in ipairs(list_files(dir .. "/" .. HOTSTRINGS_SUBDIR) or {}) do
		local stem = path:match("([^/\\]+)%.toml$")
		if stem and stem:find(UNADDRESSABLE_PATTERN) then
			-- A backup such as words.old.toml costs that file, not its siblings.
			local err = "Extension hotstring file stem cannot carry a dot or a colon (content withheld)"
			if not skip_file then error(err, 0) end
			skip_file(path, err)
		elseif stem and bindings[stem] then
			bound_files[#bound_files + 1] = { path = path, stem = stem, binding = bindings[stem] }
			bound_found[stem] = true
		elseif stem then
			toml_files[#toml_files + 1] = { path = path, stem = stem }
		end
	end
	-- A binding names a file the pack must carry. Publishing the pack
	-- without it would leave a historical section with no source, which
	-- reads as "the rules were removed" rather than "the install is broken".
	for stem in pairs(bindings) do
		if not bound_found[stem] then
			error("Bound extension hotstring file is missing (content withheld)", 0)
		end
	end

	-- Sorted so the menu order is the same on every machine. A
	-- directory listing is not ordered by any contract, and a menu
	-- whose rows move between launches is one nobody learns.
	table.sort(toml_files, function(a, b) return a.stem < b.stem end)
	table.sort(bound_files, function(a, b) return a.stem < b.stem end)

	return {
		id           = id,
		name         = name or id,
		dir          = dir,
		descriptions = descriptions,
		toml_files   = toml_files,
		bound_files  = bound_files,
		magic_key    = magic_key,
	}
end

--- The extension directories one root contributes.
--- A root is a folder of extensions, or `{ pack = dir }` naming one extension
--- directory itself: the layout extension a driver ships inside its registry
--- folder sits next to layouts that are not installed, so its parent cannot be
--- scanned as a root.
--- @param root any One root entry.
--- @param list_dirs function Injected directory lister.
--- @return table Extension directories.
local function root_dirs(root, list_dirs)
	if type(root) == "table" then
		if type(root.pack) ~= "string" or root.pack == "" then
			error("Invalid extension pack root (content withheld)", 0)
		end
		return { (root.pack:gsub("[/\\]+$", "")) }
	end
	if type(root) == "string" and root ~= "" then return list_dirs(root) or {} end
	return {}
end

--- Scans one or more roots for installed extensions.
---
--- Later roots win on a repeated id, which is what lets a user override a bundled
--- extension by installing their own under the same name — the same overlay rule
--- the hotstring packs themselves follow.
--- A file with a historical binding is listed apart, in `bound_files`: it is the
--- source of a bundled category, not a namespaced pack, so every consumer that
--- offers `toml_files` as `ext:` categories leaves it out without knowing why.
--- Without `on_error` any unreadable root or invalid pack raises. With it, the
--- failure is handed to `on_error({ root, dir, id, path }, err)` and only that
--- root, pack or file is left out: a driver that must keep booting reports one
--- broken pack instead of losing every extension, and every bundled feature, to it.
--- @param roots table Array of absolute directory paths, or { pack = dir } entries, in precedence order.
--- @param io_fns table { list_dirs, list_files, read_file, on_error? } — injected I/O.
--- @return table Array of { id, name, dir, descriptions, toml_files, bound_files, magic_key };
---   toml_files entries are { path, stem }, bound_files entries { path, stem, binding },
---   magic_key the declared physical key code or nil.
function M.scan(roots, io_fns)
	if type(roots) ~= "table" or type(io_fns) ~= "table" then return {} end
	local list_dirs = io_fns.list_dirs
	local list_files = io_fns.list_files
	local read_file = io_fns.read_file
	local on_error = io_fns.on_error
	if type(list_dirs) ~= "function" or type(list_files) ~= "function" then return {} end
	if on_error ~= nil and type(on_error) ~= "function" then error("Extension scan on_error must be a function", 0) end

	local by_id, order = {}, {}

	for _, root in ipairs(roots) do
		local listed, dirs = true, nil
		if on_error then listed, dirs = pcall(root_dirs, root, list_dirs) else dirs = root_dirs(root, list_dirs) end
		if not listed then
			on_error({ root = root }, dirs)
			dirs = {}
		end
		for _, dir in ipairs(dirs or {}) do
			local id = dir:match("([^/\\]+)[/\\]?$")
			if id and id ~= "" then
				local read, record = true, nil
				if on_error then
					local function skip_file(path, err)
						on_error({ root = root, dir = dir, id = id, path = path }, err)
					end
					read, record = pcall(read_pack, dir, id, list_files, read_file, skip_file)
				else
					record = read_pack(dir, id, list_files, read_file)
				end
				if read then
					if not by_id[id] then order[#order + 1] = id end
					by_id[id] = record
				else
					on_error({ root = root, dir = dir, id = id }, record)
				end
			end
		end
	end

	local out = {}
	for _, id in ipairs(order) do out[#out + 1] = by_id[id] end
	return out
end

--- The category key a given extension pack occupies.
---
--- Namespaced by extension id. Without it an extension shipping `rolls.toml`
--- would collide with the bundled category of the same stem, and the collision
--- would resolve to whichever was scanned last — silently replacing a shipped
--- category with a third party's file, or the reverse.
--- @param extension_id string
--- @param stem string
--- @return string
function M.category_key(extension_id, stem)
	return string.format("ext:%s:%s", tostring(extension_id), tostring(stem))
end

--- Splits a category key back into its extension id and pack stem.
--- @param key string
--- @return string|nil extension_id, string|nil stem
function M.parse_category_key(key)
	if type(key) ~= "string" then return nil, nil end
	local id, stem = key:match("^ext:([^:]+):(.+)$")
	return id, stem
end




-- ================================================
-- ================================================
-- ======= 3/ Historical source bindings ==========
-- ================================================
-- ================================================

--- Whether a binding claims one section, or the general data, of a category.
--- @param binding table Validated binding.
--- @param section string|nil Section name; nil asks for the category's general data.
--- @return boolean
local function binding_covers(binding, section)
	if binding.sections == nil then return true end
	if section == nil then return false end
	for _, name in ipairs(binding.sections) do
		if name == section then return true end
	end
	return false
end

--- Restricts binding discovery to one explicitly selected logical category.
--- A single shipped source includes its bound sections without loading unrelated
--- categories from the same extension. Ownership conflict checks still run over
--- every discovered owner of that category through bound_source().
--- @param packs table Validated discovered extension records.
--- @param category string Exact runtime category.
--- @return table Detached pack records carrying only this category's bindings.
function M.category_bindings(packs, category)
	assert(type(packs) == "table" and type(category) == "string" and category ~= "",
		"category bindings need discovered packs and an exact category")
	local selected = {}
	for _, pack in ipairs(packs) do
		local files = {}
		for _, file in ipairs(pack.bound_files or {}) do
			if file.binding and file.binding.category == category then files[#files + 1] = file end
		end
		if #files > 0 then
			selected[#selected + 1] = { id = pack.id, name = pack.name, bound_files = files }
		end
	end
	return selected
end

--- The discovered file that supplies a category, or one section of it.
---
--- A namespaced key names its own file. A historical category keeps its bundled
--- source unless an extension binds it: a whole-category binding replaces the
--- file, a section binding replaces only those sections, and the category's
--- general metadata stays with the bundled file. Two owners of the same source
--- are refused, because either silent winner would change the user's rules
--- depending on which extension happened to be scanned last.
--- @param packs table Records returned by M.scan().
--- @param category string Runtime category, historical or namespaced.
--- @param section string|nil Section name, or nil for the category itself.
--- @return string|nil The bound file path, nil when the bundled source applies.
function M.bound_source(packs, category, section)
	if type(packs) ~= "table" or type(category) ~= "string" or category == ""
		or (section ~= nil and (type(section) ~= "string" or section == "")) then
		error("bound_source needs discovered packs, a category and an optional section", 0)
	end
	local extension_id, stem = M.parse_category_key(category)
	local owner = nil
	for _, pack in ipairs(packs) do
		for _, list in ipairs({ pack.toml_files or {}, pack.bound_files or {} }) do
			for _, file in ipairs(list) do
				if extension_id then
					if pack.id == extension_id and file.stem == stem then return file.path end
				elseif file.binding and file.binding.category == category and binding_covers(file.binding, section) then
					if owner ~= nil then
						error("Two extensions bind the same historical hotstring source: " .. category
							.. (section and ("." .. section) or ""), 0)
					end
					owner = file.path
				end
			end
		end
	end
	return owner
end

--- The historical categories an extension binds, in the order its Hotstrings
--- submenu lists them.
---
--- The discovery catalogue sorts bound files by stem, which put rolls before
--- SFB reduction on macOS and Linux while Windows walked the menu manifest's
--- hotstring groups (SFB reduction, then rolls, as every driver listed them
--- before they moved into the Ergopti extension). That manifest is the one
--- ordering source: its standard, then ergopti, then dynamic lists, under
--- either spelling of an id; a category none of them names keeps its place
--- after those, in the given order.
--- @param names table Category ids.
--- @param hotstring_groups table|nil The menu manifest's hotstring_groups table.
--- @return table A new array.
function M.menu_order(names, hotstring_groups)
	local rank, count = {}, 0
	local classes = type(hotstring_groups) == "table" and hotstring_groups or {}
	for _, class in ipairs({ "standard", "ergopti", "dynamic" }) do
		for _, id in ipairs(type(classes[class]) == "table" and classes[class] or {}) do
			count = count + 1
			if type(id) == "string" then
				local flat = id:gsub("_", "")
				rank[id] = rank[id] or count
				rank[flat] = rank[flat] or count
			end
		end
	end
	local indexed = {}
	for index, name in ipairs(names) do indexed[index] = { name = name, index = index } end
	table.sort(indexed, function(a, b)
		local rank_a, rank_b = rank[a.name] or math.huge, rank[b.name] or math.huge
		if rank_a ~= rank_b then return rank_a < rank_b end
		return a.index < b.index
	end)
	local out = {}
	for index, entry in ipairs(indexed) do out[index] = entry.name end
	return out
end

return M
