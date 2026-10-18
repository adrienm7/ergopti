--- tests/unit/infra/config/test_file_watchers_single_selected_toml.lua

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
local helpers, native_ok, native_luv =
	Fixture.helpers, Fixture.native_ok, Fixture.native_luv




helpers.describe("file watchers single selected TOML", function()
	if not native_ok then
		print("  [Selected-file receiving not executed: native luv unavailable]")
		return
	end

	local function selected_file_session(backend_name, run)
		local root = assert(native_luv.fs_mkdtemp("/var/tmp/eg-single-XXXXXX"))
		local files, records, directories = {}, {}, { root }
		local previous_watch = package.loaded["infra.file_watchers"]
		local state = { root = root, path = root .. "/selected.toml", now = 0, reloads = 0 }
		local backend = {}
		for key, value in pairs(native_luv) do backend[key] = value end
		function backend.new_fs_event()
			local handle = assert(native_luv.new_fs_event())
			records[handle] = { handle = handle }
			return handle
		end
		function backend.fs_event_start(handle, path, flags, callback)
			local record = assert(records[handle])
			record.path, record.callback = path, callback
			local attributes = assert(native_luv.fs_lstat(path))
			record.device, record.inode, record.kind = attributes.dev, attributes.ino, attributes.type
			local result, detail, code = native_luv.fs_event_start(handle, path, flags, callback)
			record.result, record.detail, record.code = result, detail, code
			if path == state.path and state.staging_filename then
				local filename = state.staging_filename
				state.staging_filename = nil
				-- A controlled inline port receipt follows actual kernel admission.
				callback(nil, filename, { change = true })
			end
			return result, detail, code
		end
		function backend.close(handle, callback)
			local record = assert(records[handle])
			return native_luv.close(handle, function(...)
				record.retired = true
				if callback then
					if state.hold_ack == record then record.pending_ack = callback else callback(...) end
				end
			end)
		end
		local sequence = 0
		function state.write(path, content)
			files[path] = true
			local file = assert(io.open(path, "w"))
			assert(file:write(content or '[personal]\nvalue = "selected"\n')); assert(file:close())
			sequence = sequence + 1
			assert(native_luv.fs_utime(path, 1700000000 + sequence, 1700000000 + sequence))
			return path
		end
		function state.rename(from, to)
			assert(native_luv.fs_rename(from, to))
			files[from], files[to] = nil, true
		end
		function state.unlink(path) assert(native_luv.fs_unlink(path)); files[path] = nil end
		function state.drain()
			local deadline = native_luv.hrtime() + 40000000
			repeat native_luv.run("nowait"); native_luv.sleep(1) until native_luv.hrtime() >= deadline
		end
		local watcher
		function state.start(reuse_owner)
			if not reuse_owner then
				watcher = helpers.load_module_with_dependency("infra.file_watchers", "luv", backend_name == "native" and backend or false)
			end
			local logger, held_debug = require("logger.shim"), nil
			held_debug = logger.debug
			state.staging_reasons = state.staging_reasons or {}
			logger.debug = function(tag, format, ...)
				local reason = ...
				if format:find("^Change detected") and type(reason) == "string" then state.staging_reasons[#state.staging_reasons + 1] = reason end
				return held_debug(tag, format, ...)
			end
			local started, detail = pcall(watcher.start, { personal_dir = state.path, hotstrings_dir = state.path,
				now_ms = function() return state.now end,
				on_reload = function() state.reloads = state.reloads + 1 end })
			logger.debug = held_debug
			if not started then error(detail, 0) end
		end
		function state.settle(expected)
			local before = state.reloads
			state.drain(); watcher.pump()
			state.now = state.now + 600; watcher.pump(); state.drain(); watcher.pump()
			if expected ~= nil then helpers.assert_eq(state.reloads, before + expected, "one selected-file burst has exactly its expected reload count") end
		end
		function state.active(path)
			local found = {}
			for _, record in pairs(records) do
				if record.path == path and not record.retired and native_luv.is_active(record.handle) then found[#found + 1] = record end
			end
			return found
		end
		function state.refused(path, code)
			for _, record in pairs(records) do
				if record.path == path and record.result == nil and record.code == code and record.retired then return true end
			end
			return false
		end
		function state.stop() return watcher.stop() end
		function state.directory(path)
			assert(native_luv.fs_mkdir(path, 448)); directories[#directories + 1] = path
		end
		function state.remove_directory(path)
			assert(native_luv.fs_rmdir(path))
			for index, value in ipairs(directories) do if value == path then table.remove(directories, index); break end end
		end
		state.write(state.path)
		local called, primary = xpcall(function() run(state) end, debug.traceback)
		local cleanup = {}
		for path in pairs(files) do native_luv.fs_chmod(path, 384) end
		if watcher then local stopped, detail = pcall(watcher.stop); if not stopped then cleanup[#cleanup + 1] = tostring(detail) end end
		native_luv.run("nowait")
		for handle, record in pairs(records) do
			if record.pending_ack then record.pending_ack(); record.pending_ack = nil end
			if not record.retired then
				local closed, detail = pcall(function()
					native_luv.fs_event_stop(handle)
					if not native_luv.is_closing(handle) then native_luv.close(handle, function() record.retired = true end) end
				end)
				if not closed then cleanup[#cleanup + 1] = tostring(detail) end
			end
		end
		native_luv.run("nowait")
		package.loaded["infra.file_watchers"] = previous_watch
		for path in pairs(files) do local removed, detail = native_luv.fs_unlink(path); if not removed then cleanup[#cleanup + 1] = tostring(detail) end end
		for index = #directories, 1, -1 do
			local removed, detail = native_luv.fs_rmdir(directories[index]); if not removed then cleanup[#cleanup + 1] = tostring(detail) end
		end
		for _, record in pairs(records) do if not record.retired then cleanup[#cleanup + 1] = "selected-file handle did not acknowledge native retirement" end end
		if not called then error(tostring(primary) .. (#cleanup > 0 and (" | cleanup: " .. table.concat(cleanup, " | ")) or ""), 0) end
		helpers.assert_eq(#cleanup, 0, "retire every privately owned selected-file fixture: " .. table.concat(cleanup, " | "))
	end

	for _, backend_name in ipairs({ "native", "pump" }) do
		helpers.it("(linux-watch-selected-file) " .. backend_name .. " observes exact in-place edits and coalesces a burst", function()
			selected_file_session(backend_name, function(s)
				s.start()
				if backend_name == "native" then
					helpers.assert_eq(#s.active(s.path), 1, "arm the selected file exactly once")
					helpers.assert_eq(#s.active(s.root), 1, "retain exactly its immediate parent anchor")
				end
				s.write(s.path); s.write(s.path); s.write(s.path); s.settle(1)
				s.write(s.path); s.settle(1); s.settle(0)
			end)
		end)
		helpers.it("(linux-watch-selected-file) " .. backend_name .. " ignores TOML siblings with distinct lexical identities", function()
			selected_file_session(backend_name, function(s)
				s.start()
				for _, name in ipairs({ "unrelated.toml", "Selected.toml", "selected.toml\\" }) do s.write(s.root .. "/" .. name); s.settle(0) end
				s.write(s.path); s.settle(1)
			end)
		end)
		helpers.it("(linux-watch-selected-file) " .. backend_name .. " follows atomic replacement and later edits", function()
			selected_file_session(backend_name, function(s)
				s.start()
				local replacement = s.write(s.root .. "/replacement.tmp")
				s.rename(replacement, s.path); s.settle(1)
				if backend_name == "native" then helpers.assert_eq(#s.active(s.path), 1, "replace the exact native file binding") end
				s.write(s.path); s.settle(1); s.settle(0)
			end)
		end)
		helpers.it("(linux-watch-selected-file) " .. backend_name .. " repairs temporary absence without accepting another source", function()
			selected_file_session(backend_name, function(s)
				s.start(); s.unlink(s.path); s.settle(1)
				s.write(s.root .. "/different.toml"); s.settle(0)
				s.write(s.path); s.settle(1); s.write(s.path); s.settle(1); s.settle(0)
			end)
		end)
		helpers.it("(linux-watch-selected-file) " .. backend_name .. " stop cancels a pending reload and permits a fresh session", function()
			selected_file_session(backend_name, function(s)
				s.start(); s.write(s.path); s.drain(); s.stop(); s.drain()
				s.settle(0); s.start(true); s.write(s.path); s.settle(1)
			end)
		end)
		helpers.it("(linux-watch-selected-file) " .. backend_name .. " refuses a replacement directory and repairs its selected file", function()
			selected_file_session(backend_name, function(s)
				s.start(); s.unlink(s.path); s.directory(s.path); s.settle(1)
				local nested = s.write(s.path .. "/other.toml"); s.settle(0)
				if backend_name == "native" then
					for _, record in ipairs(s.active(s.path)) do helpers.assert_eq(record.kind, "file", "a retained old-inode watch cannot become directory coverage") end
				end
				s.unlink(nested); s.remove_directory(s.path)
				s.write(s.path); s.settle(1); s.write(s.path); s.settle(1)
			end)
		end)
	end

	helpers.it("(linux-watch-selected-file) native admission callback retains the exact file identity", function()
		selected_file_session("native", function(s)
			s.staging_filename = "selected.toml"; s.start()
			helpers.assert_eq(s.staging_reasons[1], "personal staging activity: " .. s.path, "a native file receipt cannot append a second basename")
			s.settle(1); helpers.assert_eq(#s.active(s.path), 1)
			s.write(s.path); s.settle(1)
		end)
	end)

	helpers.it("(linux-watch-selected-file) native retired file callback cannot reload its replacement", function()
		selected_file_session("native", function(s)
			s.start(); local old = s.active(s.path)[1]
			helpers.assert_true(old ~= nil, "capture the actual original file binding")
			local replacement = s.write(s.root .. "/replacement.tmp"); s.rename(replacement, s.path); s.settle(1)
			helpers.assert_true(old.retired, "the replaced native inode must acknowledge its close")
			-- This invokes a retained native port; the replacement itself used real rename.
			old.callback(nil, nil, { change = true }); s.settle(0)
			s.write(s.path); s.settle(1)
		end)
	end)
	helpers.it("(linux-watch-selected-file) native session replacement fences held file retirement", function()
		selected_file_session("native", function(s)
			s.start(); local old = s.active(s.path)[1]
			helpers.assert_true(old ~= nil)
			s.hold_ack = old; helpers.assert_eq(s.stop(), false); s.drain()
			helpers.assert_true(old.retired and type(old.pending_ack) == "function", "hold only an actual completed native close acknowledgement")
			s.start(true); old.callback(nil, nil, { rename = true }); s.settle(0)
			helpers.assert_eq(#s.active(s.path), 1, "the old session cannot replace the new file binding")
			old.pending_ack(); old.pending_ack = nil; s.hold_ack = nil
			s.write(s.path); s.settle(1)
		end)
	end)
	if native_luv.getuid() ~= 0 then
		helpers.it("(linux-watch-selected-file) native actual EACCES admission remains repairable", function()
			selected_file_session("native", function(s)
				assert(native_luv.fs_chmod(s.path, 0)); s.start(); s.drain()
				helpers.assert_true(s.refused(s.path, "EACCES"), "receive and retire an actual kernel EACCES binding")
				helpers.assert_eq(#s.active(s.path), 0, "a refused native binding cannot be published as active")
				assert(native_luv.fs_chmod(s.path, 384)); s.settle(1)
				helpers.assert_eq(#s.active(s.path), 1, "restored native read permission admits the exact file")
				s.write(s.path); s.settle(1)
			end)
		end)
	else
		print("  [Selected-file EACCES receiving not executed: ordinary user required]")
	end
end)

