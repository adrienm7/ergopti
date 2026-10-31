--- tests/unit/platform/remap/runtime_artifact_fetch/test_runtime_artifact_fetch.lua

--- ==============================================================================
--- MODULE: Owned Runtime Artifact Fetch
--- DESCRIPTION:
--- Pins platform/remap/runtime_artifact_fetch.lua with fake ports: the first
--- start downloads the pinned artifact into Ergopti's own folder and verifies
--- its size, digest and members before extracting it; a later start with a
--- matching receipt uses the kept payload without any command.
---
--- ROOT CAUSE ENCODED: the owned runtime must be the pinned bytes and only
--- those. A fetch that trusted a download before its digest, extracted a link
--- or an absolute member, kept a payload whose receipt names another digest,
--- or wrote outside the Ergopti folder would run a runtime nobody pinned.
--- ==============================================================================

local helpers = require("tests.helpers")

local HOME = "/Users/test/Library/Application Support/ErgoptiPlus/RemapRuntime/16.3.0-ergopti.1"
local DIGEST = string.rep("ab", 32)

--- A complete runtime pin.
--- @return table pin
local function pin()
	return {
		version = "16.3.0-ergopti.1",
		file_name = "ErgoptiPlus-Remap-Runtime-16.3.0-ergopti.1.tar.gz",
		source_url = "https://github.com/adrienm7/ergopti/releases/download/remap-runtime-v16.3.0-ergopti.1/"
			.. "ErgoptiPlus-Remap-Runtime-16.3.0-ergopti.1.tar.gz",
		sha256 = DIGEST,
		size = 4096,
	}
end

