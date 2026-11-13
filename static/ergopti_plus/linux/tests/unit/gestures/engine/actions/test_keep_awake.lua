--- tests/unit/gestures/engine/actions/test_keep_awake.lua

--- ==============================================================================
--- MODULE: Session Idle Inhibitor Regression (Linux)
--- DESCRIPTION:
--- Acquisition requires the inhibited child marker, failed launches never
--- announce success, and cancellation keeps custody until native settlement.
--- A real libuv child proves the private stdin lifetime without touching logind.
--- ==============================================================================

local helpers = require("tests.helpers")
local KeepAwake = require("modules.keep_awake")

--- A controlled process and scheduler with independently delivered settlement.
--- @return table fixture
local function fixture()
	local f = { notices = {}, launches = 0, running = true, settled = false, present = true, now = 0, sessions = {} }
	local op = { started = true }
	function op:is_running() return f.running end
	function op:is_settled() return f.settled end
	function op:on_settled(fn) f.on_settled = fn; if f.settled then fn() end; return true end
	function op:cancel() f.cancelled = true; return f.settled end
	local input = {}
	function input:cancel() f.input_closed = true; return true end
	f.owner = KeepAwake.new({
		has_command = function(name) helpers.assert_eq(name, "systemd-inhibit"); return f.present end,
		pipe = function() return input end,
		start = function(name, args, options)
			helpers.assert_eq(name, "systemd-inhibit")
			helpers.assert_eq(args[1], "--what=idle")
			helpers.assert_eq(options.stdin_owner, input)
			f.launches, f.options = f.launches + 1, options
			return op
		end,
		scheduler = {
			every = function(_, fn) f.poll = fn; return { armed = true } end,
			cancel = function() return not f.refuse_timer end,
		},
		notify = function(key) f.notices[#f.notices + 1] = key end,
		now_ms = function() return f.now end,
		record_session = function(duration_ms) f.sessions[#f.sessions + 1] = duration_ms; return true end,
	})
	function f.finish() f.settled, f.running = true, false; f.on_settled() end
	return f
end

helpers.describe("Linux idle inhibition (linux-keep-awake)", function()
	helpers.it("linux-keep-awake: fragmented acquisition receipt then toggle retains physical cleanup", function()
		local f = fixture()
		helpers.assert_true(f.owner.toggle())
		helpers.assert_eq(f.owner.is_active(), false)
		helpers.assert_eq(#f.notices, 0, "launch alone proves no inhibition")
		f.options.on_output("ERGOPTI_", "stdout")
		f.options.on_output("INHIBITED\n", "stdout")
		helpers.assert_true(f.owner.is_active())
		helpers.assert_eq(f.notices, { "shortcuts.keep_awake_inhibitor_on" })
		helpers.assert_eq(f.owner.toggle(), false, "native retirement remains pending")
		helpers.assert_true(f.cancelled and f.input_closed)
		local settled = false
		helpers.assert_true(f.owner.when_settled(function() settled = true end))
		helpers.assert_eq(settled, false)
		f.owner.toggle()
		helpers.assert_eq(f.launches, 1, "another toggle cannot create a second inhibitor")
		f.finish()
		helpers.assert_true(settled)
		helpers.assert_eq(f.owner.is_active(), false)
		helpers.assert_eq(f.notices[2], "shortcuts.keep_awake_off")
		helpers.assert_true(f.owner.stop())
	end)

	-- KMD-3 (decided by the maintainer on 2026-11-11): a finished session is the
	-- day's awake_ms, as on Windows and macOS; an unconfirmed one credits nothing.
	helpers.it("linux-awake-definition: a released session credits its confirmed time", function()
		local f = fixture()
		f.now = 1000
		helpers.assert_true(f.owner.toggle())
		f.now = 4000
		f.options.on_output("ERGOPTI_INHIBITED\n", "stdout")
		f.now = 64000
		f.owner.toggle()
		helpers.assert_eq(f.sessions, {}, "nothing is credited before native retirement")
		f.finish()
		helpers.assert_eq(f.sessions, { 60000 }, "from the confirmed inhibition to the release")
		local refused = fixture()
		helpers.assert_true(refused.owner.toggle())
		refused.owner.toggle()
		refused.finish()
		helpers.assert_eq(refused.sessions, {}, "a session never confirmed is no keep-awake time")
	end)

	helpers.it("linux-keep-awake: missing tool or refused acquisition never reports active", function()
		local f = fixture()
		f.present = false
		helpers.assert_eq(f.owner.toggle(), false)
		helpers.assert_eq(f.launches, 0)
		f.present = true
		helpers.assert_true(f.owner.toggle())
		for _ = 1, 5 do f.poll() end
		helpers.assert_true(f.cancelled)
		helpers.assert_eq(f.owner.is_active(), false)
		f.finish()
		for _, key in ipairs(f.notices) do helpers.assert_eq(key, "notify.keep_awake_failed") end
	end)

	helpers.it("linux-keep-awake: a refused timer retirement retains the owner after process exit", function()
		local f = fixture()
		helpers.assert_true(f.owner.toggle())
		f.refuse_timer = true
		helpers.assert_eq(f.owner.stop(), false)
		local settled = false
		f.owner.when_settled(function() settled = true end)
		f.finish()
		helpers.assert_eq(settled, false)
		f.refuse_timer = false
		helpers.assert_true(f.owner.stop())
		helpers.assert_true(settled)
	end)

	helpers.it("linux-keep-awake: autonomous process failures report refusal and never orphan a timer", function()
		local f = fixture()
		f.settled = true
		helpers.assert_eq(f.owner.toggle(), false)
		helpers.assert_eq(f.poll, nil, "an already retired child cannot own a repeating timer")
		helpers.assert_eq(f.notices, { "notify.keep_awake_failed" })
		f = fixture()
		helpers.assert_true(f.owner.toggle())
		f.finish()
		helpers.assert_eq(f.notices, { "notify.keep_awake_failed" })
		helpers.assert_true(f.owner.stop())
	end)

	helpers.it("linux-keep-awake: real child holds until its daemon-owned pipe closes", function()
		local uv = require("luv")
		local Process = require("core.process.adapters.owned_process")
		local operation, input, active, sessions = nil, nil, false, {}
		local owner = KeepAwake.new({
			-- Its own sink: the metrics sampler is process-wide, and a session
			-- credited there would outlive this case (KMD-3).
			record_session = function(duration_ms) sessions[#sessions + 1] = duration_ms; return true end,
			has_command = function() return true end,
			start = function(_, args, options, callback)
				input = options.stdin_owner
				operation = Process.start("sh", { "-c", args[#args] }, options, callback)
				return operation
			end,
			notify = function(key) if key == "shortcuts.keep_awake_inhibitor_on" then active = true end end,
		})
		local function await(predicate)
			local deadline = uv.hrtime() + 3000000000
			while not predicate() and uv.hrtime() < deadline do uv.run("nowait"); uv.sleep(1) end
			return predicate()
		end
		local ok, err = pcall(function()
			helpers.assert_true(owner.toggle())
			helpers.assert_true(await(function() return active end), "real child acknowledged inhibition")
			helpers.assert_true(operation:is_running())
			input:cancel() -- The same EOF an exited daemon delivers, without a signal.
			helpers.assert_true(await(function() return operation:is_settled() end), "EOF retires the real child")
		end)
		owner.stop()
		await(function() return not operation or operation:is_settled() end)
		uv.run("nowait")
		if not ok then error(err, 0) end
		helpers.assert_eq(#sessions, 1, "the released real session is credited once")
	end)

	helpers.it("linux-keep-awake: the action is offered through the actual catalogue handler", function()
		local row = require("_generated.action_catalogue").actions.activity_simulation
		helpers.assert_true(row ~= nil)
		helpers.assert_eq(row.requires, { "tool:systemd-inhibit" })
		local previous, calls = package.loaded["modules.keep_awake"], 0
		package.loaded["modules.keep_awake"] = { toggle = function() calls = calls + 1; return true end }
		local ok, err = pcall(require("gestures.engine.system_actions").HANDLERS.activity_simulation)
		package.loaded["modules.keep_awake"] = previous
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(calls, 1)
	end)

	helpers.it("linux-keep-awake: shutdown waits for inhibitor settlement and pause releases it", function()
		local manager = helpers.load_module("gestures.engine.manager")
		local previous, stopped, listener = package.loaded["modules.keep_awake"], 0, nil
		package.loaded["modules.keep_awake"] = {
			stop = function() stopped = stopped + 1; return false end,
			when_settled = function(fn) listener = fn; return true end,
		}
		local ok, err = pcall(function()
			helpers.assert_eq(manager.set_program_paused(true), false)
			helpers.assert_eq(manager.stop_programs(), false)
			helpers.assert_eq(stopped, 2)
			local done = false
			helpers.assert_true(manager.when_programs_settled(function() done = true end))
			helpers.assert_eq(done, false)
			listener()
			helpers.assert_true(done)
		end)
		package.loaded["modules.keep_awake"] = previous
		manager.set_program_paused(false)
		if not ok then error(err, 0) end
	end)
end)
