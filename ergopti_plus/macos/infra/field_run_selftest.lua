--- infra/field_run_selftest.lua

--- ==============================================================================
--- MODULE: Field Run Selftest Window
--- DESCRIPTION:
--- The one scratch window the developer field run types its selftest keys
--- into. The typing step publishes the window while it types and retracts it
--- when it ends; the keymap's selftest gate (modules/keymap/selftest_gate.lua)
--- reads it for every selftest key.
---
--- FEATURES & RATIONALE:
--- 1. One owner at a time: a second publication raises instead of replacing
---    the first, and a retraction must name the publication it ends, so a
---    late callback of an earlier run cannot close a later run's window.
--- 2. A generation per publication lets the gate log a refusal once per run.
--- 3. No platform call: the window id is read by the step that opened it.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local LOG = "infra.field_run_selftest"

local _window_id = nil
local _generation = 0

--- Publishes the scratch window the selftest keys may be decoded as typing in.
--- @param window_id integer The window's id, as hs.window:id() reads it.
--- @return integer generation The token the matching retract takes.
function M.publish(window_id)
	if math.type(window_id) ~= "integer" or window_id <= 0 then
		error("field_run_selftest.publish: window_id must be a positive integer", 2)
	end
	if _window_id ~= nil then
		error("field_run_selftest.publish: a selftest window is already published", 2)
	end
	_generation = _generation + 1
	_window_id = window_id
	Logger.start(LOG, "Selftest window %d published for run %d.", window_id, _generation)
	return _generation
end

--- Retracts the scratch window of one publication.
--- @param generation integer The token publish returned.
function M.retract(generation)
	if _window_id == nil or generation ~= _generation then
		error("field_run_selftest.retract: not the published selftest window", 2)
	end
	_window_id = nil
	Logger.success(LOG, "Selftest window of run %d retracted.", generation)
end

--- The published scratch window's id, nil when no typing step runs.
--- @return integer|nil window_id
function M.window_id()
	return _window_id
end

--- The number of publications so far, the current one included.
--- @return integer generation
function M.generation()
	return _generation
end

return M
