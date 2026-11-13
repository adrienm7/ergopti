--- tests/unit/infra/control/test_driver_control.lua

--- ==============================================================================
--- MODULE: Local Driver Control (Linux)
--- DESCRIPTION:
--- Replays the shared driver-control contract, then drives a genuine session
--- over in-memory files: an authenticated request reaches the tray's reload
--- owner and completes in this process, a stale token or a postponed reload is
--- refused, and the session refuses a folder it cannot make private.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The application folder under every XDG base, from the shared registry.
local APP_FOLDER = require("core.fs.engine.app_dirs").linux.folder_name
local Json = require("core.text.engine.json")
local Policy = require("diagnostics.engine.control_driver_control")
local DriverControl = require("infra.driver_control")

local shared = helpers.driver_root() .. "/../_shared"
require("tests.lua.core_lifecycle.driver_control_contract").run(helpers, shared)

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return text
end

local SPEC = Policy.validate(Json.decode(read(shared .. "/diagnostics/data/control/driver_control.json")))
local TOKEN = Json.decode(read(shared .. "/tests/corpus/control/driver_control.json")).token
local FOLDER = "/run/user/1000/" .. APP_FOLDER .. "/control"

if require("tests.win_compat").is_windows() then
	helpers.it("SKIP [CONF-LINUX-RELOAD-CLI] — a Windows host lacks Linux flock, SIGUSR1 and procfs descriptors", function()
		helpers.assert_eq(package.config:sub(1, 1), "\\")
	end)
else
helpers.it("(linux-reload-cli-overlap) a second client cannot overwrite a pending request", function()
	local quote = require("core.text.engine.utils_core").shell_quote
	local driver = helpers.driver_root()
	local fixture = driver .. "/tests/fixtures/reload_cli_overlap.sh"
	local tool = driver .. "/../../../tools/control/request_driver_reload.sh"
	local status = os.execute("sh " .. quote(fixture) .. " " .. quote(tool))
	helpers.assert_true(status == true or status == 0, "concurrent real CLI requests must retain the first request and refuse the second")
end)

helpers.it("(linux-reload-cli-lock-types) refuses FIFO, symlink and directory locks without blocking", function()
	local quote = require("core.text.engine.utils_core").shell_quote
	local driver = helpers.driver_root()
	local fixture = driver .. "/tests/fixtures/reload_cli_lock_types.sh"
	local tool = driver .. "/../../../tools/control/request_driver_reload.sh"
	local status = os.execute("sh " .. quote(fixture) .. " " .. quote(tool))
	helpers.assert_true(status == true or status == 0, "invalid lock objects must be refused without changing them")
end)

helpers.it("(linux-reload-cli-decimal) accepts leading zeroes and refuses overflow before publication", function()
	local quote = require("core.text.engine.utils_core").shell_quote
	local driver = helpers.driver_root()
	local fixture = driver .. "/tests/fixtures/reload_cli_decimal.sh"
	local tool = driver .. "/../../../tools/control/request_driver_reload.sh"
	for _, shell in ipairs({ "sh", "dash", "bash" }) do
		local available = os.execute("command -v " .. quote(shell) .. " >/dev/null 2>&1")
		if available == true or available == 0 then
			local status = os.execute("sh " .. quote(fixture) .. " " .. quote(tool) .. " " .. quote(shell))
			helpers.assert_true(status == true or status == 0, shell .. " must accept decimal timeouts and reject overflow before signalling")
		end
	end
end)
end

--- A session over in-memory files.
local NOW = 1700000000

