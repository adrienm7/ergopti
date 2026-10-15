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


-- ======================================================================
-- Linux directory identities (real files, both watcher backends)
-- ======================================================================

helpers.describe("file_watchers Linux directory identity", function()
	if not native_ok then
		print("  [Linux path identity receiving not executed: native luv filesystem API unavailable]")
		return
	end
	if not CAN_STAT or package.config:sub(1, 1) ~= "/" then
		print("  [Linux path identity receiving not executed: POSIX filesystem/coreutils unavailable]")
		return
	end

	local function session(backend, callback)
		local base = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
		local root = assert(native_luv.fs_mkdtemp(base .. "/ergopti_fw_identity_XXXXXX"))
		local directories, files, watcher = { root }, {}, nil
		local now, fired, version = 0, 0, 0
		local fixture = { root = root }
		function fixture.directory(path)
			assert(native_luv.fs_mkdir(path, 448))
			directories[#directories + 1] = path
			return path
		end
		function fixture.file(path)
			local handle = assert(io.open(path, "w"))
			assert(handle:write('[personal.identity]\ntrigger = "before"\n'))
			assert(handle:close())
			files[path] = true
			assert(native_luv.fs_utime(path, 1700000000, 1700000000))
			return path
		end
		function fixture.distinct(left, right)
			local a, b = assert(native_luv.fs_stat(left)), assert(native_luv.fs_stat(right))
			helpers.assert_true(a.dev ~= b.dev or a.ino ~= b.ino,
				"the prescribed names must denote distinct real directories")
		end
		function fixture.start(path)
			watcher = helpers.load_module_with_dependency("infra.file_watchers", "luv",
				backend == "native" and native_luv or false)
			watcher.start({ personal_dir = path, now_ms = function() return now end,
				on_reload = function() fired = fired + 1 end })
			helpers.assert_eq(watcher.has_inotify(), backend == "native", "select the intended real backend")
			watcher.pump()
			helpers.assert_eq(fired, 0, "the unmodified source must not reload")
		end
		function fixture.edit(path, expected)
			local before = fired
			version = version + 1
			local handle = assert(io.open(path, "w"))
			assert(handle:write('[personal.identity]\ntrigger = "after' .. version .. '"\n'))
			assert(handle:close())
			assert(native_luv.fs_utime(path, 1700000000 + version, 1700000000 + version))
			if backend == "native" then
				-- Drain the real inotify burst before advancing only the debounce clock.
				local deadline = native_luv.hrtime() + 50000000
				repeat native_luv.run("nowait"); native_luv.sleep(1) until native_luv.hrtime() >= deadline
			end
			watcher.pump()
			helpers.assert_eq(fired, before, "a changed file must wait for debounce")
			now = now + 600
			watcher.pump()
			helpers.assert_eq(fired, before + expected, "settled edit must preserve exact directory identity: " .. path)
			watcher.pump()
			helpers.assert_eq(fired, before + expected, "unchanged source must not repeat the reload")
		end
		local previous = package.loaded["infra.file_watchers"]
		local ok, err = xpcall(function() callback(fixture) end, debug.traceback)
		local stopped, stop_error = true, nil
		if watcher then stopped, stop_error = pcall(watcher.stop) end
		native_luv.run("nowait")
		package.loaded["infra.file_watchers"] = previous
		local removed = true
		for path in pairs(files) do
			if native_luv.fs_unlink(path) ~= true then removed = false end
		end
		for index = #directories, 1, -1 do
			if native_luv.fs_rmdir(directories[index]) ~= true then removed = false end
		end
		helpers.assert_true(ok, tostring(err))
		helpers.assert_true(stopped, tostring(stop_error))
		helpers.assert_true(removed, "every owned real source and directory must retire")
	end

	for _, backend in ipairs({ "native", "pump" }) do
		helpers.it("(linux-watch-path-identity) " .. backend .. " watches distinct Foo and foo siblings", function()
			session(backend, function(s)
				local upper = s.directory(s.root .. "/Foo")
				local lower = s.directory(s.root .. "/foo")
				s.distinct(upper, lower)
				local first, second = s.file(upper .. "/upper.toml"), s.file(lower .. "/lower.toml")
				s.start(s.root)
				s.edit(first, 1)
				s.edit(second, 1)
			end)
		end)
		helpers.it("(linux-watch-path-identity) " .. backend .. " preserves a literal trailing backslash in sibling names", function()
			session(backend, function(s)
				local plain = s.directory(s.root .. "/plain")
				local literal = s.directory(s.root .. "/plain\\")
				s.distinct(plain, literal)
				local first, second = s.file(plain .. "/plain.toml"), s.file(literal .. "/literal.toml")
				s.start(s.root)
				s.edit(first, 1)
				s.edit(second, 1)
			end)
		end)
		helpers.it("(linux-watch-path-identity) " .. backend .. " preserves a literal trailing backslash in the configured root", function()
			session(backend, function(s)
				local literal = s.directory(s.root .. "/personal\\")
				local source = s.file(literal .. "/literal.toml")
				s.start(literal)
				s.edit(source, 1)
			end)
		end)
		helpers.it("(linux-watch-path-identity) " .. backend .. " accepts ordinary trailing directory slashes", function()
			session(backend, function(s)
				local source = s.file(s.root .. "/ordinary.toml")
				s.start(s.root .. "///")
				s.edit(source, 1)
			end)
		end)
		helpers.it("(linux-watch-path-identity) " .. backend .. " retains the existing recursive depth boundary", function()
			session(backend, function(s)
				local path = s.root
				for _ = 1, 15 do path = s.directory(path .. "/level") end
				local inside = s.file(path .. "/inside.toml")
				path = s.directory(path .. "/outside")
				local outside = s.file(path .. "/outside.toml")
				s.start(s.root)
				s.edit(inside, 1)
				s.edit(outside, 0)
			end)
		end)
	end
end)


-- ======================================================================
-- Personal watcher topology (independent real native source controls)
-- ======================================================================

helpers.describe("file_watchers Personal topology", function()
	if not native_ok or not CAN_STAT or package.config:sub(1, 1) ~= "/" then
		print("  [Personal topology receiving not executed: POSIX/native luv filesystem unavailable]")
		return
	end
	local posix_ok, actual_posix = pcall(require, "posix")
	local fixture_filesystem = posix_ok and actual_posix or nil
	if not fixture_filesystem or type(fixture_filesystem.dir) ~= "function" then
		if type(native_luv.fs_scandir) ~= "function" or type(native_luv.fs_scandir_next) ~= "function"
			or type(native_luv.fs_lstat) ~= "function" then
			print("  [Personal topology receiving not executed: native fixture scan/stat APIs unavailable]")
			return
		end
		-- Controlled fixture port backed by actual native filesystem operations.
		-- This supplies no-follow metadata like the POSIX fixture, not lua-posix execution.
		fixture_filesystem = {
			dir = function(path)
				local request, detail = native_luv.fs_scandir(path)
				if not request then error(detail, 0) end
				local entries = {}
				while true do
					local name, kind = native_luv.fs_scandir_next(request)
					if not name then
						if kind then error(kind, 0) end
						break
					end
					entries[#entries + 1] = name
				end
				return entries
			end,
			stat = function(path)
				local attributes, detail = native_luv.fs_lstat(path)
				if not attributes then return nil, detail end
				return { dev = attributes.dev, ino = attributes.ino, type = attributes.type,
					mtime = { sec = attributes.mtime.sec, nsec = attributes.mtime.nsec } }
			end,
		}
		print("  [Personal topology fixture uses native luv scan/stat port; lua-posix unavailable]")
	end
	-- Base-source cases select /var/tmp because the producer deliberately excludes /tmp.
	local function session(backend_name, run, root_parent)
		local root = assert(native_luv.fs_mkdtemp((root_parent or os.getenv("TMPDIR") or "/tmp") .. "/ergopti_topology_XXXXXX"))
		local directories, files, records = { root }, {}, {}
		local state = { root = root, now = 0, reloads = 0, scans = 0, callbacks = {},
			fail_callback = false, denied = nil, start_refused = nil, stop_refused = nil, close_refused = nil }
		local actual_shell = require("adapters.shell_runner")
		local backend, scan_port, shell_port = {}, {}, {}
		for key, value in pairs(native_luv) do backend[key] = value end
		for key, value in pairs(fixture_filesystem) do scan_port[key] = value end
		for key, value in pairs(actual_shell) do shell_port[key] = value end
		function shell_port.exec_checked(command)
			if command:find("ls -1A ", 1, true) == 1 and state.command_refusal then
				state.checked_refusals = (state.checked_refusals or 0) + 1
				return actual_shell.exec_checked("printf 'partial.toml\n'; exit 23")
			end
			if command:find("ls -1A ", 1, true) == 1 and state.capture_refusal then
				local original_popen = io.popen
				io.popen = function(...)
					local pipe = assert(original_popen(...))
					return { read = function(_, ...) return pipe:read(...) end, close = function()
						local closed = pipe:close()
						state.actual_child_closed = closed == true or closed == 0
						return nil, "controlled native checked-capture close refusal"
					end }
				end
				local called, complete, output, detail = pcall(actual_shell.exec_checked, command)
				io.popen = original_popen
				if not called then error(complete, 0) end
				state.checked_refusals = (state.checked_refusals or 0) + 1
				return complete, output, detail
			end
			return actual_shell.exec_checked(command)
		end
		function scan_port.dir(path)
			state.scans = state.scans + 1
			if state.denied == path then error("controlled native enumeration refusal") end
			local entries = fixture_filesystem.dir(path)
			if state.duplicate == path then
				for _, name in ipairs(entries) do if name ~= "." and name ~= ".." then entries[#entries + 1] = name; break end end
			end
			if state.after_listing then state.after_listing(path) end
			return entries
		end
		function backend.new_fs_event()
			local handle = assert(native_luv.new_fs_event())
			records[handle] = { handle = handle, retired = false }
			return handle
		end
		function backend.fs_event_start(handle, path, flags, callback)
			local record = assert(records[handle])
			record.path, record.callback = path, callback
			state.callbacks[#state.callbacks + 1] = record
			if state.start_refused == path then return nil, "controlled native activation refusal", "EACCES" end
			return native_luv.fs_event_start(handle, path, flags, callback)
		end
		function backend.fs_event_stop(handle)
			if state.stop_refused == records[handle].path then return nil, "controlled native stop refusal" end
			return native_luv.fs_event_stop(handle)
		end
		function backend.close(handle, callback)
			local record = assert(records[handle])
			if state.close_refused == record.path then return nil, "controlled native close refusal" end
			return native_luv.close(handle, function(...)
				record.retired = true
				if callback then
					if state.withhold_ack == record.path then record.pending_ack = callback else callback(...) end
				end
			end)
		end
		function state.directory(path)
			assert(native_luv.fs_mkdir(path, 448)); directories[#directories + 1] = path; return path
		end
		local sequence = 0
		function state.file(path, content)
			files[path] = true
			local handle = assert(io.open(path, "w"))
			local wrote, detail = handle:write(content or '[personal.topology]\ntrigger = "before"\n')
			local closed, close_detail = handle:close()
			assert(wrote, detail); assert(closed, close_detail)
			sequence = sequence + 1
			assert(native_luv.fs_utime(path, 1700000000 + sequence, 1700000000 + sequence))
			return path
		end
		function state.rename(from, to)
			assert(native_luv.fs_rename(from, to))
			for index, path in ipairs(directories) do
				if path == from or path:sub(1, #from + 1) == from .. "/" then directories[index] = to .. path:sub(#from + 1) end
			end
			local moved = {}
			for path in pairs(files) do
				if path == from or path:sub(1, #from + 1) == from .. "/" then moved[path] = to .. path:sub(#from + 1) end
			end
			for old, new in pairs(moved) do files[old], files[new] = nil, true end
		end
		function state.remove_file(path) assert(native_luv.fs_unlink(path)); files[path] = nil end
		function state.remove_directory(path)
			assert(native_luv.fs_rmdir(path))
			for index, value in ipairs(directories) do if value == path then table.remove(directories, index); break end end
		end
		local previous_watch = package.loaded["infra.file_watchers"]
		local previous_posix, previous_posix_preload = package.loaded["posix"], package.preload["posix"]
		local previous_shell = package.loaded["adapters.shell_runner"]
		local watcher
		function state.start(reuse_owner)
			if not reuse_owner then
				if state.no_native_stat then backend.fs_stat = nil end
				package.loaded["posix"] = state.no_posix and nil or scan_port
				if state.no_posix then
					package.loaded["posix"] = nil
					package.preload["posix"] = function() error("explicit supported no-posix watcher backend") end
				end
				package.loaded["adapters.shell_runner"] = shell_port
				watcher = helpers.load_module_with_dependency("infra.file_watchers", "luv", backend_name == "native" and backend or false)
				package.loaded["posix"], package.preload["posix"] = previous_posix, previous_posix_preload
				package.loaded["adapters.shell_runner"] = previous_shell
			end
			watcher.start({ personal_dir = state.personal, hotstrings_dir = state.overlap and state.personal or nil,
				base_dir = state.base, now_ms = function() return state.now end,
				on_reload = function()
					state.reloads = state.reloads + 1
					if state.fail_callback then error("controlled reload callback refusal") end
					if state.observe_path then
						local file = assert(io.open(state.observe_path, "r"))
						local content = assert(file:read("*a")); assert(file:close())
						state.observed = state.observed or {}; state.observed[#state.observed + 1] = content
					end
				end })
			helpers.assert_eq(watcher.has_inotify(), backend_name == "native")
		end
		function state.drain()
			local deadline = native_luv.hrtime() + 50000000
			repeat native_luv.run("nowait"); native_luv.sleep(1) until native_luv.hrtime() >= deadline
		end
		function state.settle(expected)
			local before = state.reloads
			state.drain(); watcher.pump()
			state.now = state.now + 600
			watcher.pump(); state.drain(); watcher.pump()
			if expected ~= nil then helpers.assert_eq(state.reloads, before + expected, "one settled source/topology burst must deliver exactly the expected reload") end
		end
		function state.idle()
			local scans, before = state.scans, state.reloads
			for _ = 1, 10 do state.now = state.now + 600; watcher.pump() end
			helpers.assert_eq(state.reloads, before, "idle pumps cannot synthesize reloads")
			helpers.assert_eq(state.scans, scans, "idle pumps cannot recursively enumerate Personal")
		end
		function state.active(path)
			local count = 0
			for _, record in pairs(records) do
				if record.path == path and not record.retired and native_luv.is_active(record.handle) then count = count + 1 end
			end
			return count
		end
		function state.pump() watcher.pump(); state.drain() end
		function state.stop() return watcher.stop() end
		state.personal = state.directory(root .. "/personal")
		local ok, primary = xpcall(function() run(state) end, debug.traceback)
		local failures = {}
		state.start_refused, state.stop_refused, state.close_refused = nil, nil, nil
		if watcher then local called, detail = pcall(watcher.stop); if not called then failures[#failures + 1] = tostring(detail) end end
		native_luv.run("nowait")
		-- Every native handle below was created by this exact private fixture.
		-- An old producer may lose its close ownership; still retire only ours.
		for handle, record in pairs(records) do
			if record.pending_ack then record.pending_ack(); record.pending_ack = nil end
			if not record.retired then
				local called, detail = pcall(function()
					native_luv.fs_event_stop(handle)
					if not native_luv.is_closing(handle) then native_luv.close(handle, function() record.retired = true end) end
				end)
				if not called then failures[#failures + 1] = tostring(detail) end
			end
		end
		native_luv.run("nowait")
		package.loaded["infra.file_watchers"], package.loaded["posix"] = previous_watch, previous_posix
		package.preload["posix"], package.loaded["adapters.shell_runner"] = previous_posix_preload, previous_shell
		for path in pairs(files) do local deleted, detail = native_luv.fs_unlink(path); if not deleted then failures[#failures + 1] = tostring(detail) end end
		for index = #directories, 1, -1 do local deleted, detail = native_luv.fs_rmdir(directories[index]); if not deleted then failures[#failures + 1] = tostring(detail) end end
		for _, record in pairs(records) do if not record.retired then failures[#failures + 1] = "owned native handle did not acknowledge retirement" end end
		if not ok then error(tostring(primary) .. (#failures > 0 and (" | cleanup: " .. table.concat(failures, " | ")) or ""), 0) end
		helpers.assert_eq(#failures, 0, "every independent private cleanup must acknowledge retirement: " .. table.concat(failures, " | "))
	end

	for _, backend in ipairs({ "native", "pump" }) do
		helpers.it("(linux-watch-topology) " .. backend .. " admits a moved-in populated tree and its later edits", function()
			session(backend, function(s)
				local staging = s.directory(s.root .. "/staging"); local sub = s.directory(staging .. "/nested")
				s.file(sub .. "/rules.toml"); s.start()
				s.rename(staging, s.personal .. "/incoming"); s.settle(1)
				s.file(s.personal .. "/incoming/nested/rules.toml"); s.settle(1); s.idle()
			end)
		end)
		helpers.it("(linux-watch-topology) " .. backend .. " observes a later TOML in a directory created after start", function()
			session(backend, function(s)
				s.start(); local sub = s.directory(s.personal .. "/later"); s.settle(1)
				local file = s.file(sub .. "/rules.toml"); s.settle(1)
				s.file(file); s.settle(1)
			end)
		end)
		helpers.it("(linux-watch-topology) " .. backend .. " observes a new direct TOML and later in-place edits", function()
			session(backend, function(s)
				s.start(); local file = s.file(s.personal .. "/new.toml"); s.settle(1)
				local scans = s.scans; s.file(file); s.settle(1)
				helpers.assert_eq(s.scans, scans, "an in-place file edit cannot recursively rescan Personal")
				s.idle()
			end)
		end)
		helpers.it("(linux-watch-topology) " .. backend .. " refreshes renamed and removed/recreated directory bindings", function()
			session(backend, function(s)
				local old = s.directory(s.personal .. "/old"); local file = s.file(old .. "/rules.toml"); s.start()
				local moved = s.personal .. "/renamed"; s.rename(old, moved); s.settle(1)
				s.file(moved .. "/rules.toml"); s.settle(1)
				if backend == "native" then helpers.assert_eq(s.active(old), 0, "removed lexical bindings cannot remain active") end
				s.remove_file(moved .. "/rules.toml"); s.remove_directory(moved); s.settle(1)
				s.directory(moved); s.file(moved .. "/new.toml"); s.settle(1)
				s.file(moved .. "/new.toml"); s.settle(1)
			end)
		end)
		helpers.it("(linux-watch-topology) " .. backend .. " keeps reconciled coverage after the reload callback refuses", function()
			session(backend, function(s)
				s.start(); s.fail_callback = true
				local sub = s.directory(s.personal .. "/refused"); s.file(sub .. "/rules.toml"); s.settle(1)
				s.fail_callback = false; s.file(sub .. "/rules.toml"); s.settle(1)
			end)
		end)
		helpers.it("(linux-watch-topology) " .. backend .. " keeps prior coverage after an unacknowledged directory scan", function()
			session(backend, function(s)
				local old = s.file(s.personal .. "/old.toml"); s.start()
				s.denied = s.personal; s.file(s.personal .. "/new.toml"); s.settle(1)
				if backend == "native" then
					helpers.assert_eq(s.active(s.personal), 1, "ambiguous emptiness cannot retire the original directory owner")
					helpers.assert_eq(s.active(old), 1, "ambiguous emptiness cannot retire the original file owner")
				end
				s.file(old); s.settle(1)
				s.denied = nil; s.settle(0); s.settle(1); s.file(old); s.settle(1)
			end)
		end)
	end

	helpers.it("(linux-watch-topology) native ignores unrelated regular files without scanning Personal", function()
		session("native", function(s)
			s.start(); local scans = s.scans; s.file(s.personal .. "/ignored.txt"); s.settle(0)
			helpers.assert_eq(s.scans, scans); s.idle()
		end)
	end)
	helpers.it("(linux-watch-topology) native retains original coverage across a refused descendant activation", function()
		session("native", function(s)
			local existing = s.file(s.personal .. "/existing.toml"); s.start()
			local new = s.directory(s.personal .. "/new"); s.file(new .. "/rules.toml"); s.start_refused = new; s.settle(1)
			helpers.assert_eq(s.active(s.personal), 1, "a refused staging candidate cannot replace admitted coverage")
			helpers.assert_eq(s.active(existing), 1, "activation refusal preserves the exact original file owner")
			s.start_refused = nil; s.settle(0); s.settle(1); s.file(existing); s.settle(1); s.file(new .. "/rules.toml"); s.settle(1)
		end)
	end)
	helpers.it("(linux-watch-topology) native rejects an obsolete callback after removal and after a new session", function()
		session("native", function(s)
			local sub = s.directory(s.personal .. "/old"); local file = s.file(sub .. "/rules.toml"); s.start()
			local held
			for _, record in ipairs(s.callbacks) do if record.path == sub then held = record.callback end end
			helpers.assert_true(type(held) == "function", "capture the actual originally admitted native callback")
			s.remove_file(file); s.remove_directory(sub); s.settle(1)
			held(nil, "forged.toml", { change = true }); s.settle(0)
			s.stop(); s.start(); held(nil, "forged.toml", { change = true }); s.settle(0)
		end)
	end)
	helpers.it("(linux-watch-topology) native admits nil-filename keyed rename receipts", function()
		session("native", function(s)
			s.start()
			local held
			for _, record in ipairs(s.callbacks) do if record.path == s.personal then held = record.callback end end
			helpers.assert_true(type(held) == "function")
			held(nil, nil, { rename = true }); s.settle(1); s.idle()
		end)
	end)
	helpers.it("(linux-watch-topology) native replaces an obsolete inode binding after atomic TOML publication", function()
		session("native", function(s)
			local path = s.file(s.personal .. "/rules.toml"); s.start()
			local before = assert(native_luv.fs_stat(path))
			local replacement = s.file(s.root .. "/replacement.toml")
			s.rename(replacement, path); s.settle(1)
			local after = assert(native_luv.fs_stat(path))
			helpers.assert_true(before.ino ~= after.ino or before.dev ~= after.dev)
			helpers.assert_eq(s.active(path), 1, "only the replacement's file binding may remain active")
			local allocated = 0
			for _, record in ipairs(s.callbacks) do if record.path == path then allocated = allocated + 1 end end
			helpers.assert_eq(allocated, 2, "the changed native inode needs a fresh owned binding")
			s.file(path); s.settle(1)
		end)
	end)
	helpers.it("(linux-watch-topology) native preserves distinct overlapping Hotstrings and base owners", function()
		session("native", function(s)
			s.overlap = true; s.base = s.directory(s.root .. "/base"); s.start()
			local root_owner, base_owner
			for _, record in ipairs(s.callbacks) do
				if record.path == s.personal and not root_owner then root_owner = record end
				if record.path == s.base then base_owner = record end
			end
			helpers.assert_true(root_owner ~= nil and base_owner ~= nil)
			local sub = s.directory(s.personal .. "/new"); s.file(sub .. "/rules.toml"); s.settle(1)
			helpers.assert_true(not root_owner.retired and native_luv.is_active(root_owner.handle), "the original main Hotstrings owner is unchanged")
			helpers.assert_true(not base_owner.retired and native_luv.is_active(base_owner.handle), "the original base owner is unchanged")
			s.file(s.base .. "/source.lua"); s.settle(1)
		end, "/var/tmp")
	end)
	helpers.it("(linux-watch-topology) native observes a file created while a new directory census is open", function()
		session("native", function(s)
			s.start(); local sub = s.directory(s.personal .. "/racing")
			local injected = false
			s.after_listing = function(path)
				if path == sub and not injected then
					injected = true
					s.file(sub .. "/raced.toml")
					native_luv.run("nowait")
				end
			end
			s.settle(0)
			helpers.assert_true(injected, "the new real directory must reach its original enumeration boundary")
			s.after_listing = nil; s.settle(1)
			s.file(sub .. "/raced.toml"); s.settle(1)
		end)
	end)
	helpers.it("(linux-watch-topology) native old reconciliation cannot rearm a replacement session", function()
		session("native", function(s)
			s.start(); s.directory(s.personal .. "/restart")
			local replaced = false
			s.after_listing = function(path)
				if path == s.personal and not replaced then
					replaced = true
					s.stop(); s.start(true)
				end
			end
			s.settle(0)
			helpers.assert_true(replaced, "the retained source read must actually replace the original session")
			s.after_listing = nil; s.idle()
		end)
	end)
	helpers.it("(linux-watch-topology) native close ownership survives until the actual retirement ACK", function()
		session("native", function(s)
			s.start(); s.withhold_ack = s.personal
			helpers.assert_eq(s.stop(), false, "a requested close is not a native retirement acknowledgement")
			s.drain()
			helpers.assert_eq(s.stop(), false, "the pending callback receipt remains owned after native close delivery is withheld")
			local delivered = false
			for _, record in ipairs(s.callbacks) do
				if record.pending_ack then
					helpers.assert_true(record.retired, "only the actual native close may produce this held ACK")
					record.pending_ack(); record.pending_ack = nil; delivered = true
				end
			end
			helpers.assert_true(delivered, "hold the real private callback rather than inventing completion")
			helpers.assert_true(s.stop(), "the exact native ACK releases its retained close ownership")
		end)
	end)

	helpers.it("(linux-watch-topology) native rejects a duplicate native directory result without shadowed handles", function()
		session("native", function(s)
			local old = s.file(s.personal .. "/old.toml"); s.start()
			local sub = s.directory(s.personal .. "/duplicated"); local child = s.file(sub .. "/rules.toml")
			s.duplicate = sub; s.settle(1)
			helpers.assert_eq(s.active(old), 1, "unjudged source cannot replace existing coverage")
			helpers.assert_eq(s.active(child), 0, "duplicate source cannot leave shadowed native bindings")
			s.duplicate = nil; s.settle(0); s.settle(1)
			helpers.assert_eq(s.active(child), 1, "the repaired unique source has exactly one admitted binding")
		end)
	end)
	helpers.it("(linux-watch-topology) native pending Personal refusal preserves accepted main and base bursts", function()
		session("native", function(s)
			s.overlap = true; s.base = s.directory(s.root .. "/base"); s.start(); s.denied = s.personal
			s.file(s.personal .. "/new.toml"); s.settle(1)
			s.file(s.base .. "/changed.lua"); s.settle(1)
			s.file(s.personal .. "/other.toml"); s.settle(1)
		end, "/var/tmp")
	end)
	helpers.it("(linux-watch-topology) native repaired unobserved coverage refreshes the consumer's latest bytes once", function()
		session("native", function(s)
			s.start(); local sub = s.directory(s.personal .. "/unobserved")
			local path = s.file(sub .. "/rules.toml", "first acknowledged source\n")
			s.observe_path, s.start_refused = path, sub; s.settle(1)
			helpers.assert_eq(s.observed[1], "first acknowledged source\n")
			s.file(path, "new bytes during refused coverage\n"); s.settle(0); s.settle(0)
			helpers.assert_eq(#s.observed, 1, "refused coverage retries cannot repeatedly publish a consumer callback")
			s.start_refused = nil; s.settle(0); s.settle(1)
			helpers.assert_eq(s.observed[2], "new bytes during refused coverage\n", "repair must refresh bytes that changed while unobserved")
			s.idle(); helpers.assert_eq(#s.observed, 2)
			s.file(path, "later observed source\n"); s.settle(1)
			helpers.assert_eq(s.observed[3], "later observed source\n")
		end)
	end)
	helpers.it("(linux-watch-topology) native no-posix irrelevant events use no shell directory probe", function()
		session("native", function(s)
			s.no_posix = true; s.start()
			local held_popen, calls = io.popen, 0
			local ok, detail = pcall(function()
				io.popen = function(...) calls = calls + 1; return held_popen(...) end
				s.file(s.personal .. "/irrelevant.txt"); s.settle(0)
			end)
			io.popen = held_popen
			helpers.assert_true(ok, tostring(detail))
			helpers.assert_eq(calls, 0, "unknown non-TOML native events must not synchronously spawn a shell")
		end)
	end)

	helpers.it("(linux-watch-topology) native retired initial construction cannot arm its obsolete base root", function()
		session("native", function(s)
			local old_base = s.directory(s.root .. "/old-base")
			local fresh_base = s.directory(s.root .. "/fresh-base")
			s.base = old_base
			local replaced = false
			s.after_listing = function(path)
				if path == s.personal and not replaced then
					replaced = true
					s.stop(); s.base = fresh_base; s.start(true)
				end
			end
			s.start(); s.after_listing = nil; s.drain()
			helpers.assert_true(replaced, "the initial genuine source read must construct its successor on the same owner")
			helpers.assert_eq(s.active(old_base), 0, "a retired constructor cannot arm its captured obsolete base root")
			helpers.assert_eq(s.active(fresh_base), 1, "the successor retains exactly its own fresh base binding")
			s.idle()
		end)
	end)

	for _, name_backend in ipairs({ "native", "pump" }) do
		helpers.it("(linux-watch-topology) " .. name_backend .. " no-posix LF sibling cannot revoke ordinary TOML coverage", function()
			session(name_backend, function(s)
				s.no_posix = true
				s.file(s.personal .. "/legal\nnon-toml.txt")
				local ordinary = s.file(s.personal .. "/ordinary.toml")
				s.start(); s.file(ordinary); s.settle(1); s.idle()
			end)
		end)
	end

	for _, shell_backend in ipairs({ "native", "pump" }) do
	for _, fault in ipairs({ "command_refusal", "capture_refusal" }) do
		helpers.it("(linux-watch-topology) " .. shell_backend .. " no-posix checked shell refuses " .. fault, function()
			session(shell_backend, function(s)
				s.no_posix, s.no_native_stat = true, true; local old = s.file(s.personal .. "/old.toml"); s.start()
				s[fault] = true; s.file(s.personal .. "/new.toml"); s.settle(1)
				helpers.assert_true((s.checked_refusals or 0) > 0, "the real checked command/capture owner must refuse")
				if fault == "capture_refusal" then helpers.assert_true(s.actual_child_closed, "close the actual captured native child before refusing its receipt") end
				if shell_backend == "native" then helpers.assert_eq(s.active(old), 1, "partial failed command output cannot erase existing coverage") end
				s.file(old); s.settle(1)
				s[fault] = false; s.settle(0); s.settle(1)
				s.file(old); s.settle(1)
			end)
		end)
	end

	end

	for _, field in ipairs({ "stop_refused", "close_refused" }) do
		helpers.it("(linux-watch-topology) native retains owned retirement after " .. field, function()
			session("native", function(s)
				local sub = s.directory(s.personal .. "/old"); local file = s.file(sub .. "/rules.toml"); s.start()
				s[field] = sub; s.remove_file(file); s.remove_directory(sub); s.settle(1)
				s[field] = nil; s.pump()
				for _, record in ipairs(s.callbacks) do
					if record.path == sub then helpers.assert_true(record.retired, "the owner must retain and repair its exact refused retirement") end
				end
			end)
		end)
	end
	for _, root_backend in ipairs({ "native", "pump" }) do
		helpers.it("(linux-watch-root-anchor) " .. root_backend .. " recovers an empty removed and recreated Personal root", function()
			session(root_backend, function(s)
				s.start(); s.remove_directory(s.personal); s.settle(1)
				s.directory(s.personal)
				local path = s.file(s.personal .. "/rules.toml", '[personal]\nvalue = "recreated"\n')
				s.observe_path = path; s.settle(1)
				helpers.assert_eq(s.observed[1], '[personal]\nvalue = "recreated"\n')
				s.file(path, '[personal]\nvalue = "later"\n'); s.settle(1)
				helpers.assert_eq(s.observed[2], '[personal]\nvalue = "later"\n')
				s.idle()
			end)
		end)
	end
	helpers.it("(linux-watch-root-anchor) native ignores distinct parent siblings without recursive scans", function()
		session("native", function(s)
			local logger = require("logger.shim")
			local held_success, reported = logger.success, nil
			logger.success = function(_, format, ...)
				local message = string.format(format, ...)
				reported = tonumber(message:match("^File watchers armed: (%d+) handle")) or reported
			end
			local called, detail = pcall(s.start)
			logger.success = held_success
			helpers.assert_true(called, tostring(detail))
			helpers.assert_eq(reported, 2, "report both genuine active handles: empty Personal root and its parent")
			helpers.assert_eq(s.active(s.root), 1, "the immediate parent has one separately owned anchor")
			local scans = s.scans
			for _, name in ipairs({ "Personal", "personal\\", "unrelated" }) do
				local sibling = s.directory(s.root .. "/" .. name)
				s.file(sibling .. "/rules.toml"); s.settle(0)
			end
			helpers.assert_eq(s.scans, scans, "parent siblings cannot admit a recursive Personal census")
			s.idle()
		end)
	end)
	helpers.it("(linux-watch-root-anchor) native refused anchor preserves healthy coverage and retries admission", function()
		session("native", function(s)
			local path = s.file(s.personal .. "/rules.toml")
			s.start_refused = s.root
			local logger, warnings = require("logger.shim"), {}
			local held_warn = logger.warn
			logger.warn = function(_, format, ...) warnings[#warnings + 1] = string.format(format, ...) end
			local called, detail = pcall(s.start)
			logger.warn = held_warn
			helpers.assert_true(called, tostring(detail))
			helpers.assert_eq(#warnings, 1, "the refused parent admission must expose its native failure")
			helpers.assert_true(warnings[1]:find("controlled native activation refusal", 1, true) ~= nil, "preserve the actual native activation reason")
			helpers.assert_eq(s.active(s.personal), 1, "parent activation refusal cannot discard an admitted healthy root")
			helpers.assert_eq(s.active(path), 1, "parent activation refusal cannot discard existing file coverage")
			s.file(path); s.settle(1); s.settle(0)
			s.start_refused = nil; s.settle(0)
			helpers.assert_eq(s.active(s.root), 1, "bounded repair must admit the previously refused parent anchor")
			s.idle(); s.remove_file(path); s.remove_directory(s.personal); s.settle(1)
			s.directory(s.personal); s.file(path); s.settle(1); s.file(path); s.settle(1)
		end)
	end)
	helpers.it("(linux-watch-root-anchor) native retirement ACK and session fence include the parent anchor", function()
		session("native", function(s)
			s.start()
			local anchor
			for _, record in ipairs(s.callbacks) do if record.path == s.root then anchor = record end end
			helpers.assert_true(anchor ~= nil, "capture the genuine parent callback")
			s.withhold_ack = s.root
			helpers.assert_eq(s.stop(), false, "the parent anchor retains its unacknowledged close ownership")
			s.drain(); helpers.assert_true(anchor.retired, "the actual native close precedes its held acknowledgement")
			helpers.assert_true(type(anchor.pending_ack) == "function", "the exact parent ACK is held")
			s.withhold_ack = nil; s.start(true)
			anchor.callback(nil, "personal", { rename = true }); s.settle(0); s.idle()
			helpers.assert_eq(s.active(s.root), 1, "the retired session cannot replace its successor's parent")
			anchor.pending_ack(); anchor.pending_ack = nil
			s.stop(); s.drain(); helpers.assert_true(s.stop(), "the delivered parent ACK releases its retirement debt")
		end)
	end)

	helpers.it("(linux-watch-root-anchor) native committed source repair refreshes bytes while only its parent refuses", function()
		session("native", function(s)
			s.start_refused = s.root; s.start(); s.denied = s.personal
			local sub = s.directory(s.personal .. "/unobserved")
			local path = s.file(sub .. "/rules.toml", "first accepted source\n")
			s.observe_path = path; s.settle(1)
			helpers.assert_eq(s.observed[1], "first accepted source\n")
			s.file(path, "latest unobserved source\n"); s.settle(0)
			s.denied = nil; s.settle(0); s.settle(1)
			helpers.assert_eq(s.observed[2], "latest unobserved source\n", "committed file coverage must refresh even while parent admission still refuses")
			s.start_refused = nil; s.settle(0); s.idle()
		end)
	end)
	helpers.it("(linux-watch-root-anchor) native nil-filename errors retain diagnostics and repair ownership", function()
		session("native", function(s)
			s.start()
			local anchor
			for _, record in ipairs(s.callbacks) do if record.path == s.root then anchor = record end end
			helpers.assert_true(anchor ~= nil)
			local logger, warnings = require("logger.shim"), {}
			local held_warn = logger.warn
			logger.warn = function(_, format, ...) warnings[#warnings + 1] = string.format(format, ...) end
			local called, detail = pcall(anchor.callback, "controlled native parent error", nil, nil)
			logger.warn = held_warn
			helpers.assert_true(called, tostring(detail))
			helpers.assert_eq(#warnings, 1, "a native parent error cannot disappear through filename filtering")
			helpers.assert_true(warnings[1]:find("controlled native parent error", 1, true) ~= nil)
			s.settle(0); s.settle(1)
			helpers.assert_true(anchor.retired, "the errored native binding must retire through its actual close")
			helpers.assert_eq(s.active(s.root), 1, "bounded retry must restore one owned parent binding")
			local path = s.file(s.personal .. "/rules.toml"); s.settle(1); s.file(path); s.settle(1); s.idle()
		end)
	end)

	helpers.it("(linux-watch-root-anchor) native ambiguous rename port receipt rebinds unchanged metadata", function()
		session("native", function(s)
			local path = s.file(s.personal .. "/rules.toml"); s.start()
			local anchor, old_root
			for _, record in ipairs(s.callbacks) do
				if record.path == s.root then anchor = record elseif record.path == s.personal then old_root = record end
			end
			helpers.assert_true(anchor ~= nil and old_root ~= nil, "capture genuine handles before the controlled ambiguous receipt")
			-- This controls the native callback port, not an actual kernel rename.
			-- Equal current metadata cannot establish that an old binding survived.
			anchor.callback(nil, nil, { rename = true }); s.settle(1)
			helpers.assert_true(old_root.retired, "an ambiguous rename cannot reuse a potentially detached root binding")
			helpers.assert_eq(s.active(s.personal), 1)
			s.file(path); s.settle(1); s.idle()
		end)
	end)

end)
