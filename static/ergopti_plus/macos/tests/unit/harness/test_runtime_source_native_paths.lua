--- tests/unit/harness/test_runtime_source_native_paths.lua

--- ==============================================================================
--- MODULE: Native Runtime Source Inventory Paths
--- DESCRIPTION:
--- Actual filesystem inventories retain opaque pathnames, complete translation
--- units and unreadable causes. Source fixtures are data and never execute.
--- ==============================================================================

local helpers = require("tests.helpers")
local Native = require("luv")
local Inventory = require("tests.support.runtime_source_inventory")
local Detector = require("tests.support.karabiner_isolation.detector")
local DIRECTORY_MODE = tonumber("700", 8)
local FILE_MODE = tonumber("600", 8)
local WINDOWS = package.config:sub(1, 1) == "\\"
-- The owning isolation guard admits more than 100 units; losing one of 104 still clears it.
local DECOY_FILES = 103
local LUA_BODY = "return { runtime_fixture = true }\n"
local TOOL_BODY = "#!/bin/sh\nexit 0\n"
local FORBIDDEN_BODY = "#!/bin/sh\npkill -f Karabiner-Menu\n"

local function with_fixture(prefix, callback)
	local root = assert(Native.fs_mkdtemp(helpers.temp_dir() .. "/ergopti-runtime-census.XXXXXX"))
	local directories, files, known = { root }, {}, { [root] = true }
	local fixture = { root = root, driver = root .. "/" .. prefix .. "/driver", custody_known = true }
	function fixture.mkdir(path)
		if known[path] then return end
		assert(path:sub(1, #root + 1) == root .. "/", "Runtime fixture directories must remain owned")
		fixture.mkdir(assert(path:match("^(.*)/[^/]+$")))
		assert(Native.fs_mkdir(path, DIRECTORY_MODE))
		known[path] = true
		directories[#directories + 1] = path
	end
	function fixture.store(relative, body)
		local path = fixture.driver .. "/" .. relative
		fixture.mkdir(assert(path:match("^(.*)/[^/]+$")))
		local descriptor = assert(Native.fs_open(path, "wx", FILE_MODE))
		files[#files + 1] = path
		local ok, failure = xpcall(function()
			local offset = 0
			while offset < #body do
				local count = assert(Native.fs_write(descriptor, body:sub(offset + 1), offset))
				assert(count > 0, "The owned runtime fixture write must progress")
				offset = offset + count
			end
		end, debug.traceback)
		local closed, reason = Native.fs_close(descriptor)
		if not closed then
			fixture.custody_known = false
			error(tostring(failure or "Runtime fixture close refused") .. ": " .. tostring(reason), 0)
		end
		if not ok then error(failure, 0) end
		return path
	end
	function fixture.link(relative, target)
		local path = fixture.driver .. "/" .. relative
		fixture.mkdir(assert(path:match("^(.*)/[^/]+$")))
		assert(Native.fs_symlink(target, path))
		files[#files + 1] = path
		return path
	end
	fixture.mkdir(fixture.driver)
	local ok, failure = xpcall(function() callback(fixture) end, debug.traceback)
	if not fixture.custody_known then error(tostring(failure) .. "; retain exact runtime fixture " .. root, 0) end
	local cleanup = {}
	for index = #files, 1, -1 do
		local retired, reason = Native.fs_unlink(files[index])
		if not retired then cleanup[#cleanup + 1] = files[index] .. ": " .. tostring(reason) end
	end
	for index = #directories, 1, -1 do
		local retired, reason = Native.fs_rmdir(directories[index])
		if not retired then cleanup[#cleanup + 1] = directories[index] .. ": " .. tostring(reason) end
	end
	if #cleanup > 0 then error(tostring(failure or "runtime cleanup refused") .. "; " .. table.concat(cleanup, "; "), 0) end
	if not ok then error(failure, 0) end
end

local function displayed(path)
	return WINDOWS and path:gsub("\\", "/") or path
end

local function assert_units(fixture)
	local a = fixture.store("a.lua", LUA_BODY)
	local tool = fixture.store("z-tool", TOOL_BODY)
	fixture.store("notes", "ordinary non-executable notes\n")
	fixture.store("not-runtime.bin", FORBIDDEN_BODY)
	local units, unreadable = Inventory.read(fixture.driver)
	helpers.assert_eq(unreadable, {}, "All selected real files must remain readable")
	helpers.assert_eq(units, {
		{ path = displayed(a), body = LUA_BODY },
		{ path = displayed(tool), body = TOOL_BODY },
	}, "The real inventory must preserve sorted exact units and the extensionless shebang rule")
end

helpers.describe("Native runtime inventory paths", function()
	local cases = { { label = "ordinary", prefix = "ordinary" }, { label = "outer-tests", prefix = "tests/checkout" } }
	if not WINDOWS then
		cases[#cases + 1] = { label = "newline", prefix = "line\nbreak" }
		cases[#cases + 1] = { label = "literal-backslash-tests", prefix = "literal\\tests\\checkout" }
	end
	for _, case in ipairs(cases) do
		helpers.it("(native-runtime-census) preserves exact units under " .. case.label, function()
			with_fixture(case.prefix, assert_units)
		end)
	end
	helpers.it("(native-runtime-census) excludes named fixture directories before traversing their contents", function()
		with_fixture("excluded-directories", function(fixture)
			local expected = fixture.store("runtime.lua", LUA_BODY)
			for _, name in ipairs({ "Tests", ".VENV", ".PyTest_Cache", ".CoDeX-private" }) do
				fixture.store(name .. "/forbidden.sh", FORBIDDEN_BODY)
			end
			fixture.store(".codex-hidden.lua", FORBIDDEN_BODY)
			local units, unreadable = Inventory.read(fixture.driver)
			helpers.assert_eq(unreadable, {})
			helpers.assert_eq(units, { { path = displayed(expected), body = LUA_BODY } }, "Ignored descendants are never runtime evidence")
		end)
	end)
	if not WINDOWS then
		helpers.it("(native-runtime-census) retains the offending real unit even when a partial census clears the caller floor", function()
			with_fixture("partial", function(fixture)
				for index = 1, DECOY_FILES do fixture.store(string.format("decoy-%03d.lua", index), LUA_BODY) end
				local offender = fixture.store("runtime\\tests\\folder/forbidden.sh", FORBIDDEN_BODY)
				local units, unreadable = Inventory.read(fixture.driver)
				helpers.assert_eq(unreadable, {})
				helpers.assert_true(#units > 100, "The historical whole-inventory floor alone still passes")
				helpers.assert_eq(#units, DECOY_FILES + 1, "Every actual translation unit must remain in the business inventory")
				local found
				for _, unit in ipairs(units) do if unit.path == offender then found = unit.body end end
				helpers.assert_eq(found, FORBIDDEN_BODY, "The exact offending path and body cannot disappear behind a high unit count")
				helpers.assert_true(#Detector.find_offenders(found) > 0, "The actual isolation detector sees the retained source")
			end)
		end)
		helpers.it("(native-runtime-census) never acquires broken targets beneath ignored directory or link names", function()
			with_fixture("ignored-links", function(fixture)
				local source = fixture.store("a.lua", LUA_BODY)
				local ignored = {}
				for _, name in ipairs({ "TESTS", ".venv", ".pytest_cache", ".codex-broken" }) do
					ignored[fixture.link(name, fixture.root .. "/missing-target")] = true
				end
				local stat, target_reads = Native.fs_stat, 0
				Native.fs_stat = function(path, ...)
					if ignored[path] then target_reads = target_reads + 1 end
					return stat(path, ...)
				end
				local outcome = table.pack(pcall(Inventory.read, fixture.driver))
				Native.fs_stat = stat
				helpers.assert_true(outcome[1], tostring(outcome[2]))
				helpers.assert_eq(outcome[2], { { path = source, body = LUA_BODY } })
				helpers.assert_eq(outcome[3], {})
				helpers.assert_eq(target_reads, 0, "Excluded links must be skipped before target metadata is acquired")
			end)
		end)
		helpers.it("(native-runtime-census) refuses an unignored broken runtime link", function()
			with_fixture("broken-runtime", function(fixture)
				fixture.link("runtime.lua", fixture.root .. "/missing-target")
				local accepted, reason = pcall(Inventory.read, fixture.driver)
				helpers.assert_eq(accepted, false, "A selected broken source cannot certify complete empty coverage")
				helpers.assert_true(tostring(reason):find("ENOENT", 1, true) ~= nil, "Retain the real metadata refusal: " .. tostring(reason))
			end)
		end)
		helpers.it("(native-runtime-census) aggregates actual source read failures without publishing failed units", function()
			with_fixture("unreadable", function(fixture)
				local good = fixture.store("a.lua", LUA_BODY)
				local denied = fixture.store("z.lua", TOOL_BODY)
				assert(Native.fs_chmod(denied, 0))
				local outcome = table.pack(pcall(Inventory.read, fixture.driver))
				assert(Native.fs_chmod(denied, FILE_MODE))
				helpers.assert_true(outcome[1], tostring(outcome[2]))
				helpers.assert_eq(outcome[2], { { path = good, body = LUA_BODY } })
				helpers.assert_eq(#outcome[3], 1)
				helpers.assert_true(outcome[3][1]:find(denied, 1, true) ~= nil and outcome[3][1]:find("source open failed", 1, true) ~= nil,
					"Retain the actual unreadable path and phase")
			end)
		end)
	end
	for _, removed in ipairs({ false, true }) do
		helpers.it("(native-runtime-census) classifies DT_UNKNOWN named tests through real nonfollowing metadata" .. (removed and " refusal" or ""), function()
			with_fixture("unknown-kind", function(fixture)
				local source = fixture.store("tests", TOOL_BODY)
				local held = fixture.driver .. "/held"
				local next_entry, lstat = Native.fs_scandir_next, Native.fs_lstat
				local moved, classifications = false, 0
				helpers.assert_eq(debug.getinfo(lstat, "S").what, "C", "Use the real nonfollowing metadata owner")
				Native.fs_scandir_next = function(request)
					local name, kind = next_entry(request)
					if name == "tests" then
						if removed then assert(Native.fs_rename(source, held)); moved = true end
						return name, "unknown"
					end
					return name, kind
				end
				Native.fs_lstat = function(path, ...)
					if path == source then classifications = classifications + 1 end
					return lstat(path, ...)
				end
				local outcome = table.pack(pcall(Inventory.read, fixture.driver))
				Native.fs_scandir_next, Native.fs_lstat = next_entry, lstat
				if moved then assert(Native.fs_rename(held, source)) end
				if removed then
					helpers.assert_eq(outcome[1], false, "Unknown metadata cannot authorize skipping a real regular-file candidate")
					helpers.assert_true(tostring(outcome[2]):find("ENOENT", 1, true) ~= nil, "Keep actual lstat refusal")
				else
					helpers.assert_true(outcome[1], tostring(outcome[2]))
					helpers.assert_eq(outcome[2], { { path = displayed(source), body = TOOL_BODY } }, "A file named tests must not become an ignored directory")
					helpers.assert_eq(outcome[3], {})
				end
				helpers.assert_eq(classifications, 1, "Classify unknown excluded names through the actual nonfollowing metadata")
			end)
		end)
	end
end)
