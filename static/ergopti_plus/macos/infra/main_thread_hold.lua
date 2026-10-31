--- infra/main_thread_hold.lua

--- ==============================================================================
--- MODULE: Main-Thread Hold Thresholds
--- DESCRIPTION:
--- How long main-thread work may hold the Hammerspoon run loop before it
--- delays typed keys, declared once for the logger (which counts and names the
--- timer callbacks that held it) and the field run (which judges other
--- main-thread work, such as the karabiner.json write, by the same bound).
---
--- FEATURES & RATIONALE:
--- 1. No dependency: a test that stubs the logger still reads the real bounds.
--- 2. 250 ms is where key events start arriving late at the event taps; macOS
---    disables an event tap that waits about a second.
--- ==============================================================================

return setmetatable({}, {
	__index = {
		-- A hold from this long on delays typed keys at the taps.
		COUNT_MS = 250,
		-- A hold from this long on is named in the log: the taps are close to
		-- being disabled.
		REPORT_MS = 1000,
	},
	__newindex = function() error("main_thread_hold is read-only", 2) end,
})
