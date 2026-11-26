--- tests/unit/settings/test_file_watchers_git_hold.lua

--- ==============================================================================
--- MODULE: File Watchers Git Hold Tests
--- DESCRIPTION:
--- A Git operation marker holds the Linux reload for as long as it exists, as on
--- Windows and macOS (_shared/core/lifecycle/engine/reload/gate.lua). The
--- watcher used to count its quiet re-polls and reload anyway after 60 s with
--- the lock still present, which loads a half-updated tree in the middle of a
--- long rebase. These tests drive the real pump backend over a real tree whose
--- .git holds index.lock, with an injected clock.
--- ==============================================================================

package.loaded["tests.support.infra.config.file_watchers_fixture"] = nil
local Fixture = require("tests.support.infra.config.file_watchers_fixture")
local helpers, CAN_STAT = Fixture.helpers, Fixture.CAN_STAT
local Gate = require("core.lifecycle.engine.reload.gate")
local Logger = require("core.logger.engine.shim")

--- Builds a repository-shaped tree: .git/HEAD and one hotstring TOML.
--- @return string root
local function repository_tree()
	local root = Fixture.make_temp_dir()
	assert(os.execute("mkdir -p '" .. root .. "/.git' '" .. root .. "/hotstrings'"))
	Fixture.write_file(root .. "/.git/HEAD", "ref: refs/heads/dev\n")
	Fixture.write_file(root .. "/hotstrings/a.toml", '[personal.a]\ntrigger = "a"\n')
	assert(os.execute("touch -d '@1700000000' '" .. root .. "/hotstrings/a.toml'"))
	return root
end

--- Runs a scenario against a started pump-mode watcher and counts its warnings.
--- @param callback function Receives the session { root, pump(ms), reloads(), warns }.
local function with_watcher(callback)
	local root = repository_tree()
	local now, reloads, warns = 1000, 0, {}
	local original_warn = Logger.warn
	Logger.warn = function(tag, format, ...)
		if tag == "file_watchers" then warns[#warns + 1] = string.format(format, ...) end
		return original_warn(tag, format, ...)
	end
	local watcher
	local ok, err = xpcall(function()
		watcher = helpers.load_module_with_dependency("core.fs.engine.file_watchers", "luv", false)
		watcher.start({
			now_ms = function() return now end,
			hotstrings_dir = root .. "/hotstrings",
			base_dir = root,
			on_reload = function() reloads = reloads + 1 end,
		})
		watcher.pump()
		helpers.assert_eq(reloads, 0, "the unmodified source must not reload")
		callback({
			root = root,
			warns = warns,
			reloads = function() return reloads end,
			pump = function(ms) now = now + ms; watcher.pump() end,
			stop = function() return watcher.stop() end,
		})
	end, debug.traceback)
	local stopped, stop_error = true, nil
	if watcher then stopped, stop_error = pcall(watcher.stop) end
	Logger.warn = original_warn
	Fixture.rm_dir(root)
	helpers.assert_true(ok, tostring(err))
	helpers.assert_true(stopped, tostring(stop_error))
end

helpers.describe("file_watchers Git hold", function()
	if not CAN_STAT then
		print("  [Git hold not executed: stat(1) unavailable]")
		return
	end

	helpers.it("(linux-git-hold-never-expires) holds past the stale delay with one warning, then reloads after the quiet period", function()
		with_watcher(function(s)
			Fixture.write_file(s.root .. "/.git/index.lock", "")
			assert(os.execute("touch -d '@1700000100' '" .. s.root .. "/hotstrings/a.toml'"))
			s.pump(0)
			-- Twenty seconds past the report delay: the old cap reloaded at 60 s.
			for _ = 1, (Gate.GIT_HOLD_REPORT_SEC + 20) * 2 do
				s.pump(500)
				helpers.assert_eq(s.reloads(), 0, "a live index.lock is never reloaded through")
			end
			helpers.assert_eq(#s.warns, 1, "the stale lock is reported exactly once:\n" .. table.concat(s.warns, "\n"))
			helpers.assert_contains(s.warns[1], "stale lock")
			assert(os.remove(s.root .. "/.git/index.lock"))
			s.pump(500)
			helpers.assert_eq(s.reloads(), 0, "the released lock restarts the quiet window")
			s.pump(500)
			helpers.assert_eq(s.reloads(), 1, "the edit reloads once the tree was quiet after the release")
			helpers.assert_eq(#s.warns, 1, "the released hold adds no warning")
		end)
	end)

	helpers.it("(linux-git-hold-never-expires) warns when it stops during a hold", function()
		with_watcher(function(s)
			Fixture.write_file(s.root .. "/.git/index.lock", "")
			assert(os.execute("touch -d '@1700000100' '" .. s.root .. "/hotstrings/a.toml'"))
			s.pump(0)
			s.pump(500)
			helpers.assert_eq(s.reloads(), 0)
			helpers.assert_eq(#s.warns, 0, "a fresh hold is not yet a stale lock")
			helpers.assert_true(s.stop(), "the watcher retires")
			helpers.assert_eq(#s.warns, 1, "stopping during a hold names the interrupted hold")
			helpers.assert_contains(s.warns[1], "held their reload")
		end)
	end)
end)
