--- keyboard/adapters/runtime/approval_watch.lua

--- ==============================================================================
--- MODULE: Owned Runtime Driver Approval Watch
--- DESCRIPTION:
--- After the owned runtime is installed, macOS keeps pqrs' VirtualHIDDevice
--- driver waiting until the user allows it in System Settings. This module
--- opens that exact pane once, watches the system extension listing, and asks
--- for a driver reload as soon as the driver is active, so the tap-holds come
--- back without a manual restart (ADR 011, WP8).
---
--- FEATURES & RATIONALE:
--- 1. Read-Only Watch: it only lists system extensions; macOS alone approves.
--- 2. Bounded: one watch per launch, polled at a fixed pace and given up after
---    a deadline, with the pane left for the user and the menu row explaining.
--- 3. Ports Only: listing, timer, pane opener and reload are ports.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local Vhid = require("keyboard.adapters.runtime.vhid")

local LOG = "remap.runtime_approval_watch"

--- Seconds between two looks at the system extension listing.
M.APPROVAL_POLL_SEC = 3

--- Seconds the user has to allow the driver before the watch gives up.
M.APPROVAL_TIMEOUT_SEC = 900

--- Creates a watch bound to its ports.
--- Port contracts:
---   listing(fn(text|nil)) is `systemextensionsctl list`;
---   now() -> monotonic seconds, so slow listings and late timers spend the budget;
---   after(seconds, fn) -> handle, committed; cancel(handle);
---   open_settings(url) -> true when the System Settings pane opened; reload() reloads the driver;
---   version() -> the pinned driver version or nil.
--- @param ports table listing, now, after, cancel, open_settings, reload, version.
--- @return table watch { start, active }.
function M.new(ports)
	assert(type(ports) == "table", "Missing approval watch ports")
	for _, name in ipairs({ "listing", "now", "after", "cancel", "open_settings", "reload", "version" }) do
		assert(type(ports[name]) == "function", "Missing approval watch port: " .. name)
	end
	local watch = {}
	local started, running, handle = false, false, nil
	local deadline

	local function stop(level, message, ...)
		running = false
		if handle then ports.cancel(handle); handle = nil end
		Logger[level](LOG, message, ...)
	end

	-- The budget is wall time from start, not a count of polls: each listing is
	-- a bounded task and each timer can fire late, and neither may extend it.
	local function expired()
		if ports.now() < deadline then return false end
		stop("warn", "The driver was not allowed within %d s; the Tap-Holds menu keeps explaining it.", M.APPROVAL_TIMEOUT_SEC)
		return true
	end

	local function poll()
		if expired() then return end
		ports.listing(function(text)
			if not running or expired() then return end
			local version = ports.version()
			if type(version) == "string" and Vhid.assess(Vhid.parse(text), version).ok then
				stop("success", "The driver is now allowed; reloading to start the owned runtime.")
				return ports.reload()
			end
			local committed
			handle, committed = ports.after(M.APPROVAL_POLL_SEC, function() handle = nil; poll() end)
			if committed ~= true then stop("error", "The approval watch could not schedule its next look; it stops.") end
		end)
	end

	--- Opens the approval pane once and watches until the driver is active.
	--- @return boolean started False when this launch already watched.
	function watch.start()
		if started then return false end
		started, running, deadline = true, true, ports.now() + M.APPROVAL_TIMEOUT_SEC
		Logger.start(LOG, "Opening the driver approval pane and watching for the approval…")
		-- The native opener answers a boolean: false is a refusal, not a success.
		local called, opened = pcall(ports.open_settings, require("keyboard.adapters.karabiner.ke_paths").EXTENSIONS_SETTINGS_URL)
		if not called then
			Logger.error(LOG, "The driver approval pane could not be opened: %s.", tostring(opened))
		elseif opened ~= true then
			Logger.error(LOG, "macOS refused to open the driver approval pane (%s); the watch goes on.", tostring(opened))
		end
		poll()
		return true
	end

	--- @return boolean running
	function watch.active() return running end

	return watch
end

return M
