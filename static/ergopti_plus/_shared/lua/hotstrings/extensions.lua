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

--- Scans one or more roots for installed extensions.
---
--- Later roots win on a repeated id, which is what lets a user override a bundled
--- extension by installing their own under the same name — the same overlay rule
--- the hotstring packs themselves follow.
--- A file with a historical binding is listed apart, in `bound_files`: it is the
--- source of a bundled category, not a namespaced pack, so every consumer that
--- offers `toml_files` as `ext:` categories leaves it out without knowing why.
--- @param roots table Array of absolute directory paths, in precedence order.
--- @param io_fns table { list_dirs, list_files, read_file } — injected I/O.
--- @return table Array of { id, name, dir, descriptions, toml_files, bound_files, magic_key };
---   toml_files entries are { path, stem }, bound_files entries { path, stem, binding },
---   magic_key the declared physical key code or nil.
function M.scan(roots, io_fns)
	if type(roots) ~= "table" or type(io_fns) ~= "table" then return {} end
	local list_dirs = io_fns.list_dirs
	local list_files = io_fns.list_files
	local read_file = io_fns.read_file
	if type(list_dirs) ~= "function" or type(list_files) ~= "function" then return {} end

	local by_id, order = {}, {}

	for _, root in ipairs(roots) do
		if type(root) == "string" and root ~= "" then
			for _, dir in ipairs(list_dirs(root) or {}) do
				local id = dir:match("([^/\\]+)[/\\]?$")
				if id and id ~= "" then
					local manifest_text = nil
					if type(read_file) == "function" then
						manifest_text = read_file(dir .. "/" .. MANIFEST_NAME)
					end

					local name, descriptions, bindings, magic_key = parse_manifest(manifest_text)
					local toml_files, bound_files = {}, {}
					local bound_found = {}
					for _, path in ipairs(list_files(dir .. "/" .. HOTSTRINGS_SUBDIR) or {}) do
						local stem = path:match("([^/\\]+)%.toml$")
						if stem and bindings[stem] then
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

					if not by_id[id] then order[#order + 1] = id end
					by_id[id] = {
						id           = id,
						name         = name or id,
						dir          = dir,
						descriptions = descriptions,
						toml_files   = toml_files,
						bound_files  = bound_files,
						magic_key    = magic_key,
					}
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

return M
