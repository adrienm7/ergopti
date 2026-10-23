--- infra/native_sleep.lua

--- ==============================================================================
--- MODULE: Native Interruptible Sleep (Linux)
--- DESCRIPTION:
--- Binds nanosleep(2) through LuaJIT FFI for every blocking wait the daemon
--- performs outside libuv: the event-loop pump and the injector's pacing.
---
--- FEATURES & RATIONALE:
--- 1. A libuv child's SIGCHLD interrupts nanosleep even with SA_RESTART. The
---    wait resumes its remaining duration, so a child exit can neither shorten
---    it (the injector used to drop the remainder and type too early) nor
---    extend it (restarting the full request would).
--- 2. Any other errno is a refusal the caller must see: the bound function
---    raises rather than reporting a wait that did not happen.
--- 3. The caller passes its own FFI module, so tests and runtimes without FFI
---    choose their fallback explicitly.
--- 4. A wait beyond the shared timer ceiling is refused before the conversion
---    to the native long: under LuaJIT that conversion is undefined.
--- ==============================================================================

local M = {}

local NumberPolicy = require("number_policy")

local EINTR = 4 -- Linux errno for a signal-interrupted wait.

--- Binds an EINTR-resuming nanosleep.
--- @param ffi table|nil LuaJIT FFI module, or nil when the runtime has none.
--- @return function|nil sleep(seconds) Raises on a refused duration or a non-EINTR native refusal; nil when unbindable.
function M.bind(ffi)
	if type(ffi) ~= "table" then return nil end
	local ok_cdef, cdef_err = pcall(ffi.cdef, [[
		struct timespec { long tv_sec; long tv_nsec; };
		int nanosleep(const struct timespec *req, struct timespec *rem);
	]])
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then return nil end
	local req = ffi.new("struct timespec[1]")
	local remaining = ffi.new("struct timespec[1]")
	return function(seconds)
		if NumberPolicy.timer_delay_ms(seconds) == nil then
			error("nanosleep refused: " .. tostring(seconds) .. " s is not finite or exceeds the timer ceiling", 0)
		end
		req[0].tv_sec = math.floor(seconds)
		req[0].tv_nsec = math.floor((seconds % 1) * 1e9)
		while ffi.C.nanosleep(req, remaining) ~= 0 do
			local code = ffi.errno()
			if code ~= EINTR then error("nanosleep failed (errno " .. tostring(code) .. ")", 0) end
			req[0].tv_sec = remaining[0].tv_sec
			req[0].tv_nsec = remaining[0].tv_nsec
		end
	end
end

return M
