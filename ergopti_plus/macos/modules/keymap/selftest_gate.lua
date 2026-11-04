--- modules/keymap/selftest_gate.lua

--- ==============================================================================
--- MODULE: Keymap Selftest Gate
--- DESCRIPTION:
--- Decides, for each field-run selftest key reaching a keymap tap, whether the
--- keymap decodes it as typing or consumes it. The keys come only from
--- SyntheticInput.emit_selftest_key_stroke, which the field run's scratch
--- typing calls; every other tap keeps them as the driver's own output.
---
--- FEATURES & RATIONALE:
--- 1. Three conditions, read for every key: the process is a developer runtime
---    (infra/dev_source.lua), the field run published its scratch window
---    (infra/field_run_selftest.lua), and that window is the focused one.
--- 2. Fail closed: any other answer, a duplicate Quartz delivery or a read that
---    raised consumes the key, so it never reaches an application.
--- 3. One diagnostic per run: the first refusal of a publication is logged,
---    deferred off the eventtap; the following ones are not.
--- 4. Cheap on the tap: the frontmost check is read from NSWorkspace, and the
---    focused window is asked only of this process (adapters/own_window.lua).
--- ==============================================================================

local M = {}

local Logger           = require("infra.logger")
local SyntheticInput   = require("adapters.synthetic_input")
local FieldRunSelftest = require("infra.field_run_selftest")
local LOG = "keymap.selftest_gate"

-- Test seam: the two system reads; nil in production, which reads them below.
M._ports = nil

-- The publication generation whose first refusal was already logged.
local _logged_generation = nil

--- The system reads, resolved at call time so the keymap loads none of them.
--- @return table ports { dev_source_active(), focused_own_window_id() }
local function ports()
	if M._ports then return M._ports end
	return {
		dev_source_active = function() return require("infra.dev_source").is_active() end,
		focused_own_window_id = function() return require("adapters.own_window").focused_window_id() end,
	}
end

--- Logs the first refusal of the current publication, off the eventtap.
--- @param reason string Closed refusal token.
local function report_refusal(reason)
	local generation = FieldRunSelftest.generation()
	if _logged_generation == generation then return end
	_logged_generation = generation
	pcall(SyntheticInput.defer_after_callback, "keymap selftest refusal", function()
		Logger.warn(LOG, "A field-run selftest key was consumed (%s); no application received it.", reason)
	end)
end

--- Decides one selftest key. The caller consumes the key unless this admits it.
--- @param provenance table Owned metadata whose selftest field is true.
--- @return boolean admitted True when the key may be decoded as typing.
--- @return string|nil reason Closed refusal token when it is not:
---         duplicate, no_dev_source, no_active_step, other_window or gate_error.
function M.admits(provenance)
	local ok, admitted, reason = pcall(function()
		if provenance.duplicate == true then return false, "duplicate" end
		local reads = ports()
		if reads.dev_source_active() ~= true then return false, "no_dev_source" end
		local window_id = FieldRunSelftest.window_id()
		if window_id == nil then return false, "no_active_step" end
		if reads.focused_own_window_id() ~= window_id then return false, "other_window" end
		return true, nil
	end)
	if not ok then admitted, reason = false, "gate_error" end
	if admitted ~= true then
		report_refusal(reason)
		return false, reason
	end
	return true, nil
end

return M
