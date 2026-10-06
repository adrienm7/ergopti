--- tests/unit/meta/test_file_watchers.lua
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

local helpers = require("tests.helpers")
local reload_gate = require("reload_gate")
local native_ok, native_luv = pcall(require, "luv")

-- ------------------------------------------------------------------
-- Temp-directory helpers.  A sequence counter guarantees uniqueness
-- even when os.clock() does not advance between tests.
-- ------------------------------------------------------------------
local _dir_seq = 0
local function make_temp_dir()
	local base = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	_dir_seq = _dir_seq + 1
	local suffix = string.format("ergopti_fw_%d_%d", os.time(), _dir_seq)
	local dir = base .. "/" .. suffix
	os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
	return dir
end

--- lib.file_watchers._is_watched_lua() deliberately excludes any path under
--- "/tmp/" (real .lua projects never live there; it is treated as OS noise).
--- make_temp_dir() resolves to "/tmp/..." on CI (no TEMP/TMPDIR env var), so
--- the base_dir-in-pump-mode test needs a directory OUTSIDE that prefix to
--- exercise the per-file .lua watcher at all (file-watcher-tmp-prefix-filter-
--- excludes-own-test-fixture).
local function make_non_tmp_dir()
	_dir_seq = _dir_seq + 1
	local dir = "./ergopti_fw_nontmp_" .. os.time() .. "_" .. _dir_seq
	os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
	return dir
end

local function write_file(path, content)
	local fh = io.open(path, "w")
	if fh then
		fh:write(content or "[test]\ntrigger = \"abc\"\n")
		fh:close()
		return true
	end
	return false
end

