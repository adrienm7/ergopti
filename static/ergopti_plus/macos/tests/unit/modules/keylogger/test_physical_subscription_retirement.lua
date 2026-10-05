--- tests/unit/modules/keylogger/test_physical_subscription_retirement.lua

--- Independent callback retirement controls; global native watcher stop is not claimed.
local helpers = require("tests.helpers")

local function lifetime()
	local owner, token = {}, {}
	local state = require("keylogger.physical_subscription_lifetime").new(owner, token)
	return state, state.capability(), owner, token
end
local function identities() return { owner = {}, token = {} } end
local function filters()
	return { disabled_apps = {}, private_filter_enabled = true,
		secure_field_filter_enabled = true, system_auth_filter_enabled = true }
end
local function clock()
	local at = 0
	return function() at = at + 1; return at end
end

helpers.describe("exact subscription callback lifetime", function()
	helpers.it("requires exact identities and invokes no foreign port", function()
		local state, scope, owner, token = lifetime()
		helpers.assert_eq(scope.current(owner, token), true)
		helpers.assert_eq(scope.retired(owner, token), false)
		helpers.assert_eq(type(state.run), "function")
	end)
	helpers.it("never calls equality hooks for foreign identities", function()
		local _, scope, owner, token = lifetime()
		local foreign = setmetatable({}, { __eq = function() error("Foreign equality hook") end })
		helpers.assert_eq(scope.current(foreign, token), false)
		helpers.assert_eq(scope.current(owner, foreign), false)
		helpers.assert_eq(scope.retired(foreign, token), false)
		helpers.assert_eq(scope.current(owner, token), true)
	end)
	helpers.it("revokes before detach but requires exact detach for retirement", function()
		local state, scope, owner, token = lifetime()
		state.revoke(); helpers.assert_eq(scope.current(owner, token), false)
		helpers.assert_eq(scope.retired(owner, token), false)
		state.detach(); helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("waits for the actual outer callback frame after detach", function()
		local state, scope, owner, token = lifetime()
		state.run(function()
			state.detach(); helpers.assert_eq(scope.current(owner, token), false)
			helpers.assert_eq(scope.retired(owner, token), false)
		end)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("waits for nested actual frames without resetting retained debt", function()
		local state, scope, owner, token = lifetime()
		state.run(function()
			state.run(function() state.detach(); helpers.assert_eq(scope.retired(owner, token), false) end)
			helpers.assert_eq(scope.retired(owner, token), false)
		end)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("releases error frames while preserving the original error", function()
		local state, scope, owner, token = lifetime(); local failure = {}
		local ok, caught = pcall(state.run, function() state.detach(); error(failure, 0) end)
		helpers.assert_eq(ok, false); helpers.assert_true(rawequal(caught, failure))
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("preserves exact nil result slots and legacy callback arguments", function()
		local state = lifetime(); local argument = {}
		local values = table.pack(state.run(function(first, second)
			helpers.assert_true(rawequal(first, argument)); helpers.assert_eq(second, nil)
			return nil, false, nil, argument
		end, argument, nil))
		helpers.assert_eq(values.n, 4); helpers.assert_eq(values[1], nil)
		helpers.assert_eq(values[2], false); helpers.assert_eq(values[3], nil)
		helpers.assert_true(rawequal(values[4], argument))
	end)
	helpers.it("does not revive a detached capability for a later unowned call", function()
		local state, scope, owner, token = lifetime(); state.detach()
		state.run(function() helpers.assert_eq(scope.retired(owner, token), true) end)
		helpers.assert_eq(scope.current(owner, token), false)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
end)

for _, kind in ipairs({ "configuration", "context" }) do
	helpers.describe("shared " .. kind .. " subscription retirement", function()
		local function channel_for(binding, receive, refused, sample)
			local Observation = require("keylogger.physical_" .. kind .. "_observation")
			if kind == "configuration" then return Observation.new(1, sample or clock(), receive, refused, binding) end
			return Observation.new(1, sample or clock(), receive, refused, nil, binding)
		end
		local function publish(channel)
			if kind == "configuration" then return channel.publish(filters()) end
			return channel.seed()
		end
		helpers.it("waits through actual receipt delivery after callback detach", function()
			local binding, channel, scope = identities()
			channel = channel_for(binding, function()
				channel.close(); helpers.assert_eq(scope.current(binding.owner, binding.token), false)
				helpers.assert_eq(scope.retired(binding.owner, binding.token), false); return true
			end, function() end)
			scope = channel.subscription()
			helpers.assert_eq(publish(channel), false)
			helpers.assert_eq(scope.retired(binding.owner, binding.token), true)
		end)
		helpers.it("revokes before refusal notification and waits for that notification", function()
			local binding, channel, scope = identities(); local calls = 0
			channel = channel_for(binding, function() return true end, function()
				calls = calls + 1; helpers.assert_eq(scope.current(binding.owner, binding.token), false)
				channel.close(); helpers.assert_eq(scope.retired(binding.owner, binding.token), false)
			end)
			scope = channel.subscription(); helpers.assert_eq(publish(channel), true)
			helpers.assert_eq(publish(channel), false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(scope.retired(binding.owner, binding.token), true)
		end)
		helpers.it("tracks a real native writer frame in addition to receipt frames", function()
			local binding = identities(); local channel = channel_for(binding, function() return true end, function() end)
			local scope = channel.subscription()
			local result = channel.run_writer(function()
				channel.close(); helpers.assert_eq(scope.retired(binding.owner, binding.token), false); return false
			end)
			helpers.assert_eq(result, false); helpers.assert_eq(scope.retired(binding.owner, binding.token), true)
		end)
		helpers.it("waits for actual foreign clock unwinding after detach", function()
			local binding, channel, scope = identities()
			channel = channel_for(binding, function() error("No future owned-token receipt") end, function() end,
				function() channel.close(); helpers.assert_eq(scope.retired(binding.owner, binding.token), false); return 1 end)
			scope = channel.subscription(); helpers.assert_eq(publish(channel), false)
			helpers.assert_eq(scope.retired(binding.owner, binding.token), true)
		end)
	end)
end

helpers.describe("shared lifecycle exact subscription retirement", function()
	local function actor_for() return require("keylogger.physical_lifecycle_observation").new("engine", clock(), function() end) end
	local function fields() return { enabled = true, paused = false, runtime_generation = 1 } end
	helpers.it("returns a scope while preserving initial receipt callback arguments", function()
		local actor, owner, count = actor_for(), {}, 0
		local token, reason, scope = actor.bind(owner, 20, function(...)
			count = select("#", ...); return true
		end)
		helpers.assert_eq(reason, nil); helpers.assert_eq(count, 2)
		helpers.assert_eq(scope.current(owner, token), true); helpers.assert_eq(scope.retired(owner, token), false)
		helpers.assert_eq(actor.unbind(owner, token), true); helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("tracks the actual writer beyond immediate detach", function()
		local actor, owner = actor_for(), {}
		local token, _, scope = actor.bind(owner, 20, function() return true end)
		local result = actor.run("stop", function()
			helpers.assert_eq(actor.unbind(owner, token), true)
			helpers.assert_eq(scope.retired(owner, token), false); return false
		end, fields)
		helpers.assert_eq(result, false); helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("does not settle after detach inside actual completion snapshot", function()
		local actor, owner = actor_for(), {}
		local token, _, scope = actor.bind(owner, 20, function() return true end)
		actor.run("start", function() return true end, function()
			actor.unbind(owner, token); helpers.assert_eq(scope.retired(owner, token), false); return fields()
		end)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("delivers terminal refusal once with exact token before retirement", function()
		local actor, owner, calls, delivered_token, scope = actor_for(), {}, 0
		local token; token, _, scope = actor.bind(owner, 1, function(record) helpers.assert_eq(record.allowed, false); return true end,
			function(reason, exact)
				calls, delivered_token = calls + 1, exact
				helpers.assert_eq(type(reason), "string"); helpers.assert_eq(scope.current(owner, exact), false)
				helpers.assert_eq(actor.unbind(owner, exact), true)
				helpers.assert_eq(scope.retired(owner, exact), false)
			end)
		actor.run("start", function() return true end, fields)
		helpers.assert_eq(calls, 1); helpers.assert_true(rawequal(delivered_token, token))
		helpers.assert_eq(scope.retired(owner, token), true)
		actor.run("start", function() return true end, fields); helpers.assert_eq(calls, 1)
	end)
	helpers.it("retains old callback debt independently of a successor binding", function()
		local actor, owner = actor_for(), {}
		local token, _, scope = actor.bind(owner, 20, function() return true end)
		local successor, next_token, next_scope = {}
		actor.run("start", function()
			actor.unbind(owner, token); next_token, _, next_scope = actor.bind(successor, 20, function() return true end)
			helpers.assert_eq(scope.retired(owner, token), false)
			helpers.assert_eq(next_scope.current(successor, next_token), true); return true
		end, fields)
		helpers.assert_eq(scope.retired(owner, token), true)
		helpers.assert_eq(next_scope.retired(successor, next_token), false)
		actor.unbind(successor, next_token)
	end)
end)

helpers.describe("native configuration subscription completion", function()
	local function with_core(callback)
		return helpers.with_stub_scope({ "modules.keylogger", "modules.keylogger.init", "adapters.physical_observation_clock",
			"modules.keylogger.text_cipher", "modules.keylogger.text_migration", "modules.keylogger.kc_bridge" }, function()
			local enabled, on_set = false, nil
			package.loaded["modules.keylogger.text_cipher"] = { set_enabled = function(value)
				enabled = value; if on_set then on_set() end
			end, is_enabled = function() return enabled end, is_available = function() return true end }
			package.loaded["modules.keylogger.text_migration"] = { is_running = function() return false end }
			package.loaded["modules.keylogger.kc_bridge"] = { init = function() return true end }
			local core = helpers.load_with_stubs("modules.keylogger")
			hs.timer.absoluteTime = clock()
			callback(core, function(callback_set) on_set = callback_set end)
		end)
	end
	helpers.it("extends bind return slots and keeps exact detach independent of global cleanup", function()
		with_core(function(core)
			local owner = {}; local accepted, token, scope = core.bind_physical_configuration_observer(owner, 20,
				function() return true end, function() end)
			helpers.assert_eq(accepted, true); helpers.assert_eq(scope.current(owner, token), true)
			helpers.assert_eq(core.unbind_physical_configuration_observer(owner, token), true)
			helpers.assert_eq(scope.retired(owner, token), true)
		end)
	end)
	helpers.it("waits for the actual configuration writer after foreign posture detach", function()
		with_core(function(core, set_callback)
			local owner = {}; local accepted, token, scope = core.bind_physical_configuration_observer(owner, 20,
				function() return true end, function() end)
			helpers.assert_eq(accepted, true); local config = core.configuration_snapshot()
			set_callback(function()
				core.unbind_physical_configuration_observer(owner, token)
				helpers.assert_eq(scope.retired(owner, token), false)
			end)
			helpers.assert_eq(core.apply_configuration(config), true)
			helpers.assert_eq(scope.retired(owner, token), true)
		end)
	end)
end)

helpers.describe("native source subscription identity", function()
	helpers.it("waits through the actual native context writer after callback detach", function()
		helpers.with_stub_scope({ "modules.keylogger.context_tracker", "adapters.physical_observation_clock" }, function()
			local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker")
			hs.timer.absoluteTime = clock()
			local state = { is_enabled = true, disabled_apps = {}, active_app_start = 0,
				private_filter_enabled = true, secure_field_filter_enabled = true, system_auth_filter_enabled = true,
				buffer_events = {}, buffer_text = "", rich_chunks = {}, last_time = 0 }
			helpers.assert_eq(tracker.init(state, { append_log = function() return true end,
				flush_buffer = function() return true end, log_app_switch = function() return true end }, function() return false end), true)
			local owner, token, scope = {}
			local accepted; accepted, token, scope = tracker.bind_physical_correlated_context_observer(owner, 20,
				function() return true end, function() end, function() return false end)
			helpers.assert_eq(accepted, true)
			hs.application.frontmostApplication = function()
				helpers.assert_eq(tracker.unbind_physical_context_observer(owner, token), true)
				helpers.assert_eq(scope.current(owner, token), false)
				helpers.assert_eq(scope.retired(owner, token), false); return nil
			end
			tracker.resync_context(); helpers.assert_eq(scope.retired(owner, token), true)
		end)
	end)
	helpers.it("forwards native system lifecycle refusal to the exact subscriber", function()
		helpers.with_stub_scope({ "modules.keylogger.watchers", "adapters.physical_observation_clock" }, function()
			local watchers = helpers.load_with_stubs("modules.keylogger.watchers")
			hs.timer.absoluteTime = clock()
			local owner, token, scope, observed = {}
			token, _, scope = watchers.bind_physical_lifecycle_observer(owner, 1, function() return true end,
				function(_, exact)
					observed = exact; helpers.assert_eq(scope.current(owner, exact), false)
					helpers.assert_eq(watchers.unbind_physical_lifecycle_observer(owner, exact), true)
					helpers.assert_eq(scope.retired(owner, exact), false)
				end)
			watchers.caffeinate_cb(-1)
			helpers.assert_true(rawequal(observed, token)); helpers.assert_eq(scope.retired(owner, token), true)
		end)
	end)
	helpers.it("returns completed old bootstrap debt without clearing a successor", function()
		local actor = require("keylogger.physical_lifecycle_observation").new("engine", clock(), function() end)
		local owner, successor, old_token, successor_token, successor_scope = {}, {}
		local accepted, reason, old_scope = actor.bind(owner, 20, function(_, exact)
			old_token = exact; actor.unbind(owner, exact)
			successor_token, _, successor_scope = actor.bind(successor, 20, function() return true end)
			return true
		end)
		helpers.assert_eq(accepted, nil); helpers.assert_eq(type(reason), "string")
		helpers.assert_eq(old_scope.retired(owner, old_token), true)
		helpers.assert_eq(successor_scope.current(successor, successor_token), true)
		actor.unbind(successor, successor_token)
	end)
end)

helpers.describe("retained exact detach request", function()
	helpers.it("requires a real source detach operation rather than caller completion", function()
		local state, scope, owner, token = lifetime()
		helpers.assert_eq(scope.detach(owner, token), false)
		state.bind_detach(function() return true end)
		helpers.assert_eq(scope.detach(owner, token), false)
		helpers.assert_eq(scope.retired(owner, token), false)
	end)
	helpers.it("requests detach after refusal but waits for its own foreign operation", function()
		local state, scope, owner, token = lifetime(); local calls = 0
		state.bind_detach(function(candidate_owner, candidate_token)
			calls = calls + 1; helpers.assert_true(rawequal(candidate_owner, owner))
			helpers.assert_true(rawequal(candidate_token, token)); state.detach()
			helpers.assert_eq(scope.retired(owner, token), false); return true
		end)
		state.revoke(); helpers.assert_eq(scope.detach({}, token), false)
		helpers.assert_eq(scope.detach(owner, {}), false); helpers.assert_eq(calls, 0)
		helpers.assert_eq(scope.detach(owner, token), true); helpers.assert_eq(calls, 1)
		helpers.assert_eq(scope.retired(owner, token), true)
		helpers.assert_eq(scope.detach(owner, token), true); helpers.assert_eq(calls, 1)
	end)
	helpers.it("retains an unfinished actual source frame after exact detach request", function()
		local state, scope, owner, token = lifetime()
		state.bind_detach(function() state.detach(); return true end)
		state.run(function()
			helpers.assert_eq(scope.detach(owner, token), true)
			helpers.assert_eq(scope.retired(owner, token), false)
		end)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("contains detach failure and refuses recursive requests", function()
		for _, kind in ipairs({ "refused", "error", "reentry" }) do
			local state, scope, owner, token = lifetime(); local calls = 0
			state.bind_detach(function()
				calls = calls + 1
				if kind == "error" then error("Native subscription detach failed") end
				if kind == "reentry" then helpers.assert_eq(scope.detach(owner, token), false) end
				return false
			end)
			helpers.assert_eq(scope.detach(owner, token), false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(scope.retired(owner, token), false)
		end
	end)
	helpers.it("requests actual lifecycle detach after writer refusal without touching a successor", function()
		local actor = require("keylogger.physical_lifecycle_observation").new("engine", clock(), function() end)
		local owner, successor = {}, {}
		local token, _, scope = actor.bind(owner, 1, function() return true end)
		actor.run("start", function() return true end, function() return { enabled = true, paused = false, runtime_generation = 1 } end)
		helpers.assert_eq(scope.current(owner, token), false); helpers.assert_eq(scope.retired(owner, token), false)
		helpers.assert_eq(scope.detach(owner, {}), false); helpers.assert_eq(scope.detach(owner, token), true)
		local next_token, _, next_scope = actor.bind(successor, 20, function() return true end)
		helpers.assert_eq(actor.unbind(owner, token), false)
		helpers.assert_eq(scope.detach(owner, token), true)
		helpers.assert_eq(next_scope.current(successor, next_token), true)
		helpers.assert_eq(scope.retired(owner, token), true); actor.unbind(successor, next_token)
	end)
end)

helpers.describe("failed acquisition retained identity", function()
	helpers.it("returns retained identity only to the exact subscription owner", function()
		local _, scope, owner, token = lifetime()
		helpers.assert_true(rawequal(scope.identity(owner), token))
		local forged = setmetatable({}, { __eq = function() error("Identity equality hook") end })
		helpers.assert_eq(scope.identity(forged), nil)
	end)
	helpers.it("keeps exact bootstrap identity available after failure before the first receipt", function()
		local actor = require("keylogger.physical_lifecycle_observation").new("engine", function() error("Clock refused") end, function() end)
		local owner = {}; local token, reason, scope = actor.bind(owner, 20, function() error("No receipt can arrive") end)
		helpers.assert_eq(token, nil); helpers.assert_eq(type(reason), "string")
		local exact = scope.identity(owner); helpers.assert_eq(type(exact), "table")
		helpers.assert_eq(scope.current(owner, exact), false); helpers.assert_eq(scope.retired(owner, exact), true)
		helpers.assert_eq(scope.detach(owner, exact), true)
	end)
end)

helpers.describe("retired source identity cannot follow a replacement", function()
	helpers.it("returns only the old source-minted token after callback replacement", function()
		local actor = require("keylogger.physical_lifecycle_observation").new("engine", clock(), function() end)
		local owner, successor, original, replacement, replacement_scope = {}, {}
		local accepted, _, old_scope = actor.bind(owner, 20, function(_, exact)
			original = exact; actor.unbind(owner, exact)
			replacement, _, replacement_scope = actor.bind(successor, 20, function() return true end); return true
		end)
		helpers.assert_eq(accepted, nil); helpers.assert_true(rawequal(old_scope.identity(owner), original))
		helpers.assert_eq(old_scope.identity(successor), nil); helpers.assert_true(not rawequal(original, replacement))
		helpers.assert_eq(old_scope.retired(owner, original), true)
		helpers.assert_eq(replacement_scope.current(successor, replacement), true); actor.unbind(successor, replacement)
	end)
end)

helpers.describe("asynchronous subscription source debt", function()
	helpers.it("retains exact asynchronous source debt after detach until its terminal frame", function()
		local state, scope, owner, token = lifetime(); local frame = state.enter()
		helpers.assert_eq(type(frame), "table"); state.detach()
		helpers.assert_eq(scope.retired(owner, token), false)
		helpers.assert_eq(state.leave(frame), true); helpers.assert_eq(scope.retired(owner, token), true)
		helpers.assert_eq(state.leave(frame), false)
	end)
	helpers.it("cannot clear asynchronous debt with a foreign or aliased frame", function()
		local state, scope, owner, token = lifetime(); local frame = state.enter(); state.detach()
		local forged = setmetatable({}, { __eq = function() error("Frame equality hook") end })
		helpers.assert_eq(state.leave(forged), false); helpers.assert_eq(scope.retired(owner, token), false)
		frame.complete = true; helpers.assert_eq(scope.retired(owner, token), false)
		helpers.assert_eq(state.leave(frame), true); helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("accounts synchronous callbacks independently of retained asynchronous frames", function()
		local state, scope, owner, token = lifetime(); local held = state.enter()
		state.run(function()
			state.detach(); helpers.assert_eq(state.leave(held), true)
			helpers.assert_eq(scope.retired(owner, token), false)
		end)
		helpers.assert_eq(scope.retired(owner, token), true); helpers.assert_eq(state.enter(), nil)
	end)
end)

--- tests/unit/modules/keylogger/test_physical_subscription_foreign_observations.lua

--- Decisive observations are asserted outside foreign ports whose errors are contained.
local helpers = require("tests.helpers")
local function clock()
	local at = 0
	return function() at = at + 1; return at end
end
local function filters() return { disabled_apps = {}, private_filter_enabled = true,
	secure_field_filter_enabled = true, system_auth_filter_enabled = true } end
local function fields() return { enabled = true, paused = false, runtime_generation = 1 } end
for _, kind in ipairs({ "configuration", "context" }) do
	helpers.describe("foreign " .. kind .. " retirement observations", function()
		local function new_channel(identity, receive, refused, sample)
			local module = require("keylogger.physical_" .. kind .. "_observation")
			if kind == "configuration" then return module.new(1, sample or clock(), receive, refused, identity) end
			return module.new(1, sample or clock(), receive, refused, nil, identity)
		end
		local function publish(channel)
			if kind == "configuration" then return channel.publish(filters()) end
			return channel.seed()
		end
		helpers.it("observes unfinished receipt debt outside its contained callback", function()
			local identity, channel, scope, observed_retired, observed_current = { owner = {}, token = {} }
			channel = new_channel(identity, function()
				channel.close(); observed_retired = scope.retired(identity.owner, identity.token)
				observed_current = scope.current(identity.owner, identity.token); return true
			end, function() end)
			scope = channel.subscription(); helpers.assert_eq(publish(channel), false)
			helpers.assert_eq(observed_retired, false); helpers.assert_eq(observed_current, false)
			helpers.assert_eq(scope.retired(identity.owner, identity.token), true)
		end)
		helpers.it("observes unfinished clock debt outside its contained getter", function()
			local identity, channel, scope, observed = { owner = {}, token = {} }
			channel = new_channel(identity, function() error("No owned-token receipt after detach") end, function() end,
				function() channel.close(); observed = scope.retired(identity.owner, identity.token); return 1 end)
			scope = channel.subscription(); helpers.assert_eq(publish(channel), false)
			helpers.assert_eq(observed, false); helpers.assert_eq(scope.retired(identity.owner, identity.token), true)
		end)
		helpers.it("observes terminal refusal debt outside its contained observer", function()
			local identity, channel, scope, observed, current, calls = { owner = {}, token = {} }, nil, nil, nil, nil, 0
			channel = new_channel(identity, function() return true end, function()
				calls = calls + 1; current = scope.current(identity.owner, identity.token)
				channel.close(); observed = scope.retired(identity.owner, identity.token)
			end)
			scope = channel.subscription(); helpers.assert_eq(publish(channel), true)
			helpers.assert_eq(publish(channel), false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(current, false); helpers.assert_eq(observed, false)
			helpers.assert_eq(scope.retired(identity.owner, identity.token), true)
		end)
	end)
end

helpers.describe("foreign lifecycle retirement observations", function()
	helpers.it("observes unfinished snapshot debt outside its contained getter", function()
		local actor = require("keylogger.physical_lifecycle_observation").new("engine", clock(), function() end)
		local owner = {}; local token, _, scope = actor.bind(owner, 20, function() return true end)
		local observed, detached
		helpers.assert_eq(actor.run("start", function() return true end, function()
			detached = actor.unbind(owner, token); observed = scope.retired(owner, token); return fields()
		end), true)
		helpers.assert_eq(detached, true); helpers.assert_eq(observed, false)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("observes receipt and actual writer debt outside contained dispatch", function()
		local owner, scope, callback_retired, writer_retired = {}
		local actor = require("keylogger.physical_lifecycle_observation").new("engine", clock(), function() end)
		local token; token, _, scope = actor.bind(owner, 20, function(record, exact)
			if record.source ~= "binding" then
				actor.unbind(owner, exact); callback_retired = scope.retired(owner, exact)
			end
			return true
		end)
		local result = actor.run("stop", function() writer_retired = scope.retired(owner, token); return false end, fields)
		helpers.assert_eq(result, false); helpers.assert_eq(callback_retired, false); helpers.assert_eq(writer_retired, false)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("observes exact bound refusal and legacy notification debt outside both ports", function()
		local actor, owner, scope, bound_retired, legacy_retired, bound_token, legacy_count, legacy_args = nil, {}, nil, nil, nil, nil, 0
		actor = require("keylogger.physical_lifecycle_observation").new("engine", clock(), function(...)
			legacy_count = legacy_count + 1; legacy_args = select("#", ...)
			legacy_retired = scope.retired(owner, scope.identity(owner))
		end)
		local token; token, _, scope = actor.bind(owner, 1, function() return true end, function(_, exact)
			bound_token = exact; scope.detach(owner, exact); bound_retired = scope.retired(owner, exact)
		end)
		actor.run("start", function() return true end, fields)
		helpers.assert_true(rawequal(bound_token, token)); helpers.assert_eq(bound_retired, false)
		helpers.assert_eq(legacy_retired, false); helpers.assert_eq(legacy_count, 1); helpers.assert_eq(legacy_args, 1)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
end)

helpers.describe("native protected callback observations outside containment", function()
	helpers.it("observes unfinished actual context query debt after native unwind", function()
		helpers.with_stub_scope({ "modules.keylogger.context_tracker", "adapters.physical_observation_clock" }, function()
			local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker")
			hs.timer.absoluteTime = clock()
			local state = { is_enabled = true, disabled_apps = {}, active_app_start = 0,
				private_filter_enabled = true, secure_field_filter_enabled = true, system_auth_filter_enabled = true,
				buffer_events = {}, buffer_text = "", rich_chunks = {}, last_time = 0 }
			helpers.assert_eq(tracker.init(state, { append_log = function() return true end,
				flush_buffer = function() return true end, log_app_switch = function() return true end }, function() return false end), true)
			local owner = {}; local accepted, token, scope = tracker.bind_physical_correlated_context_observer(owner, 20,
				function() return true end, function() end, function() return false end)
			helpers.assert_eq(accepted, true)
			local detached, observed_retired, observed_current
			hs.application.frontmostApplication = function()
				detached = tracker.unbind_physical_context_observer(owner, token)
				observed_current = scope.current(owner, token); observed_retired = scope.retired(owner, token); return nil
			end
			tracker.resync_context()
			helpers.assert_eq(detached, true); helpers.assert_eq(observed_current, false)
			helpers.assert_eq(observed_retired, false); helpers.assert_eq(scope.retired(owner, token), true)
		end)
	end)
	helpers.it("observes exact system refusal debt after native callback unwind", function()
		helpers.with_stub_scope({ "modules.keylogger.watchers", "adapters.physical_observation_clock" }, function()
			local watchers = helpers.load_with_stubs("modules.keylogger.watchers")
			hs.timer.absoluteTime = clock()
			local owner = {}; local scope, token, observed_token, observed_current, observed_retired, detached
			token, _, scope = watchers.bind_physical_lifecycle_observer(owner, 1, function() return true end, function(_, exact)
				observed_token = exact; observed_current = scope.current(owner, exact)
				detached = scope.detach(owner, exact); observed_retired = scope.retired(owner, exact)
			end)
			watchers.caffeinate_cb(-1)
			helpers.assert_true(rawequal(observed_token, token)); helpers.assert_eq(detached, true)
			helpers.assert_eq(observed_current, false); helpers.assert_eq(observed_retired, false)
			helpers.assert_eq(scope.retired(owner, token), true)
		end)
	end)
end)
