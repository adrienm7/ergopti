--- tests/unit/modules/updater/check/test_updater_list_cache_persistence.lua

--- ==============================================================================
--- MODULE: Release-List Copy Survives A Restart (Linux)
--- DESCRIPTION:
--- The update check answers a 304 from the release list it holds. That list
--- lived in memory only, so the first request after every start was a full one
--- and spent the 60-per-hour anonymous GitHub quota (Windows and macOS keep
--- their copy across restarts). The copy is now kept in the Storage port, and
--- it is trusted again only while the ETag file curl saved still names it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local PAGE_ONE = "https://etag-fixture.invalid/releases/page-1"
local VALIDATOR = '"PAGE-ONE"'
local LIST = '[{"tag_name":"v1.2.0","prerelease":false}]'

--- Builds the answer of the transport for one scripted response.
local function answer(result, validator, conditional)
	result.etag_receipt = { format = "curl-etag-final-v1", effective_url = PAGE_ONE,
		validator = validator, associated = true, conditional_sent = conditional == true,
		sent_validator = conditional == true and validator or nil }
	return result
end

--- Loads a fresh manager over a Storage fake and a file system that reports the
--- ETag cache directory present and the ETag file holding etag_content.
--- @param storage table Storage fake shared across the simulated restarts.
--- @param etag_content string|nil What the saved ETag file reads as.
--- @return table manager
local function boot(storage, etag_content)
	local names = { "adapters.file_system", "adapters.storage", "modules.updater.manager" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local real_fs = require("adapters.file_system")
	package.loaded["adapters.file_system"] = setmetatable({
		exists = function() return true end,
		read = function(path)
			if tostring(path):find("ergopti_updater_etag_", 1, true) then return etag_content end
			return real_fs.read(path)
		end,
	}, { __index = real_fs })
	package.loaded["adapters.storage"] = storage
	package.loaded["modules.updater.manager"] = nil
	local ok, fresh = pcall(require, "modules.updater.manager")
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	helpers.assert_true(ok and type(fresh) == "table", tostring(fresh))
	return fresh
end

--- One fetch of the first page against a scripted answer.
local function fetch(manager, result)
	manager._http_client = require("tests.support.release_http_fixture").attach({
		get = function(_, _, _, callback) callback(result) return true end,
		cancel = function() return true end,
	})
	local done = {}
	helpers.assert_true(manager._fetch_releases("main", function(body, status, err)
		done = { body = body, status = status, error = err }
	end))
	return done
end

helpers.describe("updater (linux): the release-list copy survives a restart", function()

	helpers.it("list-copy: a 200 is stored and the next start asks conditionally", function()
		local storage = Fakes.storage({ initial = {} })
		local first = boot(storage, VALIDATOR .. "\n")
		local _, _, before = first._build_fetch_request("main", 1)
		helpers.assert_nil(before.etag_compare, "nothing is held yet: the first request is a full one")
		local done = fetch(first, answer({ ok = true, status = 200, body = LIST }, VALIDATOR, false))
		helpers.assert_eq(done.status, 200)

		local stored = storage.get(first.LIST_CACHE_KEY)
		helpers.assert_true(type(stored) == "table", "the list copy reaches the Storage port")
		local entry = stored["main-page-1-size-20"]
		helpers.assert_true(type(entry) == "table", "it is keyed by channel and page")
		helpers.assert_eq(entry.etag, VALIDATOR)
		helpers.assert_eq(entry.url, PAGE_ONE)
		helpers.assert_eq(entry.body, LIST)

		local restarted = boot(storage, VALIDATOR .. "\n")
		local _, _, after = restarted._build_fetch_request("main", 1)
		helpers.assert_true(after.etag_compare ~= nil,
			"after a restart the first request is conditional, so a 304 costs no quota")
		helpers.assert_eq(after.etag_expected_value, VALIDATOR)
		helpers.assert_eq(after.etag_expected_url, PAGE_ONE)

		-- The 304 is then answered from the restored copy.
		local result = fetch(restarted, answer({ ok = false, status = 304, body = "", error = "HTTP 304", error_body = "" },
			VALIDATOR, true))
		helpers.assert_eq(result.body, LIST, "the restored list answers the 304")
	end)

	helpers.it("list-copy: an ETag file that moved on makes the request a full one", function()
		local storage = Fakes.storage({ initial = {} })
		local first = boot(storage, VALIDATOR .. "\n")
		fetch(first, answer({ ok = true, status = 200, body = LIST }, VALIDATOR, false))
		local restarted = boot(storage, '"ANOTHER"\n')
		local _, _, options = restarted._build_fetch_request("main", 1)
		helpers.assert_nil(options.etag_compare,
			"curl may have advanced the file past the stored list: pairing them would answer a 304 with the wrong list")
	end)

	helpers.it("list-copy: a stored value that is not a whole copy is dropped", function()
		local storage = Fakes.storage({ initial = {} })
		local probe = boot(storage, VALIDATOR .. "\n")
		storage.set(probe.LIST_CACHE_KEY, {
			["main-page-1-size-20"] = { url = PAGE_ONE, etag = VALIDATOR, body = '{"message":"rate limited"}' },
		})
		local restarted = boot(storage, VALIDATOR .. "\n")
		local _, _, options = restarted._build_fetch_request("main", 1)
		helpers.assert_nil(options.etag_compare, "an object is not a release list")
	end)

	helpers.it("list-copy: a failed page removes its stored copy", function()
		local storage = Fakes.storage({ initial = {} })
		local manager = boot(storage, VALIDATOR .. "\n")
		fetch(manager, answer({ ok = true, status = 200, body = LIST }, VALIDATOR, false))
		helpers.assert_true(storage.get(manager.LIST_CACHE_KEY) ~= nil)
		local failed = fetch(manager, { ok = false, status = 500, body = "", error = "HTTP 500" })
		helpers.assert_nil(failed.body)
		helpers.assert_nil(storage.get(manager.LIST_CACHE_KEY),
			"the saved ETag file may have advanced: the next start must send a full request")
	end)

end)
