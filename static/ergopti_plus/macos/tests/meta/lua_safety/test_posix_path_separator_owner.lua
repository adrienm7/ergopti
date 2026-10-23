--- tests/meta/lua_safety/test_posix_path_separator_owner.lua

--- ==============================================================================
--- MODULE: POSIX Path Separator Owner Guard
--- DESCRIPTION:
--- Class-wide guard: the macOS driver, the Linux driver and the shared Lua they
--- both load split, join and trim real POSIX paths only through the shared
--- owner _shared/lua/native_path.lua.
---
--- ROOT CAUSE ENCODED:
--- A backslash is an ordinary filename byte on macOS and Linux, but about 85
--- macOS sites, 25 shared ones and 8 Linux ones spelled the separator class as
--- [/\\], [^/\\] or [\\/]. Above a folder named "back\slash" the bootstrap walk
--- stepped into "back"; a group or file name holding a backslash lost its first
--- half; a configuration folder ending in a backslash lost that byte. The owner
--- applies the host rule once (backslash separates only on a Windows host,
--- where the headless suite runs). A per-site fix does not hold, so every new
--- class spelling outside the owner fails here unless it is listed below with a
--- reason (posix-backslash-separator-owner). The shared Lua is read here because
--- macOS loads it: a shared site cuts a macOS path exactly like a driver site.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Each tree is read except its test harness, which runs on a Windows checkout
-- and parses its own Windows paths. Floors: a walk that reads nothing, or an
-- owner nobody calls, must not pass.
local TREES = {
	{ dir = "macos", excluded = "macos/tests/", min_files = 300, min_owner_calls = 60 },
	{ dir = "_shared/lua", excluded = "_shared/lua/test/", min_files = 80, min_owner_calls = 15 },
	{ dir = "linux", excluded = "linux/tests/", min_files = 150, min_owner_calls = 6 },
}

-- The owner itself spells the classes it hands out.
local OWNER = "_shared/lua/native_path.lua"

-- Genuine Windows-path parsers, which must see both separators on every host:
-- path = { count, reason }.
local WINDOWS_PATH_PARSERS = {
	["_shared/lua/program_parameter.lua"] = { 3, "validates a drive or UNC executable typed for the AHK driver" },
	["_shared/lua/diagnostics/redact.lua"] = { 1, "redacts the home folder in both slash spellings a log can hold" },
	["_shared/lua/open_target/init.lua"] = { 3, "classifies a drive, UNC or %VARIABLE% target as Windows-only" },
	["_shared/lua/updater/config_backup.lua"] = { 1,
		"refuses a shipped backup name that would not be one component on Windows" },
}

-- Unconverted sites, each owned by a concurrent change and converted next:
-- path = { count, reason }. The goal is an empty table.
local BASELINE = {
	["_shared/lua/config_migrate.lua"] = { 2, "config migration owner: split the backup path through NativePath" },
	["_shared/lua/config_unused_keys.lua"] = { 2, "unused-key owner: split the backup path through NativePath" },
	["_shared/lua/llm/profile_selector.lua"] = { 2, "LLM owner: resolve the profiles file through NativePath" },
	["linux/modules/keystats/sqlite_writer.lua"] = { 1, "keystats owner: take the database folder through NativePath" },
}

-- The separator class in each spelling, as raw Lua source text. The last two
-- are the escaped form "[\\\\/]" that the first four do not contain.
local SPELLINGS = { "[/\\\\", "[^/\\\\", "[\\\\/", "[^\\\\/", "[\\\\\\\\/", "[^\\\\\\\\/" }





-- ====================================
-- ====================================
-- ======= 1/ Source Collection =======
-- ====================================
-- ====================================

