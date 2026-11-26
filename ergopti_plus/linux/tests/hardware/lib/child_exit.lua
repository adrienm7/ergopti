--- tests/hardware/lib/child_exit.lua

--- ==============================================================================
--- MODULE: Owned Child Exit Wait
--- DESCRIPTION:
--- Waits for a forked child of a hardware fixture to exit, bounded in
--- wall-clock time. A fixture that serves its child between two reaps cannot
--- bound the wait by a number of serve calls: once the child closes its
--- connection the socket reads at end of file at once, every call returns
--- without waiting, and a hundred calls spend well under a millisecond while
--- the child is still tearing down (dev run 45119239568, « the worker kept
--- running after the compositor finished »). The deadline here is read from
--- CLOCK_MONOTONIC, and a slice whose serve call did not wait sleeps instead.
--- ==============================================================================

local ffi = require("ffi")

-- Redirected names: a fixture that loads this module may declare poll or
-- waitpid itself, and LuaJIT refuses a second declaration of one name.
ffi.cdef([[
	struct ergopti_child_exit_timespec { long tv_sec; long tv_nsec; };
	int ergopti_child_exit_clock_gettime(int clock, struct ergopti_child_exit_timespec *now) __asm__("clock_gettime");
	int ergopti_child_exit_waitpid(int pid, int *status, int options) __asm__("waitpid");
	int ergopti_child_exit_poll(void *fds, unsigned long count, int timeout) __asm__("poll");
]])

local CLOCK_MONOTONIC = 1
local WNOHANG = 1
local SLICE_MS = 20

local M = {}

--- Milliseconds on the monotonic clock.
--- @return number
function M.now_ms()
	local now = ffi.new("struct ergopti_child_exit_timespec")
	assert(ffi.C.ergopti_child_exit_clock_gettime(CLOCK_MONOTONIC, now) == 0, "clock_gettime refused")
	return tonumber(now.tv_sec) * 1000 + tonumber(now.tv_nsec) / 1e6
end

--- Sleeps for `ms` milliseconds without a busy loop.
--- @param ms number
function M.sleep_ms(ms)
	ffi.C.ergopti_child_exit_poll(nil, 0, ms)
end

--- Waits until the owned child exits or `budget_ms` of wall-clock time pass.
--- @param child number The child's process id, from fork.
--- @param budget_ms number The wall-clock bound.
--- @param between function|nil Called once per slice with the slice length in
---   milliseconds (a fixture's serve loop); a false return means it did not
---   wait, so the slice sleeps instead.
--- @return boolean exited True once the child was reaped.
--- @return number status The raw waitpid status, 0 when not reaped.
function M.wait(child, budget_ms, between)
	assert(type(child) == "number" and child > 0, "child_exit.wait needs a child process id")
	assert(type(budget_ms) == "number" and budget_ms > 0, "child_exit.wait needs a positive budget")
	local status = ffi.new("int[1]")
	local deadline = M.now_ms() + budget_ms
	while true do
		local reaped = ffi.C.ergopti_child_exit_waitpid(child, status, WNOHANG)
		if reaped == child then return true, status[0] end
		assert(reaped == 0, "waitpid refused the owned child")
		if M.now_ms() >= deadline then return false, 0 end
		local waited = between and between(SLICE_MS)
		if not waited then M.sleep_ms(SLICE_MS) end
	end
end

return M
