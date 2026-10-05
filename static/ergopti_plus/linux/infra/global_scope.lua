--- infra/global_scope.lua

--- ==============================================================================
--- MODULE: Global Scope (Linux)
--- DESCRIPTION:
--- Restores Ergopti's recommended values, or clears every category to the
--- system's own behaviour, by composing the daemon's per-scope owners through
--- the shared composition. The manifest's `[scopes.global]` orders them; each
--- keeps its own backup, conflict detection and runtime acknowledgement, and a
--- refusal reverts every category already committed.
---
--- FEATURES & RATIONALE:
--- 1. Live Owners Only: the registry names the owners this daemon actually
---    runs (a missing touchpad, AI engine or pending owner is skipped and
---    reported), so the restore never fails on a feature the machine lacks.
--- 2. One Retained Composition: a refused rollback stays owned here and is
---    retried before the next request, never silently dropped.
--- 3. Consent: AI and metrics consent stay out of « recommended » through the
---    manifest's scope exclusions, which each owner applies.
--- 4. Hotstrings: their scope owner takes part like every other one, across
---    config.toml and the override file, with the dynamic and preview runtimes
---    the daemon hands the menu.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Composition = require("config_scope_composition")
local Logger = require("logger.shim")
local LOG = "infra.global_scope"
local _composition, _registry = nil, {}

--- The composite owner, created once so its debt survives between requests.
--- @return table composition
local function composition()
	if _composition == nil then
		_composition = Composition.new({ manifest = Manifest, scope = "global", logger = Logger, log = LOG,
			participants = function() return _registry end })
	end
	return _composition
end

--- The participants of the owners a menu context runs, keyed by scope id.
--- A new scope owner registers here with the same one-line shape.
--- @param ctx table Menu context (live owners and the live pause getter).
--- @return table registry
function M.participants(ctx)
	assert(type(ctx) == "table", "the global scope needs the menu context")
	local function is_paused()
		return ctx.paused == true or (type(ctx.is_paused) == "function" and ctx.is_paused() == true)
	end
	local registry = {}
	if type(ctx.is_paused) == "function" then
		registry.global = require("infra.script_scope").participant(function()
			if ctx.paused == true then return true end
			return ctx.is_paused()
		end)
	end
	if ctx.tap_holds then registry.tap_holds = require("infra.tap_hold_scope").participant(is_paused) end
	if ctx.shortcuts then registry.shortcuts = require("infra.shortcuts_scope").participant(is_paused) end
	-- Without a touchpad the gestures are skipped and reported: their
	-- « recommended » reader could never start, which would refuse every row.
	if ctx.gestures and type(ctx.gestures.scope_participant) == "function"
		and ctx.gestures.scope_available() == true then
		registry.gestures = ctx.gestures.scope_participant()
	end
	if ctx.config then
		registry.hotstrings = require("infra.hotstrings_scope").participant(is_paused,
			{ dynamic = ctx.dyn_hotstrings, preview = ctx.tooltip_preview })
	end
	if ctx.llm then registry.llm = require("infra.llm_scope").participant(is_paused) end
	if ctx.keylogger then registry.metrics = require("infra.metrics_scope").participant(is_paused) end
	return registry
end

--- Applies one mode to every registered category, all or nothing.
--- @param mode string "recommended" or "clear".
--- @param registry table Scope id -> participant, from participants().
--- @return boolean committed
--- @return table report Composition report (applied, skipped, failed, detail).
function M.apply(mode, registry)
	assert(type(registry) == "table", "the global scope needs its participant registry")
	local owner = composition()
	if owner.pending() then
		local settled = false
		owner.retry_restore(function(ok) settled = ok == true end)
		if not settled then
			Logger.error(LOG, "Global scope %s refused: an earlier rollback is still pending.", tostring(mode))
			return false, { scope = "global", mode = mode, detail = "an earlier rollback is still pending" }
		end
	end
	_registry = registry
	local committed, report = false, nil
	owner.apply(mode, function(ok, result) committed, report = ok == true, result end)
	-- Every Linux owner settles synchronously; an unsettled request is a defect.
	assert(report ~= nil, "a Linux scope participant settled asynchronously")
	return committed, report
end

--- Test seam: forgets the composition and its debt.
function M._reset_for_test()
	_composition, _registry = nil, {}
end

return M
