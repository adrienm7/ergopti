--- ui/menu/global_scope.lua

--- ==============================================================================
--- MODULE: Global Scope (macOS)
--- DESCRIPTION:
--- Restores Ergopti's recommended values, or clears every category to the
--- system's own behaviour, by composing the per-scope owners through the shared
--- composition in the manifest's `[scopes.global]` order. Both apply at once,
--- without a question: each owner keeps its own backup, conflict detection and
--- runtime acknowledgement, and a refusal reverts every committed one.
---
--- FEATURES & RATIONALE:
--- 1. Existing Owners: the config.toml categories are the scoped owners the
---    menus already use (each takes the global writer fence itself); the remap
---    file joins through the remap engine's asynchronous scope request, the
---    keys under tap_holds and the chords under shortcuts.
--- 2. Live Owners Only: a category whose owner is unavailable on this Mac is
---    skipped and reported, never guessed.
--- 3. Consent: AI and metrics consent stay out of « recommended » through the
---    manifest's scope exclusions, which each owner applies.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Composition = require("config_scope_composition")
local Participant = require("config_scope_participant")
local Logger = require("infra.logger")
local LOG = "menu.global_scope"

--- The remap engine's part of one scope, as an asynchronous participant: its
--- inverse includes its settings snapshot and exact navigation-layer import
--- receipt, both restored through the same native cohort gate.
--- The next category never runs on the Karabiner terminal's own stack: the
--- continuation is deferred, so a second regeneration is not requested from
--- inside the callback that settles the first. A `persisted-guardian-…`
--- terminal commits too: the settings are saved and deploy once the remap
--- guardian is ready. This flow shows no notice of its own for it; the
--- guardian's notice already told the user why the rules wait, and the
--- Tap-Hold submenu keeps saying so.
--- @param remap table Remap facade (apply_scope, snapshot/restore_settings).
--- @param scope string Manifest scope id served by the remap file.
--- @param backup_path function scope -> unique backup path.
--- @param defer function fn -> true once fn is scheduled off this stack.
--- @return table participant See config_scope_composition.
local function remap_participant(remap, scope, backup_path, defer)
	local snapshot, committed, layer_receipt, missing_receipt = nil, false, nil, false
	local participant = {}
	local function settle(done, ok, reason)
		if defer(function() return done(ok, reason) end) == true then return end
		-- The terminal is already known, so settling here is exact, only earlier
		-- than intended; an unscheduled continuation would orphan the rollback.
		Logger.warn(LOG, "Remap %s continuation could not be deferred; settling in place.", scope)
		return done(ok, reason)
	end
	function participant.apply(mode, done)
		snapshot, committed, layer_receipt, missing_receipt = remap.snapshot_settings(), false, nil, false
		if type(snapshot) ~= "table" then return done(false, "remap settings are owned by another transaction") end
		remap.apply_scope({ scope = scope, mode = mode, backup_path = backup_path(scope) }, function(ok, reason, _, receipt)
			committed = ok == true
			if committed and scope == "tap_holds" and mode == "recommended" then
				if type(receipt) ~= "table" then
					missing_receipt = true
					return settle(done, false, "missing-navigation-layer-receipt")
				end
				layer_receipt = receipt
			end
			return settle(done, committed, reason)
		end)
	end
	function participant.revert(done)
		if not committed then return done(false, "no committed remap scope to revert") end
		if missing_receipt then return done(false, "missing-navigation-layer-receipt") end
		remap.restore_settings(snapshot, function(ok, reason)
			if ok == true then committed = false end
			return settle(done, ok == true, reason)
		end, layer_receipt)
	end
	function participant.release()
		assert(committed and not missing_receipt and remap.settings_pending() == false,
			"remap scope cannot release an unacknowledged cohort")
		snapshot, committed, layer_receipt = nil, false, nil
	end
	function participant.pending() return missing_receipt or remap.settings_pending() == true end
	function participant.retry_restore(done)
		if missing_receipt then return done(false, "missing-navigation-layer-receipt") end
		if remap.retry_settings_recovery() ~= true or remap.settings_pending() ~= false then
			return done(false, "remap settings recovery remains pending")
		end
		-- A failed restore's own inverse recovers the pre-restore settings.
		-- The parent's snapshot is still owed until its true terminal.
		if committed then return participant.revert(done) end
		return done(true)
	end
	return participant
end

--- Creates the global owner from the menu's scope owners.
--- @param options table owners (scope id -> function returning the scoped owner
---   or nil when unavailable), remap (facade or nil), backup_path(scope),
---   defer(fn), paused() and refresh(committed, report).
--- @return table owner apply(mode), pending(), retry_restore(done).
function M.new(options)
	assert(type(options) == "table" and type(options.owners) == "table", "the global scope needs its owners")
	for _, name in ipairs({ "backup_path", "defer", "paused", "refresh" }) do
		assert(type(options[name]) == "function", "the global scope needs " .. name)
	end
	-- Retired with the clear's question on 2026-09-30: a caller still wiring
	-- one would expect it to be asked, so it is refused rather than ignored.
	assert(options.confirm == nil, "the global scope asks no question: the confirm port is retired")
	local function participants()
		local registry = {}
		for id, provider in pairs(options.owners) do
			assert(type(provider) == "function", "scope owner provider must be a function: " .. tostring(id))
			local owner = provider()
			if owner ~= nil then
				registry[id] = Participant.synchronous({
					apply = function(mode) return owner.apply(mode) end,
					owner = function() return owner end,
				})
			end
		end
		local remap = options.remap
		if type(remap) == "table" and type(remap.get_enabled) == "function" and remap.get_enabled() == true then
			registry.tap_holds = remap_participant(remap, "tap_holds", options.backup_path, options.defer)
			local chords = remap_participant(remap, "shortcuts", options.backup_path, options.defer)
			registry.shortcuts = registry.shortcuts and { registry.shortcuts, chords } or { chords }
		end
		return registry
	end
	local composition = Composition.new({ manifest = Manifest, scope = "global", logger = Logger, log = LOG,
		participants = participants })
	local owner = { pending = composition.pending, retry_restore = composition.retry_restore }
	--- Applies one mode to every available category, at once for both modes:
	--- the maintainer retired the clear's question on 2026-09-30.
	--- @param mode string "recommended" or "clear".
	--- @return boolean accepted True once the composition started.
	function owner.apply(mode)
		if options.paused() ~= false then return false end
		if composition.pending() then
			local settled = false
			composition.retry_restore(function(ok) settled = ok == true end)
			if not settled then
				Logger.error(LOG, "Global scope %s refused: an earlier rollback is still pending.", tostring(mode))
				return false
			end
		end
		return composition.apply(mode, function(committed, report)
			options.refresh(committed == true, report)
		end)
	end
	return owner
end

return M
