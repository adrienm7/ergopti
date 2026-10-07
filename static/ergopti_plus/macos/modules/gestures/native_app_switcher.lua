--- modules/gestures/native_app_switcher.lua

--- Product broker facade. Structural reachability is not native readiness.
--- Existing previous-window actions retain their direct activation semantics.
local NativeOwner = require("native_app_switcher_owner")
local SyntheticInput = require("adapters.synthetic_input")
local Scheduler = require("adapters.timer_scheduler")
local Windows = require("adapters.window_manager")
local M = {}

local INPUT_METHODS = {
	ready = "system_switcher_available",
	prepare = "prepare_system_switcher",
	post = "post_system_switcher_edge",
	observed = "system_switcher_observation_current",
	released = "system_switcher_release_current",
	cancel_input = "cancel_system_switcher",
	retire_input = "retire_system_switcher",
}
local owner, captured, initialized = nil, nil, false
local paused, generation = true, 0

local function references()
	if not captured then return false end
	for _, name in pairs(INPUT_METHODS) do
		if not rawequal(rawget(SyntheticInput, name), captured[name]) then return false end
	end
	return rawequal(rawget(Scheduler, "every"), captured.every)
		and rawequal(rawget(Scheduler, "cancel"), captured.cancel)
		and rawequal(rawget(Scheduler, "awake_time"), captured.awake_time)
		and rawequal(rawget(Windows, "frontmost_pid"), captured.frontmost_pid)
end

--- Initializes only after the native input owner exports the complete contract.
--- The policy must be admitted by the root's canonical timing owner; it is not
--- borrowed from diagnostic polling or an unrelated product timeout.
--- @param policy table {deadline_sec=number, poll_sec=number}.
--- @return boolean initialized
function M.init(policy)
	if initialized then return false end
	local input = {}
	for _, name in pairs(INPUT_METHODS) do
		local fn = rawget(SyntheticInput, name)
		if type(fn) ~= "function" then return false end
		input[name] = fn
	end
	for _, name in ipairs({ "every", "cancel", "awake_time" }) do
		if type(rawget(Scheduler, name)) ~= "function" then return false end
		input[name] = rawget(Scheduler, name)
	end
	if type(rawget(Windows, "frontmost_pid")) ~= "function" then return false end
	input.frontmost_pid = rawget(Windows, "frontmost_pid")
	local ports = {
		every = input.every, cancel_timer = input.cancel,
		now = input.awake_time, frontmost = input.frontmost_pid,
		provider_current = function() return initialized and not paused and references() end,
	}
	for role, name in pairs(INPUT_METHODS) do ports[role] = input[name] end
	local candidate = NativeOwner.new(ports, policy)
	if not candidate then return false end
	captured, owner, initialized = input, candidate, true
	paused, generation = false, generation + 1
	return true
end

--- @return boolean available Native readiness; never substitutes a window focus.
function M.available()
	return initialized and not paused and references() and owner.available()
end

--- Starts a source-bound operation, preserving the caller's terminal seal.
--- @param publication table {current=function, cached=function}.
--- @param complete function|nil fn(capability, closed_status).
--- @return table|nil capability
--- @return boolean admitted
function M.request(publication, complete)
	if not initialized or paused or not references() or type(publication) ~= "table"
		or getmetatable(publication) ~= nil then return nil, false end
	local current, cached = rawget(publication, "current"), rawget(publication, "cached")
	if type(current) ~= "function" or type(cached) ~= "function" then return nil, false end
	local epoch = generation
	local function bound()
		return initialized and not paused and generation == epoch and references()
			and getmetatable(publication) == nil
			and rawequal(rawget(publication, "current"), current)
			and rawequal(rawget(publication, "cached"), cached)
	end
	return owner.request({
		current = function()
			if not bound() then return false end
			local value = current()
			return value == true and bound()
		end,
		cached = function()
			if not bound() then return false end
			local value = cached()
			return value == true and bound()
		end,
	}, complete)
end

--- Revokes normal emission before retrying exact input and timer retirement.
--- @return boolean physically_settled
function M.pause()
	if not initialized then return false end
	paused, generation = true, generation + 1
	return owner.stop()
end

--- @return boolean resumed A retained operation cannot be bypassed by resume.
function M.resume()
	if not initialized or owner.has_pending() or not references() then return false end
	paused, generation = false, generation + 1
	return true
end

--- @return boolean physically_settled
function M.stop() return M.pause() end

--- @return boolean pending Exact native input/timer retirement remains.
function M.has_pending() return owner ~= nil and owner.has_pending() end

--- Revokes only the exact request without pausing an unrelated parent scope.
--- @param capability table Exact request capability.
--- @return boolean physically_settled
function M.cancel(capability) return owner ~= nil and owner.cancel(capability) end

--- @param capability table Exact request capability.
--- @return string|nil status Closed result, published after physical retirement.
function M.status(capability) return owner and owner.status(capability) or nil end

return M
