--- _shared/lua/keystats/text_migration_driver.lua

--- ==============================================================================
--- MODULE: Typed-Text At-Rest Migration Driver Surface (Shared)
--- DESCRIPTION:
--- The public surface both drivers expose for the at-rest migration of stored
--- typed text (modules/keystats/text_migration.lua): start, resume, pump,
--- cancel, progress, the test seam that swaps the backend, and the optional
--- slicing. The state machine is keystats/text_migration_runner.lua and the SQL
--- is keystats/text_migration.lua; what a driver supplies here is only its
--- ports: the row access (backend), the logger, the cipher, and when the pass
--- is driven by a scheduler, that scheduler.
---
--- FEATURES & RATIONALE:
--- 1. One surface. The seam that swaps the backend and the rule that a restarted
---    pass cancels the previous one live here once, so a driver cannot grow a
---    variant of either.
--- 2. Slicing is a port, not a branch. Without a scheduler the owner calls pump()
---    from its own periodic tick (Linux daemon); with one, every started pass
---    schedules its own next slice (Hammerspoon has no tick to borrow, and one
---    long loop would block the run loop that services the keyboard tap).
--- 3. The posture entry points exist only with a scheduler and a default device,
---    because only a driver that owns its own device identity can start a pass
---    from the setting alone.
--- 4. No load-time driver dependency: every collaborator is a port, so the module
---    loads in a test that builds no driver paths.
--- ==============================================================================

local Runner = require("keystats.text_migration_runner")
local Plan   = require("keystats.text_migration")

local M = {}





-- ==============================
-- ==============================
-- ======= 1/ Public API ========
-- ==============================
-- ==============================

--- Builds one driver's migration surface.
--- @param ports table {
---   logger     table     error/warn/info/start/success.
---   log_tag    string    Tag passed as the logger's first argument.
---   cipher     table     encrypt/decrypt of the driver's text_cipher.
---   backend    table     The driver's real row access (see text_migration_runner).
---   scheduler  table|nil { after(seconds, fn) -> handle, cancel(handle), gap_sec }
---                        When present, the module slices its own passes.
---   device_id  function|nil Returns the LOCAL device id used when a caller gives none.
--- }
--- @return table|nil module
--- @return string|nil error
function M.new(ports)
	if type(ports) ~= "table" then return nil, "ports are required" end
	local scheduler = ports.scheduler
	if scheduler ~= nil and (type(scheduler) ~= "table" or type(scheduler.after) ~= "function"
		or type(scheduler.cancel) ~= "function" or type(scheduler.gap_sec) ~= "number") then
		return nil, "scheduler needs after, cancel and gap_sec"
	end
	if ports.device_id ~= nil and type(ports.device_id) ~= "function" then
		return nil, "device_id must be a function"
	end

	local function build(backend)
		local runner = Runner.new({
			logger = ports.logger, log_tag = ports.log_tag, cipher = ports.cipher, backend = backend,
		})
		return runner
	end

	local _runner = build(ports.backend)
	if not _runner then return nil, "the runner needs a logger, a log tag, a cipher and a backend" end

	local module = {}
	local _slice = nil
	local run_slice

	--- Resolves the device a pass runs for.
	local function resolve_device(device_id)
		if device_id ~= nil or not ports.device_id then return device_id end
		return ports.device_id()
	end

	--- Arms the next slice; a no-op without a scheduler.
	local function arm()
		if scheduler then _slice = scheduler.after(scheduler.gap_sec, run_slice) end
	end

	-- Declared as a local BEFORE the closure that reschedules it: a forward
	-- reference inside the closure would resolve to a nil global and the pass
	-- would convert exactly one batch and stop.
	run_slice = function()
		_slice = nil
		if not _runner.pump() then return end
		arm()
	end

	--- Installs a replacement backend (test seam); nil restores the real one.
	--- @param replacement table|nil
	function module._set_backend(replacement)
		_runner = build((type(replacement) == "table") and replacement or ports.backend)
	end

	--- Starts a migration pass, cancelling the one in flight when sliced.
	--- @param mode       string Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT.
	--- @param device_id  string|nil The LOCAL device.
	--- @return boolean True when a pass is now in flight.
	function module.start(mode, device_id)
		if scheduler then module.cancel() end
		if not _runner.start(mode, resolve_device(device_id)) then return false end
		arm()
		return true
	end

	--- Resumes only a pass a previous run left unfinished.
	--- @param mode       string
	--- @param device_id  string|nil
	--- @return boolean True when a pass is now in flight.
	function module.resume(mode, device_id)
		if scheduler then module.cancel() end
		if not _runner.resume(mode, resolve_device(device_id)) then return false end
		arm()
		return true
	end

	--- Converts one bounded batch. Safe to call at any cadence; a no-op when idle.
	--- @return boolean True when there is more to do.
	function module.pump() return _runner.pump() end

	--- Stops the pass. Converted rows stay converted and the stored cursor lets a
	--- later call resume from there, so this is a pause and not a revert.
	function module.cancel()
		if _slice then
			scheduler.cancel(_slice)
			_slice = nil
		end
		_runner.cancel()
	end

	--- Whether a pass is in flight.
	--- @return boolean
	function module.is_running() return _runner.is_running() end

	--- Snapshot of the pass, for the menu and for diagnostics.
	--- @return table
	function module.get_progress() return _runner.get_progress() end

	if scheduler and ports.device_id then
		--- Starts the pass matching a posture. Called when the user flips the setting.
		--- @param encrypt_enabled boolean The posture now in force.
		--- @return boolean True when a pass is now in flight.
		function module.start_for_posture(encrypt_enabled)
			return module.start(encrypt_enabled and Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT)
		end

		--- Resumes the pass matching a posture, if a previous run left one unfinished.
		--- @param encrypt_enabled boolean The posture now in force.
		--- @param device_id string|nil
		--- @return boolean True when a pass is now in flight.
		function module.resume_for_posture(encrypt_enabled, device_id)
			return module.resume(encrypt_enabled and Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT, device_id)
		end
	end

	return module, nil
end

return M
