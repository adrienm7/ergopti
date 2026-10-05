-- tools/diagnostics/macos_physical_clock.lua
-- Actual hosted borrowed-clock qualification only. No input or context sensor starts.
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local json = require("hs.json")
local config = assert(json.read(directory .. "/probe-config.json"))
local result = { schema = 1, status = "error", runtime = "native Hammerspoon",
	version = hs.processInfo.version, pid = hs.processInfo.processID, nonce = config.nonce,
	binding_scope = "borrowed hs.timer.absoluteTime API only", samples = {}, facts = {} }
local bindings = {}
local function sample(phase, value)
	assert(math.type(value) == "integer" and value >= 0, "Actual clock sample lost integer representation")
	result.samples[#result.samples + 1] = { phase = phase, ns = tostring(value) }
end
local function cleanup()
	for _, binding in ipairs(bindings) do
		assert(binding.scope.detach(binding.owner, binding.token) == true, "Exact clock binding detach refused")
		assert(binding.scope.retired(binding.owner, binding.token) == true, "Clock getter frame remains unfinished")
	end
end
hs.shutdownCallback = cleanup
local completed, failure = xpcall(function()
	assert(result.version == config.version, "Actual hosted runtime version differs")
	assert(type(config.nonce) == "string" and #config.nonce > 0, "Missing private observation nonce")
	local root = _G.hs
	local timer = hs.timer -- Load the actual native timer export before capturing its raw binding.
	local getter = rawget(timer, "absoluteTime")
	assert(type(getter) == "function", "Actual native clock getter unavailable")
	result.getter_what = debug.getinfo(getter, "S").what
	assert(result.getter_what == "C", "Native qualification requires the actual C getter")
	package.path = config.source_root .. "/static/ergopti_plus/macos/?.lua;"
		.. config.source_root .. "/static/ergopti_plus/_shared/lua/?.lua;" .. package.path
	assert(package.loaded["adapters.physical_observation_clock"] == nil, "Clock adapter was already loaded")
	assert(package.loaded["keylogger.physical_subscription_lifetime"] == nil, "Lifetime helper was already loaded")
	local Clock = require("adapters.physical_observation_clock")
	assert(type(Clock.bind_history_scope) == "function", "Reviewed clock binding prerequisite is missing")
	sample("legacy_before", Clock.now())
	local owner = {}
	local scope, reason = Clock.bind_history_scope(owner)
	assert(scope and reason == nil, "Actual clock binding refused")
	local token = assert(scope.identity(owner))
	bindings[#bindings + 1] = { scope = scope, owner = owner, token = token }
	local facts = result.facts
	facts.current_before = scope.current(owner, token) == true and scope.retired(owner, token) == false
	local wrong_owner, wrong_owner_reason = scope.read({}, token)
	facts.wrong_owner_denied = wrong_owner == nil and wrong_owner_reason == "clock_identity_refused"
	local wrong_token, wrong_token_reason = scope.read(owner, {})
	facts.wrong_token_denied = wrong_token == nil and wrong_token_reason == "clock_identity_refused"
	local duplicate, duplicate_reason = Clock.bind_history_scope({})
	facts.duplicate_bind_refused = duplicate == nil and duplicate_reason == "clock_subscription_busy"
	sample("bound_read", assert(scope.read(owner, token)))
	sample("bound_now", Clock.now())
	facts.detached = scope.detach(owner, token) == true
	facts.retired_after_detach = scope.current(owner, token) == false and scope.retired(owner, token) == true
	local detached_read, detached_reason = scope.read(owner, token)
	facts.read_after_detach_denied = detached_read == nil and detached_reason == "clock_subscription_detached"
	sample("legacy_after_detach", Clock.now())
	local successor = {}
	local next_scope, next_reason = Clock.bind_history_scope(successor)
	assert(next_scope and next_reason == nil, "Actual successor clock binding refused")
	local next_token = assert(next_scope.identity(successor))
	bindings[#bindings + 1] = { scope = next_scope, owner = successor, token = next_token }
	facts.successor_distinct = not rawequal(token, next_token) and rawequal(scope.identity(owner), token)
	facts.successor_current = next_scope.current(successor, next_token) == true
	sample("successor_read", assert(next_scope.read(successor, next_token)))
	facts.successor_detached = next_scope.detach(successor, next_token) == true
	facts.successor_retired = next_scope.retired(successor, next_token) == true
	facts.getter_unchanged = rawequal(_G.hs, root) and rawequal(rawget(root, "timer"), timer)
		and rawequal(rawget(timer, "absoluteTime"), getter) and debug.getinfo(getter, "S").what == "C"
	for name, observed in pairs(facts) do assert(observed == true, "Actual binding observation failed: " .. name) end
	cleanup()
	result.status = "ok"
end, debug.traceback)
if not completed then
	result.error = tostring(failure)
	local cleaned, cleanup_error = pcall(cleanup)
	if not cleaned then result.cleanup_error = tostring(cleanup_error) end
end
local temporary = config.output_dir .. "/result.json.tmp"
assert(json.write(result, temporary, true, true), "Native clock result staging failed")
assert(os.rename(temporary, config.output_dir .. "/result.json"), "Native clock result publication failed")
-- Remain alive without timers until the parent observes this exact child and
-- retires its reserved inherited process group through the existing creator.
