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
--- 2. Flat output: returns a plain array of mapping tables compatible with
---    engine:load_mappings(), regardless of source file or category.
--- 3. Graceful errors: a malformed file logs a warning and is skipped; valid
---    entries from other files are still returned.
--- 4. API-stable: the returned mapping shape (trigger, replacement, is_word,
---    is_case_sensitive, group) is identical to the previous implementation.
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


-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- Loads hotstring definitions from a list of TOML file paths.
--- Returns a flat array of mapping tables suitable for engine:load_mappings().
--- Each mapping has:
---   trigger           string
---   replacement       string
---   is_word           boolean
---   is_case_sensitive boolean
---   group             string  (category inferred from directory name)
--- @param paths table Array of absolute TOML file paths.
--- @return table  Flat array of mapping tables.
function M.load(paths)
	Logger.start(LOG, "Loading hotstrings from %d file(s)…", #paths)
	if type(paths) ~= "table" then
		Logger.error(LOG, "load(): expected table of paths, got %s.", type(paths))
		return {}
	end

	local mappings = {}

	for _, path in ipairs(paths) do
		local ok, data = pcall(Reader.parse, path)
		if not ok then
			Logger.warn(LOG, "load(): error in '%s' — %s", tostring(path), tostring(data))
		else
			-- Derive the group name from the parent directory.
			local group = path:match("[/\\]([^/\\]+)[/\\][^/\\]+%.toml$") or "unknown"
			-- File-level priority override, the third rung of the cascade.
			local file_priority = type(data.meta) == "table" and type(data.meta.priority) == "number"
				and data.meta.priority or nil
			local section_priorities = (type(data.meta) == "table"
				and type(data.meta.section_priorities) == "table") and data.meta.section_priorities or {}

			for _, sec_name in ipairs(data.sections_order or {}) do
				local section = data.sections[sec_name]
				if section and type(section.entries) == "table" then
					for _, entry in ipairs(section.entries) do
						if type(entry.trigger) == "string" and type(entry.output) == "string" then
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
							}
						end
					end
				end
			end
		end
	end

	Logger.success(LOG, "Loaded %d mapping(s) total.", #mappings)
	return mappings
end

--- Scans a directory tree and returns all .toml file paths found.
--- Useful for pointing the loader at ~/.config/ergopti/hotstrings/.
--- @param dir string Absolute path to the root directory to scan.
--- @return table  Array of absolute .toml file paths.
function M.find_toml_files(dir)
	Logger.trace(LOG, "Scanning '%s' for .toml files…", dir)
	local result = {}
	local ok, err = pcall(function()
		-- Use the POSIX find command available on any Linux system.
		local cmd  = string.format("find '%s' -type f -name '*.toml' 2>/dev/null", dir:gsub("'", "'\\''"))
		local pipe = io.popen(cmd)
		if not pipe then return end
		for line in pipe:lines() do
			local p = line:match("^%s*(.-)%s*$")
			if p and p ~= "" then result[#result + 1] = p end
		end
		pipe:close()
	end)
	if not ok then
		Logger.warn(LOG, "find_toml_files('%s'): scan failed — %s", dir, tostring(err))
	end
	Logger.done(LOG, "Found %d .toml file(s) under '%s'.", #result, dir)
	return result
end

return M
