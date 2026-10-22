--- adapters/task_output_turn.lua

--- ==============================================================================
--- MODULE: Task Output Turn Probe (Hammerspoon)
--- DESCRIPTION:
--- Tells a caller when the main run loop delivers child process output again.
---
--- FEATURES & RATIONALE:
--- 1. Two run loop modes: hs.task reads a streaming child with
---    readInBackgroundAndNotify, whose notification is posted in the default
---    run loop mode only, while hs.timer callbacks and hs.task completions run
---    in the common modes. While a menubar menu is open (event tracking mode) or
---    a modal panel runs, a deadline timer therefore fires on time while the
---    answer it waits for already sits in the pipe, unread. Issue #100 lost the
---    Karabiner lease seven times that way, each time "on time" and with the
---    worker's own answer never read.
--- 2. An echo, not a clock: the probe writes one line to /bin/cat and waits for
---    the echo through the same streaming path. Background read notifications
---    are delivered in the order they were posted, so when the echo arrives,
---    every output another task wrote before the probe started has already been
---    handed to its callback. Only then may a deadline conclude that a child is
---    silent.
--- 3. Exact settlement: the caller hears exactly once, with true for a
---    delivered echo or false and a reason when the probe could not prove one.
---    Cancelling a probe closes its input so the echo child exits.
--- ==============================================================================

local M = {}

local ShellRunner = require("adapters.shell_runner")
local Logger      = require("infra.logger")

local LOG = "task_output_turn"

-- A stock binary that echoes its input and stays alive until its input closes,
-- so its exit can never race the echo it is asked for.
M.ECHO_EXECUTABLE = "/bin/cat"
local PROBE_LINE = "turn\n"





-- ====================================
-- ====================================
-- ======= 1/ Output Turn Probe =======
-- ====================================
-- ====================================

--- Starts one probe whose echo proves a delivered task output turn.
--- @param label string Caller label used in diagnostics.
--- @param on_turn function fn(delivered, reason) called once.
--- @return table|nil probe Handle with cancel(), or nil when nothing started.
--- @return string|nil err Why no probe started.
function M.request(label, on_turn)
	if type(on_turn) ~= "function" then
		Logger.error(LOG, "request(): the turn callback for %s is not a function.", tostring(label))
		return nil, "turn callback missing"
	end
	local settled = false
	local handle

	--- Delivers the single outcome, logging a raising callback instead of losing it.
	--- @param delivered boolean True when the echo arrived.
	--- @param reason string|nil Why no echo can arrive.
	local function settle(delivered, reason)
		if settled then return end
		settled = true
		local ok, err = xpcall(on_turn, debug.traceback, delivered, reason)
		if not ok then
			Logger.error(LOG, "The output turn callback for %s raised: %s", tostring(label), tostring(err))
		end
	end

	handle = ShellRunner.spawn(M.ECHO_EXECUTABLE, {}, function(exit_code)
		settle(false, "the output probe exited (exit " .. tostring(exit_code) .. ") before its echo")
	end, function(_task, stdout_chunk)
		if settled then return true end
		if type(stdout_chunk) == "string" and stdout_chunk:find("\n", 1, true) then
			settle(true, nil)
			if handle then pcall(handle.close_input) end
		end
		return true
	end)
	if type(handle) ~= "table" or handle.isSettled() then
		settled = true
		return nil, "the output probe could not be constructed"
	end
	if handle.start() ~= true then
		settled = true
		return nil, "the output probe could not start"
	end
	if handle.set_input(PROBE_LINE) ~= true then
		settled = true
		pcall(handle.terminate)
		return nil, "the output probe refused its input"
	end

	local probe = {}

	--- Abandons the probe: its outcome is never delivered and its child exits.
	function probe.cancel()
		if settled then return end
		settled = true
		local ok, closed = pcall(handle.close_input)
		if not ok or closed ~= true then pcall(handle.terminate) end
	end

	return probe, nil
end

return M
