--- tests/unit/modules/keylogger/test_physical_initial_lifecycle.lua

--- Frozen reviewer controls copied before implementation; original expectations are preserved.
do
--- Independent observed-point controls; clocks and native writers are modeled.
--- Actual shared actors, conjunction and lifetime capabilities execute unchanged.
local h = require("tests.helpers")
local Lifecycle = require("keylogger.physical_lifecycle_observation")
local Conjunction = require("keylogger.physical_lifecycle_conjunction")
local function fields(domain)
	if domain == "pause" then
		return { paused = false, transition_generation = 3, admission_released = true, settled = true }
	end
	local result = { enabled = true, paused = false, settled = true }
	if domain == "engine" then result.runtime_generation = 3
	else result.hardware_committed = true; result.hardware_generation = 3; result.context_refresh_generation = 4 end
	return result
end
local function actor(domain, custom_clock)
	local records, counters, owner = {}, { clock = 0, snapshot = 0, refused = 0 }, {}
	local a = Lifecycle.new(domain, function()
		counters.clock = counters.clock + 1
		if custom_clock then return custom_clock(counters.clock) end
		return counters.clock * 10
	end, function() counters.refused = counters.refused + 1 end)
	local function receive(r, token) records[#records + 1] = r; counters.token = token; return true end
	local function snapshot() counters.snapshot = counters.snapshot + 1; return fields(domain) end
	return a, owner, records, counters, receive, snapshot
end
local function observe_lifetime(body)
	local name = "keylogger.physical_subscription_lifetime"
	local actual = require(name)
	local captured
	package.loaded[name] = { new = function(owner, token)
		local lifetime = actual.new(owner, token)
		captured = lifetime.capability()
		return lifetime
	end }
	local ok, err = pcall(body, function() return captured end)
	package.loaded[name] = actual
	if not ok then error(err, 0) end
end
local function conjunction(receive)
	local sources = {}
	for _, name in ipairs({ "engine", "system" }) do
		local owner, token = {}, {}
		local scope = {}
		function scope.identity(o) if rawequal(o, owner) then return scope.changed and {} or token end end
		function scope.current(o, t) return rawequal(o, owner) and rawequal(t, token) end
		function scope.detach(o, t) return rawequal(o, owner) and rawequal(t, token) end
		function scope.retired() return false end
		sources[name] = { owner = owner, token = token, scope = scope }
	end
	local output = {}
	local joined = Conjunction.new(sources, 12, receive or function(r) output[#output + 1] = r; return true end, function() end)
	local function send(domain, r)
		local s = sources[domain]
		return joined.accept(domain, s.owner, s.token, r)
	end
	return joined, sources, send, output
end
local function receipt(domain, revision, source, stage)
	return { kind = "physical_lifecycle", domain = domain, revision = revision, at = revision * 10,
		source = source, stage = stage, allowed = false, complete = false, fields_complete = false }
end

h.describe("independent initial lifecycle observed point", function()
	h.it("preserves old four-argument binding and the original writer receipt inventory", function()
		for _, domain in ipairs({ "engine", "system", "pause" }) do
			local a, owner, records, counters, receive, snapshot = actor(domain)
			local token = a.bind(owner, 8, receive, nil)
			h.assert_eq(type(token), "table"); h.assert_eq(#records, 1)
			h.assert_eq(counters.clock, 1); h.assert_eq(counters.snapshot, 0)
			local writes = 0
			local source = domain == "pause" and "resume" or "start"
			if domain == "system" then source = "hardware_start" end
			h.assert_eq(a.run(source, function() writes = writes + 1; return true, "original" end, snapshot), true)
			h.assert_eq(writes, 1); h.assert_eq(#records, 3); h.assert_eq(counters.clock, 3)
			h.assert_eq(counters.snapshot, 1); h.assert_eq(records[2].stage, "boundary")
			h.assert_eq(records[3].complete, true); h.assert_eq(records[3].stage, "complete")
			h.assert_eq(a.unbind(owner, token), true)
		end
	end)
	h.it("emits only a denied binding and an observed point without inventing a writer", function()
		for _, domain in ipairs({ "engine", "system", "pause" }) do
			local a, owner, records, counters, receive, snapshot = actor(domain)
			local token, _, scope = a.bind(owner, 8, receive, nil, snapshot)
			h.assert_eq(type(token), "table"); h.assert_eq(#records, 2)
			h.assert_eq(counters.clock, 2); h.assert_eq(counters.snapshot, 1)
			local observed = records[2]
			h.assert_eq(observed.source, "initial_snapshot"); h.assert_eq(observed.stage, "observed")
			h.assert_eq(observed.revision, 2); h.assert_eq(observed.at, 20)
			h.assert_eq(observed.complete, false); h.assert_eq(observed.allowed, false)
			h.assert_eq(observed.fields_complete, true); h.assert_eq(observed.observation_complete, true)
			h.assert_eq(observed.qualification, "observed")
			h.assert_eq(scope.current(owner, token), true)
			h.assert_eq(a.unbind(owner, token), true); h.assert_eq(scope.retired(owner, token), true)
		end
	end)
	h.it("does not qualify absent or unsettled local fields", function()
		for _, domain in ipairs({ "engine", "system", "pause" }) do
			for _, omission in ipairs({ "settled", "paused", "false_settled" }) do
				local a, owner, records, _, receive = actor(domain)
				local token = a.bind(owner, 8, receive, nil, function()
					local r = fields(domain)
					if omission == "false_settled" then r.settled = false else r[omission] = nil end
					return r
				end)
				h.assert_eq(type(token), "table"); h.assert_eq(#records, 2)
				h.assert_eq(records[2].qualification, "unknown")
				h.assert_eq(records[2].observation_complete, false); h.assert_eq(records[2].complete, false)
				h.assert_eq(records[2].fields_complete, omission == "false_settled")
			end
		end
	end)
	h.it("rejects invalid optional snapshot ports before even the binding clock", function()
		for _, invalid in ipairs({ false, true, {}, "snapshot" }) do
			local a, owner, records, counters, receive = actor("engine")
			local token = a.bind(owner, 8, receive, nil, invalid)
			h.assert_eq(token, nil); h.assert_eq(counters.clock, 0); h.assert_eq(#records, 0)
		end
	end)
	h.it("reserves the bounded second receipt before any foreign snapshot query", function()
		local a, owner, records, counters, receive, snapshot = actor("engine")
		local token, reason, scope = a.bind(owner, 1, receive, nil, snapshot)
		h.assert_eq(token, nil); h.assert_eq(type(reason), "string")
		h.assert_eq(counters.clock, 1); h.assert_eq(counters.snapshot, 0); h.assert_eq(#records, 1)
		h.assert_eq(scope.current(owner, counters.token), false); h.assert_eq(scope.retired(owner, counters.token), true)
	end)
	h.it("refuses a second clock error before snapshot evaluation", function()
		local marker = {}
		local a, owner, records, counters, receive, snapshot = actor("engine", function(n)
			if n == 2 then error(marker, 0) end
			return 10
		end)
		local token = a.bind(owner, 8, receive, nil, snapshot)
		h.assert_eq(token, nil); h.assert_eq(counters.clock, 2)
		h.assert_eq(counters.snapshot, 0); h.assert_eq(#records, 1)
	end)
	h.it("does not convert a foreign snapshot exception to observed qualification", function()
		local a, owner, records, counters, receive = actor("engine")
		local queried = 0
		local token = a.bind(owner, 8, receive, nil, function() queried = queried + 1; error("independent snapshot error") end)
		h.assert_eq(queried, 1)
		if token then
			h.assert_eq(#records, 2); h.assert_eq(records[2].qualification, "unknown")
			h.assert_eq(records[2].observation_complete, false); h.assert_eq(records[2].complete, false)
		else h.assert_eq(#records, 1); h.assert_eq(counters.refused > 0, true) end
	end)
	h.it("keeps actual callback debt after detach from inside the snapshot getter", function()
		observe_lifetime(function(capability)
			local a, owner, records, counters, receive = actor("engine")
			local inside, calls = {}, 0
			local token, _, scope = a.bind(owner, 8, receive, nil, function()
				calls = calls + 1
				inside.detached = a.unbind(owner, counters.token)
				inside.retired = capability().retired(owner, counters.token)
				return fields("engine")
			end)
			h.assert_eq(calls, 1); h.assert_eq(inside.detached, true); h.assert_eq(inside.retired, false)
			h.assert_eq(token, nil); h.assert_eq(#records, 1)
			h.assert_eq(scope.retired(owner, counters.token), true)
		end)
	end)
	h.it("refuses caught writer reentry without publishing the old snapshot", function()
		local a, owner, records, counters, receive = actor("engine")
		local writes, snapshots = 0, 0
		local token = a.bind(owner, 8, receive, nil, function()
			snapshots = snapshots + 1
			a.run("stop", function() writes = writes + 1; return true end, function() return fields("engine") end)
			return fields("engine")
		end)
		h.assert_eq(snapshots, 1); h.assert_eq(writes, 1)
		h.assert_eq(token, nil); h.assert_eq(#records, 1); h.assert_eq(counters.refused > 0, true)
	end)
	h.it("retains observed point fields but leaves every OS posture unknown", function()
		local _, _, send, output = conjunction()
		h.assert_eq(send("system", receipt("system", 1, "binding", "boundary")), true)
		local r = receipt("system", 2, "initial_snapshot", "observed")
		for key, value in pairs(fields("system")) do r[key] = value end
		r.fields_complete, r.observation_complete, r.qualification = true, true, "observed"
		h.assert_eq(send("system", r), true); h.assert_eq(#output, 2)
		local result = output[2]
		h.assert_eq(result.system.writer_complete, false); h.assert_eq(result.system.observation_complete, true)
		h.assert_eq(result.system.qualification, "observed"); h.assert_eq(result.system.hardware_committed, true)
		h.assert_eq(result.allowed, nil)
		for _, component in ipairs({ "system_awake", "screen_awake", "unlocked" }) do
			h.assert_eq(result.posture[component].qualification, "unknown")
			h.assert_eq(result.posture[component].value, nil)
		end
	end)
	h.it("cannot admit snapshot permission or fabricated writer completion", function()
		for _, field in ipairs({ "allowed", "complete" }) do
			local _, _, send, output = conjunction()
			h.assert_eq(send("engine", receipt("engine", 1, "binding", "boundary")), true)
			local r = receipt("engine", 2, "initial_snapshot", "observed")
			for key, value in pairs(fields("engine")) do r[key] = value end
			r.fields_complete, r.observation_complete, r.qualification = true, true, "observed"; r[field] = true
			h.assert_eq(send("engine", r), false); h.assert_eq(#output, 1)
		end
	end)
	h.it("rechecks real source identity after the observed facts subscriber returns", function()
		local sources, calls = nil, 0
		local joined, actual, send = conjunction(function(r)
			calls = calls + 1
			if r.engine.source == "initial_snapshot" then sources.system.scope.changed = true end
			return true
		end)
		sources = actual
		h.assert_eq(send("engine", receipt("engine", 1, "binding", "boundary")), true)
		local r = receipt("engine", 2, "initial_snapshot", "observed")
		for key, value in pairs(fields("engine")) do r[key] = value end
		r.fields_complete, r.observation_complete, r.qualification = true, true, "observed"
		h.assert_eq(send("engine", r), false)
		h.assert_eq(calls, 2)
		h.assert_eq(joined.retired(), false)
	end)
end)

end
do
--- Actual engine writer/snapshot controls with the existing modeled OS fixture.
local h = require("tests.helpers")
local Fixture = require("tests.support.keylogger_provenance_fixture")
local NAMES = {
	"adapters.event_provenance", "adapters.input_source_broker", "adapters.keyboard_hook",
	"adapters.physical_observation_clock", "adapters.process_lifecycle", "adapters.synthetic_input",
	"infra.config_paths", "infra.dialog_util", "infra.logger", "infra.manifest_reader",
	"keylogger.physical_lifecycle_observation", "modules.keylogger.context_tracker", "modules.keylogger.init",
	"modules.keylogger.kc_bridge", "modules.keylogger.log_manager", "modules.keylogger.watchers", "modules.keymap",
}
local function actual(body)
	return h.with_stub_scope(NAMES, function()
		local f = Fixture.load_keylogger()
		local queries = { paused = 0, pending = 0, clock = 0 }
		f.hs.timer.absoluteTime = function() queries.clock = queries.clock + 1; return queries.clock * 10 end
		local hooks = {}
		local control = {
			is_paused = function()
				queries.paused = queries.paused + 1
				if hooks.paused then return hooks.paused() end
				return false
			end,
			is_pause_transition_pending = function()
				queries.pending = queries.pending + 1
				if hooks.pending then return hooks.pending() end
				return false
			end,
		}
		f.hs.caffeinate = { watcher = { new = function(callback)
			local watcher = { callback = callback, running = false }
			function watcher:start() self.running = true; return self end
			function watcher:stop() self.running = false; return self end
			return watcher
		end } }
		f.start(control)
		local owner, records = {}, {}
		local function bind(option)
			return f.keylogger.bind_physical_lifecycle_observer(owner, 16, function(r)
				records[#records + 1] = r; return true
			end, nil, option)
		end
		body(f, control, hooks, queries, records, owner, bind)
	end)
end
h.describe("independent initial engine local-state fences", function()
	h.it("keeps legacy binding free of extra state/pending queries", function()
		actual(function(f, _, _, q, records, owner, bind)
			local paused, pending, clock = q.paused, q.pending, q.clock
			local token = bind()
			h.assert_eq(type(token), "table"); h.assert_eq(#records, 1)
			h.assert_eq(q.paused, paused); h.assert_eq(q.pending, pending); h.assert_eq(q.clock, clock + 1)
			h.assert_eq(f.keylogger.unbind_physical_lifecycle_observer(owner, token), true)
		end)
	end)
	h.it("uses the real pending predicate for a known observed engine point", function()
		actual(function(_, _, _, q, records, _, bind)
			local pending = q.pending
			local token = bind(true)
			h.assert_eq(type(token), "table"); h.assert_eq(#records, 2)
			h.assert_eq(q.pending > pending, true)
			h.assert_eq(records[2].source, "initial_snapshot"); h.assert_eq(records[2].qualification, "observed")
			h.assert_eq(records[2].observation_complete, true); h.assert_eq(records[2].complete, false)
			h.assert_eq(records[2].enabled, true); h.assert_eq(records[2].paused, false)
		end)
	end)
	h.it("does not qualify an engine whose pause settlement predicate is absent", function()
		actual(function(_, control, _, _, records, _, bind)
			control.is_pause_transition_pending = nil
			local token = bind(true)
			h.assert_eq(type(token), "table"); h.assert_eq(#records, 2)
			h.assert_eq(records[2].qualification, "unknown"); h.assert_eq(records[2].observation_complete, false)
			h.assert_eq(records[2].complete, false)
		end)
	end)
	h.it("does not qualify pending or throwing real local pause settlement", function()
		for _, kind in ipairs({ "pending", "throw" }) do
			actual(function(_, _, hooks, _, records, _, bind)
				hooks.pending = function() if kind == "throw" then error("independent pause settlement") end; return true end
				local token = bind(true)
				h.assert_eq(type(token), "table"); h.assert_eq(#records, 2)
				h.assert_eq(records[2].qualification, "unknown"); h.assert_eq(records[2].observation_complete, false)
				h.assert_eq(records[2].complete, false)
			end)
		end
	end)
	h.it("denies a copied scalar state changed by the actual pause predicate", function()
		actual(function(f, _, hooks, _, records, _, bind)
			local called = 0
			hooks.paused = function() called = called + 1; f.state.is_enabled = false; return false end
			local token = bind(true)
			h.assert_eq(called > 0, true); h.assert_eq(f.state.is_enabled, false)
			h.assert_eq(type(token), "table"); h.assert_eq(#records, 2)
			h.assert_eq(records[2].qualification, "unknown"); h.assert_eq(records[2].observation_complete, false)
			h.assert_eq(records[2].complete, false)
		end)
	end)
	h.it("cannot publish after a pending predicate executes the actual stop writer", function()
		actual(function(f, _, hooks, _, records, _, bind)
			local writes = 0
			hooks.pending = function() writes = writes + 1; f.keylogger.stop(); return false end
			local token = bind(true)
			h.assert_eq(writes, 1); h.assert_eq(token, nil); h.assert_eq(#records, 1)
			h.assert_eq(f.state.is_enabled, false)
		end)
	end)
end)

end
do
--- Actual shared subscription debt around a modeled foreign clock getter.
local h = require("tests.helpers")
local Lifecycle = require("keylogger.physical_lifecycle_observation")
h.describe("independent initial clock getter frame debt", function()
	h.it("retains the exact actual lifetime before entering the initial observation clock", function()
		local name = "keylogger.physical_subscription_lifetime"
		local actual = require(name)
		local capability
		package.loaded[name] = { new = function(owner, token)
			local lifetime = actual.new(owner, token)
			capability = lifetime.capability()
			return lifetime
		end }
		local ok, err = pcall(function()
			local a, owner, observed_token = nil, {}, nil
			local clocks, snapshots, records, inside = 0, 0, {}, {}
			a = Lifecycle.new("engine", function()
				clocks = clocks + 1
				if clocks == 2 then
					inside.detached = a.unbind(owner, observed_token)
					inside.retired = capability.retired(owner, observed_token)
				end
				return clocks * 10
			end, function() end)
			local token, _, scope = a.bind(owner, 8, function(r, source_token)
				records[#records + 1] = r; observed_token = source_token; return true
			end, nil, function()
				snapshots = snapshots + 1
				return { enabled = true, paused = false, runtime_generation = 3, settled = true }
			end)
			h.assert_eq(clocks, 2); h.assert_eq(inside.detached, true); h.assert_eq(inside.retired, false)
			h.assert_eq(token, nil); h.assert_eq(snapshots, 0); h.assert_eq(#records, 1)
			h.assert_eq(scope.retired(owner, observed_token), true)
		end)
		package.loaded[name] = actual
		if not ok then error(err, 0) end
	end)
end)

end

do
local h = require("tests.helpers")
local Pause = require("tests.support.pause_transaction_fixture")
h.describe("initial native ledger observations", function()
 h.it("observes initial unpaused pause ledger without committing a resume", function()
  h.with_stub_scope({"keylogger.physical_lifecycle_observation", "adapters.physical_observation_clock"}, function()
   Pause.with_context(nil, function(control, ctx)
    local clocks, records, owner = 0, {}, {}
    hs.timer.absoluteTime = function() clocks = clocks + 1; return clocks * 10 end
    local order = #ctx.call_order
    local token = control.bind_physical_pause_observer(owner, 8, function(r) records[#records + 1] = r; return true end, nil, true)
    h.assert_eq(type(token), "table"); h.assert_eq(#records, 2); h.assert_eq(clocks, 2)
    h.assert_eq(records[2].source, "initial_snapshot"); h.assert_eq(records[2].stage, "observed")
    h.assert_eq(records[2].paused, false); h.assert_eq(records[2].admission_released, true)
    h.assert_eq(records[2].settled, true); h.assert_eq(records[2].qualification, "observed")
    h.assert_eq(records[2].complete, false); h.assert_eq(records[2].allowed, false)
    h.assert_eq(#ctx.call_order, order); h.assert_eq(control.is_paused(), false)
    h.assert_eq(control.unbind_physical_pause_observer(owner, token), true)
   end)
  end)
 end)
 h.it("validates native options before the first clock and keeps explicit false legacy", function()
  h.with_stub_scope({"keylogger.physical_lifecycle_observation", "adapters.physical_observation_clock"}, function()
   Pause.with_context(nil, function(control)
    local clocks, records, owner = 0, {}, {}
    hs.timer.absoluteTime = function() clocks = clocks + 1; return clocks * 10 end
    local receive = function(r) records[#records + 1] = r; return true end
    h.assert_eq(control.bind_physical_pause_observer(owner, 8, receive, nil, {}), nil)
    h.assert_eq(clocks, 0); h.assert_eq(#records, 0)
    local token = control.bind_physical_pause_observer(owner, 8, receive, nil, false)
    h.assert_eq(type(token), "table"); h.assert_eq(clocks, 1); h.assert_eq(#records, 1)
    h.assert_eq(control.unbind_physical_pause_observer(owner, token), true)
   end)
  end)
 end)
 h.it("reads actual initialized system scalars without acquiring a hardware watcher", function()
  h.with_stub_scope({"modules.keylogger.watchers", "modules.keylogger.log_manager", "infra.logger", "keylogger.physical_lifecycle_observation", "adapters.physical_observation_clock"}, function()
   package.loaded["infra.logger"] = h.make_logger_stub()
   package.loaded["modules.keylogger.log_manager"] = {}
   local clocks, queries, records = 0, 0, {}
   local W = h.load_with_stubs("modules.keylogger.watchers", {
    timer = {absoluteTime = function() clocks = clocks + 1; return clocks * 10 end},
    wifi = false, battery = false, spaces = false, audiodevice = false,
   })
   local state, owner = {is_enabled = true}, {}
   h.assert_eq(W.init(state, function() queries = queries + 1; return false end), true)
   local token = W.bind_physical_lifecycle_observer(owner, 8, function(r) records[#records + 1] = r; return true end, nil, true)
   h.assert_eq(type(token), "table"); h.assert_eq(#records, 2); h.assert_eq(clocks, 2)
   h.assert_eq(queries > 0, true); h.assert_eq(records[2].enabled, true)
   h.assert_eq(records[2].hardware_committed, false); h.assert_eq(records[2].qualification, "observed")
   h.assert_eq(records[2].complete, false); h.assert_eq(records[2].allowed, false)
   h.assert_eq(records[2].hardware_generation, 0)
   h.assert_eq(W.unbind_physical_lifecycle_observer(owner, token), true)
  end)
 end)
end)
end

do
--- Independent actual local hardware cleanup debt, with one modeled OS handle.
local h = require("tests.helpers")
h.describe("initial system actual hardware retirement debt", function()
	h.it("cannot qualify refused retained hardware cleanup as locally settled", function()
		h.with_stub_scope({ "modules.keylogger.watchers", "modules.keylogger.log_manager", "infra.logger",
			"keylogger.physical_lifecycle_observation", "adapters.physical_observation_clock" }, function()
			package.loaded["infra.logger"] = h.make_logger_stub()
			package.loaded["modules.keylogger.log_manager"] = {}
			local clock, stops, permit, running = 0, 0, false, false
			local handle = {}
			function handle:start() running = true; return self end
			function handle:stop()
				stops = stops + 1
				if not permit then return false end
				running = false; return self
			end
			local W = h.load_with_stubs("modules.keylogger.watchers", {
				timer = { absoluteTime = function() clock = clock + 1; return clock * 10 end },
				wifi = { watcher = { new = function() return handle end } },
				battery = false, spaces = false, audiodevice = false,
			})
			h.assert_eq(W.init({ is_enabled = true }, function() return false end), true)
			h.assert_eq(W.init_hardware_watchers(), true)
			local function point()
				local owner, records = {}, {}
				local token = W.bind_physical_lifecycle_observer(owner, 8, function(r)
					records[#records + 1] = r; return true
				end, nil, true)
				h.assert_eq(type(token), "table"); h.assert_eq(#records, 2)
				h.assert_eq(W.unbind_physical_lifecycle_observer(owner, token), true)
				return records[2]
			end
			local healthy = point()
			h.assert_eq(healthy.hardware_committed, true); h.assert_eq(healthy.settled, true)
			h.assert_eq(healthy.observation_complete, true); h.assert_eq(healthy.qualification, "observed")
			h.assert_eq(stops, 0); h.assert_eq(running, true)
			h.assert_eq(W.stop_hardware_watchers(), false); h.assert_eq(stops, 1); h.assert_eq(running, true)
			local owed = point()
			h.assert_eq(owed.hardware_committed, false); h.assert_eq(owed.settled, false)
			h.assert_eq(owed.observation_complete, false); h.assert_eq(owed.qualification, "unknown")
			h.assert_eq(owed.complete, false); h.assert_eq(owed.allowed, false)
			permit = true
			h.assert_eq(W.stop_hardware_watchers(), true); h.assert_eq(stops, 2); h.assert_eq(running, false)
			local cleared = point()
			h.assert_eq(cleared.hardware_committed, false); h.assert_eq(cleared.settled, true)
			h.assert_eq(cleared.observation_complete, true); h.assert_eq(cleared.qualification, "observed")
		end)
	end)
end)

end
