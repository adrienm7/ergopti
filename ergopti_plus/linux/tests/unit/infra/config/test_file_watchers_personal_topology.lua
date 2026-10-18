--- tests/unit/infra/config/test_file_watchers_personal_topology.lua

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

