--- tests/unit/infra/test_sqlite_batch_process.lua

--- The transport model exposes each write/shutdown/close receipt independently;
--- native regressions exercise the same public transport with real SQLite.
local helpers = require("tests.helpers")
require("infra.monotonic") -- Never freeze a temporary native port into the clock.
local names = { "luv", "adapters.owned_process", "infra.sqlite_batch_process" }
local function with_transport(body)
	local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local ports = { writes = {}, shutdowns = {} }
	local operation = { started = true, settled = false }
	function operation:is_settled() return self.settled end
	function operation:cancel() ports.options.stdin_owner:cancel(); return self.settled end
	package.loaded["luv"] = {
		exepath = function() return "/owned/luajit" end,
		os_getpid = function() return 1234 end,
		update_time = function() ports.fresh = true end,
		new_pipe = function()
			helpers.assert_true(ports.fresh, "new native ownership must use fresh loop time")
			return ports.pipe or {}
		end,
		write = function(pipe, text, callback)
			ports.writes[#ports.writes + 1] = { pipe = pipe, text = text, callback = callback }
			if ports.write_refused then return nil end
			if ports.write_throws then error("controlled acquired write") end
			return {}
		end,
		shutdown = function(pipe, callback)
			ports.shutdowns[#ports.shutdowns + 1] = { pipe = pipe, callback = callback }
			return {}
		end,
	}
	package.loaded["adapters.owned_process"] = { start = function(executable, args, options, callback)
		ports.executable, ports.args, ports.options, ports.complete = executable, args, options, callback
		return operation
	end }
	package.loaded["infra.sqlite_batch_process"] = nil
	local ok, err = xpcall(function() body(require("infra.sqlite_batch_process"), ports, operation) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("private SQLite stdin transport", function()
	helpers.it("never places private SQL in argv or retained process output", function()
		with_transport(function(process, ports, operation)
			local sql = "SELECT 'owned-private-transport';"
			local request = process.start("-database.sqlite", sql, { owner = "owned", timeout_ms = 1000 })
			helpers.assert_eq(ports.args[2], "1234")
			helpers.assert_eq(ports.args[3], "./-database.sqlite")
			helpers.assert_eq(ports.options.capture_output, false)
			for _, value in ipairs(ports.args) do helpers.assert_true(not value:find(sql, 1, true)) end
			helpers.assert_eq(ports.writes[1].text, sql)
			helpers.assert_eq(ports.options.stdin_owner:can_close(), false)
			ports.writes[1].callback(nil)
			helpers.assert_eq(ports.options.stdin_owner:can_close(), false)
			ports.shutdowns[1].callback(nil)
			helpers.assert_true(ports.options.stdin_owner:can_close())
			ports.options.on_output("secret-error-body", "stderr")
			ports.options.on_output("1\n", "stdout")
			ports.complete({ ok = true, exit_code = 0 })
			helpers.assert_eq(request:poll(), nil, "callback alone cannot acknowledge native cleanup")
			operation.settled = true
			helpers.assert_eq(request:poll().output, "1\n")
			helpers.assert_true(request:poll().ok)
		end)
	end)

	helpers.it("cancellation keeps the exact pending write until its callback", function()
		with_transport(function(process, ports)
			local request = process.start("database.sqlite", "SELECT 1;", { owner = "owned", timeout_ms = 1000 })
			helpers.assert_eq(request:cancel(), false)
			helpers.assert_eq(ports.options.stdin_owner:is_settled(), false)
			helpers.assert_eq(ports.options.stdin_owner:can_close(), false)
			ports.writes[1].callback("ECANCELED")
			helpers.assert_true(ports.options.stdin_owner:is_settled())
			helpers.assert_eq(ports.options.stdin_owner:result().ok, false)
			helpers.assert_eq(#ports.shutdowns, 0)
		end)
	end)

	helpers.it("a throwing acquired write cannot manufacture a cleanup ACK", function()
		with_transport(function(process, ports)
			ports.write_throws = true
			local request = process.start("database.sqlite", "SELECT 1;", { owner = "owned", timeout_ms = 1000 })
			request:cancel()
			helpers.assert_eq(ports.options.stdin_owner:can_close(), false)
			helpers.assert_eq(request:poll(), nil)
			ports.writes[1].callback("ECANCELED")
			helpers.assert_true(ports.options.stdin_owner:can_close())
		end)
	end)

	helpers.it("known write refusal settles only stdin, not native process cleanup", function()
		with_transport(function(process, ports, operation)
			ports.write_refused = true
			local request = process.start("database.sqlite", "SELECT 1;", { owner = "owned", timeout_ms = 1000 })
			helpers.assert_true(ports.options.stdin_owner:can_close())
			helpers.assert_eq(request:poll(), nil)
			operation.result, operation.settled = { ok = false }, true
			helpers.assert_eq(request:poll().ok, false)
		end)
	end)

	helpers.it("bounds protocol stdout and rejects overflow without returning its body", function()
		with_transport(function(process, ports, operation)
			local request = process.start("database.sqlite", "SELECT 1;", { owner = "owned", timeout_ms = 1000 })
			ports.writes[1].callback(nil); ports.shutdowns[1].callback(nil)
			ports.options.on_output(string.rep("x", 257), "stdout")
			ports.complete({ ok = true, exit_code = 0 }); operation.settled = true
			helpers.assert_eq(request:poll().ok, false)
			helpers.assert_eq(request:poll().output, nil)
		end)
	end)
end)