local function touch_file(path)
	os.execute("touch '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
end

local function rm_dir(dir)
	os.execute("rm -rf '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
end

local function sleep_sec(n)
	os.execute("sleep " .. tostring(n) .. " 2>/dev/null")
end

--- Probe: can we stat a file's mtime on this system?
--- @return boolean true when stat(1) works and returns an integer epoch timestamp.
local function _can_stat()
	local tmp = os.tmpname and os.tmpname() or "/tmp/__ergopti_stat_probe__"
	local fh = io.open(tmp, "w")
	if fh then fh:close() end
	local fh2 = io.popen("stat -c %Y '" .. tmp:gsub("'", "'\\''") .. "' 2>/dev/null", "r")
	if fh2 then
		local out = fh2:read("*l")
		fh2:close()
		os.remove(tmp)
		if out and tonumber(out) then return true end
	end
	pcall(os.remove, tmp)
	return false
end

local CAN_STAT = _can_stat()

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


--- Isolates the real libuv return-value interface, not a physical watch.
local function activation_fixture(receipt)
	local state = { handles = {}, starts = 0, stops = 0, closes = 0, warnings = {}, summaries = {} }
	local backend = { constants = {} }
	function backend.new_fs_event()
		local handle = {}
		state.handles[#state.handles + 1] = handle
		return handle
	end
	function backend.fs_event_start(handle, path, flags, callback)
		state.starts = state.starts + 1
		handle.callback = callback
		if receipt.throws then error(receipt.reason) end
		return receipt.value, receipt.reason, receipt.code
	end
	function backend.fs_event_stop() state.stops = state.stops + 1; return 0 end
	function backend.close(handle)
		state.closes = state.closes + 1
		handle.closed = true
	end
	local logger = {}
	for _, level in ipairs({ "debug", "trace", "done", "info", "start", "error" }) do
		logger[level] = function() end
	end
	function logger.warn(_, format, ...)
		state.warnings[#state.warnings + 1] = string.format(format, ...)
	end
	function logger.success(_, format, ...)
		state.summaries[#state.summaries + 1] = string.format(format, ...)
	end
	local replacements = {
		{ "luv", backend }, { "posix", { stat = function() return { type = "directory" } end } },
		{ "logger.shim", logger }, { "infra.file_watchers", nil },
	}
	local saved = {}
	for _, entry in ipairs(replacements) do
		saved[#saved + 1] = { entry[1], package.loaded[entry[1]] }
		package.loaded[entry[1]] = entry[2]
	end
	local ok, watcher = pcall(require, "infra.file_watchers")
	for _, entry in ipairs(saved) do package.loaded[entry[1]] = entry[2] end
	if not ok then error(watcher, 0) end
	return watcher, state
end

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
				local dir = make_non_tmp_dir()
				write_file(dir .. "/init.lua", "return {}")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired_count = 0
				fw.start({ base_dir = dir, on_reload = function() fired_count = fired_count + 1 end })

				fw.pump()
				sleep_sec(0.1)
				touch_file(dir .. "/init.lua")
				fw.pump()
				sleep_sec(1.0)
				fw.pump()

				fw.stop()
				rm_dir(dir)
				helpers.assert_eq(fired_count, 1, ".lua file change in base_dir should fire on_reload")
			end)

			helpers.it("personal_dir with subdirectory .toml files is watched", function()
				local dir = make_temp_dir()
				local sub = dir .. "/sub"
				os.execute("mkdir -p '" .. sub:gsub("'", "'\\''") .. "' 2>/dev/null")
				write_file(sub .. "/personal.toml")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired = 0
				fw.start({ personal_dir = dir, on_reload = function() fired = fired + 1 end })

				fw.pump()
				sleep_sec(0.1)
				touch_file(sub .. "/personal.toml")
				fw.pump()
				sleep_sec(1.0)
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
				local dir = make_temp_dir()
				write_file(dir .. "/hotstrings.toml")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
				local fired = false
				fw.start({
					hotstrings_dir = dir,
					on_reload = function() fired = true; error("INTENTIONAL CRASH IN CALLBACK") end,
				})

				fw.pump()
				sleep_sec(0.1)
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
				sleep_sec(1.0)
				fw.pump()
				helpers.assert_true(fired, "callback must have been called")

				local fired2 = false
				fw.stop()
				fw.start({ hotstrings_dir = dir, on_reload = function() fired2 = true end })
				fw.pump()
				sleep_sec(0.1)
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
				sleep_sec(1.0)
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
				local dir = make_temp_dir()
				write_file(dir .. "/hotstrings.toml")
				local fw = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)

				local old_fired = 0
				fw.start({ hotstrings_dir = dir, on_reload = function() old_fired = old_fired + 1 end })
				fw.pump()
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()

				fw.stop()

				local new_fired = 0
				fw.start({ hotstrings_dir = dir, on_reload = function() new_fired = new_fired + 1 end })
				fw.pump()
				helpers.assert_eq(old_fired, 0, "old callback was cleared by stop()")
				helpers.assert_eq(new_fired, 0, "new callback not fired yet")

				sleep_sec(0.1)
				touch_file(dir .. "/hotstrings.toml")
				fw.pump()
				sleep_sec(1.0)
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


-- ======================================================================
-- 6. Debounce clock source (root-cause guard, runs in every environment)
-- ======================================================================

-- The behavioural timing tests above are stat-gated and skipped where stat(1)
-- is unavailable. This source guard runs everywhere and encodes the root cause:
-- the debounce deadline must be computed from a monotonic WALL clock, never
-- os.clock(). On Linux os.clock() is CPU time, which barely advances in an
-- I/O-bound daemon, so a deadline derived from it never lines up with real
-- elapsed time and the reload either never fires or fires immediately.
helpers.describe("file_watchers debounce clock source", function()

	local function read_file(path)
		local fh = io.open(path, "r")
		if not fh then return "" end
		local s = fh:read("*a")
		fh:close()
		return s
	end

	local src = read_file(helpers.driver_root() .. "/infra/file_watchers.lua")

	helpers.it("computes the debounce deadline from the monotonic clock, not os.clock", function()
		helpers.assert_true(src ~= "", "could not read infra/file_watchers.lua")
		helpers.assert_true(src:find('require("infra.monotonic")', 1, true) ~= nil,
			"file_watchers must source its clock from lib.monotonic")
		helpers.assert_true(src:find("os.clock", 1, true) == nil,
			"file_watchers must not use os.clock() — CPU time breaks the debounce on Linux")
		helpers.assert_true(src:find("_now_ms()", 1, true) ~= nil,
			"the debounce deadline must be set and checked through the injectable wall clock")
	end)

end)
