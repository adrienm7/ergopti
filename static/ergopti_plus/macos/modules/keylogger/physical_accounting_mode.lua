--- modules/keylogger/physical_accounting_mode.lua

--- ==============================================================================
--- MODULE: Physical Accounting Mode
--- DESCRIPTION:
--- Owns the one answer every physical-key writer asks: which source may credit
--- a physical key right now. Exactly one source may, so a single press can never
--- be counted twice (HS-274).
---
--- FEATURES & RATIONALE:
--- 1. Legacy by default: until a producer stream is selected, the keylogger's
---    Quartz event tap credits the keycode it observes and the Karabiner
---    shell_command ledger credits the physical key of each managed tap-hold
---    slot. That is today's behaviour, HS-274 double count included: a remapped
---    tap is credited once as its output and once as its physical key.
---    Suppressing the output keycode instead is not a fix. The shipped defaults
---    send CapsLock to Return and left Command to Backspace while the physical
---    Return and Backspace pass through without a ledger line, so a global
---    suppression loses real presses; see docs/memory/macos-hammerspoon.md
---    (project-hs-physical-accounting-needs-producer-ownership).
--- 2. Stream only while admitted: once the owner selects the stream and admits
---    a capture whose coverage is complete, only that capture credits. Quartz
---    and the ledger credit nothing, which removes the double count by
---    construction instead of by guessing which output belongs to which key.
--- 3. No silent fallback: a selected stream without an admitted capture (before
---    admission, after a loss) is a gap. Nothing credits during a gap, and the
---    owner records it; falling back to Quartz or the ledger would bring HS-274
---    back and hide the coverage loss. Only the owner's explicit release returns
---    to the legacy sources.
--- 4. Fixture coverage is refused: the experimental producer declares
---    `fixture_only`; production admits `COMPLETE_COVERAGE` alone.
--- 5. Single owner: the stream owner that selected the source is the only caller
---    that can admit, interrupt or release it; any other call is a bug and raises.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local LOG    = "keylogger.physical_accounting"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- The Quartz event tap and the Karabiner ledger credit physical keys.
M.SOURCE_LEGACY = "legacy"

--- Only the admitted producer capture credits physical keys.
M.SOURCE_STREAM = "stream"

--- The stream is selected but no capture is admitted: nothing credits.
M.SOURCE_GAP = "gap"

--- The only producer coverage value that can be admitted.
M.COMPLETE_COVERAGE = "complete"

-- The owner that selected the stream source, or nil while the legacy sources credit.
local _owner = nil

-- The admitted capture identity, or nil during a gap.
local _capture = nil

-- The production keylogger owns one process-lifetime settlement port.
local _settlement_owner, _settlement = nil, nil
local _transitioning, _generation = false, 0

--- Refuses reentry before validating or changing a source owner.
local function require_idle()
	if _transitioning then error("physical accounting: source transition is pending", 3) end
end

--- Requires exact settlement before any source-generation publication.
--- An unbound pure policy has no held native bookkeeping to settle.
--- @return boolean settled
local function settle()
	local generation, owner, capture = _generation, _owner, _capture
	_transitioning = true
	local called, accepted = true, true
	if _settlement then called, accepted = pcall(_settlement) end
	_transitioning = false
	if not called or accepted ~= true or _generation ~= generation
		or _owner ~= owner or _capture ~= capture then return false end
	_generation = generation + 1
	return true
end





-- =============================
-- =============================
-- ======= 2/ Validation =======
-- =============================
-- =============================

--- Raises unless the value is a non-empty string.
--- @param value any Candidate identity.
--- @param label string What the identity names, for the error message.
local function require_identity(value, label)
	if type(value) ~= "string" or value == "" then
		error("physical accounting: " .. label .. " must be a non-empty string", 3)
	end
end

