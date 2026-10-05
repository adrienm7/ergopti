--- tests/unit/modules/keylogger/test_physical_lifecycle_observation.lua

--- Exercises dormant lifecycle ports against actual native module writer bodies.
--- Hammerspoon boundaries are adversarial stubs; this is not native macOS proof.
local helpers = require("tests.helpers")
local describe, it = helpers.describe, helpers.it

local MODULE_NAMES = {
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"infra.logger",
	"infra.timings",
	"modules.keylogger.context_tracker",
	"modules.keylogger.log_manager",
	"modules.keylogger.watchers",
	"keylogger.physical_lifecycle_observation",
	"adapters.physical_observation_clock",
}

--- Creates one object-style Hammerspoon watcher with injectable lifecycle results.
--- @param label string Watcher diagnostic label.
--- @param callback function Native callback.
--- @param options table Fixture options.
--- @param watchers table All constructed watcher handles.
--- @return table watcher Native watcher stub.
local function make_object_watcher(label, callback, options, watchers)
	local watcher = {
		label = label,
		callback = callback,
		running = false,
		start_calls = 0,
		stop_calls = 0,
	}
	function watcher:start()
		self.start_calls = self.start_calls + 1
		self.running = true
		local result = options.start_results
			and options.start_results[label]
		if result == "throw" then error(label .. " start exploded") end
		if result == false then return false end
		return self
	end
	function watcher:stop()
		self.stop_calls = self.stop_calls + 1
		local sequence = options.stop_results and options.stop_results[label]
		local result = sequence and sequence[self.stop_calls]
		if result == "throw" then error(label .. " stop exploded") end
		if result == false then return false end
		self.running = false
		return self
	end
	watchers[label] = watcher
	return watcher
end

