--- modules/hotstrings/loader.lua

--- ==============================================================================
--- MODULE: Hotstring TOML Loader (Linux)
--- DESCRIPTION:
--- Loads hotstring definitions from TOML files that follow the schema defined
--- in static/ergopti_plus/_shared/modules/hotstrings/schema.md. Delegates all
--- TOML parsing to the shared toml_codec.reader module so the two
--- implementations cannot diverge.
---
--- FEATURES & RATIONALE:
--- 1. Single parser: parsing is handled by toml_codec.reader (shared across all
---    Lua drivers), which soft-resolves lib.logger so it loads on this runtime.
--- 2. The category is the FILE STEM, not the parent directory. This is the fix
---    for a defect that made the whole category menu wrong: the five shared packs
---    live flat in _shared/modules/hotstrings/ and install.sh copies them flat
---    into ~/.config/ergopti/hotstrings/, so deriving the group from the
---    directory collapsed magickey, autocorrection, rolls, sfbsreduction and
---    distancesreduction into ONE group literally named "hotstrings". Nothing
---    could match the manifest's category ids, so the menu rendered three
---    "no group loaded" stubs and the single real group fell into the personal
---    bucket by exclusion.
--- 3. Metadata comes back with the mappings. [_meta] carries the localised
---    description in 21 locales, the section order, the delay and the tooltip
---    colour, and every one of them was being thrown away — so the menu could
---    only ever show a raw file stem, unordered and untranslated.
--- 4. Underscore-prefixed files are skipped. _index.toml is the menu manifest
---    for this directory, not a category, and loading it as one produced a group
---    called "_index" with no entries.
--- 5. Graceful errors: a malformed file logs a warning and is skipped; valid
---    entries from other files are still returned.
--- ==============================================================================

local M = {}


-- =========================================
-- =========================================
-- ======= 1/ Dependencies =================
-- =========================================
-- =========================================

local Logger = require("logger.shim")
local Reader = require("toml_codec.reader")
local Priority = require("hotstring_priority")
local Paths  = require("infra.paths")
local Shell  = require("adapters.shell_runner")

local LOG = "modules.hotstrings.loader"

--- Canonical collision tiers, read once from the shared JSON. Kept as a lazily
--- resolved local rather than a require-time read so a driver that never loads a
--- hotstring never touches the filesystem for it.
local _tiers = nil

--- Loads _shared/modules/hotstrings/priority.json, falling back to the module's
--- own defaults. A missing file is logged, never silently absorbed: the tiers
--- decide which of two colliding hotstrings the user actually gets.
--- @return table The tier table.
local function tiers()
	if _tiers then return _tiers end
	_tiers = Priority.DEFAULT_TIERS
	local ok, result = pcall(function()
		local path = Paths.shared("modules/hotstrings/priority.json")
		local fh   = io.open(path, "r")
		if not fh then return nil end
		local raw = fh:read("*a")
		fh:close()
		return require("json").decode(raw)
	end)
	if not ok or type(result) ~= "table" then
		Logger.warn(LOG, "priority.json unreadable — keeping the default tiers (%s).", tostring(result))
		return _tiers
	end
	local merged = {}
	for key, fallback in pairs(Priority.DEFAULT_TIERS) do
		merged[key] = type(result[key]) == "number" and result[key] or fallback
	end
	_tiers = merged
	Logger.debug(LOG, "Priority tiers: common=%d, package=%d, personal=%d.",
		merged.common, merged.package, merged.personal)
	return _tiers
end


--- The category a TOML file belongs to: its file STEM.
---
--- Not the parent directory. The five shared packs live flat beside each other
--- and are installed flat, so the directory is the same for all of them and the
--- category the user sees would be the folder's name.
--- @param path string Absolute path to a .toml file.
--- @return string
local function category_of(path)
	local stem = path:match("([^/\\]+)%.toml$")
	return stem or "unknown"
end

