--- tests/unit/adapters/file_system/test_write_lock_outside_destination.lua

--- ==============================================================================
--- MODULE: Cooperative Write Lock Lives Outside the Destination Folder
--- DESCRIPTION:
--- The real adapter publishes and removes files in a private folder and leaves
--- no lock entry there (write-lock-outside-destination). Every field run result
--- used to keep a `.ergoptiplus-write-lock-v1` sidecar, and the Ollama pull's
--- private operation folder kept `authority.json.ergoptiplus-write-lock-v1`
--- after its conditional removal, so its exact two-file census refused the
--- retirement and the task slot stayed held (field run 2026-10-31).
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

--- Lists one directory's entries, sorted.
--- @param directory string Directory path.
--- @return table names
local function entries(directory)
	local names = {}
	for name in require("lfs").dir(directory) do
		if name ~= "." and name ~= ".." then names[#names + 1] = name end
	end
	table.sort(names)
	return names
end

helpers.describe("adapters.file_system: the cooperative write lock lives outside the destination folder", function()
	helpers.it("publishes and removes in a private folder without leaving a lock entry (write-lock-outside-destination)", function()
		with_fixture(function(fixture)
			local lfs = require("lfs")
			local directory = os.tmpname():gsub("\\", "/")
			os.remove(directory)
			assert(lfs.mkdir(directory))
			local result, authority = directory .. "/01_check.json", directory .. "/authority.json"
			local ok, failure = xpcall(function()
				local adapter = fixture.make_adapter()
				helpers.assert_eq(adapter.write(result, "{}\n"), true)
				helpers.assert_eq(adapter.write(authority, "proof"), true)
				helpers.assert_eq(table.concat(entries(directory), ","), "01_check.json,authority.json",
					"an atomic write leaves only its destination in the folder")
				local removed = adapter.remove_if_unchanged(authority, { status = "ok", content = "proof" })
				helpers.assert_eq(removed, true)
				helpers.assert_eq(table.concat(entries(directory), ","), "01_check.json",
					"a conditional removal leaves no lock entry in a private census folder")
				local lock = fixture.write_lock_path(result)
				helpers.assert_true(lock:find(os.getenv("HOME") .. "/Library/Application Support/ErgoptiPlus/write-locks/",
					1, true) == 1, "the lock inode lives in the per-user lock directory: " .. lock)
				helpers.assert_eq(lfs.attributes(lock, "mode"), "file", "the stable lock inode stays for later writers")
			end, debug.traceback)
			for _, name in ipairs(entries(directory)) do os.remove(directory .. "/" .. name) end
			lfs.rmdir(directory)
			if not ok then error(failure, 0) end
		end)
	end)

	helpers.it("derives one fixed-length lock name per canonical destination", function()
		local WriteLockPath = require("adapters.write_lock_path")
		local first = assert(WriteLockPath.for_canonical("/a/" .. string.rep("x", 400), "/Users/tester/"))
		local second = assert(WriteLockPath.for_canonical("/a/b", "/Users/tester"))
		helpers.assert_eq(#first, #second, "a long destination keeps a fixed-length lock name")
		helpers.assert_true(first ~= second)
		helpers.assert_eq(second, assert(WriteLockPath.for_canonical("/a/b", "/Users/tester")))
		helpers.assert_true(second:match("^/Users/tester/Library/Application Support/ErgoptiPlus/write%-locks/%x+%.ergoptiplus%-write%-lock%-v1$") ~= nil, second)
		local missing, detail = WriteLockPath.for_canonical("/a/b", nil)
		helpers.assert_nil(missing)
		helpers.assert_true(type(detail) == "string" and detail:find("HOME", 1, true) ~= nil)
	end)
end)
