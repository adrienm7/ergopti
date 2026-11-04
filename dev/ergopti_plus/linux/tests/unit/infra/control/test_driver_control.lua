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
local Json = require("json")
local Policy = require("control.driver_control")
local DriverControl = require("infra.driver_control")

local shared = helpers.driver_root() .. "/../_shared"
require("test.driver_control_contract").run(helpers, shared)

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return text
end

local SPEC = Policy.validate(Json.decode(read(shared .. "/modules/control/driver_control.json")))
local TOKEN = Json.decode(read(shared .. "/tests/corpus/control/driver_control.json")).token
local FOLDER = "/run/user/1000/ergopti_plus/control"

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
				parts[#parts + 1] = segment == "{app}" and require("app_dirs").folder_name or segment
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
						assert(file:write(read(shared .. "/modules/control/driver_control.json"))); assert(file:close())
					end
					if variant:find("-link", 1, true) then assert(uv.fs_symlink(target, source)) end
					if variant == "default-denied" then assert(uv.fs_chmod(source, 0)) end
					local admitted = variant == "explicit-file" or variant == "default-file-link"
					local code = string.format([[package.path = %q
local uv = require("luv")
local paths = require("infra.paths")
package.loaded["infra.paths"] = setmetatable({ shared = function(relative)
 if relative == "modules/control/driver_control.json" then return %q end
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
