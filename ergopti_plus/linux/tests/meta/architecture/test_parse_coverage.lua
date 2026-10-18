--- static/ergopti_plus/linux/tests/meta/architecture/test_parse_coverage.lua

--- ==============================================================================
--- MODULE: Linux Parse Coverage
--- DESCRIPTION:
--- Compiles every production Lua file of the Linux driver — the entry point
--- included — and fails on the first one the interpreter refuses to parse.
---
--- ROOT CAUSE ENCODED:
--- The driver's entry point, ergopti_hotstrings.lua, had ZERO parse coverage.
--- Nothing in the suite required it (it starts a daemon), nothing compiled it,
--- and the JS gates only ever read it as text. A syntax error there — the one
--- file whose failure means the driver does not start at all — would have
--- shipped with a fully green suite and been discovered by a user. The same held
--- for every module the suite does not happen to require.
---
--- FEATURES & RATIONALE:
--- 1. loadfile COMPILES without executing. That distinction is the whole design:
---    requiring the entry point would spawn the daemon, and a probe that runs the
---    thing it is checking is not a test, it is a launch.
--- 2. The file list is discovered from disk, so a new module is covered the day
---    it lands rather than the day someone remembers to add it here.
--- 3. A floor assertion on the number of files scanned. Without it a broken walk
---    reports "0 files, 0 failures" and reads exactly like success.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==========================================
-- ==========================================
-- ======= 1/ Constants =====================
-- ==========================================
-- ==========================================

--- Trees excluded from the scan, and why.
--- - tests/   the suite compiles itself by running.
--- - vendor/  third-party source, kept verbatim; not ours to fix.
local EXCLUDED = { "/tests/", "/vendor/" }

--- Test trees the runner never loads, so the "compiles itself by running"
--- exemption above does not apply to them. tests/hardware/ runs only in the CI
--- job that needs a real kernel, which means a syntax error there is invisible
--- to every developer and to every other job — the exact shape of failure this
--- gate exists to remove.
local UNLOADED_TEST_TREES = { "/tests/hardware/" }

--- Lower bound on the production file count. Measured at 72 when this landed;
--- set below that so ordinary growth or a small refactor does not trip it, but
--- far enough above zero that a walk returning nothing fails loudly.
local MIN_FILES = 60




-- ==========================================
-- ==========================================
-- ======= 2/ Discovery =====================
-- ==========================================
-- ==========================================

