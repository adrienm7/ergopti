--- tests/fixtures/native_keystats_json_fallback.lua
--- ==============================================================================
--- MODULE: Native Keystats JSON Fallback Fixture
--- DESCRIPTION:
--- Public flush saves a private summary with the real SQLite CLI unavailable.
--- Only the exact summary stream receives a write/close refusal. The caller
--- owns the directory, five private XDG roots and the bounded worker lifetime.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_keystats_json_fallback%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local folder, kind = assert(arg[1]), assert(arg[2])
for _, key in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR" }) do
	assert(assert(os.getenv(key)):sub(1, #folder + 1) == folder .. "/", "each worker requires private XDG roots")
end
local Shell, Json, uv = require("adapters.shell_runner"), require("json"), require("luv")
local open = io.open
local function write(path, bytes)
	local file = assert(open(path, "wb")); assert(file:write(bytes)); assert(file:close())
end
local function read(path)
	local file = assert(open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
end
local bin, logs = folder .. "/bin", folder .. "/logs"
assert(uv.fs_mkdir(bin, 448)); assert(uv.fs_mkdir(logs, 448))
for _, program in ipairs({ "mkdir", "hostname" }) do
	local found, path = Shell.exec_checked("command -v " .. program)
	assert(found and path:sub(1, 1) == "/"); assert(uv.fs_symlink(path:gsub("\n$", ""), bin .. "/" .. program))
end
assert(uv.os_setenv("PATH", bin)); assert(Shell.has_command("sqlite3") == false)
local Writer = require("infra.regular_file_writer")
local native_open = Writer.open
local Keystats, Sqlite = require("modules.keystats.keystats"), require("modules.keystats.sqlite_writer")
require("tests.support.metrics_preferences_fixture").with(function()
	Keystats.init({ log_dir = logs, sqlite_path = folder .. "/metrics.sqlite" })
	assert(Sqlite.is_available() == false and Sqlite.get_db_path() == nil, "the actual SQLite store must be unavailable")
	assert(Keystats.set_enabled(true)); Keystats.reset_session()
	local app = "fixture.json.fallback"
	Keystats.on_app_focus(app, 1000); Keystats.on_keydown("a", 1100, app)
	assert(Keystats.flush() == true and Keystats._pending_buffer_count_for_test() == 0)
	local path = logs .. "/keystrokes_" .. os.date("%Y-%m-%d") .. ".json"
	local before = read(path)
	assert(Json.decode_lossless(before).apps[app].keystrokes == 1)
	local fault, handles = true, {}
	local function refuse()
		if kind:match("_throw$") then error("controlled summary receipt exception") end
		if kind:match("_false$") then return false, "controlled summary receipt" end
		return nil, "controlled summary receipt"
	end
	local function wrap(stream, detail, errno, cleanup, current)
		if not stream then return stream, detail, errno, cleanup, current end
		local record = { stream = stream, closed = false }; handles[#handles + 1] = record
		return {
			write = function(_, ...)
				if fault and kind:match("^write_") then assert(stream:write((...):sub(1, 13))); return refuse() end
				return stream:write(...)
			end,
			close = function()
				assert(stream:close()); record.closed = true
				if fault and kind:match("^close_") then return refuse() end
				return true
			end,
		}, detail, errno, cleanup, current
	end
	io.open = function(candidate, mode)
		if candidate == path and mode == "w" then return wrap(open(candidate, mode)) end
		return open(candidate, mode)
	end
	Writer.open = function(candidate, mode)
		if candidate == path .. ".tmp" then return wrap(native_open(candidate, mode)) end
		return native_open(candidate, mode)
	end
	Keystats.on_keydown("b", 1200, app)
	local pending_before = Keystats._pending_buffer_count_for_test()
	assert(pending_before > 0)
	local called, saved = pcall(Keystats.flush)
	local after, pending_after, streams_closed = read(path), Keystats._pending_buffer_count_for_test(), true
	for _, record in ipairs(handles) do if not record.closed then streams_closed = false; assert(record.stream:close()); record.closed = true end end
	fault = false; Keystats.on_keydown("c", 1300, app)
	local retry = Keystats.flush()
	local final = assert(Json.decode_lossless(read(path)))
	local row = { kind = kind, called = called, saved = saved, before_bytes = before, after_first_bytes = after,
		source_preserved = after == before, streams_closed_after_failure = streams_closed,
		pending_before = pending_before, pending_after = pending_after, retry = retry,
		pending_final = Keystats._pending_buffer_count_for_test(), final_keystrokes = final.apps[app].keystrokes,
		public_keystrokes = Keystats.export_session().apps[app].keystrokes,
		real_SQLite_unavailable = Sqlite.is_available() == false, private_PATH = os.getenv("PATH") }
	write(folder .. "/receipt.json", assert(Json.encode(row)))
	assert(called, "a native summary refusal must remain an explicit result")
	assert(streams_closed, "every summary stream must close, including after a thrown write")
	if kind == "healthy" then assert(saved == true and pending_after == 0)
	else
		assert(saved == false, "a refused summary publication cannot report success")
		assert(after == before, "a failed save must retain the exact previous summary")
		assert(pending_after == pending_before, "a failed summary save cannot consume raw queues")
	end
	assert(retry == true and row.pending_final == 0)
	assert(final.apps[app].keystrokes == 3 and row.public_keystrokes == 3, "retry must save cumulative A+B+C exactly once")
	assert(uv.fs_lstat(path .. ".tmp") == nil and uv.fs_lstat(folder .. "/metrics.sqlite") == nil)
	write(folder .. "/complete", "complete")
end, { initial = { ["metrics.encrypt"] = false } })
