--- tests/unit/infra/control/test_driver_control.lua

--- ==============================================================================
--- MODULE: Local Driver Control (macOS)
--- DESCRIPTION:
--- Replays the shared driver-control contract, then drives a genuine session
--- over in-memory files and a fake folder watcher: an authenticated request
--- reaches the termination coordinator and names this process, the reloaded
--- state completes it, and a stale token, a refusing coordinator or an abort
--- is reported as refused.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Policy = require("control.driver_control")

require("test.driver_control_contract").run(helpers, helpers.shared(""))

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return text
end

local SPEC = Policy.validate(Json.decode(read(helpers.shared("modules/control/driver_control.json"))))
local TOKEN = Json.decode(read(helpers.shared("tests/corpus/control/driver_control.json"))).token
local FOLDER = "/Users/u/Library/Application Support/ergopti_plus/control"

--- A session over in-memory files; `coordinator(reason, on_aborted)` answers the reload.
local function world(coordinator, files)
	files = files or {}
	local state = { files = files, calls = {}, deferred = {}, watcher = nil, stopped = 0 }
	local ports = {
		read = function(path) return files[path] end,
		write = function(path, text) files[path] = text; return true end,
		remove = function(path) files[path] = nil; return true end,
		exists = function(path) return files[path] ~= nil end,
		private_dir = function() return true end,
		random_hex = function() return TOKEN end,
		watch = function(path, callback)
			state.watched = path
			state.watcher = callback
			return { stop = function() state.stopped = state.stopped + 1 end }
		end,
		defer = function(callback) state.deferred[#state.deferred + 1] = callback end,
	}
	local DriverControl = require("infra.driver_control")
	state.session = DriverControl.new({ spec = SPEC, folder = FOLDER, pid = 777, ports = ports,
		request_reload = function(reason, on_aborted)
			state.calls[#state.calls + 1] = reason
			return coordinator(reason, on_aborted)
		end })
	return state
end

local function ring(state, token, id)
	state.files[FOLDER .. "/reload.request"] = string.format('{"schema":1,"token":"%s","request_id":"%s"}', token, id)
	state.watcher({ FOLDER .. "/reload.request" })
	helpers.assert_eq(#state.deferred, 1, "the request runs on a later timer, not in the watcher callback")
	local run = table.remove(state.deferred, 1)
	run()
end

helpers.describe("macOS local driver control", function()
	helpers.it("hands an authenticated request to the termination coordinator", function()
		local state = world(function() return true end)
		state.session:start()
		helpers.assert_eq(state.watched, FOLDER)
		helpers.assert_eq(state.files[FOLDER .. "/session.json"],
			'{"schema":1,"driver":"macos","pid":777,"token":"' .. TOKEN .. '"}\n')
		ring(state, TOKEN, "mac-1")
		helpers.assert_eq(#state.calls, 1, "one controlled reload is requested")
		helpers.assert_eq(state.calls[1], "driver_control")
		helpers.assert_nil(state.files[FOLDER .. "/reload.request"], "the request is consumed")
		helpers.assert_eq(state.files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"mac-1","state":"requested","driver_pid":777,"successor_pid":777}\n')
		helpers.assert_eq(state.session:stop(), true)
		helpers.assert_eq(state.stopped, 1, "the folder watcher is retired")
		helpers.assert_nil(state.files[FOLDER .. "/session.json"], "the session withdraws its own file")
	end)

	helpers.it("completes the request in the reloaded Lua state", function()
		local files = { [FOLDER .. "/reload.result"] =
			'{"schema":1,"request_id":"mac-1","state":"requested","driver_pid":777,"successor_pid":777}\n' }
		local state = world(function() return true end, files)
		state.session:start()
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"mac-1","state":"completed","driver_pid":777,"successor_pid":777}\n')
	end)

	helpers.it("refuses a stale token without asking for a reload", function()
		local state = world(function() return true end)
		state.session:start()
		ring(state, (TOKEN:gsub("0", "1")), "stale")
		helpers.assert_eq(#state.calls, 0, "an unauthenticated request never reaches the coordinator")
		helpers.assert_eq(state.files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"stale","state":"refused","driver_pid":777,"reason":"unauthenticated"}\n')
	end)

	helpers.it("reports a coordinator refusal and an abort as refused", function()
		local state = world(function() return false end)
		state.session:start()
		ring(state, TOKEN, "busy-1")
		helpers.assert_eq(state.files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"busy-1","state":"refused","driver_pid":777,"reason":"busy"}\n')
		local aborting = world(function(_, on_aborted) on_aborted(); return true end)
		aborting.session:start()
		ring(aborting, TOKEN, "abort-1")
		helpers.assert_eq(aborting.files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"abort-1","state":"refused","driver_pid":777,"reason":"refused"}\n')
	end)

	-- The reloaded state can only complete a request if boot starts the control
	-- after it is complete, and a controlled teardown must retire its watcher.
	helpers.it("starts after a complete boot on the owned controlled reload and stops in teardown", function()
		local init = assert(helpers.read_driver_unit("Storage.set(HS_BOOT_READY_SETTING_KEY, true)"))
		local ready = assert(init:find("Storage.set(HS_BOOT_READY_SETTING_KEY, true)", 1, true))
		local start = init:find('require("infra.driver_control").start({', 1, true)
		helpers.assert_true(start ~= nil and start > ready, "the control starts once boot is complete")
		helpers.assert_true(init:find("return TerminationCoordinator.request_reload_owned(reason, on_aborted)", start, true) ~= nil,
			"a request goes through the owned controlled reload")
		local step = init:find('name = "driver-control",', 1, true)
		helpers.assert_true(step ~= nil and step < ready, "the local teardown retires the control")
		helpers.assert_true(init:find('package.loaded["infra.driver_control"]', step, true) ~= nil)
	end)

	helpers.it("ignores other files in the folder and refuses a second start", function()
		local state = world(function() return true end)
		state.session:start()
		state.watcher({ FOLDER .. "/reload.result", FOLDER .. "/session.json" })
		helpers.assert_eq(#state.deferred, 0, "only the request file rings the session")
		helpers.assert_true(not pcall(state.session.start, state.session), "a second start is refused")
	end)
end)

return true
