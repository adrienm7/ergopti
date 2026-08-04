--- adapters/event_tap_guard.lua

--- ==============================================================================
--- MODULE: Event Tap Guard
--- DESCRIPTION:
--- Single place where the driver reacts to macOS switching one of its event taps
--- off. Every `hs.eventtap` callback routes its first line through
--- `M.handle_disabled()`; the tap owner keeps owning its tap and its logic, and
--- gains the one behaviour none of them had.
---
--- FEATURES & RATIONALE:
--- 1. Deals with the failure macOS reports through the callback itself. When a
---    tap's callback overruns the system deadline, or the user toggles the
---    accessibility permission, CoreGraphics disables the tap and delivers a
---    `tapDisabledByTimeout` / `tapDisabledByUserInput` event to that same
---    callback. Nothing raises, nothing is logged and `:isEnabled()` is never
---    read again — so the tap is disabled for the rest of the session. On the
---    typing tap that is the entire driver going silent mid-sentence.
--- 2. Keeps the event-type constants out of `modules/` and `infra/`. Those two
---    trees are measured by the `hs.` purity ratchet, so the comparison lives
---    here in the OS-isolation layer and call sites stay free of `hs.` tokens.
--- 3. Logs at WARNING, not DEBUG. A disabled tap is the symptom of a callback
---    that blew the deadline; it must be visible in a log the user sends us, or
---    the latency bug behind it stays invisible forever.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.event_tap_guard"

-- Resolved lazily: `hs.eventtap.event.types` does not exist under the unit-test
-- stubs, and this module is required by files those tests load.
local _types = nil

--- Returns the CoreGraphics event-type table, or nil when unavailable.
--- @return table|nil
local function event_types()
	if _types then return _types end
	local ok, t = pcall(function() return hs.eventtap.event.types end)
	if ok and type(t) == "table" then _types = t end
	return _types
end




-- =========================================
-- =========================================
-- ======= 1/ Disabled-tap Recovery ========
-- =========================================
-- =========================================

-- How many times each cause has fired since boot, and on which taps.
--
-- The log line alone is recoverable but not OBSERVABLE: it takes a user willing
-- to send their log and someone willing to grep it. A count the driver holds is
-- something the same user reads in their own health report — and a timeout count
-- is the driver's only self-reported performance metric, because a callback that
-- overran the CoreGraphics deadline is the one latency event macOS tells us
-- about directly.
--
-- Declared HERE, above the closure that writes to it. A `local` sitting
-- textually below its caller is not captured — the caller binds the nil global
-- instead, and the resulting error inside an eventtap callback goes to the
-- Hammerspoon Console and never to the driver log
-- (project-lua-closure-before-local-nil-global).
local _counts = { by_timeout = 0, by_user = 0, taps = {} }

--- Records one disable, by cause and by tap.
--- @param label string Owner identifier.
--- @param by_timeout boolean True when the cause was a callback overrun.
local function record(label, by_timeout)
	if by_timeout then
		_counts.by_timeout = _counts.by_timeout + 1
	else
		_counts.by_user = _counts.by_user + 1
	end
	local key = tostring(label)
	_counts.taps[key] = (_counts.taps[key] or 0) + 1
end

--- Re-engages a tap that macOS has switched off, and reports it.
---
--- Call this as the FIRST statement of every `hs.eventtap` callback:
---
--- ```lua
--- if EventTapGuard.handle_disabled(event, my_tap, "keymap.main") then return false end
--- ```
---
--- Returning `false` after a handled disable is deliberate: the disable
--- notification is not a real event, so it must be passed through untouched
--- rather than swallowed as if the tap had consumed a keystroke.
---
--- @param event userdata The event handed to the tap callback.
--- @param tap userdata|nil The tap to restart. When nil, the condition is still
---        reported — a tap owner that cannot name its own handle would otherwise
---        lose the diagnostic too.
--- @param label string Owner identifier used in the log line.
--- @return boolean handled True when the event was a disable notification.
function M.handle_disabled(event, tap, label)
	local types = event_types()
	if not types then return false end

	local ok_type, t = pcall(function() return event:getType() end)
	-- A nil type must never match. Both sides of the comparison can legitimately
	-- be nil — an event object that does not answer getType, and a Hammerspoon
	-- build that does not publish these constants — and `nil == nil` is true, so
	-- an unguarded comparison declares EVERY event a disable notification and
	-- swallows the whole tap. That is a worse outage than the one being fixed.
	if not ok_type or t == nil then return false end

	local by_timeout = (types.tapDisabledByTimeout ~= nil and t == types.tapDisabledByTimeout)
	local by_user    = (types.tapDisabledByUserInput ~= nil and t == types.tapDisabledByUserInput)
	if not by_timeout and not by_user then return false end

	-- The two causes need different follow-up from whoever reads the log, so
	-- they are never collapsed into one message: a timeout means our own
	-- callback was too slow and the latency is ours to fix, while a user-input
	-- disable means the accessibility permission was toggled underneath us.
	record(label, by_timeout)

	Logger.warn(LOG, "Tap '%s' was DISABLED by macOS (%s) — re-engaging.",
		tostring(label), by_timeout and "callback overran the deadline" or "user input")

	if tap then
		local ok_start = pcall(function() tap:start() end)
		if ok_start then
			Logger.info(LOG, "Tap '%s' re-engaged.", tostring(label))
		else
			Logger.error(LOG, "Tap '%s' could not be re-engaged — it stays deaf until reload.",
				tostring(label))
		end
	else
		Logger.error(LOG, "Tap '%s' was disabled but its owner passed no handle — cannot re-engage.",
			tostring(label))
	end

	return true
end





-- =========================================
-- =========================================
-- ======= 2/ Overrun Accounting ===========
-- =========================================
-- =========================================

--- The disable tally since boot, copied so a caller cannot mutate it.
---
--- `by_timeout` is the number to read first: each one is a callback that blew
--- the deadline on this machine, under this load. A non-zero count on a user's
--- report turns "it feels sluggish sometimes" into a measurement.
--- @return table { by_timeout, by_user, taps = { [label] = count } }
function M.disable_counts()
	local taps = {}
	for label, n in pairs(_counts.taps) do taps[label] = n end
	return { by_timeout = _counts.by_timeout, by_user = _counts.by_user, taps = taps }
end

--- Clears the tally. Test-only: the driver never resets it, because a count that
--- restarts mid-session would under-report exactly when it matters.
function M.reset_disable_counts()
	_counts = { by_timeout = 0, by_user = 0, taps = {} }
end

return M
