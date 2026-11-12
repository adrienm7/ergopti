--- tests/support/session_language.lua

--- ==============================================================================
--- MODULE: Pinned Session Language (Linux tests)
--- DESCRIPTION:
--- A first run's interface language follows the session (LC_ALL, then
--- LC_MESSAGES, then LANG), as on Windows and macOS (infra/i18n.lua). The suite
--- was written against the French catalogue, so the runner pins the language
--- the test process reads to French, whatever the developer's or the CI
--- runner's session says. Only this Lua process sees the pin: children keep the
--- real environment, so the shell messages they print are unchanged. A test
--- that exercises detection passes its own environment reader.
--- ==============================================================================

local M = {}

local PINNED = { LANG = "fr_FR.UTF-8", LC_ALL = false, LC_MESSAGES = false }

local _wrapper = nil

--- Wraps os.getenv so the session language reads as French. Idempotent while
--- the wrapper is in place, as test.runner_home's isolation is: a test that
--- reloads tests/helpers in the same process installs it again.
function M.install()
	if _wrapper ~= nil and os.getenv == _wrapper then return end
	local previous = os.getenv
	_wrapper = function(name)
		local pinned = PINNED[name]
		if pinned == nil then return previous(name) end
		return pinned or nil
	end
	os.getenv = _wrapper
end

return M