--- Builds a fetcher over a fake Mac.
--- @param overrides table|nil Command answers keyed by executable basename.
--- @return table fetcher
--- @return table world { commands, files }
local function fake(overrides)
	package.loaded["platform.remap.runtime_artifact_fetch"] = nil
	local Fetch = require("platform.remap.runtime_artifact_fetch")
	local world = { commands = {}, files = {} }
	local listing_names = table.concat({ "Runtime/", "Runtime/bin/", Fetch.PRODUCTS[1], Fetch.PRODUCTS[2],
		Fetch.PRODUCTS[3] }, "\n") .. "\n"
	local listing_verbose = "drwxr-xr-x 0 0 0 0 Jan 1 1970 Runtime/\ndrwxr-xr-x 0 0 0 0 Jan 1 1970 Runtime/bin/\n"
		.. "-rwxr-xr-x 0 0 0 9 Jan 1 1970 a\n-rwxr-xr-x 0 0 0 9 Jan 1 1970 b\n-rwxr-xr-x 0 0 0 9 Jan 1 1970 c\n"
	local answers = {
		stat = function() return 0, "4096\n" end,
		shasum = function(args) return 0, DIGEST .. "  " .. args[3] .. "\n" end,
		tar = function(args)
			if args[1] == "-tvzf" then return 0, listing_verbose end
			if args[1] == "-tzf" then return 0, listing_names end
			for _, product in ipairs(Fetch.PRODUCTS) do world.files[args[4] .. "/" .. product] = true end
			return 0, ""
		end,
		mv = function(args)
			for path in pairs(world.files) do
				if path:sub(1, #args[1]) == args[1] then
					world.files[args[2] .. path:sub(#args[1] + 1)] = world.files[path]
					world.files[path] = nil
				end
			end
			return 0, ""
		end,
	}
	for name, answer in pairs(overrides or {}) do answers[name] = answer end
	local fetcher = Fetch.new({
		exec = function(executable, args, _, callback)
			local name = executable:match("[^/]+$")
			world.commands[#world.commands + 1] = { name = name, args = args }
			local answer = answers[name]
			if answer then return callback(answer(args)) end
			callback(0, "", "")
		end,
		exists = function(path) return world.files[path] ~= nil end,
		read = function(path) return type(world.files[path]) == "string" and world.files[path] or nil end,
		write = function(path, content) world.files[path] = content; return true end,
		expand = function(path) return (path:gsub("^~", "/Users/test")) end,
	})
	return fetcher, world, Fetch
end

--- Runs one ensure and returns its settlement.
--- @param fetcher table Fetcher.
--- @param candidate table Pin.
--- @return table result { ok, value, detail }
local function ensure(fetcher, candidate)
	local result
	fetcher.ensure(candidate, function(ok, value, detail) result = { ok = ok, value = value, detail = detail } end)
	return assert(result, "the fetch did not settle")
end

--- The executables a run called, in order.
--- @param world table Fake world.
--- @return table names
local function called(world)
	local names = {}
	for _, command in ipairs(world.commands) do names[#names + 1] = command.name end
	return names
end





-- ==================================
-- ==================================
-- ======= 1/ The First Start =======
-- ==================================
-- ==================================

helpers.describe("owned runtime artifact fetch: the first start", function()
	helpers.it("downloads, verifies, extracts and keeps the pinned artifact in Ergopti's own folder", function()
		local fetcher, world = fake()
		local result = ensure(fetcher, pin())
		helpers.assert_true(result.ok, tostring(result.detail))
		helpers.assert_eq(result.value, HOME .. "/payload")
		helpers.assert_eq(called(world), { "rm", "mkdir", "curl", "stat", "shasum", "tar", "tar", "tar", "mv", "mv" })
		helpers.assert_eq(world.files[HOME .. "/receipt"], DIGEST .. "\n")
		for _, command in ipairs(world.commands) do
			for _, argument in ipairs(command.args) do
				if argument:sub(1, 1) == "/" then
					helpers.assert_true(argument:sub(1, #HOME) == HOME, "a command reached outside the folder: " .. argument)
				end
			end
		end
	end)

	helpers.it("downloads over https only, bounded by the pinned size", function()
		local fetcher, world = fake()
		ensure(fetcher, pin())
		local curl = world.commands[3].args
		helpers.assert_contains(table.concat(curl, " "), "--proto =https")
		helpers.assert_contains(table.concat(curl, " "), "--max-filesize 4096")
		helpers.assert_eq(curl[#curl], pin().source_url)
	end)
end)





-- =================================
-- =================================
-- ======= 2/ Named Refusals =======
-- =================================
-- =================================

helpers.describe("owned runtime artifact fetch: named refusals", function()
	helpers.it("refuses an unpinned runtime without running anything", function()
		local fetcher, world = fake()
		local unpinned = pin()
		unpinned.sha256 = nil
		local result = ensure(fetcher, unpinned)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.value, "artifact_unpinned")
		helpers.assert_eq(#world.commands, 0)
	end)

	helpers.it("refuses a download of another size before hashing it", function()
		local fetcher, world = fake({ stat = function() return 0, "4095\n" end })
		local result = ensure(fetcher, pin())
		helpers.assert_eq(result.value, "artifact_size_mismatch")
		helpers.assert_eq(called(world)[#world.commands], "stat")
	end)

	helpers.it("refuses a download whose digest is not the pin and never extracts it", function()
		local fetcher, world = fake({ shasum = function() return 0, string.rep("cd", 32) .. "  x\n" end })
		local result = ensure(fetcher, pin())
		helpers.assert_eq(result.value, "artifact_digest_mismatch")
		helpers.assert_nil(world.files[HOME .. "/receipt"])
		helpers.assert_eq(called(world)[#world.commands], "shasum")
	end)

	helpers.it("refuses an archive holding a link before extracting it", function()
		local fetcher, world = fake({ tar = function(args)
			if args[1] == "-tvzf" then return 0, "lrwxr-xr-x 0 0 0 0 Jan 1 1970 Runtime/x -> /etc\n" end
			return 0, "Runtime/x\n"
		end })
		local result = ensure(fetcher, pin())
		helpers.assert_eq(result.value, "artifact_members_refused")
		for _, command in ipairs(world.commands) do helpers.assert_true(command.args[1] ~= "-xzf", "extracted") end
	end)

	helpers.it("names the failing download with its status", function()
		local fetcher = fake({ curl = function() return 22, "", "The requested URL returned error: 404" end })
		local result = ensure(fetcher, pin())
		helpers.assert_eq(result.value, "artifact_download_failed")
		helpers.assert_contains(result.detail, "404")
	end)
end)





-- =======================================
-- =======================================
-- ======= 3/ Then Always That One =======
-- =======================================
-- =======================================

helpers.describe("owned runtime artifact fetch: then always that one", function()
	helpers.it("uses the kept payload without any command when the receipt matches", function()
		local fetcher, world = fake()
		ensure(fetcher, pin())
		world.commands = {}
		local result = ensure(fetcher, pin())
		helpers.assert_true(result.ok)
		helpers.assert_eq(#world.commands, 0)
		helpers.assert_eq(fetcher.payload_for(pin()), HOME .. "/payload")
	end)

	helpers.it("fetches again when the receipt names another digest", function()
		local fetcher, world = fake()
		ensure(fetcher, pin())
		world.files[HOME .. "/receipt"] = string.rep("ef", 32) .. "\n"
		helpers.assert_nil(fetcher.payload_for(pin()))
		world.commands = {}
		helpers.assert_true(ensure(fetcher, pin()).ok)
		helpers.assert_eq(world.commands[3].name, "curl")
	end)

	helpers.it("lets a caller that asks during a fetch wait for that same fetch", function()
		package.loaded["platform.remap.runtime_artifact_fetch"] = nil
		local Fetch = require("platform.remap.runtime_artifact_fetch")
		local held, runs = nil, 0
		local fetcher = Fetch.new({
			exec = function(executable, _, _, callback)
				if executable:match("curl$") then
					runs = runs + 1
					held = callback
					return
				end
				callback(0, "", "")
			end,
			exists = function() return false end,
			read = function() return nil end,
			write = function() return true end,
			expand = function(path) return path end,
		})
		local answers = {}
		fetcher.ensure(pin(), function(ok, reason) answers[#answers + 1] = { ok, reason } end)
		fetcher.ensure(pin(), function(ok, reason) answers[#answers + 1] = { ok, reason } end)
		helpers.assert_eq(runs, 1)
		helpers.assert_eq(#answers, 0)
		held(7, "", "connection refused")
		helpers.assert_eq(answers, { { false, "artifact_download_failed" }, { false, "artifact_download_failed" } })
	end)

	helpers.it("judges a listing closed only with every product under Runtime/", function()
		local _, _, Fetch = fake()
		helpers.assert_eq((Fetch.closed_listing("-x\n", "/etc/passwd\n")), false)
		helpers.assert_eq((Fetch.closed_listing("-x\n", "Runtime/../x\n")), false)
		helpers.assert_eq((Fetch.closed_listing("dx\n", "Runtime/\n")), false)
	end)
end)
