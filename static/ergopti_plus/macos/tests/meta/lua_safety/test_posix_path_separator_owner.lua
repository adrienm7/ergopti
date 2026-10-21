--- tests/meta/lua_safety/test_posix_path_separator_owner.lua

--- ==============================================================================
--- MODULE: POSIX Path Separator Owner Guard
--- DESCRIPTION:
--- Class-wide guard: driver code splits, joins and trims real macOS paths only
--- through the shared owner _shared/lua/native_path.lua.
---
--- ROOT CAUSE ENCODED:
--- A backslash is an ordinary filename byte on macOS, but about 85 sites in 30
--- files spelled the separator class as [/\\], [^/\\] or [\\/]. Above a folder
--- named "back\slash" the bootstrap walk stepped into "back"; a group or file
--- name holding a backslash lost its first half. The owner applies the host
--- rule once (backslash separates only on a Windows host, where the headless
--- suite runs). A per-site fix does not hold on this driver, so every new class
--- spelling outside the owner fails here unless it is listed below with a reason
--- (posix-backslash-separator-owner).
--- ==============================================================================

local helpers = require("tests.helpers")

-- The whole driver tree is read except tests/: the harness itself runs on a
-- Windows checkout and parses its own Windows paths.
local EXCLUDED_PREFIX = "tests/"

-- Justified remaining spellings: path = { count, reason }. Empty while every
-- macOS filesystem path goes through the owner.
local BASELINE = {}

-- Floors: a walk that reads nothing, or an owner nobody calls, must not pass.
local MIN_FILES = 300
local MIN_OWNER_CALLS = 60

-- The separator class in each spelling, as raw Lua source text.
local SPELLINGS = { "[/\\\\", "[^/\\\\", "[\\\\/", "[^\\\\/" }





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

helpers.describe("macOS paths split only through the shared owner (posix-backslash-separator-owner)", function()
	helpers.it("posix-backslash-separator-owner: no [/\\] separator class outside native_path.lua", function()
		local root = helpers.driver_root()
		local files = {}
		local all = {}
		collect(root:gsub("/$", ""), all)
		for _, path in ipairs(all) do
			if path:gsub("^.*/macos/", ""):sub(1, #EXCLUDED_PREFIX) ~= EXCLUDED_PREFIX then files[#files + 1] = path end
		end
		helpers.assert_true(#files >= MIN_FILES, string.format(
			"the source walk found %d driver .lua files (floor %d): the guard would be vacuous", #files, MIN_FILES))

		local offenders, owner_calls, seen = {}, 0, {}
		for _, path in ipairs(files) do
			local handle = assert(io.open(path, "rb"), "unreadable driver source " .. path)
			local source = handle:read("*a"); handle:close()
			local rel = path:gsub("^.*/macos/", "")
			local found = 0
			for _, spelling in ipairs(SPELLINGS) do found = found + count(source, spelling) end
			owner_calls = owner_calls + count(source, "NativePath.") + count(source, 'require("native_path").')
			local allowed = BASELINE[rel]
			seen[rel] = true
			if found ~= (allowed and allowed[1] or 0) then
				offenders[#offenders + 1] = string.format("%s (%d, baseline %d)", rel, found, allowed and allowed[1] or 0)
			end
		end
		for rel in pairs(BASELINE) do
			if not seen[rel] then offenders[#offenders + 1] = rel .. " (baseline names a missing file)" end
		end
		table.sort(offenders)
		helpers.assert_true(#offenders == 0, "separator classes outside _shared/lua/native_path.lua treat a "
			.. "backslash as a separator although it is a macOS filename byte. Use the owner, or list a "
			.. "justified Windows-path parser in BASELINE: " .. table.concat(offenders, ", "))
		helpers.assert_true(owner_calls >= MIN_OWNER_CALLS, string.format(
			"only %d native path owner calls found (floor %d): the scan is not reading the converted sites",
			owner_calls, MIN_OWNER_CALLS))
	end)
end)
