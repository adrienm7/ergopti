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
local function world(reload, private)
	local files, calls = {}, {}
	local ports = {
		read = function(path) return files[path] end,
		write = function(path, text) files[path] = text; return true end,
		remove = function(path) files[path] = nil; return true end,
		rename = function(from, to) files[to] = files[from]; files[from] = nil; return true end,
		exists = function(path) return files[path] ~= nil end,
		private_dir = function() return private ~= false end,
		random_hex = function() return TOKEN end,
	}
	local session = DriverControl.new({ spec = SPEC, folder = FOLDER, pid = 4242, ports = ports,
		reload = function(trigger)
			calls[#calls + 1] = trigger
			return reload()
		end })
	return session, files, calls
end

local function request(files, token, id)
	files[FOLDER .. "/reload.request"] = string.format('{"schema":1,"token":"%s","request_id":"%s"}', token, id)
end

helpers.describe("Linux local driver control", function()
	helpers.it("publishes its session and completes an authenticated reload in this process", function()
		local session, files, calls = world(function() return true end)
		session:start()
		helpers.assert_eq(files[FOLDER .. "/session.json"],
			'{"schema":1,"driver":"linux","pid":4242,"token":"' .. TOKEN .. '"}\n')
		request(files, TOKEN, "sh-1")
		helpers.assert_eq(session:handle(), true)
		helpers.assert_eq(#calls, 1, "the tray's reload owner runs once")
		helpers.assert_nil(files[FOLDER .. "/reload.request"], "the request is consumed")
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"sh-1","state":"completed","driver_pid":4242,"successor_pid":4242}\n')
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

	helpers.it("keeps a successor's session when it stops", function()
		local session, files = world(function() return true end)
		session:start()
		local successor = '{"schema":1,"driver":"linux","pid":5000,"token":"' .. TOKEN:gsub("0", "5") .. '"}\n'
		files[FOLDER .. "/session.json"] = successor
		helpers.assert_eq(session:stop(), true)
		helpers.assert_eq(files[FOLDER .. "/session.json"], successor)
	end)
end)

return true
