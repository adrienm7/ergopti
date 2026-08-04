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

-- The file naming an extension, at the root of its directory.
local MANIFEST_NAME = "manifest.toml"

-- The subdirectory holding its hotstring packs. A flat layout was considered and
-- rejected: an extension also ships `shortcuts/`, so the packs need their own
-- folder to stay distinguishable from everything else it carries.
local HOTSTRINGS_SUBDIR = "hotstrings"





-- =======================================
-- =======================================
-- ======= 1/ Parsing the manifest =======
-- =======================================
-- =======================================

--- Extracts the display name from an extension manifest.
---
--- Deliberately a pattern match rather than a TOML parse. The only key read here
--- is a quoted scalar under `[extension]`, and pulling the whole TOML codec into
--- the startup path — the Windows driver does this scan before the menu is built
--- — costs more than it explains. A manifest whose name cannot be found falls
--- back to the directory id, which is always present and always usable.
--- @param text string|nil The manifest contents.
--- @return string|nil The declared name, or nil when it carries none.
function M.parse_name(text)
	if type(text) ~= "string" then return nil end
	local name = text:match('name%s*=%s*"([^"]+)"')
	if name and name ~= "" then return name end
	return nil
end

--- Extracts the localised descriptions from an extension manifest.
---
--- The value is an inline table of locale → string. Returned as a map so a caller
--- can pick the active locale and fall back to English without re-parsing.
--- @param text string|nil The manifest contents.
--- @return table Map of locale code to description; empty when there is none.
function M.parse_descriptions(text)
	local out = {}
	if type(text) ~= "string" then return out end
	local block = text:match("description%s*=%s*{(.-)}")
	if not block then return out end
	for locale, value in block:gmatch('(%w+)%s*=%s*"([^"]*)"') do
		out[locale] = value
	end
	return out
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
--- @param roots table Array of absolute directory paths, in precedence order.
--- @param io_fns table { list_dirs, list_files, read_file } — injected I/O.
--- @return table Array of { id, name, dir, descriptions, toml_files }.
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

					local toml_files = {}
					for _, path in ipairs(list_files(dir .. "/" .. HOTSTRINGS_SUBDIR) or {}) do
						local stem = path:match("([^/\\]+)%.toml$")
						if stem then
							toml_files[#toml_files + 1] = { path = path, stem = stem }
						end
					end

					-- Sorted so the menu order is the same on every machine. A
					-- directory listing is not ordered by any contract, and a menu
					-- whose rows move between launches is one nobody learns.
					table.sort(toml_files, function(a, b) return a.stem < b.stem end)

					if not by_id[id] then order[#order + 1] = id end
					by_id[id] = {
						id           = id,
						name         = M.parse_name(manifest_text) or id,
						dir          = dir,
						descriptions = M.parse_descriptions(manifest_text),
						toml_files   = toml_files,
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

return M