--- Runs one isolated watcher-lifecycle scenario.
--- @param options table|nil Native and scheduler behavior controls.
--- @param scenario function Scenario receiving module, fixture, and state.
local function with_fixture(options, scenario)
	options = options or {}
	local saved = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local saved_hs = _G.hs

	local fixture = {
		watchers = {},
		system_events = {},
		log_entries = {},
		timers = {},
		cancel_calls = {},
		capture_calls = 0,
		flush_calls = 0,
		error_lines = {},
		now_ms = options.now_ms or 1000,
	}
	local audio = {
		callback = nil,
		running = false,
		start_calls = 0,
		stop_calls = 0,
	}
	function audio.setCallback(callback)
		audio.callback = callback
		if callback ~= nil and options.audio_set_callback_throw then
			error("audio callback setter exploded after mutation")
		end
	end
	function audio.start()
		audio.start_calls = audio.start_calls + 1
		audio.running = true
		if options.audio_start == "throw" then error("audio start exploded") end
	end
	function audio.stop()
		audio.stop_calls = audio.stop_calls + 1
		local result = options.audio_stop_results
			and options.audio_stop_results[audio.stop_calls]
		if result == "throw" then error("audio stop exploded") end
		if result == false then return false end
		audio.running = false
		return audio
	end
	function audio.isRunning() return audio.running end
	fixture.audio = audio

	local hs_stub = {
		timer = { absoluteTime = function() fixture.clock_reads = (fixture.clock_reads or 0) + 1; return fixture.now_ms * 1000000 + fixture.clock_reads end },
		mouse = { absolutePosition = function() return { x = 0, y = 0 } end },
		caffeinate = {
			watcher = {
				systemWillSleep = 1,
				screensDidSleep = 2,
				systemDidWake = 3,
				screensDidWake = 4,
				screensDidLock = 5,
				screensDidUnlock = 6,
			},
		},
		wifi = {
			currentNetwork = function() return "Test Wi-Fi" end,
			watcher = {
				new = function(callback)
					return make_object_watcher("wifi", callback, options, fixture.watchers)
				end,
			},
		},
		battery = {
			percentage = function() return 75 end,
			isCharging = function() return true end,
			powerSource = function() return "AC Power" end,
			watcher = {
				new = function(callback)
					return make_object_watcher("battery", callback, options, fixture.watchers)
				end,
			},
		},
		spaces = {
			watcher = {
				new = function(callback)
					return make_object_watcher("spaces", callback, options, fixture.watchers)
				end,
			},
		},
		audiodevice = {
			watcher = audio,
			defaultOutputDevice = function()
				return {
					volume = function() return 40 end,
					muted = function() return false end,
				}
			end,
		},
	}
	_G.hs = hs_stub

	local function noop() end
	package.loaded["infra.logger"] = setmetatable({
		callback = function(_, _, callback, ...) return pcall(callback, ...) end,
		error = function(_, format_string, ...)
			fixture.error_lines[#fixture.error_lines + 1] = string.format(format_string, ...)
		end,
	}, { __index = function() return noop end })
	package.loaded["infra.timings"] = {
		ms = function(_, key)
			return options.timings and options.timings[key] or 1
		end,
	}
	package.loaded["adapters.task_lifecycle"] = {
		native = function() return nil end,
		start = function() return false end,
	}
	local scheduler = {}
	function scheduler.after(_, callback)
		local mode = options.after_mode or "commit"
		if mode == "throw" then error("context timer constructor exploded") end
		if mode == "nil" then return nil, false end
		local handle = { callback = callback, active = true, timer = {} }
		fixture.timers[#fixture.timers + 1] = handle
		return handle, mode == "commit"
	end
	function scheduler.cancel(handle)
		fixture.cancel_calls[#fixture.cancel_calls + 1] = handle
		local result = options.cancel_results
			and options.cancel_results[#fixture.cancel_calls]
		if result == "throw" then error("context timer cancel exploded") end
		if result == false then return false end
		handle.active = false
		handle.timer = nil
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["modules.keylogger.log_manager"] = {
		append_log = function(entry)
			fixture.log_entries[#fixture.log_entries + 1] = entry
		end,
		flush_buffer = function()
			fixture.flush_calls = fixture.flush_calls + 1
			return true
		end,
		day_rollover = function() return true end,
		log_app_switch = noop,
		log_passive_period = noop,
		log_system_event = function(kind, payload)
			fixture.system_events[#fixture.system_events + 1] = {
				kind = kind,
				payload = payload,
			}
		end,
	}
	package.loaded["modules.keylogger.context_tracker"] = {
		capture_frontmost_app = function()
			fixture.capture_calls = fixture.capture_calls + 1
			return true
		end,
	}

	local state = {
		is_enabled = true,
		is_secure_field = false,
		active_app_name = nil,
		active_app_start = 0,
		current_battery_level = nil,
		buffer_events = {},
		last_mouse_pos = nil,
		mouse_distance_px = 0,
		session_last_active = 0,
	}
	local watchers = require("modules.keylogger.watchers")
	helpers.assert_eq(watchers.init(state, function()
		if options.pause_throw then error("pause predicate exploded") end
		if options.pause_nil then return nil end
		return options.paused == true
	end), true)
	local ok, err = xpcall(function()
		scenario(watchers, fixture, state)
	end, debug.traceback)
	watchers.stop_hardware_watchers()
	_G.hs = saved_hs
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end





-- =================================================
-- =================================================
-- ======= 2/ Composite Watcher Transactions =======
-- =================================================
-- =================================================

local function bind_watchers(watchers, capacity, receive)
	local records, owner = {}, {}
	local token, reason = watchers.bind_physical_lifecycle_observer(owner, capacity or 100, function(record, observed_token)
		records[#records + 1] = record
		if receive then return receive(record, observed_token) end
		return true
	end)
	helpers.assert_true(token ~= nil, tostring(reason))
	return records, owner, token
end

local function last(records) return records[#records] end

local function actor_fixture(capacity, callback, clock)
	local now, records, refused = 0, {}, {}
	local actor = require("keylogger.physical_lifecycle_observation").new("engine", clock or function()
		now = now + 1; return now
	end, function(reason) refused[#refused + 1] = reason end)
	local owner = {}
	local token = actor.bind(owner, capacity or 100, function(record, observed_token)
		records[#records + 1] = record
		if callback then return callback(actor, record, observed_token) end
		return true
	end)
	helpers.assert_true(token ~= nil)
	return actor, records, refused, owner, token
end

local function engine_snapshot()
	return { enabled = true, paused = false, runtime_generation = 2 }
end

describe("Dormant physical lifecycle actor", function()
	it("seeds denied without snapshot or writer side effects", function()
		local _, records = actor_fixture()
		helpers.assert_eq(#records, 1)
		helpers.assert_eq(records[1].source, "binding")
		helpers.assert_eq(records[1].allowed, false)
		helpers.assert_eq(records[1].complete, false)
	end)
	it("denies before foreign work and preserves all legacy return values", function()
		local actor, records = actor_fixture()
		local a, b, c = actor.run("start", function()
			helpers.assert_eq(last(records).stage, "boundary")
			helpers.assert_eq(last(records).allowed, false)
			return true, nil, "tail"
		end, engine_snapshot)
		helpers.assert_eq(a, true); helpers.assert_eq(b, nil); helpers.assert_eq(c, "tail")
		helpers.assert_eq(last(records).fields_complete, true)
		helpers.assert_eq(last(records).complete, true)
		helpers.assert_eq(last(records).allowed, false)
	end)
	it("reserves the completion clock before the foreign pause snapshot",function()
		local calls=0
		local actor,records=actor_fixture(100,nil,function() calls=calls+1; return calls end)
		actor.run("start",function() return true end,function()
			helpers.assert_eq(calls,3)
			return engine_snapshot()
		end)
		helpers.assert_eq(last(records).complete,true)
	end)
	it("completion clock owner detachment skips the foreign snapshot",function()
		local calls,actor,owner,token,ignored_records,ignored_refused=0
		actor,ignored_records,ignored_refused,owner,token=actor_fixture(100,nil,function()
			calls=calls+1
			if calls==3 then helpers.assert_eq(actor.unbind(owner,token),true) end
			return calls
		end)
		local queries=0
		actor.run("start",function() return true end,function() queries=queries+1; return engine_snapshot() end)
		helpers.assert_eq(queries,0)
	end)
	it("unbound actor performs no clock or snapshot queries", function()
		local queries = 0
		local actor = require("keylogger.physical_lifecycle_observation").new("engine", function() error("extra clock") end, function() end)
		local result = actor.run("start", function() return false end, function() queries = queries + 1 end)
		helpers.assert_eq(result, false); helpers.assert_eq(queries, 0)
	end)
	it("nil pause cannot complete even after successful writer", function()
		local actor, records = actor_fixture()
		actor.run("resync", function() return true end, function() return { enabled=true, runtime_generation=2 } end)
		helpers.assert_eq(last(records).complete, false)
		helpers.assert_eq(last(records).fields_complete, false)
	end)
	it("failed writer records known fields but cannot complete", function()
		local actor, records = actor_fixture()
		actor.run("stop", function() return false end, engine_snapshot)
		helpers.assert_eq(last(records).fields_complete, true)
		helpers.assert_eq(last(records).complete, false)
		helpers.assert_eq(last(records).allowed, false)
	end)
	it("throwing writer preserves its error and denied receipt", function()
		local actor, records = actor_fixture()
		local ok, reason = pcall(actor.run, "stop", function() error("native writer failure") end, engine_snapshot)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(reason):find("native writer failure",1,true) ~= nil)
		helpers.assert_eq(last(records).complete, false)
	end)
	it("throwing snapshot retains legacy success without completion", function()
		local actor, records = actor_fixture()
		helpers.assert_eq(actor.run("start", function() return true end, function() error("pause failure") end), true)
		helpers.assert_eq(last(records).complete, false)
	end)
	it("a receipt refusal retires before further foreign snapshot", function()
		local actor, records, refused = actor_fixture(100, function(_, record) return record.source == "binding" end)
		local queries = 0
		actor.run("start", function() return true end, function() queries = queries + 1; return engine_snapshot() end)
		helpers.assert_eq(queries, 0); helpers.assert_eq(#refused, 1)
		helpers.assert_eq(#records, 2)
	end)
	it("literal true acknowledgement rejects truthy values", function()
		local actor = require("keylogger.physical_lifecycle_observation").new("engine", function() return 1 end, function() end)
		local token = actor.bind({}, 10, function() return 1 end)
		helpers.assert_eq(token, nil)
	end)
	it("exact owner and token reject forged equality metamethods", function()
		local actor, _, _, owner, token = actor_fixture()
		local forged = setmetatable({}, {__eq=function() error("must not run equality hook") end})
		helpers.assert_eq(actor.unbind(forged, token), false)
		helpers.assert_eq(actor.unbind(owner, forged), false)
		helpers.assert_eq(actor.unbind(owner, token), true)
	end)
	it("capacity exhaustion retires before a completion snapshot", function()
		local actor, records, refused = actor_fixture(1)
		local queries = 0
		actor.run("start", function() return true end, function() queries=queries+1 end)
		helpers.assert_eq(queries,0); helpers.assert_eq(#records,1); helpers.assert_eq(#refused,1)
	end)
	it("same actor writer reentry cannot restore current completion", function()
		local actor, records, refused = actor_fixture()
		actor.run("start", function()
			actor.run("stop", function() return true end, engine_snapshot)
			return true
		end, engine_snapshot)
		helpers.assert_eq(last(records).complete,false); helpers.assert_eq(#refused,1)
	end)
	it("detachment during boundary leaves replacement seed denied", function()
		local actor, records, _, owner, token = actor_fixture()
		actor.unbind(owner,token)
		local replacement = {}
		token = actor.bind(owner,100,function(record)
			records[#records+1]=record
			if record.source == "start" then
				helpers.assert_eq(actor.unbind(owner,token),true)
				helpers.assert_true(actor.bind(replacement,100,function(r) records[#records+1]=r; return true end) ~= nil)
			end
			return true
		end)
		local queries=0
		actor.run("start",function() return true end,function() queries=queries+1; return engine_snapshot() end)
		helpers.assert_eq(queries,0); helpers.assert_eq(last(records).source,"binding"); helpers.assert_eq(last(records).complete,false)
	end)
	it("unordered clock retires before completion", function()
		local actor, records, refused = actor_fixture(100,nil,function() return 4 end)
		actor.run("start",function() return true end,engine_snapshot)
		helpers.assert_eq(#records,1); helpers.assert_eq(#refused,1)
	end)
	it("malformed native fields cannot complete", function()
		local actor, records = actor_fixture()
		for _, generation in ipairs({-1, 0.5, math.huge, "2"}) do
			actor.run("start",function() return true end,function() return {enabled=true,paused=false,runtime_generation=generation} end)
			helpers.assert_eq(last(records).complete,false)
		end
	end)
end)

describe("Actual hardware and system lifecycle writers", function()
	it("binding is dormant and requires exact ownership", function()
		with_fixture({},function(watchers,fixture)
			local records,owner,token=bind_watchers(watchers)
			helpers.assert_eq(next(fixture.watchers),nil)
			helpers.assert_eq(#fixture.timers,0)
			helpers.assert_eq(#records,1)
			helpers.assert_eq(watchers.unbind_physical_lifecycle_observer({},token),false)
			helpers.assert_eq(watchers.unbind_physical_lifecycle_observer(owner,token),true)
		end)
	end)
	it("hardware startup and stop publish actual generations", function()
		with_fixture({},function(watchers)
			local records=bind_watchers(watchers)
			helpers.assert_eq(watchers.init_hardware_watchers(),true)
			helpers.assert_eq(last(records).source,"hardware_start")
			helpers.assert_eq(last(records).hardware_committed,true)
			helpers.assert_eq(last(records).complete,true)
			helpers.assert_eq(last(records).allowed,false)
			local generation=last(records).hardware_generation
			helpers.assert_eq(watchers.stop_hardware_watchers(),true)
			helpers.assert_eq(last(records).hardware_committed,false)
			helpers.assert_true(last(records).hardware_generation>generation)
		end)
	end)
	it("partial native startup cannot complete lifecycle", function()
		with_fixture({start_results={battery=false}},function(watchers)
			local records=bind_watchers(watchers)
			helpers.assert_eq(watchers.init_hardware_watchers(),false)
			helpers.assert_eq(last(records).complete,false)
			helpers.assert_eq(last(records).hardware_committed,false)
		end)
	end)
	it("hardware stop debt denies until the actual retry settles", function()
		with_fixture({stop_results={wifi={false,true}}},function(watchers)
			local records=bind_watchers(watchers)
			helpers.assert_eq(watchers.init_hardware_watchers(),true)
			helpers.assert_eq(watchers.stop_hardware_watchers(),false)
			helpers.assert_eq(last(records).complete,false)
			helpers.assert_eq(watchers.stop_hardware_watchers(),true)
			helpers.assert_eq(last(records).complete,true)
		end)
	end)
	for _, options in ipairs({{paused=true},{disabled=true},{hardware_off=true}}) do
		it("sleep and lock deny before legacy posture guards " .. (options.paused and "paused" or options.disabled and "disabled" or "hardware off"),function()
			with_fixture(options,function(watchers,fixture,state)
				if not options.hardware_off then helpers.assert_eq(watchers.init_hardware_watchers(),true) end
				state.is_enabled=not options.disabled
				local records=bind_watchers(watchers)
				for _,event in ipairs({1,2,5}) do
					helpers.assert_eq(watchers.caffeinate_cb(event),true)
					helpers.assert_eq(records[#records-1].stage,"boundary")
					helpers.assert_eq(last(records).allowed,false)
					helpers.assert_eq(last(records).value,false)
				end
				helpers.assert_eq(#fixture.system_events,0)
			end)
		end)
	end
	it("six event facts remain independent and never enable capture",function()
		with_fixture({},function(watchers)
			helpers.assert_eq(watchers.init_hardware_watchers(),true)
			local records=bind_watchers(watchers)
			local expected={{"system_awake",false},{"screen_awake",false},{"system_awake",true},{"screen_awake",true},{"unlocked",false},{"unlocked",true}}
			for event, fact in ipairs(expected) do
				helpers.assert_eq(watchers.caffeinate_cb(event),true)
				helpers.assert_eq(last(records).component,fact[1]); helpers.assert_eq(last(records).value,fact[2])
				helpers.assert_eq(last(records).allowed,false)
			end
		end)
	end)
	it("unknown system event cannot complete",function()
		with_fixture({},function(watchers)
			local records=bind_watchers(watchers)
			helpers.assert_eq(watchers.caffeinate_cb(999),true)
			helpers.assert_eq(last(records).complete,false)
		end)
	end)
	it("missing pause fact cannot complete native snapshot",function()
		with_fixture({pause_nil=true},function(watchers)
			local records=bind_watchers(watchers)
			helpers.assert_eq(watchers.init_hardware_watchers(),true)
			helpers.assert_eq(last(records).complete,false)
		end)
	end)
	it("pre-guard bridge produces one boundary and one completion",function()
		with_fixture({},function(watchers)
			helpers.assert_eq(watchers.init_hardware_watchers(),true)
			local records=bind_watchers(watchers)
			local result=watchers.observe_caffeinate_callback(1,function(event) watchers.caffeinate_cb(event) end)
			helpers.assert_eq(result,nil)
			helpers.assert_eq(#records,3)
			helpers.assert_eq(last(records).complete,true)
		end)
	end)
	it("pre-guard bridge without admitted child cannot complete",function()
		with_fixture({},function(watchers)
			local records=bind_watchers(watchers)
			watchers.observe_caffeinate_callback(1,function() end)
			helpers.assert_eq(#records,3); helpers.assert_eq(last(records).complete,false)
		end)
	end)
	it("queued wake continuation stays stale after real hardware stop",function()
		with_fixture({},function(watchers,fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(),true)
			local records=bind_watchers(watchers)
			helpers.assert_eq(watchers.caffeinate_cb(3),true)
			local timer=fixture.timers[1]
			helpers.assert_eq(watchers.stop_hardware_watchers(),true)
			local count=#records
			timer.callback()
			helpers.assert_eq(fixture.capture_calls,0); helpers.assert_eq(#records,count)
		end)
	end)
end)

local root_fixture = require("tests.unit.modules.keylogger.test_activation_callback_fail_closed")
local function with_root(options, scenario)
	local names={"adapters.event_provenance","adapters.input_source_broker","adapters.keyboard_hook","adapters.physical_observation_clock","adapters.process_lifecycle","adapters.synthetic_input","infra.config_paths","infra.dialog_util","infra.logger","infra.manifest_reader","keylogger.physical_lifecycle_observation","modules.keylogger.context_tracker","modules.keylogger.init","modules.keylogger.kc_bridge","modules.keylogger.log_manager","modules.keylogger.watchers","modules.keymap"}
	helpers.with_stub_scope(names,function()
		local original=helpers.load_with_stubs
		local records,owner,token,clock= {},{},nil,0
		helpers.load_with_stubs=function(name,...)
			local module=original(name,...)
			if name=="modules.keylogger.init" then
				hs.timer.absoluteTime=function() clock=clock+1; return clock end
				if options.before_native_layout then
					local original_layout=hs.keycodes.currentLayout
					hs.keycodes.currentLayout=function(...) options.before_native_layout(records); return original_layout(...) end
				end
				if options.pause_override then
					local original_start=module.start
					module.start=function(_,...) return original_start({is_paused=options.pause_override},...) end
				end
				token=module.bind_physical_lifecycle_observer(owner,100,function(record) records[#records+1]=record; return true end)
				helpers.assert_true(token~=nil)
			end
			return module
		end
		local ok,reason=xpcall(function()
			local ctx=root_fixture.load_keylogger(options)
			scenario(ctx,records,owner,token)
		end,debug.traceback)
		helpers.load_with_stubs=original
		if not ok then error(reason,0) end
	end)
end

describe("Actual engine lifecycle writers",function()
	it("engine denies before the first native layout query",function()
		local calls=0
		with_root({before_native_layout=function(records)
			calls=calls+1
			helpers.assert_eq(last(records).source,"start")
			helpers.assert_eq(last(records).stage,"boundary")
			helpers.assert_eq(last(records).allowed,false)
		end},function(ctx,records)
			helpers.assert_eq(ctx.start_result,true); helpers.assert_eq(calls,1)
			helpers.assert_eq(last(records).complete,true)
		end)
	end)
	it("engine missing pause value keeps actual startup success but denies completion",function()
		with_root({pause_override=function() return nil end},function(ctx,records)
			helpers.assert_eq(ctx.start_result,true)
			helpers.assert_eq(last(records).enabled,true)
			helpers.assert_eq(last(records).fields_complete,false)
			helpers.assert_eq(last(records).complete,false)
		end)
	end)
	it("engine throwing pause value keeps actual startup success but denies completion",function()
		with_root({pause_override=function() error("pause snapshot failed") end},function(ctx,records)
			helpers.assert_eq(ctx.start_result,true)
			helpers.assert_eq(last(records).complete,false)
		end)
	end)
	it("engine observation detach restores the existing unbound writer",function()
		with_root({},function(ctx,records,owner,token)
			helpers.assert_eq(ctx.keylogger.unbind_physical_lifecycle_observer(owner,token),true)
			local count=#records
			helpers.assert_eq(ctx.keylogger.stop(),true)
			helpers.assert_eq(ctx.state.is_enabled,false); helpers.assert_eq(#records,count)
		end)
	end)

	it("start completes only after actual enabled commit",function()
		with_root({},function(ctx,records)
			helpers.assert_eq(ctx.start_result,true)
			helpers.assert_eq(records[2].source,"start"); helpers.assert_eq(records[2].stage,"boundary")
			helpers.assert_eq(last(records).enabled,true); helpers.assert_eq(last(records).paused,false)
			helpers.assert_eq(last(records).complete,true); helpers.assert_eq(last(records).allowed,false)
		end)
	end)
	it("actual partial start remains incomplete and disabled",function()
		with_root({hardware_start_returns_nil=true},function(ctx,records)
			helpers.assert_eq(ctx.start_result,false)
			helpers.assert_eq(last(records).enabled,false); helpers.assert_eq(last(records).complete,false)
		end)
	end)
	it("actual stop debt and retry preserve native settlement results",function()
		with_root({stop_results={false,true}},function(ctx,records)
			helpers.assert_eq(ctx.keylogger.stop(),false)
			helpers.assert_eq(last(records).enabled,false); helpers.assert_eq(last(records).complete,false)
			helpers.assert_eq(ctx.keylogger.stop(),true)
			helpers.assert_eq(last(records).complete,true); helpers.assert_eq(last(records).allowed,false)
		end)
	end)
	it("resync does not represent a pause commit or permission",function()
		with_root({},function(ctx,records)
			package.loaded["modules.keylogger.context_tracker"].resync_context=function() return true end
			helpers.assert_eq(ctx.keylogger.resync_context(),true)
			helpers.assert_eq(last(records).source,"resync"); helpers.assert_eq(last(records).allowed,false)
			helpers.assert_eq(last(records).pause_committed,nil)
		end)
	end)
	it("shutdown records actual disabled lifecycle without enabling capture",function()
		with_root({},function(ctx,records)
			helpers.assert_eq(ctx.keylogger.shutdown(),true)
			helpers.assert_eq(last(records).source,"shutdown"); helpers.assert_eq(last(records).enabled,false)
			helpers.assert_eq(last(records).allowed,false)
		end)
	end)
	it("current generation forwards system boundary before disabled guard",function()
		with_root({},function(ctx)
			local watchers=package.loaded["modules.keylogger.watchers"]
			local bridges=0
			watchers.observe_caffeinate_callback=function(event,callback,...)
				bridges=bridges+1
				return callback(event,...)
			end
			ctx.state.is_enabled=false
			ctx.caffeinate_callback(1)
			helpers.assert_eq(bridges,1); helpers.assert_eq(ctx.caffeinate_calls,nil)
		end)
	end)
	it("stale native generation does not forward system boundary",function()
		with_root({},function(ctx)
			local callback=ctx.caffeinate_callback
			helpers.assert_eq(ctx.keylogger.stop(),true)
			local watchers=package.loaded["modules.keylogger.watchers"]
			watchers.observe_caffeinate_callback=function() error("stale generation bridge invoked") end
			callback(1)
			helpers.assert_eq(ctx.caffeinate_calls,nil)
		end)
	end)
end)