--- A session over in-memory files. `shared` lets a successor see the files of
--- the process it replaces; `pid` and `boot` describe the process itself.
local function world(reload, private, shared, pid, boot)
	local files, calls = shared or {}, {}
	local clock = { now = NOW }
	local ports = {
		now = function() return clock.now end,
		read = function(path) return files[path] end,
		write = function(path, text) files[path] = text; return true end,
		stage = function(path, text)
			if files[path] ~= nil then return nil, "stage already exists" end
			files[path] = text
			return {
				current = function(expected) return files[path] == expected end,
				discard = function()
					if files[path] ~= text then return false end
					files[path] = nil
					return true
				end,
			}
		end,
		remove = function(path) files[path] = nil; return true end,
		rename = function(from, to) files[to] = files[from]; files[from] = nil; return true end,
		exists = function(path) return files[path] ~= nil end,
		private_dir = function() return private ~= false end,
		random_hex = function() return TOKEN end,
	}
	local session = DriverControl.new({ spec = SPEC, folder = FOLDER, pid = pid or 4242, ports = ports,
		boot_outcome = boot,
		reload = function(trigger)
			calls[#calls + 1] = trigger
			return reload()
		end })
	return session, files, calls, clock
end

local function request(files, token, id)
	files[FOLDER .. "/reload.request"] = string.format('{"schema":1,"token":"%s","request_id":"%s"}', token, id)
end

helpers.describe("Linux local driver control", function()
	helpers.it("linux-control-session-read: retains unreadable session ownership until retry", function()
		local session, files = world(function() return true end)
		session:start()
		local path = FOLDER .. "/session.json"
		local original = files[path]
		session.ports.read_status = function() return nil, "error", "controlled EIO" end
		helpers.assert_eq(session:stop(), false, "an unreadable session is not proven absent")
		helpers.assert_eq(files[path], original)
		session.ports.read_status = function(target) return files[target], "ok" end
		helpers.assert_eq(session:stop(), true)
		helpers.assert_nil(files[path])
	end)
	for _, mode in ipairs({ "stage", "rename" }) do
		helpers.it("linux-control-reload-receipt: refuses restart when requested record cannot " .. mode, function()
			local session, files, calls = world(function() return true end)
			session:start()
			local original = session.ports[mode]
			session.ports[mode] = function(...) return false end
			request(files, TOKEN, "receipt-failure")
			local handled = session:handle()
			session.ports[mode] = original
			helpers.assert_eq(handled, false)
			helpers.assert_eq(#calls, 0, "a successor cannot claim a requested result that was not published")
		end)
	end
	for _, kind in ipairs({ "session", "result" }) do
		for _, collision in ipairs({ false, true }) do
			helpers.it("(driver-control-owned-stage) " .. kind .. " collision=" .. tostring(collision), function()
				local session, files, calls = world(function() return true end)
				if kind == "result" then session:start() end
				local target, stage = session:path(kind), session:path(kind) .. ".tmp-" .. tostring(session.pid)
				local prior, foreign = "prior independent receipt", "foreign pending publication"
				files[target] = prior
				if collision then files[stage] = foreign end
				if kind == "session" then
					local ok = pcall(session.start, session)
					helpers.assert_eq(ok, not collision, "session startup must honor its exclusive stage receipt")
				else
					request(files, TOKEN, "owned-stage")
					-- A restart is owed only after its requested record is published.
					helpers.assert_eq(session:handle(), not collision, "the genuine authenticated handler must dispatch")
					helpers.assert_eq(#calls, collision and 0 or 1, "exactly one reload owner is called")
				end
				if collision then
					helpers.assert_eq(files[stage], foreign, "foreign stage bytes survive untouched")
					helpers.assert_eq(files[target], prior, "stage refusal preserves the old receipt")
				else
					local expected = kind == "session" and Policy.session_text(SPEC, "linux", session.pid, TOKEN)
						or ('{"schema":1,"request_id":"owned-stage","state":"requested","driver_pid":4242,"successor_pid":null,"deadline":'
							.. tostring(NOW + SPEC.pending_ttl_seconds) .. '}\n')
					helpers.assert_eq(files[target], expected, "the actual owner publishes the exact shared protocol")
					helpers.assert_nil(files[stage], "successful rename consumes the owned stage")
				end
			end)
		end
	end

	helpers.it("publishes its session and writes a pending record for an authenticated reload", function()
		local session, files, calls = world(function() return true end)
		session:start()
		helpers.assert_eq(files[FOLDER .. "/session.json"],
			'{"schema":1,"driver":"linux","pid":4242,"token":"' .. TOKEN .. '"}\n')
		request(files, TOKEN, "sh-1")
		helpers.assert_eq(session:handle(), true)
		helpers.assert_eq(#calls, 1, "the tray's reload owner runs once")
		helpers.assert_nil(files[FOLDER .. "/reload.request"], "the request is consumed")
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"sh-1","state":"requested","driver_pid":4242,"successor_pid":null,"deadline":'
				.. tostring(NOW + SPEC.pending_ttl_seconds) .. '}\n', "a restart cannot name its successor")
		helpers.assert_eq(session:handle(), false, "a ring without a request does nothing")
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(session:stop(), true)
		helpers.assert_nil(files[FOLDER .. "/session.json"], "the session withdraws its own file")
	end)

	helpers.it("refuses a stale token without reloading", function()
		local session, files, calls = world(function() return true end)
		session:start()
		request(files, (TOKEN:gsub("0", "1")), "stale")
		helpers.assert_eq(session:handle(), false)
		helpers.assert_eq(#calls, 0, "an unauthenticated request never reaches the reload owner")
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"stale","state":"refused","driver_pid":4242,"reason":"unauthenticated"}\n')
	end)

	helpers.it("reports a postponed reload as refused and busy", function()
		local session, files = world(function() return false, "postponed" end)
		session:start()
		request(files, TOKEN, "busy-1")
		helpers.assert_eq(session:handle(), false)
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"busy-1","state":"refused","driver_pid":4242,"reason":"busy"}\n')
	end)

	helpers.it("reports a failed reload as refused and failed", function()
		local session, files = world(function() error("hotstrings exploded") end)
		session:start()
		request(files, TOKEN, "boom")
		helpers.assert_eq(session:handle(), false)
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"boom","state":"refused","driver_pid":4242,"reason":"failed"}\n')
	end)

	helpers.it("refuses a control folder it cannot make private, and a second start", function()
		local session = world(function() return true end, false)
		helpers.assert_true(not pcall(session.start, session), "a folder other users could read is refused")
		local ready = world(function() return true end)
		ready:start()
		helpers.assert_true(not pcall(ready.start, ready), "a second start is refused")
	end)

	-- The POSIX tool cannot read JSON, so it spells the declared folders and
	-- files: a renamed folder would leave it knocking on an empty one.
	helpers.it("keeps the POSIX request tool on the declared folders, files and signal", function()
		local tool = read(helpers.driver_root() .. "/../../../tools/control/request_driver_reload.sh")
		local function spelled(platform, base)
			local parts = { "$" .. base }
			for _, segment in ipairs(SPEC.folders[platform].segments) do
				-- Each OS spells its own application folder (`Ergopti` on macOS).
				parts[#parts + 1] = segment == "{app}" and require("core.fs.engine.app_dirs")[platform].folder_name or segment
			end
			return table.concat(parts, "/")
		end
		helpers.assert_eq(SPEC.folders.linux.base, "XDG_RUNTIME_DIR")
		helpers.assert_eq(SPEC.folders.macos.base, "HOME")
		for _, needle in ipairs({ 'folder="' .. spelled("linux", "XDG_RUNTIME_DIR") .. '"',
			'folder="' .. spelled("macos", "HOME") .. '"', '/' .. SPEC.files.session .. '"',
			'/' .. SPEC.files.request .. '"', '/' .. SPEC.files.result .. '"', 'kill -USR1 "$pid"' }) do
			helpers.assert_true(tool:find(needle, 1, true) ~= nil, "the tool spells " .. needle)
		end
	end)

	-- The restart flow: the replaced daemon writes the pending record, the
	-- successor (another pid, same folder) claims and completes it.
	local function replaced()
		local session, files = world(function() return true end)
		session:start()
		request(files, TOKEN, "restart-1")
		helpers.assert_eq(session:handle(), true)
		return files
	end

	helpers.it("lets the successor claim the pending record and complete it", function()
		local files = replaced()
		local successor = world(function() return true end, true, files, 5000, function() return true end)
		successor:start()
		local done = '{"schema":1,"request_id":"restart-1","state":"completed","driver_pid":5000,"successor_pid":5000}\n'
		helpers.assert_eq(files[FOLDER .. "/reload.result"], done)
		local second = world(function() return true end, true, files, 5001, function() return true end)
		second:start()
		helpers.assert_eq(files[FOLDER .. "/reload.result"], done, "a second driver cannot claim a completed request")
	end)

	helpers.it("lets the successor refuse the request with the reason of its own boot", function()
		local files = replaced()
		local successor = world(function() return true end, true, files, 5000, function() return false, "refused" end)
		successor:start()
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"restart-1","state":"refused","driver_pid":5000,"reason":"refused"}\n')
	end)

	helpers.it("reports a pending record past its deadline as a timeout, never as completed", function()
		local files = replaced()
		local late, _, _, clock = world(function() return true end, true, files, 5000, function() return true end)
		clock.now = NOW + SPEC.pending_ttl_seconds + 1
		late:start()
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"restart-1","state":"timeout","driver_pid":5000,"reason":"deadline"}\n')
	end)

	helpers.it("overwrites the pending record with a refusal when no restart could be requested", function()
		local session, files = world(function() return false, "failed" end)
		session:start()
		request(files, TOKEN, "nope")
		helpers.assert_eq(session:handle(), false)
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"nope","state":"refused","driver_pid":4242,"reason":"failed"}\n')
	end)

	helpers.it("keeps a successor's session when it stops", function()
		local session, files = world(function() return true end)
		session:start()
		local successor = '{"schema":1,"driver":"linux","pid":5000,"token":"' .. TOKEN:gsub("0", "5") .. '"}\n'
		files[FOLDER .. "/session.json"] = successor
		helpers.assert_eq(session:stop(), true)
		helpers.assert_eq(files[FOLDER .. "/session.json"], successor)
	end)
