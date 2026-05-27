--- ui/menu/menu_llm/warmup_controller.lua

--- ==============================================================================
--- MODULE: LLM Warmup Controller
--- DESCRIPTION:
--- Centralises all model pre-warming calls triggered on backend switches and
--- API entry changes. Wraps every warmup path with structured logging so a
--- silent warmup failure is immediately visible in the log stream.
---
--- FEATURES & RATIONALE:
--- 1. Single call site: callers invoke M.warmup(ctx) instead of scattering
---    pcall(llm_mod.warmup_model, …) throughout init.lua's switch handlers.
--- 2. Logged failures: every warmup attempt is bracketed with Logger.trace /
---    Logger.done so incomplete pairs reveal problems at a glance.
--- 3. Dependency-free: only requires modules.llm and lib.logger — no circular
---    dependency risk when loaded from inside init.lua's factory.
--- ==============================================================================

local M = {}

local llm_mod = require("modules.llm")
local Logger  = require("lib.logger")

local LOG = "menu_llm.warmup"




-- ==============================
-- ==============================
-- ======= 1/ Public API =======
-- ==============================
-- ==============================

--- Fires a model warmup for the currently active model.
--- Safe to call even when no model is configured: exits silently in that case.
--- @param label string Short call-site label used in log messages.
function M.warmup(label)
	local model = llm_mod.get_current_model and llm_mod.get_current_model()
	if type(model) ~= "string" or model == "" then
		Logger.debug(LOG, "warmup('%s'): no active model — skipping.", tostring(label))
		return
	end

	Logger.trace(LOG, "Warming up model '%s' (%s)…", model, tostring(label))
	local ok, err = pcall(llm_mod.warmup_model, model)
	if ok then
		Logger.done(LOG, "Warmup complete for '%s' (%s).", model, tostring(label))
	else
		Logger.error(LOG, "Warmup failed for '%s' (%s): %s", model, tostring(label), tostring(err))
	end
end

--- Fires a model warmup for an explicit model name.
--- Useful when the active model has not been committed to llm_mod yet.
--- @param model string The backend model name to warm up.
--- @param label string Short call-site label used in log messages.
function M.warmup_model(model, label)
	if type(model) ~= "string" or model == "" then
		Logger.debug(LOG, "warmup_model('%s'): empty model name — skipping.", tostring(label))
		return
	end

	Logger.trace(LOG, "Warming up model '%s' (%s)…", model, tostring(label))
	local ok, err = pcall(llm_mod.warmup_model, model)
	if ok then
		Logger.done(LOG, "Warmup complete for '%s' (%s).", model, tostring(label))
	else
		Logger.error(LOG, "Warmup failed for '%s' (%s): %s", model, tostring(label), tostring(err))
	end
end

return M
