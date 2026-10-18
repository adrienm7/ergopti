--- tests/unit/infra/config/test_file_watchers_native_backend.lua

---
--- Unit tests for infra/file_watchers.lua. Exercises the public API —
--- has_inotify(), start/stop lifecycle, debounce deadline logic, and
--- pump-mode mtime polling — by creating a real temporary directory
--- with .toml files and driving changes through M.pump().
---
--- When stat(1) is unavailable, the mtime-dependent tests are skipped
--- gracefully because _mtime() returns nil and the pump backend silently
--- no-ops. On Windows the test mode runs the watcher's date, ls and test
--- through Git's sh and coreutils, so they run there too. Lifecycle and
--- API contract tests always run.
---
--- NOTE: polling fixtures explicitly hide luv only while loading a fresh module, so
--- module-level state (_on_reload, _pump_entries, _reload_deadline)
--- resets between test cases.

package.loaded["tests.support.infra.config.file_watchers_fixture"] = nil
local Fixture = require("tests.support.infra.config.file_watchers_fixture")
local helpers, reload_gate, native_ok, native_luv, make_temp_dir, make_non_tmp_dir, write_file, touch_file, rm_dir, sleep_sec, CAN_STAT, activation_fixture =
	Fixture.helpers, Fixture.reload_gate, Fixture.native_ok, Fixture.native_luv, Fixture.make_temp_dir, Fixture.make_non_tmp_dir, Fixture.write_file, Fixture.touch_file, Fixture.rm_dir, Fixture.sleep_sec, Fixture.CAN_STAT, Fixture.activation_fixture




