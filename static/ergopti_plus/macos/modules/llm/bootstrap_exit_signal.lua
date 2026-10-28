--- modules/llm/bootstrap_exit_signal.lua

--- ==============================================================================
--- MODULE: Bootstrap Exit Signal
--- DESCRIPTION:
--- Names the Darwin signal behind a bootstrap exit status. The native PTY
--- guardian reports a signalled leader as 128 + signal, and bash reports a
--- signalled child the same way, so 137 is SIGKILL whichever process died.
--- The 2026-10-27 22:32 field run logged "exit=137 — Erreur inconnue", which
--- named neither the signal nor the stage it stopped.
--- ==============================================================================

local M = {}

-- Darwin <sys/signal.h> numbering; it differs from Linux above 6 (7 is SIGEMT).
local DARWIN_SIGNALS = {
	[1] = "SIGHUP", [2] = "SIGINT", [3] = "SIGQUIT", [4] = "SIGILL", [5] = "SIGTRAP",
	[6] = "SIGABRT", [7] = "SIGEMT", [8] = "SIGFPE", [9] = "SIGKILL", [10] = "SIGBUS",
	[11] = "SIGSEGV", [12] = "SIGSYS", [13] = "SIGPIPE", [14] = "SIGALRM", [15] = "SIGTERM",
	[16] = "SIGURG", [17] = "SIGSTOP", [18] = "SIGTSTP", [19] = "SIGCONT", [20] = "SIGCHLD",
	[21] = "SIGTTIN", [22] = "SIGTTOU", [23] = "SIGIO", [24] = "SIGXCPU", [25] = "SIGXFSZ",
	[26] = "SIGVTALRM", [27] = "SIGPROF", [28] = "SIGWINCH", [29] = "SIGINFO", [30] = "SIGUSR1",
	[31] = "SIGUSR2",
}

-- Shell convention for a process ended by signal N.
local SIGNAL_STATUS_BASE = 128

--- Returns the signal name for an exit status of 128 + N, or nil.
--- @param exit_code any Exit status reported to the task callback.
--- @return string|nil name Such as "SIGKILL"; nil for an ordinary exit.
function M.name(exit_code)
	if type(exit_code) ~= "number" or exit_code % 1 ~= 0 then return nil end
	return DARWIN_SIGNALS[exit_code - SIGNAL_STATUS_BASE]
end

return M
