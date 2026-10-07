--- modules/gestures/native_app_switcher_action.lua

--- Joins native input and per-parent action lifecycle without direct activation.
local M = {}
local Facade = require("modules.gestures.native_app_switcher")
local Input = require("adapters.synthetic_input")
local Runtime = require("adapters.system_switcher_runtime")
local Timings = require("infra.timings")
local Logger = require("infra.logger")
local LOG = "gestures.native_app_switcher"
local initialized, active = false, nil
local scopes = {}
local function scope(parent)
	if type(parent) ~= "string" or parent == "" then return nil end
	local entry = scopes[parent]
	if not entry then entry = { paused = false, generation = 0 }; scopes[parent] = entry end
	return entry
end
local function configure()
	if initialized then return true end
	local descriptor = Runtime.descriptor()
	if descriptor == nil then return false end
	local policy = { deadline_sec = Timings.sec("gestures", "native_switcher_deadline_ms"),
		poll_sec = Timings.sec("gestures", "native_switcher_poll_ms") }
	if not Input.init_system_switcher(descriptor, policy) or not Facade.init(policy) then return false end
	initialized = true
	return true
end

--- Starts the OS switcher only while the exact source and parent remain current.
--- @param parent string Action lifecycle parent.
--- @param publication table Full source check and pure cached terminal seal.
--- @return boolean admitted
function M.request(parent, publication)
	local claim = scope(parent)
	if not claim or claim.paused or active or type(publication) ~= "table"
		or getmetatable(publication) ~= nil or type(publication.current) ~= "function"
		or type(publication.cached) ~= "function" then return false end
	if not configure() or not Facade.resume() then
		Logger.error(LOG, "Native switcher prerequisites or exact retirement are unavailable.")
		return false
	end
	local entry = { parent = parent, claim = claim, generation = claim.generation, acquiring = true }
	active = entry
	local current, cached = publication.current, publication.cached
	local function bound()
		return rawequal(active, entry) and not claim.paused and claim.generation == entry.generation
			and getmetatable(publication) == nil and rawequal(publication.current, current)
			and rawequal(publication.cached, cached)
	end
	local cap, admitted = Facade.request({
		current = function() return bound() and current() == true and bound() end,
		cached = function() return bound() and cached() == true and bound() end,
	}, function(_, status)
		if not rawequal(active, entry) then return end
		active = nil
		Logger.debug(LOG, "Native switcher completed: %s.", tostring(status))
	end)
	entry.cap, entry.acquiring = cap, false
	if cap == nil and rawequal(active, entry) then active = nil end
	return admitted == true
end

--- Revokes only the named parent and preserves any exact native cleanup debt.
--- @param parent string Action lifecycle parent.
--- @return boolean settled
function M.pause(parent)
	local claim = scope(parent)
	if not claim then return false end
	claim.paused, claim.generation = true, claim.generation + 1
	if not active or active.parent ~= parent then return true end
	if active.acquiring then Facade.pause(); return false end
	return Facade.cancel(active.cap) == true
end

--- Opens a parent only after its native retirement has completed.
--- @param parent string Action lifecycle parent.
--- @return boolean resumed
function M.resume(parent)
	local claim = scope(parent)
	if not claim or M.has_pending(parent) then return false end
	claim.paused, claim.generation = false, claim.generation + 1
	return true
end

--- @param parent string Action lifecycle parent.
--- @return boolean paused
function M.is_paused(parent) local claim = scope(parent); return claim ~= nil and claim.paused end

--- @param parent string Action lifecycle parent.
--- @return boolean pending Exact native input/tap/task/timer retirement remains.
function M.has_pending(parent) return active ~= nil and active.parent == parent end

return M
