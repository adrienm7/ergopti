--- ui/owned_runtime_install.lua

--- ==============================================================================
--- MODULE: Owned Runtime Install Offer
--- DESCRIPTION:
--- Asks the user to install Ergopti's own Karabiner runtime (ADR 011, WP8),
--- then says what happened and reloads after a success, so the next start
--- admits the runtime or names the driver approval macOS still waits for.
---
--- FEATURES & RATIONALE:
--- 1. Explicit Confirmation: nothing runs before the click, and the dialog
---    says that macOS asks for an administrator password and may then ask to
---    allow the driver in System Settings.
--- 2. The Remap Bridge Acts: the launcher role, the helper and the driver
---    activation belong to platform/remap/runtime_install.lua through the
---    facade; this module only asks, reports and reloads.
--- 3. Deferred Report: the outcome arrives from a task callback, where no
---    modal dialog may run, so the report goes through the timer scheduler.
--- 4. A Cancelled Prompt Is Not An Error: closing the administrator prompt
---    changes nothing and shows nothing.
--- 5. Service Repair: « Réparer le service » (MRT-004) asks and reports the
---    same way for an installed runtime whose service is not loaded, with its
---    own texts and the facade's repair_owned_runtime.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local i18n   = require("infra.i18n")

local LOG = "owned_runtime_install"

-- The reasons of platform/remap/runtime_install.lua this module acts on.
local REASON = require("platform.remap.runtime_install").REASON




-- =====================================
-- ======= 1/ Internal helpers =========
-- =====================================

-- The two offers: their facade operation, their texts and their log wording.
local OFFERS = {
	install = { operation = "install_owned_runtime", texts = "karabiner.owned_install", name = "install" },
	repair = { operation = "repair_owned_runtime", texts = "karabiner.owned_repair", name = "service repair" },
}

--- Checks the remap facade before any side effect.
--- @param remap table Remap facade.
--- @param offer table OFFERS entry.
local function validate(remap, offer)
	if type(remap) ~= "table" or type(remap[offer.operation]) ~= "function" then
		error("owned_runtime_install: remap must provide " .. offer.operation, 3)
	end
end

--- Shows the outcome on the timer scheduler, then reloads after a success.
--- @param offer table OFFERS entry.
--- @param ok boolean True when the operation finished.
--- @param reason string|nil Stable refusal reason.
--- @param detail string|nil What the refusal names.
--- @param reload function fn() reloading the driver.
--- @return boolean scheduled
local function report(offer, ok, reason, detail, reload)
	if not ok and reason == REASON.CANCELLED then return false end
	local message = ok and i18n.get(offer.texts .. ".done")
		or i18n.format(offer.texts .. ".failed", tostring(detail or reason))
	local committed = require("infra.deferred_work").after(0, function()
		require("infra.dialog_util").block_alert(i18n.get(offer.texts .. ".title"), message,
			i18n.get("common.ok"))
		if ok then reload() end
	end, "owned_runtime_install.report")
	if committed ~= true then
		Logger.error(LOG, "The owned runtime %s result could not be shown to the user.", offer.name)
		if ok then reload() end
	end
	return committed == true
end

--- Asks, then runs the offer on confirmation.
--- @param offer table OFFERS entry.
--- @param remap table Remap facade.
--- @param reload function|nil fn() reloading the driver; defaults to hs.reload.
--- @return boolean started
local function open_offer(offer, remap, reload)
	validate(remap, offer)
	reload = reload or function() hs.reload() end
	local confirm = i18n.get(offer.texts .. ".confirm")
	local clicked = require("infra.dialog_util").block_alert(i18n.get(offer.texts .. ".title"),
		i18n.get(offer.texts .. ".body"), confirm, i18n.get("common.later"), "informational")
	if clicked ~= confirm then
		Logger.info(LOG, "Owned runtime %s postponed.", offer.name)
		return false
	end
	Logger.info(LOG, "Owned runtime %s confirmed by the user.", offer.name)
	local started = remap[offer.operation](function(ok, reason, detail)
		report(offer, ok == true, reason, detail, reload)
	end)
	if started ~= true then
		report(offer, false, REASON.NOT_OFFERED, nil, reload)
		return false
	end
	return true
end




-- ==============================
-- ======= 2/ Public API ========
-- ==============================

--- Asks, then installs the owned runtime on confirmation (Tap-Holds menu row).
--- @param remap table Remap facade { install_owned_runtime(on_done) }.
--- @param reload function|nil fn() reloading the driver; defaults to hs.reload.
--- @return boolean started True when the install started.
function M.open(remap, reload)
	return open_offer(OFFERS.install, remap, reload)
end

--- Asks, then repairs the installed runtime's service on confirmation
--- (« Réparer le service », Tap-Holds menu row).
--- @param remap table Remap facade { repair_owned_runtime(on_done) }.
--- @param reload function|nil fn() reloading the driver; defaults to hs.reload.
--- @return boolean started True when the repair started.
function M.open_repair(remap, reload)
	return open_offer(OFFERS.repair, remap, reload)
end

return M
