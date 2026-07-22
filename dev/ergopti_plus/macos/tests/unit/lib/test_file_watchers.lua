--- tests/unit/lib/test_file_watchers.lua

--- ==============================================================================
--- MODULE: lib/file_watchers smoke contract
--- DESCRIPTION:
--- The auto-reload watchers were extracted from init.lua Section 7 into
--- lib/file_watchers. The Lua suite never loads init.lua, so without this test a
--- missing require, a renamed dep, or a typo in M.start would only surface as a
--- boot failure on the maintainer's Mac. This exercises M.start under stubbed
--- hs.pathwatcher/timer/fs so the require graph + arming logic are verified, and
--- asserts each armed watcher is pinned in _G.script_watchers (the GC root the
--- shutdown callback stops).
--- ==============================================================================

local helpers = require("tests.helpers")

-- ui_restore is UI glue not meant to load headless; mock it so the test isolates
-- file_watchers' own logic. notifications/i18n load fine under the stub harness.
package.loaded["lib.ui_restore"] = {
	defer_reload = function(fn) if type(fn) == "function" then fn() end end,
	snapshot     = function() end,
	restore      = function() end,
}

helpers.describe("lib/file_watchers — arming contract", function()
	helpers.it("loads and exposes start()", function()
		package.loaded["lib.file_watchers"] = nil
		local FW = require("lib.file_watchers")
		helpers.assert_true(type(FW.start) == "function", "must expose start()")
	end)

	helpers.it("arms watchers and pins them all in _G.script_watchers", function()
		local FW = require("lib.file_watchers")

		-- Stub the OS-touching hs surface M.start uses.
		local prev_pw, prev_timer, prev_attr = hs.pathwatcher, hs.timer, hs.fs.attributes
		local armed = 0
		hs.pathwatcher = { new = function(_path, _cb)
			return { start = function() armed = armed + 1 end }
		end }
		hs.timer = { doAfter = function(_s, _fn) return { stop = function() end } end, secondsSinceEpoch = function() return 0 end }
		-- No personal dir tree, no per-file entries: attributes returns nil so the
		-- recursive personal scan early-returns; fs_dir over an unset dir yields none.
		hs.fs.attributes = function(_p) return nil end

		_G.script_watchers = nil
		local ok, err = pcall(FW.start, {
			hotstrings_dir = "/fake/hotstrings/",
			base_dir = "/fake/base/",
			personal_hotstrings_dir = "/fake/personal",
		})

		hs.pathwatcher, hs.timer, hs.fs.attributes = prev_pw, prev_timer, prev_attr

		helpers.assert_true(ok, "start() must not throw: " .. tostring(err))
		helpers.assert_true(type(_G.script_watchers) == "table", "_G.script_watchers must be populated")
		-- dir_watcher + project_watcher at minimum (personal dir absent in this stub).
		helpers.assert_true(#_G.script_watchers >= 2 and #_G.script_watchers == armed,
			"every armed watcher must be pinned in _G.script_watchers (armed=" .. armed
			.. ", pinned=" .. #_G.script_watchers .. ")")
		_G.script_watchers = nil
	end)

	helpers.it("watch_personal_hotstrings_dir terminates on a self-referential directory cycle (F-LOW-4)", function()
		-- Simulate a self-referential symlink under the personal-hotstrings tree:
		-- every directory contains one further "loop" entry that resolves back to
		-- a directory again — a growing-path cycle indistinguishable, from this
		-- module's point of view, from a real filesystem symlink loop. Before the
		-- depth guard, M.start would recurse until Lua's C-stack limit aborted.
		local prev_fs_dir = package.loaded["lib.fs_dir"]
		package.loaded["lib.fs_dir"] = {
			entries = function(_dir) return { "loop" } end,
		}
		package.loaded["lib.file_watchers"] = nil
		local FW = require("lib.file_watchers")

		local prev_pw, prev_timer, prev_attr = hs.pathwatcher, hs.timer, hs.fs.attributes
		hs.pathwatcher = { new = function(_path, _cb)
			return { start = function() end }
		end }
		hs.timer = { doAfter = function(_s, _fn) return { stop = function() end } end, secondsSinceEpoch = function() return 0 end }
		-- Every path in this fixture is a directory — there is no file to bottom
		-- out on, so only the depth guard can stop the recursion.
		hs.fs.attributes = function(_p) return { mode = "directory" } end

		_G.script_watchers = nil
		local ok, err = pcall(FW.start, {
			hotstrings_dir = "/fake/hotstrings/",
			base_dir = "/fake/base/",
			personal_hotstrings_dir = "/fake/personal",
		})

		hs.pathwatcher, hs.timer, hs.fs.attributes = prev_pw, prev_timer, prev_attr
		package.loaded["lib.fs_dir"] = prev_fs_dir
		package.loaded["lib.file_watchers"] = nil
		_G.script_watchers = nil

		helpers.assert_true(ok, "start() must terminate and not throw/hang on a directory cycle: " .. tostring(err))
	end)
end)
