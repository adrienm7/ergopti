--- ui/legacy_rules_cleanup.lua

--- ==============================================================================
--- MODULE: Legacy Karabiner Rules Cleanup
--- DESCRIPTION:
--- Asks the user to remove the rules an older ErgoptiPlus left in Karabiner
--- when they keep every setting from being applied, then says what happened.
---
--- FEATURES & RATIONALE:
--- 1. A button, never a command: the merge refuses untagged rules carrying a
---    historical ErgoptiPlus signature that no released block proves, and
---    nothing in the app removed them, so every deploy failed with only a log
---    line. The dialog names the rules and removes them on one click.
--- 2. Offered, not imposed: the remap bridge offers it once per launch for one
---    set of rules, from its timer after the refused regeneration settled; the
---    Tap-Holds menu row shows it again while the rules are pending. « Later »
---    changes nothing.
--- 3. The remap bridge owns the removal (a verified backup of karabiner.json,
---    then a publication over the exact bytes it classified) and the
---    regeneration after it. This module only asks and reports.
--- 4. The report is deferred to the timer scheduler: the regeneration's outcome
---    arrives from a lease callback, where no modal dialog may run.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local i18n   = require("infra.i18n")

local LOG = "legacy_rules_cleanup"

-- Rules named in the dialog; the others are counted on one more line.
local MAX_LISTED_RULES = 8




-- =====================================
-- ======= 1/ Internal helpers =========
-- =====================================

--- Checks the remap facade before any side effect.
--- @param remap table Remap facade.
local function validate(remap)
	if type(remap) ~= "table" or type(remap.legacy_rule_conflicts) ~= "function"
		or type(remap.remove_legacy_rules) ~= "function" then
		error("legacy_rules_cleanup: remap must provide legacy_rule_conflicts and remove_legacy_rules", 3)
	end
end

--- Lists the rule descriptions, one per line, the overflow counted.
--- @param descriptions table Dense description array.
--- @return string list
local function listed_rules(descriptions)
	local lines = {}
	for index = 1, math.min(#descriptions, MAX_LISTED_RULES) do
		lines[#lines + 1] = "• " .. tostring(descriptions[index])
	end
	if #descriptions > MAX_LISTED_RULES then
		lines[#lines + 1] = i18n.format("karabiner.legacy_cleanup.more", #descriptions - MAX_LISTED_RULES)
	end
	return table.concat(lines, "\n")
end

--- Shows one result on the timer scheduler, outside the caller's stack.
--- @param message string Localized result.
--- @return boolean scheduled
local function show_report(message)
	local committed = require("infra.deferred_work").after(0, function()
		require("infra.dialog_util").block_alert(i18n.get("karabiner.legacy_cleanup.title"), message,
			i18n.get("common.ok"))
	end, "legacy_rules_cleanup.report")
	if committed ~= true then
		Logger.error(LOG, "The legacy-rule cleanup result could not be shown to the user.")
	end
	return committed == true
end

--- Reports the removal and the regeneration that followed it.
--- @param ok boolean True when the settings were applied.
--- @param result table|nil { stage, reason, removed_count, backup_path }.
--- @return boolean scheduled
local function report(ok, result)
	result = type(result) == "table" and result or {}
	if result.stage ~= "regeneration" then
		Logger.error(LOG, "The legacy Karabiner rules were not removed: %s.", tostring(result.reason))
		return show_report(i18n.format("karabiner.legacy_cleanup.removal_failed", tostring(result.reason)))
	end
	local removed_count = result.removed_count or 0
	local parts = {}
	if removed_count > 0 then
		parts[#parts + 1] = i18n.format("karabiner.legacy_cleanup.removed", removed_count,
			tostring(result.backup_path))
	end
	if ok == true then
		Logger.success(LOG, "Legacy Karabiner rules removed (%d); the settings are applied.", removed_count)
		parts[#parts + 1] = i18n.get("karabiner.legacy_cleanup.applied")
	else
		Logger.error(LOG, "Legacy Karabiner rules removed (%d), but the regeneration failed: %s.",
			removed_count, tostring(result.reason))
		parts[#parts + 1] = i18n.format("karabiner.legacy_cleanup.apply_failed", tostring(result.reason))
	end
	return show_report(table.concat(parts, "\n\n"))
end

--- Asks, then removes the pending legacy rules on confirmation.
--- @param remap table Remap facade.
--- @param trigger string Why the dialog is shown, for the log.
--- @return boolean shown True when the dialog reached the user.
local function present(remap, trigger)
	validate(remap)
	local read_ok, conflicts = pcall(remap.legacy_rule_conflicts, true)
	if not read_ok then
		Logger.error(LOG, "The pending legacy Karabiner rules could not be read: %s.", tostring(conflicts))
		return false
	end
	if type(conflicts) ~= "table" or type(conflicts.count) ~= "number" or conflicts.count < 1 then
		Logger.info(LOG, "No legacy Karabiner rule to remove (%s).", trigger)
		return false
	end

	local count = conflicts.count
	local list = listed_rules(conflicts.descriptions or {})
	local body = count == 1 and i18n.format("karabiner.legacy_cleanup.body_one", list)
		or i18n.format("karabiner.legacy_cleanup.body_other", count, list)
	local remove_label = i18n.get("karabiner.legacy_cleanup.remove")
	local clicked = require("infra.dialog_util").block_alert(i18n.get("karabiner.legacy_cleanup.title"), body,
		remove_label, i18n.get("common.later"), "warning")
	if clicked ~= remove_label then
		Logger.info(LOG, "Removal of %d legacy Karabiner rule(s) postponed (%s).", count, trigger)
		return true
	end

	Logger.start(LOG, "Removing %d legacy Karabiner rule(s) on the user's request (%s)…", count, trigger)
	local call_ok, err = xpcall(function()
		return remap.remove_legacy_rules(report, conflicts.confirmation)
	end, debug.traceback)
	if not call_ok then
		Logger.error(LOG, "The legacy-rule removal raised: %s.", tostring(err))
		show_report(i18n.format("karabiner.legacy_cleanup.removal_failed", "removal-raised"))
	end
	return true
end




-- ==============================
-- ======= 2/ Public API ========
-- ==============================

--- Offers the removal: the remap bridge's presenter, which calls it once per
--- launch for one set of rules, after the refused regeneration settled.
--- @param remap table Remap facade { legacy_rule_conflicts(), remove_legacy_rules(on_done) }.
--- @return boolean shown True when the dialog reached the user.
function M.offer(remap)
	return present(remap, "automatic")
end

--- Shows the dialog again on the user's request (Tap-Holds menu row).
--- @param remap table Remap facade { legacy_rule_conflicts(), remove_legacy_rules(on_done) }.
--- @return boolean shown True when the dialog reached the user.
function M.open(remap)
	return present(remap, "requested")
end

return M
