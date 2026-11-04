--- ui/virtual_hid_update.lua

--- ==============================================================================
--- MODULE: VirtualHIDDevice Driver Update Offer
--- DESCRIPTION:
--- Asks the user to replace an incompatible Karabiner virtual keyboard driver
--- with the version Ergopti's own runtime needs (ADR 011, "driver-only update
--- offer"), then says what happened and reloads after a success.
---
--- FEATURES & RATIONALE:
--- 1. Explicit Confirmation: macOS keeps one driver version active for every
---    Karabiner on the Mac, so the dialog says that the user's own
---    Karabiner-Elements changes driver too, and nothing runs before the click.
--- 2. The Remap Bridge Acts: the download, the checks and the privileged
---    install belong to platform/remap/runtime_vhid_update.lua through the
---    facade; this module only asks, reports and reloads.
--- 3. Deferred Report: the outcome arrives from a task callback, where no modal
---    dialog may run, so the report goes through the timer scheduler.
--- 4. A Cancelled Prompt Is Not An Error: closing the administrator prompt
---    changes nothing and shows nothing.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local i18n   = require("infra.i18n")

local LOG = "virtual_hid_update"

-- The reasons of platform/remap/runtime_vhid_update.lua this module acts on.
local REASON = require("platform.remap.runtime_vhid_update").REASON




-- =====================================
-- ======= 1/ Internal helpers =========
-- =====================================

--- Checks the remap facade before any side effect.
--- @param remap table Remap facade.
local function validate(remap)
	if type(remap) ~= "table" or type(remap.update_virtual_hid_driver) ~= "function"
		or type(remap.owned_virtual_hid_version) ~= "function" then
		error("virtual_hid_update: remap must provide update_virtual_hid_driver and owned_virtual_hid_version", 3)
	end
end

--- Shows the outcome on the timer scheduler, then reloads after a success.
--- @param ok boolean True when the driver was installed and activation requested.
--- @param reason string|nil Stable refusal reason.
--- @param reload function fn() reloading the driver.
--- @return boolean scheduled
local function report(ok, reason, reload)
	if not ok and reason == REASON.CANCELLED then return false end
	local message = ok and i18n.get("karabiner.vhid_update.done")
		or i18n.format("karabiner.vhid_update.failed", tostring(reason))
	local committed = require("infra.deferred_work").after(0, function()
		local shown, err = pcall(function()
			require("infra.dialog_util").block_alert(i18n.get("karabiner.vhid_update.title"), message,
				i18n.get("common.ok"))
		end)
		if not shown then Logger.error(LOG, "The driver update result could not be shown: %s.", tostring(err)) end
		if ok then reload() end
	end, "virtual_hid_update.report")
	if committed ~= true then
		Logger.error(LOG, "The driver update result could not be shown to the user.")
		if ok then reload() end
	end
	return committed == true
end




-- ==============================
-- ======= 2/ Public API ========
-- ==============================

--- Asks, then updates the driver on confirmation (Tap-Holds menu row).
--- @param remap table Remap facade { update_virtual_hid_driver(on_done), owned_virtual_hid_version() }.
--- @param reload function|nil fn() reloading the driver; defaults to hs.reload.
--- @return boolean started True when the update started.
function M.open(remap, reload)
	validate(remap)
	reload = reload or function() hs.reload() end
	local version = remap.owned_virtual_hid_version()
	if type(version) ~= "string" then
		Logger.error(LOG, "No pinned driver version to offer; the update stays unavailable.")
		return false
	end
	local confirm = i18n.get("karabiner.vhid_update.confirm")
	local clicked = require("infra.dialog_util").block_alert(i18n.get("karabiner.vhid_update.title"),
		i18n.format("karabiner.vhid_update.body", version), confirm, i18n.get("common.later"), "warning")
	if clicked ~= confirm then
		Logger.info(LOG, "VirtualHIDDevice driver update to %s postponed.", version)
		return false
	end
	Logger.info(LOG, "VirtualHIDDevice driver update to %s confirmed by the user.", version)
	local started = remap.update_virtual_hid_driver(function(ok, reason)
		report(ok == true, reason, reload)
	end)
	if started ~= true then
		report(false, REASON.NOT_OFFERED, reload)
		return false
	end
	return true
end

return M
