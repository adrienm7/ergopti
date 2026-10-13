--- tests/unit/lib/test_loaded_physical_termination.lua

--- ==============================================================================
--- MODULE: Loaded Physical Owner Controlled Termination
--- DESCRIPTION:
--- Executes the actual top-level teardown body with the real scheduler and local
--- teardown transaction. Native timer delivery and the session forwarding port
--- are explicit models; this is software ownership evidence, not native proof.
--- ==============================================================================

local helpers = require("tests.helpers")
local session_name = "modules.keylogger.physical_history_session"

local function read(selector)
	local source_helpers = require("tests.helpers")
	return assert(source_helpers.read_driver_unit(selector))
end

local function fixture(options)
	options = options or {}
	local state = { native = {}, steps = 0, stop_calls = 0, retired_calls = 0,
		requires = 0, receipts = {}, layout_calls = 0, mlx_calls = 0 }
	local noop = function() end
	local logger = { info = noop, error = noop, debug = noop }
	local native_hs = { timer = {} }
	function native_hs.timer.new(delay, callback)
		local timer = { delay = delay, callback = callback, live = false, stops = 0 }
		function timer:start()
			if options.start_refused then return false end
			self.live = true
			if options.start_reentry then self.callback() end
			return self
		end
		function timer:stop()
			self.stops = self.stops + 1
			if options.cancel_refused then return false end
			self.live = false
			return self
		end
		function timer:running() return self.live end
		state.native[#state.native + 1] = timer
		return timer
	end
	local library_env = setmetatable({ hs = native_hs, require = function(name)
		assert(name == "infra.logger", "only actual library logger dependency is modeled")
		return logger
	end }, { __index = _G })
	local scheduler = assert(load(read("function M.after(delaySec, fn)"), "@actual-timer-scheduler", "t", library_env))()
	local transaction = assert(load(read("function M.run_with_finalizer(state, steps, finalizer)"), "@actual-teardown-transaction", "t", library_env))()
	local loaded = { ["modules.keylogger"] = { shutdown = function()
		state.steps = state.steps + 1
		return true
	end } }
	local owner = {}
	function owner.stop(callback)
		state.stop_calls = state.stop_calls + 1
		state.callback = callback
		if options.stop_reentry then state.reentry_result = state.teardown("reload", state.ready) end
		if options.stop_sync then state.deliver(true) end
		if options.stop_throw then error(options.stop_throw) end
		if options.stop_result ~= nil then return options.stop_result end
		return true
	end
	function owner.retired()
		state.retired_calls = state.retired_calls + 1
		return state.retired == true and state.in_callback ~= true
	end
	if not options.absent then loaded[session_name] = owner end
	if options.uninitialized then state.retired = true end
	if options.metatable_only then
		owner.stop, owner.retired = nil, nil
		setmetatable(owner, { __index = function() state.alias_reads = (state.alias_reads or 0) + 1; error("no inherited authority") end })
	end
	local env = setmetatable({
		_local_teardown_state = transaction.new_state(), _local_teardown_started = false,
		_mlx_teardown_pending = false, _mlx_teardown_settled = false,
		TimerScheduler = scheduler, TeardownTransaction = transaction, Logger = logger, LOG = "topinit-control",
		HS_BOOT_READY_SETTING_KEY = "test-ready", Storage = { set = function() return true end },
		package = { loaded = loaded }, require = function() state.requires = state.requires + 1; error("must not acquire dormant owner") end,
		_G = { script_watchers = nil },
		quit_layout_step = { run = function() state.layout_calls = state.layout_calls + 1; return true end },
	}, { __index = _G })
	if options.mlx then
		loaded["ui.menu.menu_llm"] = {
			stop_mlx_server = function(callback) state.mlx_calls = state.mlx_calls + 1; state.mlx_callback = callback; return true end,
			terminate_helper_processes = function() return true end,
			terminate_orphan_mlx_server = function() return true end,
		}
	end
	local source = read("local function teardown_all_resources(")
	local first = assert(source:find("local function teardown_all_resources(", 1, true))
	local last = assert(source:find("--- Settles scheduler capabilities", first, true))
	local body = source:sub(first, last - 1)
	local physical_helper_start = source:find("local physical_teardown_schedule =", 1, true)
		or source:find("local function settle_loaded_physical_owner(", 1, true)
	if physical_helper_start ~= nil then
		local physical_helper_end = assert(source:find("--- Releases every Lua-owned resource.", physical_helper_start, true))
		body = source:sub(physical_helper_start, physical_helper_end - 1) .. body
	end
	assert(body:find("TeardownTransaction.run", 1, true), "actual full production teardown required")
	state.teardown = assert(load(body .. "\nreturn teardown_all_resources", "@actual-root-teardown", "t", env))()
	function state.ready(value) state.receipts[#state.receipts + 1] = value; return true end
	function state.deliver(value)
		assert(type(state.callback) == "function", "actual session stop callback must be retained")
		state.in_callback = true
		local result = state.callback(value)
		state.in_callback = false
		return result
	end
	function state.fire()
		if #state.native == 0 then
			assert(state.receipts[1] == false, "earlier refusal requires its exact negative receipt")
			assert(state.steps == 0, "earlier refusal must leave all generic teardown steps untouched")
			return false
		end
		assert(#state.native == 1, "only one exact continuation is owned")
		state.native[1].callback()
	end
	state.loaded, state.owner, state.scheduler = loaded, owner, scheduler
	return state
end

helpers.describe("loaded-only physical owner termination", function()
	helpers.it("keeps ordinary absent-owner teardown synchronous with no acquisition", function()
		local s = fixture({ absent = true })
		helpers.assert_eq(s.teardown("reload", s.ready), true)
		helpers.assert_eq(s.steps, 1)
		helpers.assert_eq(s.requires, 0)
		helpers.assert_eq(#s.native, 0)
		helpers.assert_eq(#s.receipts, 0)
	end)

	helpers.it("keeps already retired loaded owner synchronous without a timer", function()
		local s = fixture({ uninitialized = true })
		helpers.assert_eq(s.teardown("reload", s.ready), true)
		helpers.assert_eq(s.steps, 1)
		helpers.assert_eq(s.requires, 0)
		helpers.assert_eq(#s.native, 0)
	end)

	helpers.it("waits before all local steps and defers exact callback until unwind", function()
		local s = fixture()
		local accepted, phase = s.teardown("reload", s.ready)
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(phase, "pending")
		helpers.assert_eq(s.steps, 0)
		helpers.assert_eq(s.stop_calls, 1)
		helpers.assert_eq(#s.native, 0)
		helpers.assert_eq(s.teardown("reload", s.ready), true)
		helpers.assert_eq(s.stop_calls, 1)
		s.retired = true
		s.deliver(true)
		helpers.assert_eq(s.steps, 0)
		helpers.assert_eq(#s.receipts, 0)
		helpers.assert_eq(#s.native, 1)
		helpers.assert_eq(s.native[1].delay, 0)
		s.fire()
		helpers.assert_eq(s.receipts[1], true)
		helpers.assert_eq(s.native[1].live, false)
		helpers.assert_eq(s.teardown("reload", s.ready), true)
		helpers.assert_eq(s.steps, 1)
		helpers.assert_eq(s.stop_calls, 1)
		helpers.assert_eq(s.requires, 0)
	end)

	helpers.it("preserves MLX prerequisite before requesting physical stop", function()
		local s = fixture({ mlx = true })
		local accepted, phase = s.teardown("reload", s.ready)
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(phase, "pending")
		helpers.assert_eq(s.mlx_calls, 1)
		helpers.assert_eq(s.stop_calls, 0)
		helpers.assert_eq(s.steps, 0)
		s.mlx_callback(true)
		s.receipts = {}
		local _, next_phase = s.teardown("reload", s.ready)
		helpers.assert_eq(next_phase, "pending")
		helpers.assert_eq(s.stop_calls, 1)
		helpers.assert_eq(s.steps, 0)
	end)

	for _, result in ipairs({ false, "accepted", 1 }) do
		helpers.it("rejects nonliteral stop acknowledgement " .. tostring(result), function()
			local s = fixture({ stop_result = result })
			helpers.assert_eq(s.teardown("reload", s.ready), false)
			helpers.assert_eq(s.steps, 0)
			helpers.assert_eq(#s.native, 0)
		end)
	end

	helpers.it("does not accept a thrown stop as completed", function()
		local s = fixture({ stop_throw = {} })
		helpers.assert_eq(s.teardown("reload", s.ready), false)
		helpers.assert_eq(s.steps, 0)
	end)

	helpers.it("holds exact stop ownership through reentrant teardown", function()
		local s = fixture({ stop_reentry = true })
		local _, phase = s.teardown("reload", s.ready)
		helpers.assert_eq(phase, "pending")
		helpers.assert_eq(s.reentry_result, true)
		helpers.assert_eq(s.stop_calls, 1)
		helpers.assert_eq(s.steps, 0)
	end)

	helpers.it("rejects callbacks that do not acknowledge literal completion", function()
		for _, completion in ipairs({ false, "settled", 1 }) do
			local s = fixture()
			s.teardown("reload", s.ready)
			s.deliver(completion)
			helpers.assert_eq(s.steps, 0)
			helpers.assert_eq(s.receipts[1], false)
			helpers.assert_eq(#s.native, 0)
		end
	end)

	helpers.it("never treats callback or timer as an owner retirement acknowledgement", function()
		local s = fixture()
		s.teardown("reload", s.ready)
		s.deliver(true)
		s.fire()
		helpers.assert_eq(s.receipts[1], false)
		helpers.assert_eq(s.steps, 0)
		helpers.assert_eq(#s.native, 1)
	end)

	helpers.it("ignores duplicate callbacks and native deliveries after once completion", function()
		local s = fixture()
		s.teardown("reload", s.ready)
		s.retired = true
		s.deliver(true)
		s.deliver(true)
		helpers.assert_eq(#s.native, 1)
		s.fire()
		s.fire()
		helpers.assert_eq(#s.receipts, 1)
		helpers.assert_eq(s.receipts[1], true)
	end)

	helpers.it("refuses changed loaded owner before continuation", function()
		local s = fixture()
		s.teardown("reload", s.ready)
		s.retired = true
		s.deliver(true)
		s.loaded[session_name] = { stop = function() return true end, retired = function() return true end }
		s.fire()
		helpers.assert_eq(s.receipts[1], false)
		helpers.assert_eq(s.steps, 0)
	end)

	helpers.it("cannot replace captured retirement authority with a mutable alias", function()
		local s = fixture()
		s.teardown("reload", s.ready)
		s.owner.retired = function() return true end
		s.deliver(true)
		s.fire()
		helpers.assert_eq(s.receipts[1], false)
		helpers.assert_eq(s.steps, 0)
	end)

	helpers.it("requires raw callable loaded ports without metatable lookup", function()
		local s = fixture({ metatable_only = true })
		helpers.assert_eq(s.teardown("reload", s.ready), false)
		helpers.assert_eq(s.alias_reads or 0, 0)
		helpers.assert_eq(s.requires, 0)
		helpers.assert_eq(s.steps, 0)
	end)

	helpers.it("keeps a refused continuation start from certifying retirement", function()
		local s = fixture({ start_refused = true })
		s.teardown("reload", s.ready)
		s.retired = true
		s.deliver(true)
		helpers.assert_eq(s.receipts[1], false)
		helpers.assert_eq(s.steps, 0)
		helpers.assert_eq(#s.native, 1)
	end)

	helpers.it("retains actual timer cleanup debt without a teardown acknowledgement", function()
		local s = fixture({ cancel_refused = true })
		s.teardown("reload", s.ready)
		s.retired = true
		s.deliver(true)
		s.fire()
		helpers.assert_eq(s.receipts[1], false)
		helpers.assert_eq(s.steps, 0)
		helpers.assert_eq(s.native[1].live, true)
		helpers.assert_eq(#s.native, 1)
		s.fire()
		helpers.assert_eq(#s.receipts, 1)
	end)

	helpers.it("preserves exact synchronous callback before a later stop throw", function()
		local s = fixture({ stop_sync = true, stop_throw = {} })
		local accepted, phase = s.teardown("reload", s.ready)
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(phase, "pending")
		helpers.assert_eq(#s.receipts, 0)
		helpers.assert_eq(#s.native, 1)
		s.retired = true
		s.fire()
		helpers.assert_eq(s.receipts[1], true)
	end)
end)

helpers.describe("physical termination foreign-boundary conservation", function()
	helpers.it("rejects retirement alias replacement after actual continuation scheduling", function()
		local s = fixture()
		s.teardown("reload", s.ready)
		s.retired = true
		s.deliver(true)
		helpers.assert_eq(#s.native, 1)
		s.owner.retired = function() return true end
		s.fire()
		helpers.assert_eq(s.receipts[1], false)
		helpers.assert_eq(s.steps, 0)
	end)

	helpers.it("revalidates exact owner on the next pass after a retirement receipt", function()
		local s = fixture()
		s.teardown("reload", s.ready)
		s.retired = true
		s.deliver(true)
		s.fire()
		helpers.assert_eq(s.receipts[1], true)
		s.loaded[session_name] = { stop = function() return true end, retired = function() return true end }
		helpers.assert_eq(s.teardown("reload", s.ready), false)
		helpers.assert_eq(s.steps, 0)
	end)

	helpers.it("does not duplicate stop when the actual retirement query reenters teardown", function()
		local s = fixture()
		local entered = false
		local original = s.owner.retired
		s.owner.retired = function()
			if not entered then
				entered = true
				s.retirement_reentry = s.teardown("reload", s.ready)
			end
			return original()
		end
		local accepted, phase = s.teardown("reload", s.ready)
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(phase, "pending")
		helpers.assert_eq(s.stop_calls, 1)
		helpers.assert_eq(s.steps, 0)
	end)
end)

-- Independent scheduler authority controls, frozen before source correction.
do
local file = assert(io.open("tests/unit/lib/test_loaded_physical_termination.lua", "rb"))
local source = file:read("*a")
file:close()
local first = assert(source:find("local session_name =", 1, true))
local last = assert(source:find('helpers.describe("loaded-only physical owner termination"', first, true))
local fixture = assert(load(source:sub(first, last - 1) .. "\nreturn fixture", "@exact-author-fixture", "t", _G))()
local cases = {}
local function check(name, test)
    cases[#cases + 1] = { name = name, test = test }
end
check("healthy actual source timer owns cleanup before positive retirement", function()
    local s = fixture()
    local accepted, state = s.teardown("reload", s.ready)
    assert(accepted == true and state == "pending")
    s.retired = true
    s.deliver(true)
    assert(#s.native == 1 and s.native[1].live == true)
    s.fire()
    assert(s.receipts[1] == true and s.native[1].live == false)
    assert(s.teardown("reload", s.ready) == true and s.steps == 1)
end)
check("changed actual scheduler cancel method cannot certify live timer cleanup", function()
    local s = fixture()
    s.teardown("reload", s.ready)
    s.retired = true
    s.deliver(true)
    assert(#s.native == 1 and s.native[1].live == true)
    local original = s.scheduler.cancel
    s.scheduler.cancel = function() return true end
    s.fire()
    local receipt, live, steps = s.receipts[1], s.native[1].live, s.steps
    local retry = s.teardown("reload", s.ready)
    s.scheduler.cancel = original
    io.write("FACT cancel_alias receipt=" .. tostring(receipt) .. " live=" .. tostring(live) .. " steps=" .. tostring(steps) .. " retry=" .. tostring(retry) .. " final_steps=" .. tostring(s.steps) .. "\n")
    assert(receipt == false, "Mutable cancel alias certified cleanup while actual timer remained live")
    assert(live == true and steps == 0 and s.steps == 0 and retry == false)
end)
check("owner stop alias changed during retirement getter never receives stop authority", function()
    local s = fixture()
    local calls = 0
    s.owner.retired = function()
        s.owner.stop = function() calls = calls + 1; return true end
        return false
    end
    assert(s.teardown("reload", s.ready) == false)
    assert(calls == 0 and s.stop_calls == 0 and s.steps == 0)
end)
check("retired getter error cannot authorize ordinary teardown", function()
    local s = fixture()
    s.owner.retired = function() error({ private = true }) end
    assert(s.teardown("reload", s.ready) == false)
    assert(s.steps == 0 and s.stop_calls == 0 and #s.native == 0)
end)
for _, case in ipairs(cases) do helpers.it(case.name, case.test) end
end

helpers.describe("exact scheduler continuation authority", function()
	helpers.it("refuses a replaced after port before scheduling any continuation", function()
		local s = fixture()
		s.teardown("reload", s.ready)
		local fake_calls = 0
		s.scheduler.after = function() fake_calls = fake_calls + 1; return {}, true end
		s.retired = true
		s.deliver(true)
		helpers.assert_eq(fake_calls, 0)
		helpers.assert_eq(#s.native, 0)
		helpers.assert_eq(s.receipts[1], false)
		helpers.assert_eq(s.steps, 0)
	end)

	helpers.it("revalidates actual after authority after scheduling", function()
		local s = fixture()
		s.teardown("reload", s.ready)
		s.retired = true
		s.deliver(true)
		helpers.assert_eq(#s.native, 1)
		s.scheduler.after = function() return {}, true end
		s.fire()
		helpers.assert_eq(s.receipts[1], false)
		helpers.assert_eq(s.steps, 0)
		helpers.assert_eq(s.teardown("reload", s.ready), false)
	end)
end)

helpers.describe("scheduler capture precedes controlled stop request", function()
	helpers.it("rejects cancellation alias installed before requesting loaded-owner stop", function()
		local s = fixture()
		s.scheduler.cancel = function() return true end
		helpers.assert_eq(s.teardown("reload", s.ready), false)
		helpers.assert_eq(s.stop_calls, 0)
		helpers.assert_eq(#s.native, 0)
		helpers.assert_eq(s.steps, 0)
	end)

	helpers.it("rejects scheduling alias installed before requesting loaded-owner stop", function()
		local s = fixture()
		local fake_calls = 0
		s.scheduler.after = function() fake_calls = fake_calls + 1; return {}, true end
		helpers.assert_eq(s.teardown("reload", s.ready), false)
		helpers.assert_eq(s.stop_calls, 0)
		helpers.assert_eq(fake_calls, 0)
		helpers.assert_eq(#s.native, 0)
		helpers.assert_eq(s.steps, 0)
	end)
end)