end)

-- A declaration is consumed before the optional control can yield to the daemon.
helpers.describe("driver-control-declaration", function()
	for _, refusal in ipairs({ "read-nil", "read-throw", "close-nil", "close-false", "close-throw" }) do
		helpers.it("(driver-control-declaration) closes and refuses " .. refusal, function()
			local Reader = require("infra.regular_file_reader")
			local open, new, stdio_open = Reader.open, DriverControl.new, io.open
			local closes, acquired = 0, 0
			Reader.open = function()
				return {
					read = function()
						if refusal == "read-nil" then return nil, "refused" end
						if refusal == "read-throw" then error("refused read") end
						return Json.encode(SPEC)
					end,
					close = function()
						closes = closes + 1
						if refusal == "close-nil" then return nil end
						if refusal == "close-false" then return false end
						if refusal == "close-throw" then error("refused close") end
						return true
					end,
				}
			end
			-- A stream refusal is independent of how that exact declaration was acquired.
			io.open = function(path, ...)
				if path == "/modeled-control-declaration" then return Reader.open(path) end
				return stdio_open(path, ...)
			end
			DriverControl.new = function() acquired = acquired + 1; error("unacknowledged declaration acquired a session") end
			local ok, err = pcall(function()
				local session, detail = DriverControl.start({ declaration = "/modeled-control-declaration", pid = 4242,
					reload = function() return true end })
				helpers.assert_nil(session, "an unreadable declaration cannot publish a session")
				helpers.assert_true(type(detail) == "string" and detail ~= "", "the refusal must be explained")
				helpers.assert_eq(closes, 1, "even a refused read closes its exact acquired stream")
				helpers.assert_eq(acquired, 0, "declaration refusal precedes session acquisition")
			end)
			Reader.open, DriverControl.new, io.open = open, new, stdio_open
			if not ok then error(err, 0) end
		end)
	end

	-- Uses the actual native ports: the collision owner is acquired by O_EXCL.
	-- No daemon, watcher, process or real reload is started by these cases.
	if package.config:sub(1, 1) == "/" then
		for _, kind in ipairs({ "session", "result" }) do
			for _, collision in ipairs({ false, true }) do
				helpers.it("(native-control-owned-stage) " .. kind .. " collision=" .. tostring(collision), function()
					local uv = require("luv")
					local Writer = require("infra.regular_file_writer")
					local root = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/erg-control-stage-XXXXXX"))
					local folder = root .. "/control"
					assert(uv.fs_mkdir(folder, 448))
					local pid, reloads = uv.os_getpid(), 0
					local session = DriverControl.new({ spec = SPEC, folder = folder, pid = pid,
						reload = function() reloads = reloads + 1; return true end })
					session.ports.now = function() return NOW end
					local target, stage = session:path(kind), session:path(kind) .. ".tmp-" .. tostring(pid)
					local prior, foreign = "prior native receipt\n", "foreign native publication: é😀\n"
					local function create(path, text)
						local stream = assert(Writer.open(path, "wx"))
						assert(stream:write(text)); assert(stream:close())
					end
					local ok, err = xpcall(function()
						if kind == "result" then session:start() end
						create(target, prior)
						local before
						if collision then create(stage, foreign); before = assert(uv.fs_lstat(stage)) end
						local started
						if kind == "session" then
							started = pcall(session.start, session)
						else
							create(session:path("request"), string.format('{"schema":1,"token":"%s","request_id":"owned-stage"}', session.token))
							-- A restart is owed only after its requested record is published.
							helpers.assert_eq(session:handle(), not collision, "the actual authenticated native owner must dispatch")
							helpers.assert_eq(reloads, collision and 0 or 1, "the inert reload boundary is reached exactly once")
						end
						print(string.format("NATIVE_STAGE kind=%s collision=%s stage_present=%s prior_target=%s",
							kind, tostring(collision), tostring(uv.fs_lstat(stage) ~= nil), tostring(read(target) == prior)))
						if kind == "session" then
							helpers.assert_eq(started, not collision, "native startup must honor exclusive acquisition")
						end
						if collision then
							helpers.assert_eq(read(stage), foreign, "native foreign bytes must survive")
							helpers.assert_eq(read(target), prior, "native refusal preserves the previous receipt")
							local after = assert(uv.fs_lstat(stage))
							for _, key in ipairs({ "dev", "ino", "size" }) do helpers.assert_eq(after[key], before[key], key) end
							helpers.assert_eq(after.mtime.sec, before.mtime.sec, "native write seconds survive")
							helpers.assert_eq(after.mtime.nsec, before.mtime.nsec, "native write nanoseconds survive")
						else
							local expected = kind == "session" and Policy.session_text(SPEC, "linux", pid, session.token)
								or string.format('{"schema":1,"request_id":"owned-stage","state":"requested","driver_pid":%d,"successor_pid":null,"deadline":%d}\n', pid, NOW + SPEC.pending_ttl_seconds)
							helpers.assert_eq(read(target), expected, "native control bytes match the shared protocol")
							helpers.assert_nil(uv.fs_lstat(stage), "the owned stage was consumed by native rename")
						end
					end, debug.traceback)
					session:stop()
					-- Only flat fixture-owned leaves are removed; no recursive operation.
					for _, name in ipairs({ "session", "request", "result" }) do
						for _, path in ipairs({ session:path(name), session:path(name) .. ".tmp-" .. tostring(pid) }) do
							local removed, _, code = uv.fs_unlink(path)
							assert(removed == true or code == "ENOENT")
						end
					end
					assert(uv.fs_rmdir(folder))
					assert(uv.fs_rmdir(root))
					if not ok then error(err, 0) end
				end)
			end
		end
	end

	if package.config:sub(1, 1) == "/" then
		local uv = require("luv")
		for _, variant in ipairs({ "explicit-fifo", "default-fifo", "default-fifo-link", "explicit-file",
			"default-file-link", "default-directory", "default-missing", "default-denied" }) do
			helpers.it("(driver-control-declaration) classifies native " .. variant, function()
				local root = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/erg-control-XXXXXX"))
				local source, target = root .. "/declaration\\source\n", root .. "/target"
				local Shell = require("adapters.shell_runner")
				local expired, status, signal, exited = false, nil, nil, false
				local ok, err = xpcall(function()
					if variant:find("fifo", 1, true) then
						assert(Shell.run("mkfifo -- " .. Shell.quote(variant == "default-fifo-link" and target or source)))
					elseif variant == "default-directory" then assert(uv.fs_mkdir(source, 448))
					elseif variant ~= "default-missing" then
						local file = assert(io.open(variant == "default-file-link" and target or source, "wb"))
						assert(file:write(read(shared .. "/diagnostics/data/control/driver_control.json"))); assert(file:close())
					end
					if variant:find("-link", 1, true) then assert(uv.fs_symlink(target, source)) end
					if variant == "default-denied" then assert(uv.fs_chmod(source, 0)) end
					local admitted = variant == "explicit-file" or variant == "default-file-link"
					local code = string.format([[package.path = %q
local uv = require("luv")
local paths = require("infra.paths")
package.loaded["infra.paths"] = setmetatable({ shared = function(relative)
 if relative == "diagnostics/data/control/driver_control.json" then return %q end
 return paths.shared(relative)
end }, { __index = paths })
local getenv = os.getenv
os.getenv = function(name) if name == "XDG_RUNTIME_DIR" then return %q end; return getenv(name) end
local options = { pid = uv.os_getpid(), reload = function() return true end }
if %s then options.declaration = %q end
local session, detail = require("infra.driver_control").start(options)
assert((session ~= nil) == %s, "control declaration admission: " .. tostring(detail))
if session then assert(session:stop()) end
]], package.path, source, root, tostring(variant:find("explicit-", 1, true) == 1), source, tostring(admitted))
					local timer, child = assert(uv.new_timer()), nil
					child = assert(uv.spawn(assert(arg[-1]), { args = { "-e", code } }, function(result, killed)
						status, signal, exited = result, killed, true
						uv.timer_stop(timer); uv.close(timer); uv.close(child)
					end))
					assert(require("infra.native_timer").start(uv, timer, 2000, 0, function()
						expired = true; child:kill("sigkill")
					end))
					while not exited do uv.run("once") end
					uv.run("nowait")
					helpers.assert_eq(expired, false, "optional control startup must not wait for a FIFO writer")
					helpers.assert_eq(status, 0, "only complete regular declarations may publish a session")
					helpers.assert_eq(signal, 0, "a killed control never counts as classified")
				end, debug.traceback)
				uv.fs_chmod(source, 384)
				assert(Shell.run("rm -r -- " .. Shell.quote(root)))
				if not ok then error(err, 0) end
			end)
		end
	end
end)

return true