--- Lists every .lua file under the driver root, minus the excluded trees.
---
--- Uses lfs when available and falls back to the platform's directory lister,
--- exactly like the suite runner: CI runs LuaJIT on Linux, the maintainer runs
--- plain Lua on Windows, and a gate that only works on one of them is a gate
--- that silently stops running on the other.
--- @return table List of absolute paths.
local function production_files()
	local root = helpers.driver_root()
	local files = {}

	local function keep(path)
		local normalised = path:gsub("\\", "/")
		if not normalised:match("%.lua$") then return end
		for _, kept in ipairs(UNLOADED_TEST_TREES) do
			if normalised:find(kept, 1, true) then
				files[#files + 1] = normalised
				return
			end
		end
		for _, skip in ipairs(EXCLUDED) do
			if normalised:find(skip, 1, true) then return end
		end
		files[#files + 1] = normalised
	end

	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(dir)
			for entry in lfs.dir(dir) do
				if entry ~= "." and entry ~= ".." then
					local full = dir .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then
						walk(full)
					elseif attr then
						keep(full)
					end
				end
			end
		end
		walk(root)
		return files
	end

	local is_windows = package.config:sub(1, 1) == "\\"
	local command = is_windows
		and ('dir /b /s "' .. root:gsub("/", "\\") .. '\\*.lua"')
		or ('find "' .. root .. '" -type f -name "*.lua"')
	local pipe = io.popen(command, "r")
	if not pipe then return files end
	for line in pipe:lines() do keep(line) end
	pipe:close()
	return files
end




-- ==========================================
-- ==========================================
-- ======= 3/ Assertions ====================
-- ==========================================
-- ==========================================

--- Inspects compiled nested prototypes without executing any driver code.
--- LuaJIT versions differ in their compiler limit; the portable budget is 60.
--- @param chunk function Compiled root function.
--- @param limit integer Portable upvalue budget.
--- @return table Prototype count, largest upvalue count and over-budget locations.
local function jit_upvalue_budget(chunk, limit)
	local util = require("jit.util")
	local result = { count = 0, maximum = 0, over = {} }
	local function visit(proto)
		local info = assert(util.funcinfo(proto), "compiled Lua prototype metadata is required")
		assert(type(info.upvalues) == "number" and type(info.gcconsts) == "number",
			"compiled Lua prototype counts are required")
		result.count = result.count + 1
		result.maximum = math.max(result.maximum, info.upvalues)
		if info.upvalues > limit then
			result.over[#result.over + 1] = string.format("%s:%s: %d upvalues",
				tostring(info.source), tostring(info.linedefined), info.upvalues)
		end
		for index = -1, -info.gcconsts, -1 do
			local child = util.funck(proto, index)
			if type(child) == "proto" then visit(child) end
		end
	end
	visit(chunk)
	return result
end

--- Inspects named PUC prototypes without counting their lexical environment.
--- LuaJIT keeps globals outside its capture array; PUC names that carrier _ENV.
--- Every listed capture must have its own compiler-provided name before exclusion.
--- @param listing string Full luac listing, including named upvalue tables.
--- @param limit integer Portable LuaJIT capture budget.
--- @return table Prototype count, largest capture count and over-budget locations.
local function luac_upvalue_budget(listing, limit)
	local result = { count = 0, maximum = 0, raw_maximum = 0, over = {} }
	local current, reading_names = nil, false
	local function finish()
		if not current then return end
		assert(type(current.raw_count) == "number" and current.named_count == current.raw_count,
			"compiled prototype must provide matching upvalue counts: " .. current.header
				.. " (" .. tostring(current.raw_count) .. "/" .. tostring(current.named_count) .. ")")
		assert(#current.names == current.raw_count, "every compiled upvalue must have a listed name")
		local captures = 0
		for _, name in ipairs(current.names) do
			if name ~= "_ENV" then captures = captures + 1 end
		end
		result.count = result.count + 1
		result.maximum = math.max(result.maximum, captures)
		result.raw_maximum = math.max(result.raw_maximum, current.raw_count)
		if captures > limit then
			result.over[#result.over + 1] = string.format("%s: %d upvalues", current.header, captures)
		end
	end
	for line in listing:gmatch("[^\r\n]+") do
		local header = line:match("^main <(.-)>") or line:match("^function <(.-)>")
		if header then
			finish()
			current, reading_names = { header = header, names = {} }, false
		elseif current then
			local count = tonumber(line:match("^%d+%+? params?,.- (%d+) upvalues?,"))
			local named = tonumber(line:match("^upvalues %((%d+)%) for "))
			if count then
				assert(current.raw_count == nil, "compiled prototype metadata cannot be repeated")
				current.raw_count = count
			elseif named then
				assert(current.named_count == nil, "compiled upvalue table cannot be repeated")
				current.named_count, reading_names = named, true
			elseif reading_names then
				local index, name = line:match("^%s*(%d+)%s+(%S+)")
				if index then
					assert(tonumber(index) == #current.names, "compiled upvalue names must retain every index")
					current.names[#current.names + 1] = name
				else
					reading_names = false
				end
			end
		end
	end
	finish()
	assert(result.count > 0, "compiled prototype discovery must not be empty")
	return result
end

--- Requires successful compilation and a complete named listing for every batch.
--- @param files table Source paths passed literally to the compiler.
--- @param limit integer Portable LuaJIT capture budget.
--- @return table Inspected compiler prototype counts and violations.
local function listed_upvalue_budget(files, limit)
	local quoted = {}
	for _, path in ipairs(files) do quoted[#quoted + 1] = '"' .. path .. '"' end
	local pipe = assert(io.popen("luac -l -l -p " .. table.concat(quoted, " ") .. " 2>&1", "r"),
		"compiled prototype listing process is required")
	local listing = pipe:read("*a") or ""
	local closed, kind, code = pipe:close()
	assert(closed == 0 or (closed == true and (kind == nil or kind == "exit") and (code == nil or code == 0)),
		"luac must successfully list every compiled prototype")
	return luac_upvalue_budget(listing, limit)
end

--- Produces an independent nested function that captures exactly the given count.
--- @param count integer Number of outer locals captured by the nested function.
--- @param globals boolean Whether the nested function also reads a global.
--- @return string Lua source with three compiled prototype levels.
local function nested_upvalue_source(count, globals)
	local names, values = {}, {}
	for index = 1, count do
		names[index] = "value_" .. index
		values[index] = tostring(index)
	end
	return "return function()\nlocal " .. table.concat(names, ",") .. " = "
		.. table.concat(values, ",") .. "\nreturn function() return "
		.. (globals and "independent_global," or "") .. table.concat(names, ",") .. " end\nend\n"
end

--- Compiles independent boundary fixtures without executing their functions.
--- @param source string Nested fixture source.
--- @param limit integer Portable LuaJIT capture budget.
--- @return table|nil Inspection, or nil when LuaJIT itself refuses compilation.
--- @return string|nil Compiler refusal.
local function fixture_upvalue_budget(source, limit)
	if jit then
		local chunk, err = loadstring(source, "=independent-upvalue-boundary")
		if not chunk then return nil, err end
		return jit_upvalue_budget(chunk, limit)
	end
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write(source))
	assert(file:close())
	local ok, result = pcall(listed_upvalue_budget, { path }, limit)
	os.remove(path)
	if not ok then error(result, 0) end
	return result
end

helpers.describe("linux: every production Lua file compiles", function()
	local files = production_files()

	helpers.it("the scan actually reaches the driver source", function()
		helpers.assert_true(#files >= MIN_FILES,
			string.format("expected at least %d production .lua file(s), found %d — a walk that finds nothing reports zero parse errors and reads as a pass",
				MIN_FILES, #files))
	end)

	helpers.it("the hardware harness is part of the scan", function()
		-- It is the one Lua file in this driver that no developer and no other CI
		-- job ever loads: it needs a real /dev/uinput. Without this, a typo in it
		-- surfaces as a red job on a branch nobody expected to touch the kernel.
		local found = false
		for _, path in ipairs(files) do
			if path:find("/tests/hardware/", 1, true) then found = true break end
		end
		helpers.assert_true(found,
			"tests/hardware/ must be compiled by this gate — the suite runner does not "
				.. "discover it, so nothing else ever parses it")
	end)

	helpers.it("the entry point is part of the scan", function()
		local found = false
		for _, path in ipairs(files) do
			if path:match("/ergopti_hotstrings%.lua$") then found = true break end
		end
		helpers.assert_true(found,
			"ergopti_hotstrings.lua must be in the scan — it is the file whose syntax error means the daemon does not start at all, and it is the one nothing else compiles")
	end)

	helpers.it("no production file has a syntax error", function()
		local broken = {}
		for _, path in ipairs(files) do
			local chunk, err = loadfile(path)
			if not chunk then broken[#broken + 1] = tostring(err) end
		end
		helpers.assert_eq(#broken, 0,
			"production Lua file(s) failed to compile:\n  " .. table.concat(broken, "\n  "))
	end)

	helpers.it("no function exceeds LuaJIT's upvalue limit", function()
		-- LuaJIT refuses to compile a function with more than 60 upvalues, which
		-- PUC Lua accepts up to 255: four file-scope requires pushed main() of the
		-- entry point to 62, the local suite stayed green and only CI's LuaJIT
		-- failed. Newer LuaJIT accepts larger functions, so inspect its compiled
		-- prototypes too; PUC's named listing excludes only its explicit _ENV.
		local LIMIT = 60
		if jit then
			local over = {}
			local inspected = 0
			for _, path in ipairs(files) do
				local chunk, err = loadfile(path)
				if not chunk then
					over[#over + 1] = tostring(err)
				else
					local result = jit_upvalue_budget(chunk, LIMIT)
					inspected = inspected + 1
					for _, location in ipairs(result.over) do over[#over + 1] = location end
				end
			end
			helpers.assert_true(inspected >= MIN_FILES, "the prototype scan must reach the production source")
			helpers.assert_eq(#over, 0, "function(s) over LuaJIT's " .. LIMIT
				.. "-upvalue limit (move file-scope requires into the function that uses them):\n  "
				.. table.concat(over, "\n  "))
			return
		end
		local BATCH = 30
		local luac_probe = io.popen("luac -v 2>&1", "r")
		local banner = luac_probe and luac_probe:read("*a") or ""
		if luac_probe then luac_probe:close() end
		helpers.assert_true(banner:find("Lua", 1, true) ~= nil,
			"luac must be on PATH next to lua: without it this gate cannot see LuaJIT's upvalue limit")
		local over, inspected = {}, 0
		for first = 1, #files, BATCH do
			local batch = {}
			for i = first, math.min(first + BATCH - 1, #files) do
				batch[#batch + 1] = files[i]
			end
			local result = listed_upvalue_budget(batch, LIMIT)
			inspected = inspected + result.count
			for _, location in ipairs(result.over) do over[#over + 1] = location end
		end
		helpers.assert_true(inspected >= #files, "the prototype scan must reach every production source")
		helpers.assert_eq(#over, 0, "function(s) over LuaJIT's " .. LIMIT
			.. "-upvalue limit (move file-scope requires into the function that uses them):\n  "
			.. table.concat(over, "\n  "))
	end)

	for _, globals in ipairs({ false, true }) do
		local suffix = globals and " with globals" or " without globals"
		helpers.it("compiled inspection accepts 60 independent captures" .. suffix, function()
			local result, err = fixture_upvalue_budget(nested_upvalue_source(60, globals), 60)
			helpers.assert_not_nil(result, tostring(err))
			helpers.assert_eq(result.count, 3, "root, outer and nested function must all be inspected")
			helpers.assert_eq(result.maximum, 60)
			helpers.assert_eq(#result.over, 0)
			if not jit then helpers.assert_eq(result.raw_maximum, globals and 61 or 60) end
		end)
		helpers.it("compiled inspection rejects 61 independent captures" .. suffix, function()
			local result, err = fixture_upvalue_budget(nested_upvalue_source(61, globals), 60)
			if not result then
				-- Older LuaJIT rejects this source before a prototype can exist.
				helpers.assert_true(jit ~= nil and tostring(err):find("upvalue", 1, true) ~= nil,
					"only an explicit compiler upvalue refusal proves this fixture was rejected")
				return
			end
			helpers.assert_eq(result.count, 3)
			helpers.assert_eq(result.maximum, 61)
			helpers.assert_eq(#result.over, 1, "the over-budget nested prototype must be rejected")
			if not jit then helpers.assert_eq(result.raw_maximum, globals and 62 or 61) end
		end)
	end

	helpers.it("refuses empty discovery and unnamed compiler upvalues", function()
		for _, listing in ipairs({ "", "compiler failed", "main <fixture:0,0>\n"
			.. "0+ params, 1 slot, 1 upvalue, 0 locals, 0 constants, 0 functions\nupvalues (1) for 0x1:\n" }) do
			local ok = pcall(luac_upvalue_budget, listing, 60)
			helpers.assert_eq(ok, false, "missing compiled prototypes or names must never report success")
		end
	end)
end)
