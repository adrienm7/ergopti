--- tests/unit/lib/test_file_watchers.lua

--- ==============================================================================
--- MODULE: infra/file_watchers smoke contract
--- DESCRIPTION:
--- The auto-reload watchers were extracted from init.lua Section 7 into
--- infra/file_watchers. The Lua suite never loads init.lua, so without this test a
--- missing require, a renamed dep, or a typo in M.start would only surface as a
--- boot failure on the maintainer's Mac. This exercises M.start under stubbed
--- hs.pathwatcher/timer/fs so the require graph + arming logic are verified, and
--- asserts each armed watcher is pinned in _G.script_watchers (the GC root the
--- shutdown callback stops).
--- ==============================================================================

local helpers = require("tests.helpers")

-- ui_restore is UI glue not meant to load headless; mock it so the test isolates
-- file_watchers' own logic. notifications/i18n load fine under the stub harness.
package.loaded["infra.ui_restore"] = {
	defer_reload = function(fn) if type(fn) == "function" then fn() end end,
	snapshot     = function() end,
	restore      = function() end,
}

helpers.describe("infra/file_watchers — arming contract", function()
	helpers.it("loads and exposes start()", function()
		package.loaded["infra.file_watchers"] = nil
		local FW = require("infra.file_watchers")
		helpers.assert_true(type(FW.start) == "function", "must expose start()")
	end)

	helpers.it("arms watchers under one pinned lifecycle owner", function()
		local FW = require("infra.file_watchers")

		-- Stub the OS-touching hs surface M.start uses.
		local prev_pw, prev_timer, prev_attr = hs.pathwatcher, hs.timer, hs.fs.attributes
		local armed, stopped = 0, 0
		hs.pathwatcher = { new = function(_path, _cb)
			local watcher = {}
			function watcher:start() armed = armed + 1; return watcher end
			function watcher:stop() stopped = stopped + 1; return watcher end
			return watcher
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
		-- One owner prevents the shared debounce timer from becoming an
		-- order-dependent sibling of the native pathwatchers at teardown.
		helpers.assert_eq(1, #_G.script_watchers, "one composite owner must be pinned")
		helpers.assert_eq(true, _G.script_watchers[1]:stop(), "the owner must settle native cleanup")
		helpers.assert_eq(armed, stopped, "the owner must transitively stop every armed watcher")
		_G.script_watchers = nil
	end)

	helpers.it("covers personal_info.toml exactly once in the bundle-fallback topology", function()
		local saved_file_watchers = package.loaded["infra.file_watchers"]
		local saved_pathwatcher = hs.pathwatcher
		local saved_timer = hs.timer
		local saved_roots = rawget(_G, "script_watchers")
		local paths = {}
		local callbacks = {}
		local timer_arms = 0
		local clock = 0

		hs.pathwatcher = { new = function(path, callback)
			paths[#paths + 1] = path
			callbacks[#callbacks + 1] = callback
			local watcher = {}
			function watcher:start() return watcher end
			function watcher:stop() return watcher end
			return watcher
		end }
		hs.timer = {
			doAfter = function(_delay, _callback)
				timer_arms = timer_arms + 1
				return { stop = function() end }
			end,
			secondsSinceEpoch = function() return clock end,
		}

		local ok, err = xpcall(function()
			package.loaded["infra.file_watchers"] = nil
			_G.script_watchers = nil
			local FileWatchers = require("infra.file_watchers")
			helpers.assert_true(FileWatchers.start({
				hotstrings_dir = "/bundle/hotstrings/",
				base_dir = "/bundle/macos/",
				personal_hotstrings_dir = "/config/hotstrings/",
				personal_info_path = "/config/personal_info.toml",
			}))
			helpers.assert_eq(#paths, 4,
				"fallback must add one required watcher beyond the three normal roots")
			helpers.assert_eq(paths[3], "/config/personal_info.toml")
			clock = 10
			callbacks[3]({ "/config/unrelated.toml" })
			helpers.assert_eq(timer_arms, 0,
				"the exact watcher must ignore unrelated sibling changes")
			callbacks[3]({ "/config/personal_info.toml" })
			helpers.assert_eq(timer_arms, 1,
				"an external personal-info edit must enter the normal reload debounce")
			helpers.assert_true(_G.script_watchers[1]:stop())

			paths, callbacks, timer_arms, clock = {}, {}, 0, 0
			_G.script_watchers = nil
			helpers.assert_true(FileWatchers.start({
				hotstrings_dir = "/config/",
				base_dir = "/bundle/macos/",
				personal_hotstrings_dir = "/config/hotstrings/",
				personal_info_path = "/config/personal_info.toml",
			}))
			helpers.assert_eq(#paths, 3,
				"the recursive config watcher must prevent a duplicate personal-info owner")
			helpers.assert_true(_G.script_watchers[1]:stop())
		end, debug.traceback)

		package.loaded["infra.file_watchers"] = saved_file_watchers
		hs.pathwatcher = saved_pathwatcher
		hs.timer = saved_timer
		_G.script_watchers = saved_roots
		if not ok then error(err, 0) end
	end)

	helpers.it("revokes a pending reload before teardown and retains failed timer cleanup for retry", function()
		for _, failure in ipairs({ "false", "throw" }) do
			package.loaded["infra.file_watchers"] = nil
			local FW = require("infra.file_watchers")
			local prev_pw, prev_timer, prev_attr, prev_reload =
				hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload
			local callbacks = {}
			local reloads = 0
			local timer_stops = 0
			local pending_callback
			local clock = 0

			hs.pathwatcher = { new = function(_path, callback)
				callbacks[#callbacks + 1] = callback
				local watcher = {}
				function watcher:start() return watcher end
				function watcher:stop() return watcher end
				return watcher
			end }
			hs.timer = {
				doAfter = function(_delay, callback)
					pending_callback = callback
					local timer = {}
					function timer:stop()
						timer_stops = timer_stops + 1
						if timer_stops == 1 then
							if failure == "throw" then error("timer stop failed") end
							return false
						end
						return timer
					end
					return timer
				end,
				secondsSinceEpoch = function() return clock end,
			}
			hs.fs.attributes = function(_path) return nil end
			hs.reload = function() reloads = reloads + 1 end

			_G.script_watchers = nil
			FW.start({
				hotstrings_dir = "/fake/hotstrings/",
				base_dir = "/fake/base/",
				personal_hotstrings_dir = "/fake/personal",
			})
			helpers.assert_eq(1, #_G.script_watchers,
				"one lifecycle owner must own every native watcher and the shared debounce timer")
			clock = 10
			callbacks[#callbacks]({ "/fake/base/modules/change.lua" })
			helpers.assert_true(type(pending_callback) == "function", "a relevant change must arm the debounce")

			local owner = _G.script_watchers[1]
			helpers.assert_eq(false, owner:stop(),
				"a failed timer cancellation must keep the exact owner retryable (" .. failure .. ")")
			pending_callback()
			helpers.assert_eq(0, reloads,
				"a callback already queued by macOS must be inert after logical teardown (" .. failure .. ")")
			helpers.assert_eq(true, owner:stop(),
				"the retained timer capability must settle on a later retry (" .. failure .. ")")
			helpers.assert_eq(2, timer_stops,
				"cleanup must retry the same timer exactly once after failure (" .. failure .. ")")

			hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload =
				prev_pw, prev_timer, prev_attr, prev_reload
			_G.script_watchers = nil
		end
	end)

	helpers.it("watch_personal_hotstrings_dir terminates on a self-referential directory cycle (F-LOW-4)", function()
		-- Simulate a self-referential symlink under the personal-hotstrings tree:
		-- every directory contains one further "loop" entry that resolves back to
		-- a directory again — a growing-path cycle indistinguishable, from this
		-- module's point of view, from a real filesystem symlink loop. Before the
		-- depth guard, M.start would recurse until Lua's C-stack limit aborted.
		local prev_fs_dir = package.loaded["infra.fs_dir"]
		package.loaded["infra.fs_dir"] = {
			entries = function(_dir) return { "loop" } end,
		}
		package.loaded["infra.file_watchers"] = nil
		local FW = require("infra.file_watchers")

		local prev_pw, prev_timer, prev_attr = hs.pathwatcher, hs.timer, hs.fs.attributes
		hs.pathwatcher = { new = function(_path, _cb)
			local watcher = {}
			function watcher:start() return self end
			function watcher:stop() return nil end
			return watcher
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
		package.loaded["infra.fs_dir"] = prev_fs_dir
		package.loaded["infra.file_watchers"] = nil
		_G.script_watchers = nil

		helpers.assert_true(ok, "start() must terminate and not throw/hang on a directory cycle: " .. tostring(err))
	end)
end)
