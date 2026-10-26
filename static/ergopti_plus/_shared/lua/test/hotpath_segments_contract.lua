--- _shared/lua/test/hotpath_segments_contract.lua

--- ==============================================================================
--- MODULE: Hot-path Segment Inventory Contract
--- DESCRIPTION:
--- Instrumentation is the one kind of code whose absence is invisible: a
--- missing assertion fails a test, a missing segment yields a profile that
--- looks clean because nothing measured the slow part. This contract holds a
--- Lua driver to the shared inventory (hotpath_segments.lua) the way
--- tools/test/test-hotpath-segments-declared.cjs holds the Windows driver to its
--- own: every declared segment is still emitted, every emitted segment is
--- declared, and the parse that proves it cannot silently match nothing.
---
--- FEATURES & RATIONALE:
--- 1. Same checks on both Lua drivers, so macOS and Linux cannot drift apart.
--- 2. A declared entry carries its reason; a failure quotes it, so a segment
---    deleted in a refactor fails with why it was added, not with a diff.
--- 3. Comment lines are ignored, so documentation can show a call without
---    counting as an emission.
--- ==============================================================================

local M = {}
local Inventory = require("hotpath_segments")

-- The parse must find at least this many call sites, or a pattern that stopped
-- matching would report nothing and pass over nothing.
local MIN_PARSED_SITES = 4
local SKIPPED_DIRECTORIES = { tests = true, vendor = true, _generated = true, native = true }

--- Lists every production .lua file under a driver root, through lfs when it is
--- installed and the platform's directory listing otherwise.
--- @param root string Absolute driver root.
--- @return table paths Sorted, forward slashes.
local function production_files(root)
	local found = {}
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(dir)
			for entry in lfs.dir(dir) do
				if entry ~= "." and entry ~= ".." then
					local full = dir .. "/" .. entry
					local mode = lfs.attributes(full, "mode")
					if mode == "directory" then
						if not SKIPPED_DIRECTORIES[entry] then walk(full) end
					elseif entry:match("%.lua$") then
						found[#found + 1] = full
					end
				end
			end
		end
		walk(root)
	else
		local windows = package.config:sub(1, 1) == "\\"
		local command = windows and string.format('cmd /c dir /b /s /a-d "%s"', root:gsub("/", "\\"))
			or string.format("find '%s' -type f -name '*.lua'", root)
		local pipe = assert(io.popen(command))
		for line in pipe:lines() do
			line = line:gsub("\\", "/")
			local skipped = false
			for directory in pairs(SKIPPED_DIRECTORIES) do
				if line:find("/" .. directory .. "/", #root, true) then skipped = true end
			end
			if not skipped and line:match("%.lua$") then found[#found + 1] = line end
		end
		pipe:close()
	end
	table.sort(found)
	return found
end

--- Collects the segment names a driver emits, with the file of the first emission.
--- @param root string Absolute driver root.
--- @param call_pattern string Lua pattern with one capture: the segment name.
--- @return table emitted name -> relative path
--- @return number sites Call sites parsed.
local function emitted_segments(root, call_pattern)
	local emitted, sites = {}, 0
	for _, path in ipairs(production_files(root)) do
		local handle = assert(io.open(path, "rb"))
		local source = handle:read("*a")
		handle:close()
		for line in source:gmatch("[^\n]+") do
			if not line:match("^%s*%-%-") then
				for name in line:gmatch(call_pattern) do
					sites = sites + 1
					emitted[name] = emitted[name] or path:sub(#root + 2)
				end
			end
		end
	end
	return emitted, sites
end

--- Registers the inventory tests of one driver.
--- @param helpers table The runner's test helpers.
--- @param options table { driver = "macos"|"linux", root = absolute driver root,
---   call_pattern = pattern capturing the segment name of one emission,
---   timed_only = optional set of emitted names that are deliberately not
---   segments (a timed wait or a background build) }.
function M.register(helpers, options)
	local declared = Inventory.for_driver(options.driver)
	local timed_only = options.timed_only or {}
	assert(type(options.default_slow_ms) == "number", "the contract needs the registry's hotpath_slow_ms")
	local emitted, sites = emitted_segments(options.root, options.call_pattern)

	helpers.describe("hot-path segment inventory: " .. options.driver, function()
		helpers.it("parses the driver's emissions", function()
			helpers.assert_true(sites >= MIN_PARSED_SITES, "parsed " .. sites
				.. " emission(s); the pattern drifted and the checks below would pass over nothing")
		end)

		helpers.it("still emits every declared segment", function()
			for name, segment in pairs(declared) do
				helpers.assert_true(emitted[name] ~= nil, "the '" .. name .. "' segment is gone. It measured: "
					.. segment.why .. ". A missing segment leaves a profile that looks clean.")
			end
		end)

		helpers.it("declares every segment it emits", function()
			for name, where in pairs(emitted) do
				helpers.assert_true(declared[name] ~= nil or timed_only[name] == true, "'" .. name .. "' (" .. where
					.. ") is emitted but not in _shared/lua/hotpath_segments.lua. Declare it with the hot path it covers.")
			end
		end)

		helpers.it("keeps timed-only names out of the inventory", function()
			for name in pairs(timed_only) do
				helpers.assert_true(declared[name] == nil, "'" .. name
					.. "' is both timed-only and a declared segment; pick one")
			end
		end)

		helpers.it("gives every declared segment a threshold and a reason", function()
			for name, segment in pairs(declared) do
				helpers.assert_true(Inventory.threshold_ms(name, options.default_slow_ms) > 0, name .. " needs a positive threshold")
				helpers.assert_true(#segment.why > 0, name .. " needs a reason")
			end
		end)

		helpers.it("slows a segment from the 5 ms the three drivers share", function()
			for name in pairs(declared) do
				helpers.assert_true(Inventory.threshold_ms(name, options.default_slow_ms) <= 5,
					name .. " must be reported slow from 5 ms at the latest, as on Windows")
			end
			helpers.assert_eq(options.default_slow_ms, 5, "the registry's [logger] hotpath_slow_ms")
		end)

		helpers.it("rate-limits the slow-segment line per segment, first occurrence always admitted", function()
			local window = Inventory.LOG_WINDOW_MS
			helpers.assert_true(window > 0, "the log window needs a positive length")
			local admit = Inventory.new_slow_gate()
			local ok, skipped = admit("a", 1000)
			helpers.assert_true(ok and skipped == 0, "the first occurrence is logged")
			helpers.assert_eq((admit("a", 1000 + window - 1)), false, "inside the window")
			helpers.assert_eq((admit("a", 1000 + window - 1)), false, "inside the window, again")
			helpers.assert_true((admit("b", 1001)), "another segment has its own window")
			ok, skipped = admit("a", 1000 + window)
			helpers.assert_true(ok, "logged again once the window has passed")
			helpers.assert_eq(skipped, 2, "the line reports the repeats it stands for")
			ok, skipped = admit("a", 1000 + 2 * window)
			helpers.assert_true(ok and skipped == 0, "nothing withheld, nothing reported")
		end)
	end)
end

return M
