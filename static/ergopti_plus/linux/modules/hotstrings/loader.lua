--- static/ergopti_plus/linux/modules/hotstrings/loader.lua

--- ==============================================================================
--- MODULE: Hotstring TOML Loader (Linux)
--- DESCRIPTION:
--- Loads hotstring definitions from TOML files that follow the schema defined
--- in static/ergopti_plus/shared/hotstrings/schema.md. Implements a lightweight
--- line-by-line parser — no external TOML library is required — capable of
--- handling the [[entry]] array format used throughout shared/hotstrings/.
---
--- FEATURES & RATIONALE:
--- 1. Zero-dependency: the parser handles the restricted subset of TOML actually
---    used in the hotstring data files, avoiding a vendored library.
--- 2. Flat output: returns a plain array of mapping tables compatible with
---    engine:load_mappings(), regardless of source file or category.
--- 3. Graceful errors: a malformed file logs a warning and is skipped; valid
---    entries from other files are still returned.
--- 4. Flag normalisation: the TOML "flags" array is converted to the boolean
---    fields (is_word, is_case_sensitive) expected by the engine.
--- ==============================================================================

local M = {}


-- =========================================
-- =========================================
-- ======= 1/ Logger Shim ==================
-- =========================================
-- =========================================

local Logger = require("logger.shim")

local LOG = "modules.hotstrings.loader"


-- =========================================
-- =========================================
-- ======= 2/ TOML Line Parser =============
-- =========================================
-- =========================================

--- Strips leading/trailing whitespace from a string.
--- @param s string
--- @return string
local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

--- Unquotes a TOML string value (double or single quoted).
--- Returns nil if the value is not a quoted string.
--- @param s string The raw value token (e.g. `"hello"` or `'world'`).
--- @return string|nil
local function unquote(s)
	s = trim(s)
	-- Double-quoted string — handle basic TOML escapes.
	local dq = s:match('^"(.*)"$')
	if dq then
		-- Unescape common sequences: \n \t \\ \"
		dq = dq:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\\\"', '"'):gsub("\\\\", "\\")
		return dq
	end
	-- Single-quoted string — no escape processing.
	local sq = s:match("^'(.*)'$")
	if sq then return sq end
	return nil
end

--- Parses a TOML inline array of strings: ["a", "b", "c"].
--- Returns a plain Lua table (array) of string values.
--- @param s string The raw array token, e.g. `["word", "case_sensitive"]`.
--- @return table
local function parse_string_array(s)
	s = trim(s)
	-- Empty array.
	if s == "[]" then return {} end
	-- Strip brackets.
	local inner = s:match("^%[(.*)%]$")
	if not inner then return {} end
	local result = {}
	-- Split on commas; each element is a quoted string.
	for element in (inner .. ","):gmatch("([^,]+),") do
		local val = unquote(trim(element))
		if val then result[#result + 1] = val end
	end
	return result
end

--- Parses a single TOML file and returns an array of raw entry tables.
--- Each raw entry has string fields: trigger, replacement, flags (table).
--- @param path string Absolute path to the .toml file.
--- @return table  Array of raw entry tables (may be empty on error).
local function parse_toml_file(path)
	Logger.trace(LOG, "Parsing '%s'…", path)
	local fh, err = io.open(path, "r")
	if not fh then
		Logger.warn(LOG, "parse_toml_file(): cannot open '%s' — %s", path, tostring(err))
		return {}
	end

	local entries = {}
	local current = nil  -- the [[entry]] block being assembled

	for line in fh:lines() do
		line = trim(line)

		-- Skip blank lines and comments.
		if line == "" or line:sub(1, 1) == "#" then
			goto next_line
		end

		-- [[entry]] header — flush previous block, start a new one.
		if line == "[[entry]]" then
			if current then entries[#entries + 1] = current end
			current = { flags = {} }
			goto next_line
		end

		-- Skip non-entry table headers (e.g. [category]).
		if line:match("^%[") then
			goto next_line
		end

		-- Key = value pairs inside an [[entry]] block.
		if current then
			local key, val = line:match("^([%w_]+)%s*=%s*(.+)$")
			if key and val then
				if key == "trigger" or key == "replacement" then
					current[key] = unquote(val) or trim(val)
				elseif key == "flags" then
					current.flags = parse_string_array(val)
				end
			end
		end

		::next_line::
	end

	-- Flush the last block.
	if current then entries[#entries + 1] = current end
	fh:close()

	Logger.done(LOG, "Parsed '%s': %d entry(ies).", path, #entries)
	return entries
end


-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
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
		local ok, entries = pcall(parse_toml_file, path)
		if not ok then
			Logger.warn(LOG, "load(): error in '%s' — %s", tostring(path), tostring(entries))
		else
			-- Derive the group name from the parent directory.
			local group = path:match("[/\\]([^/\\]+)[/\\][^/\\]+%.toml$") or "unknown"

			for _, entry in ipairs(entries) do
				if type(entry.trigger) == "string" and type(entry.replacement) == "string" then
					-- Normalise flags array into boolean fields.
					local flags_set = {}
					for _, flag in ipairs(entry.flags or {}) do
						flags_set[flag] = true
					end
					mappings[#mappings + 1] = {
						trigger           = entry.trigger,
						replacement       = entry.replacement,
						is_word           = flags_set["word"]           == true,
						is_case_sensitive = flags_set["case_sensitive"] == true,
						group             = group,
					}
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
