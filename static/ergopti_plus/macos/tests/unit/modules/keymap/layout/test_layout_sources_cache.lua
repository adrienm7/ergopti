--- tests/unit/modules/keymap/layout/test_layout_sources_cache.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Sources Cache Tests (macOS)
--- DESCRIPTION:
--- The layout menu's disk reads are kept between rebuilds only while an
--- FSEvents watcher runs on every scope folder and has reported nothing since:
--- a watcher event or the driver's own install reads the disk again; an absent
--- folder or a watcher that cannot start keeps every read fresh; one owner.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "modules.keymap.layout_sources_cache", "core.fs.adapters.file_system", "core.logger.engine.logger" }

--- A fresh cache over fake folders and recording watchers.
--- @param folders table { [path] = true } the folders that exist.
--- @param refuse_watch boolean|nil Whether hs.pathwatcher.new raises.
local function fixture(folders, refuse_watch)
	local watchers = {}
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end
	local saved_hs = rawget(_G, "hs")
	package.loaded["modules.keymap.layout_sources_cache"] = nil
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["core.fs.adapters.file_system"] = {
		classify_no_follow = function(path)
			if folders[path] then return { mode = "directory" }, "ok" end
			return nil, "absent"
		end,
	}
	_G.hs = { pathwatcher = { new = function(path, callback)
		if refuse_watch then error("FSEvents refused") end
		local watcher = { path = path, callback = callback, running = false }
		function watcher:start() self.running = true; return self end
		function watcher:stop() self.running = false; return self end
		watchers[#watchers + 1] = watcher
		return watcher
	end } }
	local Cache = require("modules.keymap.layout_sources_cache")
	local function restore()
		for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
		_G.hs = saved_hs
	end
	return Cache, watchers, restore
end

local DIRS = { "/Library/Keyboard Layouts/", "/Users/me/Library/Keyboard Layouts/" }
local BOTH = { ["/Library/Keyboard Layouts"] = true, ["/Users/me/Library/Keyboard Layouts"] = true }

local function counting_read()
	local reads = 0
	return function()
		reads = reads + 1
		return { reads = reads }
	end, function() return reads end
end

helpers.describe("layout sources cache (menu_keyboard_layout.sources)", function()
	helpers.it("reads the disk once while both watched folders report nothing", function()
		local Cache, watchers, restore = fixture(BOTH)
		local ok, err = pcall(function()
			local owner = Cache.start(DIRS)
			helpers.assert_true(Cache.is_armed())
			helpers.assert_eq(#watchers, 2)
			helpers.assert_eq(watchers[1].path, "/Library/Keyboard Layouts")
			local read, reads = counting_read()
			local first = Cache.read(read)
			helpers.assert_true(Cache.read(read) == first, "a rebuild with nothing changed reads nothing")
			helpers.assert_eq(reads(), 1)
			helpers.assert_true(owner:stop())
		end)
		restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("reads again after an FSEvents report or the driver's own install", function()
		local Cache, watchers, restore = fixture(BOTH)
		local ok, err = pcall(function()
			local owner = Cache.start(DIRS)
			local read, reads = counting_read()
			Cache.read(read)
			-- A nested Info.plist rewritten in the same second as the last read.
			watchers[2].callback({ "/Users/me/Library/Keyboard Layouts/Ergopti_v2.2.2.bundle/Contents/Info.plist" })
			Cache.read(read)
			helpers.assert_eq(reads(), 2, "a watcher event invalidates")
			Cache.read(read)
			helpers.assert_eq(reads(), 2)
			Cache.invalidate("User install")
			Cache.read(read)
			helpers.assert_eq(reads(), 3, "an install invalidates without waiting for FSEvents")
			helpers.assert_true(owner:stop())
			helpers.assert_true(not watchers[1].running and not watchers[2].running, "stop ends both watchers")
			Cache.read(read)
			Cache.read(read)
			helpers.assert_eq(reads(), 5, "a stopped cache serves nothing")
			watchers[1].callback({})
		end)
		restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("keeps every read fresh when a folder is absent or cannot be watched", function()
		for _, case in ipairs({ { folders = { ["/Library/Keyboard Layouts"] = true } }, { folders = BOTH, refuse = true } }) do
			local Cache, watchers, restore = fixture(case.folders, case.refuse)
			local ok, err = pcall(function()
				local owner = Cache.start(DIRS)
				helpers.assert_true(owner ~= nil)
				helpers.assert_true(not Cache.is_armed())
				for _, watcher in ipairs(watchers) do helpers.assert_true(not watcher.running, "no watcher left running") end
				local read, reads = counting_read()
				Cache.read(read)
				Cache.read(read)
				helpers.assert_eq(reads(), 2, "no watcher, no cache")
				helpers.assert_true(owner:stop())
			end)
			restore()
			helpers.assert_true(ok, tostring(err))
		end
	end)

	helpers.it("refuses a second owner while one runs", function()
		local Cache, _, restore = fixture(BOTH)
		local ok, err = pcall(function()
			local owner = Cache.start(DIRS)
			helpers.assert_true(Cache.start(DIRS) == nil)
			helpers.assert_true(owner:stop())
			local again = Cache.start(DIRS)
			helpers.assert_true(again ~= nil, "a stopped owner frees the slot")
			helpers.assert_true(again:stop())
		end)
		restore()
		helpers.assert_true(ok, tostring(err))
	end)
end)

return true
