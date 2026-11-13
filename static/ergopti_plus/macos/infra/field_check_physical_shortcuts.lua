--- infra/field_check_physical_shortcuts.lua

--- ==============================================================================
--- MODULE: Field Check, Physical Shortcut Delivery
--- DESCRIPTION:
--- The field run's read of the physical shortcuts (TODO, To confirm on the
--- Mac, « Physical shortcut delivery »): whether delivery is available, how
--- many physical slots are bound, and what the physical hook did this session
--- with each key it suppressed. Read before and after a guided press, the
--- rise of the suppressed and delivered counts proves the press reached its
--- action through the hook alone.
---
--- FEATURES & RATIONALE:
--- 1. Counts from the hook itself (adapters/physical_shortcut_hook.lua), never
---    from the log: a suppressed key is delivered, unacknowledged or dropped
---    by a later fence, exactly once.
--- 2. A suppressed key that is not delivered fails by name: unacknowledged
---    (the action refused) or dropped (a pause or source change cut it).
--- 3. No slot bound, or delivery unavailable, is a skip with its reason.
--- ==============================================================================

local Report = require("diagnostics.engine.field_check.report")

local M = {}

local PASS, FAIL, INFO, SKIP = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO, Report.STATE_SKIP

--- Runs the check.
--- ports.physical_shortcut_facts() → { available, bound, suppressed, delivered, unacknowledged, dropped }.
--- @param ports table
--- @param report table field_check_report report.
--- @param finish function
function M.physical_shortcuts(ports, report, finish)
	local facts = ports.physical_shortcut_facts()
	report.step("physical_delivery_available", facts.available and PASS or SKIP,
		facts.available and "yes" or "unavailable")
	report.step("physical_slots_bound", facts.bound > 0 and PASS or SKIP,
		facts.bound > 0 and facts.bound or "none_bound")
	report.step("physical_suppressed", INFO, facts.suppressed)
	report.step("physical_delivered", INFO, facts.delivered)
	if facts.suppressed == 0 then
		report.step("physical_delivery_balance", SKIP, "not_pressed")
	elseif facts.unacknowledged > 0 or facts.dropped > 0 then
		report.step("physical_delivery_balance", FAIL,
			"unacknowledged:" .. facts.unacknowledged .. "+dropped:" .. facts.dropped)
	elseif facts.delivered < facts.suppressed then
		-- An action still queued on its next turn; the next read settles it
		report.step("physical_delivery_balance", INFO, "pending:" .. (facts.suppressed - facts.delivered))
	else
		report.step("physical_delivery_balance", PASS, "delivered:" .. facts.delivered)
	end
	finish()
end

return M