--- Counts the entries of a non-array table.
--- @param t table
--- @return integer
local function count_categories(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end




-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- Loads hotstring definitions from a list of TOML file paths.
--- Returns a flat array of mapping tables suitable for engine:load_mappings().
--- @param paths table Array of absolute TOML file paths.
--- @return table  Flat array of mapping tables.
function M.load(paths)
	return M.load_catalogue(paths).mappings
end

--- Loads hotstring definitions AND the metadata the menu needs to describe them.
---
--- One pass, because the two answers come from the same parse: splitting them
--- would mean reading a 300 KB magickey.toml twice to learn its name.
--- @param paths table Array of absolute TOML file paths.
--- @return table { mappings = array, categories = { [stem] = category } }
--- where a category is
---   { id, path, description = {locale → text}, delay, show_tooltip, color,
---     sections_order = array, sections = { [name] = { count } }, count }
function M.load_catalogue(paths)
	Logger.start(LOG, "Loading hotstrings from %d file(s)…", type(paths) == "table" and #paths or 0)
	if type(paths) ~= "table" then
		Logger.error(LOG, "load_catalogue(): expected table of paths, got %s.", type(paths))
		return { mappings = {}, categories = {} }
	end

	local mappings = {}
	local categories = {}

	for _, source in ipairs(paths) do
		-- A source is a path, or a table carrying a path and the category key it
		-- must occupy. Extension packs need the second form: two extensions may
		-- each ship `rolls.toml`, and keying those by stem would silently make one
		-- replace the other — and replace the bundled category of that name too.
		local path = type(source) == "table" and source.path or source
		local forced_group = type(source) == "table" and source.category or nil
		local extension = type(source) == "table" and source.extension or nil
		local ok, data = pcall(Reader.parse, path)
		if not ok then
			Logger.warn(LOG, "load(): error in '%s' — %s", tostring(path), tostring(data))
		else
			local group = forced_group or category_of(path)
			local meta = type(data.meta) == "table" and data.meta or {}

			-- File-level priority override, the third rung of the cascade.
			local file_priority = type(meta.priority) == "number" and meta.priority or nil
			local section_priorities = type(meta.section_priorities) == "table"
				and meta.section_priorities or {}

			local category = categories[group] or {
				id             = group,
				path           = path,
				description    = type(meta.description) == "table" and meta.description or {},
				delay          = tonumber(meta.delay),
				show_tooltip   = meta.show_tooltip,
				color          = meta.color,
				-- The file-level priority, kept rather than only folded into each
				-- entry: the settings window shows it as the category's default, and
				-- reading it back from an entry would report whatever the last one
				-- resolved to.
				priority       = file_priority,
				-- Set only for a pack that came from an extension. The menu groups
				-- those under their own heading and labels them with the extension's
				-- name, which a bare file stem like "demo-phrases" cannot convey.
				extension      = extension,
				sections_order = {},
				sections       = {},
				count          = 0,
			}
			categories[group] = category

			-- The declared order, minus the "-" separators the menu renders itself.
			for _, name in ipairs(meta.sections_order or data.sections_order or {}) do
				if name ~= "-" then
					category.sections_order[#category.sections_order + 1] = name
				end
			end

			for _, sec_name in ipairs(data.sections_order or {}) do
				local section = data.sections[sec_name]
				if section and type(section.entries) == "table" then
					local entry_count = 0
					for _, entry in ipairs(section.entries) do
						if type(entry.trigger) == "string" and type(entry.output) == "string" then
							entry_count = entry_count + 1
							mappings[#mappings + 1] = {
								trigger           = entry.trigger,
								replacement       = entry.output,
								is_word           = entry.is_word           or false,
								is_case_sensitive = entry.is_case_sensitive or false,
								-- The three flags the loader used to drop on the floor. Without
								-- them every entry behaved as auto_expand + non-final +
								-- case-folding, so "ya" fired inside "yaourt", nothing could
								-- chain, and the 1 300 strict-case magickey entries matched
								-- any casing — autocorrecting the very input they exist to
								-- leave alone.
								auto_expand       = entry.auto_expand       or false,
								final_result      = entry.final_result      or false,
								is_case_sensitive_strict = entry.is_case_sensitive_strict or false,
								-- Resolved here rather than in the engine because only the
								-- loader knows which file and section an entry came from,
								-- which is what the lower rungs of the cascade are. An
								-- unresolved priority defaults to 0 in the engine, and 0
								-- would let a deliberately low individual priority beat an
								-- undeclared personal hotstring.
								priority          = Priority.resolve(
									entry.priority, section_priorities[sec_name], file_priority, group, tiers()),
								group             = group,
								section           = sec_name,
							}
						end
					end
					-- The section's own TOML metadata, not just how many entries it
					-- holds. `[_meta.section_delays]` is parsed by the shared reader
					-- and was dropped here, so rung 3 of the five-rung cascade — the
					-- section's declared delay — resolved to nil on this driver and a
					-- pack shipping per-section timings had them silently ignored.
					category.sections[sec_name] = {
						count    = entry_count,
						delay    = tonumber((meta.section_delays or {})[sec_name]),
						priority = section_priorities[sec_name],
					}
					category.count = category.count + entry_count
				end
			end
		end
	end

	Logger.success(LOG, "Loaded %d mapping(s) across %d categor(ies).",
		#mappings, count_categories(categories))
	return { mappings = mappings, categories = categories }
end

--- Whether a discovered .toml file is a hotstring pack.
---
--- Underscore-prefixed files in that directory are not categories: _index.toml
--- is the menu index for the directory and defaults.toml holds the resolver's
--- fallback values. Loading either as a pack produced an empty group sitting in
--- the menu beside the real ones.
---
--- A pure predicate rather than an inline condition inside the scan, because the
--- scan shells out to `find` and cannot run on the interpreter this repo is
--- developed on — the rule would otherwise be unassertable outside CI.
--- @param path string A file path.
--- @return boolean
function M.is_pack_file(path)
	if type(path) ~= "string" or path == "" then return false end
	local name = path:match("([^/\\]+)$")
	if not name or not name:match("%.toml$") then return false end
	return name:sub(1, 1) ~= "_" and name ~= "defaults.toml"
end

--- Scans a directory tree and returns every hotstring pack in it.
--- Useful for pointing the loader at ~/.config/ergopti/hotstrings/.
--- @param dir string Absolute path to the root directory to scan.
--- @return table  Array of absolute .toml file paths.
function M.find_toml_files(dir)
	if type(dir) ~= "string" or dir == "" then return {} end
	Logger.trace(LOG, "Scanning '%s' for hotstring packs…", dir)

	-- Through the shell adapter rather than a hand-quoted io.popen: this is a
	-- path that can come from a config file, and quoting re-derived at a call
	-- site is quoting that is eventually wrong.
	local result = {}
	local out = Shell.exec(string.format(
		"find %s -type f -name '*.toml' 2>/dev/null", Shell.quote(dir)))
	for line in out:gmatch("[^\r\n]+") do
		local path = line:match("^%s*(.-)%s*$")
		if M.is_pack_file(path) then result[#result + 1] = path end
	end

	Logger.done(LOG, "Found %d pack(s) under '%s'.", #result, dir)
	return result
end

--- Lists the immediate subdirectories of a directory.
---
--- Extensions are one directory each, so discovery is a listing at depth 1 —
--- `-maxdepth 1 -mindepth 1` rather than a recursive walk, which would descend
--- into every `hotstrings/` and `shortcuts/` folder and report those as
--- extensions too.
--- @param dir string Absolute path.
--- @return table Array of absolute directory paths.
function M.list_subdirs(dir)
	if type(dir) ~= "string" or dir == "" then return {} end
	local result = {}
	local out = Shell.exec(string.format(
		"find %s -mindepth 1 -maxdepth 1 -type d 2>/dev/null", Shell.quote(dir)))
	for line in out:gmatch("[^\r\n]+") do
		local path = line:match("^%s*(.-)%s*$")
		if path ~= "" then result[#result + 1] = path end
	end
	return result
end

--- Reads a whole file, or nil when it is absent.
---
--- The extension scanner needs manifests, and an absent manifest is the ordinary
--- case rather than an error — an extension without one is named after its
--- folder.
--- @param path string Absolute path.
--- @return string|nil
function M.read_file(path)
	if type(path) ~= "string" or path == "" then return nil end
	local fh = io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

return M