--- Recursively lists every .lua file under a driver subtree.
--- @param dir string Absolute directory to walk.
--- @param out table Accumulator.
local function collect(dir, out)
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local attributes = lfs.attributes(dir)
		if not attributes or attributes.mode ~= "directory" then return end
		local function walk(path)
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					local full = path .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then walk(full)
					elseif entry:match("%.lua$") then out[#out + 1] = full end
				end
			end
		end
		walk(dir)
		return
	end
	local windows = package.config:sub(1, 1) == "\\"
	local cmd = windows
		and ('cmd /c dir /b /s /a-d "' .. dir:gsub("/", "\\") .. '\\*.lua" 2>nul')
		or ("find '" .. dir .. "' -type f -name '*.lua' 2>/dev/null")
	local pipe = io.popen(cmd)
	if not pipe then return end
	for line in pipe:lines() do
		local t = line:gsub("%s+$", ""):gsub("\\", "/")
		if t:match("%.lua$") then out[#out + 1] = t end
	end
	pipe:close()
end

--- Counts plain occurrences of needle in text.
--- @param text string
--- @param needle string
--- @return integer
local function count(text, needle)
	local n, from = 0, 1
	while true do
		local at = text:find(needle, from, true)
		if not at then return n end
		n, from = n + 1, at + #needle
	end
end





-- ==================================================
-- ==================================================
-- ======= 2/ Every Separator Goes Through Owner ====
-- ==================================================
-- ==================================================

--- Reads every production source of one tree.
--- @param base string The ergopti_plus folder, with a trailing slash.
--- @param tree table One TREES entry.
--- @return table sources Array of { rel, text }, rel relative to base.
local function tree_sources(base, tree)
	local all, sources = {}, {}
	collect(base .. tree.dir, all)
	for _, path in ipairs(all) do
		local rel = path:sub(#base + 1)
		assert(path:sub(1, #base) == base, "the walk left the ergopti_plus folder: " .. path)
		if rel:sub(1, #tree.excluded) ~= tree.excluded and rel ~= OWNER then
			local handle = assert(io.open(path, "rb"), "unreadable driver source " .. path)
			sources[#sources + 1] = { rel = rel, text = handle:read("*a") }
			handle:close()
		end
	end
	return sources
end

helpers.describe("POSIX paths split only through the shared owner (posix-backslash-separator-owner)", function()
	helpers.it("posix-backslash-separator-owner: no [/\\] separator class outside native_path.lua", function()
		local base = (helpers.driver_root():gsub("\\", "/"):gsub("/$", ""):gsub("[^/]+$", ""))
		local offenders, seen = {}, {}
		for _, tree in ipairs(TREES) do
			local sources = tree_sources(base, tree)
			helpers.assert_true(#sources >= tree.min_files, string.format(
				"the %s walk found %d .lua files (floor %d): the guard would be vacuous",
				tree.dir, #sources, tree.min_files))
			local owner_calls = 0
			for _, source in ipairs(sources) do
				local found = 0
				for _, spelling in ipairs(SPELLINGS) do found = found + count(source.text, spelling) end
				owner_calls = owner_calls + count(source.text, "NativePath.") + count(source.text, 'require("native_path").')
				local allowed = WINDOWS_PATH_PARSERS[source.rel] or BASELINE[source.rel]
				seen[source.rel] = true
				if found ~= (allowed and allowed[1] or 0) then
					offenders[#offenders + 1] = string.format("%s (%d, allowed %d)", source.rel, found,
						allowed and allowed[1] or 0)
				end
			end
			helpers.assert_true(owner_calls >= tree.min_owner_calls, string.format(
				"only %d native path owner calls found in %s (floor %d): the scan is not reading the converted sites",
				owner_calls, tree.dir, tree.min_owner_calls))
		end
		for _, listed in ipairs({ WINDOWS_PATH_PARSERS, BASELINE }) do
			for rel in pairs(listed) do
				if not seen[rel] then offenders[#offenders + 1] = rel .. " (listed, but no such source)" end
			end
		end
		table.sort(offenders)
		helpers.assert_true(#offenders == 0, "separator classes outside _shared/lua/native_path.lua treat a "
			.. "backslash as a separator although it is a macOS and Linux filename byte. Use the owner, or "
			.. "list a genuine Windows-path parser in WINDOWS_PATH_PARSERS: " .. table.concat(offenders, ", "))
	end)
end)
