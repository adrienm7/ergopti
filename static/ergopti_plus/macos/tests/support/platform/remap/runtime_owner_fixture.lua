--- tests/support/platform/remap/runtime_owner_fixture.lua

--- ==============================================================================
--- MODULE: Owned Runtime Owner Fixture
--- DESCRIPTION:
--- A modelled Mac for platform/remap/runtime_owner.lua: an in-memory filesystem,
--- launchd, system extension listing, other-Karabiner processes, a physical
--- capture and a manual timer, every one of them recording its calls. A test
--- that needs a callback to arrive later sets `world.deferred = true` and
--- delivers the queue itself with `world.flush()`; a test that needs time to pass
--- calls `world.tick()`.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}

M.VHID_VERSION = "8.5.0"

--- A listing line as `systemextensionsctl list` prints it.
--- @param version string Driver version.
--- @param state string Bracketed activation text.
--- @param team string|nil Team identifier.
--- @return string listing
function M.listing(version, state, team)
	return "1 extension(s)\n--- com.apple.system_extension.driver_extension\n"
		.. "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n"
		.. "*\t*\t" .. (team or "G43BCU2T37") .. "\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice ("
		.. version .. "/" .. version .. ")\tKarabiner-DriverKit-VirtualHIDDevice\t[" .. state .. "]\n"
end

--- Builds a world in which the owned runtime is installed, compatible and alone.
--- @return table world
function M.new_world()
	local KePaths = require("platform.remap.ke_paths")
	local world = {
		deferred = false,
		pending = {},
		files = {},
		jobs = {},
		listing_text = M.listing(M.VHID_VERSION, "activated enabled"),
		others = 0,
		close_result = true,
		others_after_close = 0,
		calls = { capture_start = {}, capture_stop = 0, close = 0, states = {}, timers = {}, cancelled = 0 },
		pinned = { virtual_hid_version = M.VHID_VERSION, capture = { requirement = "pinned" } },
		capture_accepts = true,
		capture_settles_sync = true,
		capture_state = "starting",
		timers = {},
		timer_commits = true,
	}
	for _, path in ipairs({ KePaths.OWNED.CLI, KePaths.OWNED.CORE_SERVICE, KePaths.OWNED.CONSOLE,
		KePaths.OWNED.CORE_JOB_FILE, "/home/user/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json" }) do
		world.files[path] = true
	end
	world.jobs[KePaths.OWNED.VIRTUAL_HID_LABEL] = true
	world.jobs[KePaths.OWNED.CORE_LABEL] = true

	local function deliver(callback, ...)
		if not world.deferred then return callback(...) end
		local arguments = table.pack(...)
		world.pending[#world.pending + 1] = function() callback(table.unpack(arguments, 1, arguments.n)) end
	end
	--- Delivers every queued callback in order.
	function world.flush()
		while #world.pending > 0 do table.remove(world.pending, 1)() end
	end
	--- Lets the armed timers fire once, oldest first.
	--- @return integer fired
	function world.tick()
		local due = world.timers
		world.timers = {}
		local fired = 0
		for _, timer in ipairs(due) do
			if not timer.cancelled then
				fired = fired + 1
				timer.callback()
			end
		end
		return fired
	end

	world.ports = {
		fs = {
			exists = function(path) return world.files[path] == true end,
			expand = function(path) return (path:gsub("^~", "/home/user")) end,
		},
		launchd = {
			loaded = function(label, callback)
				local value = world.jobs[label]
				if world.launchd_unreadable then value = nil end
				deliver(callback, value)
			end,
		},
		system_extensions = {
			listing = function(callback) deliver(callback, world.listing_text) end,
		},
		coexistence = {
			detect = function(callback)
				local count = world.others
				if world.probe_fails then count = nil end
				deliver(callback, count)
			end,
			close = function(callback)
				world.calls.close = world.calls.close + 1
				world.others = world.others_after_close
				deliver(callback, world.close_result)
			end,
		},
		artifact = {
			pinned = function()
				if world.pinned == nil then return nil, "manifest absent" end
				return world.pinned
			end,
		},
		capture = {
			start = function(options)
				world.calls.capture_start[#world.calls.capture_start + 1] = options
				return world.capture_accepts
			end,
			stop = function(callback)
				world.calls.capture_stop = world.calls.capture_stop + 1
				if world.capture_settles_sync then return true end
				world.capture_stop_callback = callback
				return false
			end,
			status = function() return { state = world.capture_state } end,
			on_lost = function(callback) world.lost_callback = callback end,
		},
		timer = {
			after = function(seconds, callback)
				world.calls.timers[#world.calls.timers + 1] = seconds
				local handle = { callback = callback }
				if not world.timer_commits then return handle, false end
				world.timers[#world.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle)
				handle.cancelled = true
				world.calls.cancelled = world.calls.cancelled + 1
				return true
			end,
		},
		observer = function(state) world.calls.states[#world.calls.states + 1] = state end,
	}
	return world
end

--- Loads a fresh owner module over a quiet logger.
--- @return table owner
function M.load_owner()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["platform.remap.ke_paths"] = nil
	package.loaded["platform.remap.runtime_vhid"] = nil
	package.loaded["platform.remap.runtime_owner"] = nil
	return require("platform.remap.runtime_owner")
end

return M