--- Raises unless the caller is the owner that selected the stream.
--- @param owner string Caller identity.
--- @param operation string Operation name, for the error message.
local function require_owner(owner, operation)
	require_identity(owner, "owner")
	if _owner == nil then
		error("physical accounting: " .. operation .. " without a selected stream", 3)
	end
	if owner ~= _owner then
		error("physical accounting: " .. operation .. " by '" .. owner
			.. "' while '" .. _owner .. "' owns the stream", 3)
	end
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Binds the one actual keylogger bookkeeping owner before source selection.
--- The owner and port remain the same through normal feature stop/restart.
--- @param owner table Process-lifetime native bookkeeping identity.
--- @param callback function Plans and swaps its own held state, returning exact true.
--- @return boolean bound
function M.bind_settlement(owner, callback)
	require_idle()
	if type(owner) ~= "table" or type(callback) ~= "function"
		or _settlement_owner ~= nil or _owner ~= nil then return false end
	_settlement_owner, _settlement = owner, callback
	return true
end

--- Returns the source that may credit physical keys right now.
--- @return string source SOURCE_LEGACY, SOURCE_STREAM or SOURCE_GAP.
function M.credit_source()
	if _owner == nil then return M.SOURCE_LEGACY end
	if _capture == nil then return M.SOURCE_GAP end
	return M.SOURCE_STREAM
end

--- Reports whether the legacy sources (Quartz keyDown and flagsChanged, and the
--- Karabiner ledger) may credit a physical key right now.
--- @return boolean
function M.legacy_credits()
	return _owner == nil
end

--- Returns the admitted capture identity, or nil when none is admitted.
--- @return string|nil
function M.admitted_capture()
	return _capture
end

--- Selects the producer stream as the only physical source. From here on the
--- legacy sources credit nothing; the source is a gap until a capture is admitted.
--- @param owner string The stream owner's stable identity.
--- @return boolean selected Exact settlement is required; misuse raises.
function M.select_stream(owner)
	require_idle()
	require_identity(owner, "owner")
	if _owner ~= nil then
		error("physical accounting: the stream is already selected by '" .. _owner .. "'", 2)
	end
	if not settle() then return false, "settlement_refused" end
	_owner = owner
	Logger.info(LOG, "Physical accounting source: legacy → gap (stream selected by '%s').", owner)
	return true
end

--- Admits one capture as the only physical source.
--- A coverage other than COMPLETE_COVERAGE is refused and the source stays a gap.
--- @param owner string The owner that selected the stream.
--- @param capture string The capture identity its credits carry.
--- @param coverage string The coverage the producer declared.
--- @return boolean admitted
--- @return string|nil reason Why admission was refused.
function M.admit(owner, capture, coverage)
	require_idle()
	require_owner(owner, "admit")
	require_identity(capture, "capture")
	if _capture ~= nil then
		error("physical accounting: capture '" .. _capture .. "' is still admitted", 2)
	end
	if coverage ~= M.COMPLETE_COVERAGE then
		Logger.warn(LOG, "Physical capture '%s' refused: coverage '%s' is not complete — the source stays a gap.",
			capture, tostring(coverage))
		return false, "incomplete_coverage"
	end
	if not settle() then return false, "settlement_refused" end
	_capture = capture
	Logger.info(LOG, "Physical accounting source: gap → stream (capture '%s' admitted).", capture)
	return true
end

--- Ends the admitted capture without returning to the legacy sources: the
--- source becomes a gap that its owner records until a new capture is admitted.
--- @param owner string The owner that selected the stream.
--- @param capture string The capture being ended.
--- @return boolean interrupted Exact settlement is required; misuse raises.
function M.interrupt(owner, capture)
	require_idle()
	require_owner(owner, "interrupt")
	require_identity(capture, "capture")
	if capture ~= _capture then
		error("physical accounting: capture '" .. capture .. "' is not the admitted capture", 2)
	end
	if not settle() then return false, "settlement_refused" end
	_capture = nil
	Logger.warn(LOG, "Physical accounting source: stream → gap (capture '%s' ended).", capture)
	return true
end

--- Deselects the stream and returns the credits to the legacy sources.
--- This is an explicit owner decision (the owner stopped because Tap-Hold was
--- turned off, for example), never a reaction to a lost capture.
--- @param owner string The owner that selected the stream.
--- @return boolean released Exact settlement is required; misuse raises.
function M.release(owner)
	require_idle()
	require_owner(owner, "release")
	if not settle() then return false, "settlement_refused" end
	local previous = M.credit_source()
	_owner, _capture = nil, nil
	Logger.info(LOG, "Physical accounting source: %s → legacy (released by '%s').", previous, owner)
	return true
end

return M