helpers.describe("file watchers native backend", function()
	helpers.it("native callbacks filter, debounce and close every watcher", function()
		local dir = make_temp_dir()
		local armed, stopped, closed = {}, 0, 0
		local uv = {
			new_fs_event = function() return {} end,
			fs_event_start = function(handle, watched, _, callback)
				armed[#armed + 1] = { handle = handle, path = watched, callback = callback }
				return 0
			end,
			fs_event_stop = function() stopped = stopped + 1 end,
			close = function() closed = closed + 1 end,
		}
		local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", uv)
		local now, fired = 0, 0
		local ok, err = pcall(function()
			fw.start({ hotstrings_dir = dir, now_ms = function() return now end,
				on_reload = function() fired = fired + 1 end })
			helpers.assert_true(fw.has_inotify(), "present dependency selects native watchers")
			helpers.assert_eq(#armed, 1, "empty directory still needs its creation watcher")
			armed[1].callback("fixture read failure", "new.toml", { "change" })
			armed[1].callback(nil, "ignored.txt", { "change" })
			now = 1000
			fw.pump()
			helpers.assert_eq(fired, 0, "errors and non-TOML events must not reload")
			armed[1].callback(nil, "new.toml", { "rename" })
			fw.pump()
			helpers.assert_eq(fired, 0, "accepted native event must wait for debounce")
			now = 10000
			fw.pump()
			fw.pump()
			helpers.assert_eq(fired, 1, "accepted event must dispatch exactly once")
		end)
		fw.stop()
		fw.stop()
		rm_dir(dir)
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(stopped, #armed, "stop must stop every native watcher once")
		helpers.assert_eq(closed, #armed, "stop must close every native watcher once")
	end)

	if native_ok then
		helpers.it("installed luv observes a real TOML creation through inotify", function()
			local dir = make_temp_dir()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", native_luv)
			local now, fired = 0, 0
			local ok, err = pcall(function()
				fw.start({ hotstrings_dir = dir, now_ms = function() return now end,
					on_reload = function() fired = fired + 1 end })
				helpers.assert_true(fw.has_inotify(), "use the installed native backend")
				helpers.assert_true(write_file(dir .. "/native.toml"), "create a real watched file")
				local deadline = native_luv.hrtime() + 2000000000
				repeat
					native_luv.run("nowait")
					now = now + 10000
					fw.pump()
				until fired > 0 or native_luv.hrtime() >= deadline
			end)
			fw.stop()
			native_luv.run("nowait")
			rm_dir(dir)
			helpers.assert_true(ok, tostring(err))
			helpers.assert_eq(fired, 1, "real inotify event must reach the reload callback")
		end)
	else
		print("  [native inotify integration unavailable; callback fixtures still run]")
	end
end)




-- ======================================================================
-- Subsecond polling receipts (real files, fixed timestamps, no sleeps)
-- ======================================================================

helpers.describe("file_watchers subsecond polling", function()
	local posix_ok, native_posix = pcall(require, "posix")
	local epoch_seconds = 1700000000
	local receipts = {
		{ name = "scalar mtime", shape = function() return { mtime = epoch_seconds } end },
		{ name = "scalar modification", shape = function() return { modification = epoch_seconds } end },
		{ name = "incomplete timespec", shape = function() return { mtime = { sec = epoch_seconds } } end },
		{ name = "complete timespec", precise = true,
			shape = function(nanoseconds) return { mtime = { sec = epoch_seconds, nsec = nanoseconds } } end },
	}
	if posix_ok and type(native_posix.stat) == "function" then
		receipts[#receipts + 1] = { name = "installed posix", native = true }
	else
		print("  [native posix integration unavailable; fixed-mtime receipt fixtures still run]")
	end

	for _, receipt in ipairs(receipts) do
		helpers.it("file_watchers subsecond polling: detects same-second edits with " .. receipt.name, function()
			local dir = make_temp_dir()
			local basename = "collision's.toml"
			local path = dir .. "/" .. basename
			local quoted_path = "'" .. path:gsub("'", "'\\''") .. "'"
			local held_popen = io.popen
			local previous_watcher = package.loaded["infra.file_watchers"]
			local previous_posix, previous_preload = package.loaded["posix"], package.preload["posix"]
			local watcher, now_ms, fired, nanoseconds, precision_reads = nil, 0, 0, 100000000, 0
			local function set_timestamp(fraction)
				local timestamp = tostring(epoch_seconds) .. "." .. fraction
				local result = os.execute("touch -m -d '@" .. timestamp .. "' " .. quoted_path)
				helpers.assert_true(result == true or result == 0, "fixed file timestamp must be acknowledged")
				local pipe = held_popen("date -r " .. quoted_path .. " +%s.%N", "r")
				helpers.assert_true(pipe ~= nil, "read the actual kernel file timestamp independently")
				local observed = pipe:read("*a")
				local closed = pipe:close()
				helpers.assert_true(closed == true or closed == 0, "timestamp reader must exit successfully")
				helpers.assert_eq(observed, timestamp .. "\n", "real file must hold the exact prescribed timestamp")
				nanoseconds = tonumber(fraction)
			end
			local ok, err = pcall(function()
				helpers.assert_true(write_file(path), "create the real watched TOML")
				set_timestamp("100000000")
				if not receipt.native then
					package.loaded["posix"] = {
						stat = function(candidate)
							if candidate == dir then return { type = "directory" } end
							if candidate == path then return receipt.shape(nanoseconds) end
						end,
						dir = function(candidate)
							helpers.assert_eq(candidate, dir, "scan only the owned fixture")
							return { basename }
						end,
					}
				end
				io.popen = function(command, ...)
					if command:find("date -r " .. quoted_path .. " ", 1, true) == 1 then
						precision_reads = precision_reads + 1
					end
					return held_popen(command, ...)
				end
				watcher = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				watcher.start({ hotstrings_dir = dir, now_ms = function() return now_ms end,
					on_reload = function() fired = fired + 1 end })
				helpers.assert_true(not watcher.has_inotify(), "exercise the real polling producer")
				watcher.pump()
				helpers.assert_eq(fired, 0, "unchanged baseline must not reload")
				for index, fraction in ipairs({ "200000000", "300000000" }) do
					set_timestamp(fraction)
					watcher.pump()
					helpers.assert_eq(fired, index - 1, "same-second edit must wait for debounce")
					now_ms = now_ms + 600
					watcher.pump()
					helpers.assert_eq(fired, index, "each settled same-second edit must reload exactly once")
					watcher.pump()
					helpers.assert_eq(fired, index, "unchanged timestamp must not repeat a reload")
				end
				if receipt.precise then
					helpers.assert_eq(precision_reads, 0, "complete native timespec retains its shell-free precision")
				elseif not receipt.native then
					helpers.assert_true(precision_reads > 0, "coarse receipts must reach the subsecond reader")
				end
			end)
			local stopped, stop_error = true, nil
			if watcher then stopped, stop_error = pcall(watcher.stop) end
			io.popen = held_popen
			package.loaded["infra.file_watchers"] = previous_watcher
			package.loaded["posix"], package.preload["posix"] = previous_posix, previous_preload
			local removed = os.execute("rm -rf '" .. dir:gsub("'", "'\\''") .. "'")
			helpers.assert_true(ok, tostring(err))
			helpers.assert_true(stopped, tostring(stop_error))
			helpers.assert_true(removed == true or removed == 0, "owned fixture removal must be acknowledged")
		end)
	end
end)




helpers.describe("linux-watch-activation-receipts", function()
	for _, receipt in ipairs({
		{ name = "EACCES", reason = "EACCES: permission denied", code = "EACCES" },
		{ name = "ENOSPC", reason = "ENOSPC: watch limit reached", code = "ENOSPC" },
		{ name = "ENOENT", reason = "ENOENT: path disappeared", code = "ENOENT" },
		{ name = "false", value = false, reason = "native refusal", code = "EIO" },
		{ name = "throw", throws = true, reason = "native activation threw" },
	}) do
		helpers.it("linux-watch-activation-receipts: retires " .. receipt.name .. " before reporting ownership", function()
			local watcher, state = activation_fixture(receipt)
			watcher.start({ base_dir = "/source", on_reload = function() error("unarmed watcher reloaded") end })
			helpers.assert_eq(state.starts, 1, "the production activation site must be exercised")
			helpers.assert_eq(state.closes, 1, "refusal must immediately retire the candidate")
			helpers.assert_true(state.handles[1].closed)
			helpers.assert_eq(#state.warnings, 1)
			helpers.assert_contains(state.warnings[1], receipt.reason)
			helpers.assert_contains(state.summaries[1], "0 handle(s)")
			watcher.stop()
			helpers.assert_eq(state.closes, 1, "refused handle cannot remain in the committed registry")
			helpers.assert_eq(state.stops, 0)
		end)
	end
	for _, value in ipairs({ 0, true }) do
		helpers.it("linux-watch-activation-receipts: owns native success " .. tostring(value), function()
			local watcher, state = activation_fixture({ value = value })
			watcher.start({ base_dir = "/source" })
			helpers.assert_eq(state.starts, 1)
			helpers.assert_eq(state.closes, 0)
			helpers.assert_eq(#state.warnings, 0)
			helpers.assert_contains(state.summaries[1], "1 handle(s)")
			watcher.stop()
			helpers.assert_eq(state.stops, 1)
			helpers.assert_eq(state.closes, 1)
			watcher.stop()
			helpers.assert_eq(state.closes, 1, "successful ownership is released once")
		end)
	end
end)




helpers.describe("file_watchers", function()

	-- ======================================================================
	-- 1. has_inotify()
	-- ======================================================================

	helpers.describe("has_inotify", function()

		helpers.it("returns a boolean", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			helpers.assert_type(fw.has_inotify(), "boolean")
		end)

		helpers.it("is stable across calls", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local a = fw.has_inotify()
			local b = fw.has_inotify()
			helpers.assert_eq(a, b, "has_inotify must return the same value every call")
		end)
	end)


	-- ======================================================================
	-- 2. Lifecycle: start() / stop() idempotency
	-- ======================================================================

	helpers.describe("lifecycle", function()

		helpers.it("stop() before start() is safe (no-op)", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			fw.stop()
		end)

		helpers.it("stop() is idempotent (second call no-op)", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			fw.stop()
			fw.stop()
		end)

		helpers.it("start() then stop() then restart() works", function()
			local dir = make_temp_dir()
			write_file(dir .. "/test.toml")
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({ hotstrings_dir = dir, on_reload = function() fired = fired + 1 end })
			fw.stop()
			local fired2 = 0
			fw.start({ hotstrings_dir = dir, on_reload = function() fired2 = fired2 + 1 end })
			fw.stop()
			rm_dir(dir)
			helpers.assert_eq(fired + fired2, 0, "should not fire before any change")
		end)

		helpers.it("start() with empty opts is a no-op", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			fw.start({})
			fw.pump()
			fw.stop()
		end)

		helpers.it("start() with nil opts is a no-op", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			fw.start(nil)
			fw.pump()
			fw.stop()
		end)

		helpers.it("start() with no readable directories still finishes gracefully", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({
				hotstrings_dir = "/nonexistent/path/xyz",
				base_dir       = "/also/nonexistent/lua",
				on_reload      = function() fired = fired + 1 end,
			})
			fw.pump()
			fw.stop()
			helpers.assert_eq(fired, 0, "no callback when dirs don't exist")
		end)
	end)


	-- ======================================================================
	-- 3. start() with a real directory (pump mode)
	-- ======================================================================

	helpers.describe("start (pump mode)", function()

		helpers.it("pump() with no entries is a no-op (no crash)", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({ on_reload = function() fired = fired + 1 end })
			fw.pump()
			fw.pump()
			fw.stop()
			helpers.assert_eq(fired, 0, "should not fire with no dirs")
		end)

		helpers.it("creates per-file entries for each .toml in the hotstrings dir", function()
			local dir = make_temp_dir()
			write_file(dir .. "/a.toml")
			write_file(dir .. "/b.toml")
			write_file(dir .. "/not_a_toml.txt", "ignored")
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({ hotstrings_dir = dir, on_reload = function() fired = fired + 1 end })
			fw.pump()
			fw.stop()
			rm_dir(dir)
			helpers.assert_eq(fired, 0, "no callback without file changes")
		end)

		helpers.it("skips directories with no .toml files", function()
			local dir = make_temp_dir()
			write_file(dir .. "/readme.txt", "hello")
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({ hotstrings_dir = dir, on_reload = function() fired = fired + 1 end })
			fw.pump()
			fw.pump()
			fw.stop()
			rm_dir(dir)
			helpers.assert_eq(fired, 0, "no .toml → nothing to watch → no callback")
		end)
	end)


	-- ======================================================================
	-- 4. File change detection (pump mode — requires stat(1))
	-- ======================================================================

	helpers.describe("file change detection", function()

		if not CAN_STAT then
			helpers.it("SKIP [CONF-LINUX-STAT-MTIME] — stat(1) not available on this system (tests require mtime detection)", function()
				-- A skip must still assert the reason it skipped for. An empty body
				-- reports a PASS, indistinguishable from the real test running — so a
				-- broken _can_stat() probe would silently disable this whole section
				-- on a machine that CAN stat.
				helpers.assert_true(not CAN_STAT,
					"this branch runs only when stat(1) is unavailable; CAN_STAT says otherwise")
			end)
		else
			helpers.it("fires on_reload after .toml mtime changes and deadline passes", function()
				local dir = make_temp_dir()
				write_file(dir .. "/hotstrings.toml")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired_count = 0
				-- Drive the debounce deadline through an injected wall clock so the
				-- test is deterministic and independent of os.clock semantics.
				local now_ms = 1000
				fw.start({
					hotstrings_dir = dir,
					now_ms = function() return now_ms end,
					on_reload = function() fired_count = fired_count + 1 end,
				})

				fw.pump()
				helpers.assert_eq(fired_count, 0, "baseline pump must not fire")

				sleep_sec(0.1)
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
				helpers.assert_eq(fired_count, 0, "deadline not yet passed — should not fire")

				now_ms = now_ms + 600 -- advance the clock past the 500 ms deadline
				fw.pump()
				helpers.assert_eq(fired_count, 1, "should fire exactly once after deadline")

				fw.stop()
				rm_dir(dir)
			end)

			helpers.it("debounces — multiple rapid changes fire only once", function()
				local dir = make_temp_dir()
				write_file(dir .. "/hotstrings.toml")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired_count = 0
				local now_ms = 1000
				fw.start({
					hotstrings_dir = dir,
					now_ms = function() return now_ms end,
					on_reload = function() fired_count = fired_count + 1 end,
				})

				fw.pump()
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()

				helpers.assert_eq(fired_count, 0, "debounce extends deadline on each change")

				now_ms = now_ms + 600 -- past the (repeatedly re-armed) deadline
				fw.pump()
				helpers.assert_eq(fired_count, 1, "debounce collapsed 3 changes into 1 callback")

				fw.stop()
				rm_dir(dir)
			end)

			-- Regression: a BULK write (git pull, OneDrive/Dropbox sync, rsync, mass
			-- save) touches many files with gaps a plain 0.5s debounce cannot bridge,
			-- so the daemon would re-scan a half-written config. The adaptive settle
			-- holds a many-file burst until the long bulk window of quiet
			-- (macos-reload-during-git-pull).
			helpers.it("holds a many-file bulk burst until the bulk settle window", function()
				local dir = make_temp_dir()
				local N = reload_gate.BULK_THRESHOLD + 5
				for i = 1, N do write_file(dir .. "/g" .. i .. ".toml") end
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired_count = 0
				local now_ms = 1000
				fw.start({
					hotstrings_dir = dir,
					now_ms = function() return now_ms end,
					on_reload = function() fired_count = fired_count + 1 end,
				})

				fw.pump() -- baseline stat of every entry
				sleep_sec(0.1)
				for i = 1, N do touch_file(dir .. "/g" .. i .. ".toml") end
				fw.pump() -- detects the bulk change, arms the settle
				helpers.assert_eq(fired_count, 0, "not fired before the deadline")

				-- Past the 500 ms poll but only the lone-edit window of quiet: a bulk
				-- burst must STILL be held.
				now_ms = now_ms + 600
				fw.pump()
				helpers.assert_eq(fired_count, 0, "a bulk burst must NOT fire after only the edit settle window")

				-- Once the bulk-settle window of quiet has elapsed, it fires exactly once.
				now_ms = now_ms + math.floor(reload_gate.BULK_SETTLE_SEC * 1000) + 100
				fw.pump()
				helpers.assert_eq(fired_count, 1, "the bulk write fires once settled")

				fw.stop()
				rm_dir(dir)
			end)

			helpers.it("detects .lua file changes in base_dir", function()
				-- The debounce deadline runs on an injected clock: no real second of waiting.
				local now_ms = 1000
				local dir = make_non_tmp_dir()
				write_file(dir .. "/init.lua", "return {}")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired_count = 0
				fw.start({ now_ms = function() return now_ms end, base_dir = dir, on_reload = function() fired_count = fired_count + 1 end })

				fw.pump()
				sleep_sec(0.1)
				touch_file(dir .. "/init.lua")
				fw.pump()
				now_ms = now_ms + 1000
				fw.pump()

				fw.stop()
				rm_dir(dir)
				helpers.assert_eq(fired_count, 1, ".lua file change in base_dir should fire on_reload")
			end)

			helpers.it("personal_dir with subdirectory .toml files is watched", function()
				-- The debounce deadline runs on an injected clock: no real second of waiting.
				local now_ms = 1000
				local dir = make_temp_dir()
				local sub = dir .. "/sub"
				os.execute("mkdir -p '" .. sub:gsub("'", "'\\''") .. "' 2>/dev/null")
				write_file(sub .. "/personal.toml")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired = 0
				fw.start({ now_ms = function() return now_ms end, personal_dir = dir, on_reload = function() fired = fired + 1 end })

				fw.pump()
				sleep_sec(0.1)
				touch_file(sub .. "/personal.toml")
				fw.pump()
				now_ms = now_ms + 1000
				fw.pump()

				fw.stop()
				rm_dir(dir)
				helpers.assert_eq(fired, 1, "personal_dir recursive scan found and watched subdirectory .toml")
			end)

			helpers.it("personal_dir empty (no .toml files) is a no-op", function()
				local dir = make_temp_dir()
				local sub = dir .. "/sub"
				os.execute("mkdir -p '" .. sub:gsub("'", "'\\''") .. "' 2>/dev/null")
				write_file(sub .. "/readme.txt", "hello")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired = 0
				fw.start({ personal_dir = dir, on_reload = function() fired = fired + 1 end })
				fw.pump()
				fw.pump()
				fw.stop()
				rm_dir(dir)
				helpers.assert_eq(fired, 0, "empty personal_dir should not fire")
			end)
		end
	end)


	-- ======================================================================
	-- 5. on_reload error handling
	-- ======================================================================

	helpers.describe("on_reload errors", function()

		if not CAN_STAT then
			helpers.it("SKIP [CONF-LINUX-STAT-MTIME] — stat(1) not available on this system", function()
				-- A skip must still assert the reason it skipped for. An empty body
				-- reports a PASS, indistinguishable from the real test running — so a
				-- broken _can_stat() probe would silently disable this whole section
				-- on a machine that CAN stat.
				helpers.assert_true(not CAN_STAT,
					"this branch runs only when stat(1) is unavailable; CAN_STAT says otherwise")
			end)
		else
			helpers.it("pcall-guards the callback so a thrown error never reaches pump()", function()
				-- The debounce deadline runs on an injected clock: no real second of waiting.
				local now_ms = 1000
				local dir = make_temp_dir()
				write_file(dir .. "/hotstrings.toml")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired = false
				fw.start({ now_ms = function() return now_ms end,
					hotstrings_dir = dir,
					on_reload = function() fired = true; error("INTENTIONAL CRASH IN CALLBACK") end,
				})

				fw.pump()
				sleep_sec(0.1)
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
				now_ms = now_ms + 1000
				fw.pump()
				helpers.assert_true(fired, "callback must have been called")

				local fired2 = false
				fw.stop()
				fw.start({ now_ms = function() return now_ms end, hotstrings_dir = dir, on_reload = function() fired2 = true end })
				fw.pump()
				sleep_sec(0.1)
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
				now_ms = now_ms + 1000
				fw.pump()
				helpers.assert_true(fired2, "file_watchers still usable after callback crash")

				fw.stop()
				rm_dir(dir)
			end)
		end
	end)


	-- ======================================================================
	-- 6. stop() cleanup
	-- ======================================================================

	helpers.describe("stop cleanup", function()

		helpers.it("clears all pump entries and the pending deadline", function()
			local dir = make_temp_dir()
			write_file(dir .. "/hotstrings.toml")
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({ hotstrings_dir = dir, on_reload = function() fired = fired + 1 end })

			fw.pump()
			if CAN_STAT then
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
			end

			fw.stop()
			fw.pump()
			helpers.assert_eq(fired, 0, "stop() cleared the pending deadline")

			rm_dir(dir)
		end)

		if not CAN_STAT then
			helpers.it("SKIP [CONF-LINUX-STAT-MTIME] — stat(1) not available for callback-after-restart test", function()
				-- A skip must still assert the reason it skipped for. An empty body
				-- reports a PASS, indistinguishable from the real test running — so a
				-- broken _can_stat() probe would silently disable this whole section
				-- on a machine that CAN stat.
				helpers.assert_true(not CAN_STAT,
					"this branch runs only when stat(1) is unavailable; CAN_STAT says otherwise")
			end)
		else
			helpers.it("stop() prevents old callback from firing after restart", function()
				-- The debounce deadline runs on an injected clock: no real second of waiting.
				local now_ms = 1000
				local dir = make_temp_dir()
				write_file(dir .. "/hotstrings.toml")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)

				local old_fired = 0
				fw.start({ now_ms = function() return now_ms end, hotstrings_dir = dir, on_reload = function() old_fired = old_fired + 1 end })
				fw.pump()
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()

				fw.stop()

				local new_fired = 0
				fw.start({ now_ms = function() return now_ms end, hotstrings_dir = dir, on_reload = function() new_fired = new_fired + 1 end })
				fw.pump()
				helpers.assert_eq(old_fired, 0, "old callback was cleared by stop()")
				helpers.assert_eq(new_fired, 0, "new callback not fired yet")

				sleep_sec(0.1)
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
				now_ms = now_ms + 1000
				fw.pump()
				helpers.assert_eq(old_fired, 0, "old callback never fired")
				helpers.assert_eq(new_fired, 1, "new callback fired exactly once")

				fw.stop()
				rm_dir(dir)
			end)
		end
	end)


	-- ======================================================================
	-- 7. base_dir and personal_dir API contract
	-- ======================================================================

	helpers.describe("base_dir and personal_dir", function()

		helpers.it("base_dir with no .lua files does not crash", function()
			local dir = make_temp_dir()
			write_file(dir .. "/readme.txt", "hello")
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({ base_dir = dir, on_reload = function() fired = fired + 1 end })
			fw.pump()
			fw.stop()
			rm_dir(dir)
			helpers.assert_eq(fired, 0)
		end)

		helpers.it("base_dir with .lua file does not crash on load", function()
			local dir = make_temp_dir()
			write_file(dir .. "/init.lua", "return {}")
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({ base_dir = dir, on_reload = function() fired = fired + 1 end })
			fw.pump()
			fw.stop()
			rm_dir(dir)
			helpers.assert_eq(fired, 0)
		end)

		helpers.it("personal_dir that does not exist is a no-op", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({ personal_dir = "/nonexistent_personal_dir", on_reload = function() fired = fired + 1 end })
			fw.pump()
			fw.stop()
			helpers.assert_eq(fired, 0)
		end)

		helpers.it("base_dir with temp files from /tmp is still safe", function()
			local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
			local fired = 0
			fw.start({ base_dir = "/tmp", on_reload = function() fired = fired + 1 end })
			fw.pump()
			fw.stop()
			-- If /tmp is accessible, it's watched but no .lua-specific filtering
			-- applies in pump mode. Just verify no crash.
			helpers.assert_eq(fired, 0)
		end)
	end)
end)

