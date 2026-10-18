--- tests/unit/infra/config/test_file_watchers_debounce_clock_source.lua

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
local helpers, native_ok, native_luv, CAN_STAT =
	Fixture.helpers, Fixture.native_ok, Fixture.native_luv, Fixture.CAN_STAT




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

