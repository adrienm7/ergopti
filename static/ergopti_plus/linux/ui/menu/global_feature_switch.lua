--- ui/menu/global_feature_switch.lua

--- ==============================================================================
--- MODULE: Global Feature Switch (Linux)
--- DESCRIPTION:
--- Owns the tray's « Disable all » and « Enable all » global actions.
---
--- « Disable all » behaves like a pause: every feature switch goes off
--- (hotstrings, shortcuts, gestures, AI, metrics, dynamic hotstrings,
--- tap-holds) while every per-key, per-slot and per-section assignment stays as
--- configured, and the script-control shortcuts keep working because they are
--- how a user gets back. « Enable all » restores exactly what was on before.
---
--- FEATURES & RATIONALE:
--- 1. Snapshot, then switch. The state each feature had is captured and
---    persisted BEFORE anything moves, so Enable all restores the user's own
---    choice — also after a restart — rather than switching every feature, and
---    every bundled hotstring section, on. The previous Enable all did exactly
---    that, and Disable all only moved the hotstrings.
--- 2. All or nothing on the way down. A feature whose switch refuses rolls back
---    the ones already switched off, and the snapshot is dropped, so a failed
---    Disable all never leaves half the features off with no way back.
--- 3. Best effort on the way up. A feature that cannot come back (a touchpad
---    that disappeared) is logged and kept in the snapshot so the next Enable
---    all retries it; the others are restored.
--- 4. Runtime-only switches are re-applied at boot. The dynamic hotstrings and
---    the tap-hold switch hold no persisted state of their own, so
---    reapply_after_boot() switches them off again while a snapshot is live.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "GlobalFeatureSwitch"

-- Storage key of the persisted snapshot. Its presence means « Disable all » is
-- in force.
M.STORAGE_KEY = "global_actions.disabled_snapshot"

--- Validates one feature descriptor.
--- @param feature table { id, capture, disable, restore, enable, persistent }
local function check_feature(feature)
	if type(feature) ~= "table" or type(feature.id) ~= "string" or feature.id == "" then
		error("every global feature needs a string id")
	end
	for _, name in ipairs({ "capture", "disable", "restore" }) do
		if type(feature[name]) ~= "function" then
			error("global feature '" .. feature.id .. "' needs a " .. name .. " function")
		end
	end
	if feature.enable ~= nil and type(feature.enable) ~= "function" then
		error("global feature '" .. feature.id .. "' enable must be a function")
	end
end

--- Runs one feature step, turning a raise or a non-true return into false.
--- @param label string
--- @param fn function
--- @param ... any
--- @return boolean
local function step(label, fn, ...)
	local ok, result = pcall(fn, ...)
	if not ok then
		Logger.error(LOG, "%s raised: %s.", label, tostring(result))
		return false
	end
	if result == false or result == nil then
		Logger.error(LOG, "%s was refused.", label)
		return false
	end
	return true
end

--- Builds the controller behind the two global actions.
--- @param opts table { features = { descriptor... }, storage = { get, set, delete } }
---   Each descriptor: capture() -> value (nil when the feature is absent),
---   disable() -> boolean, restore(value) -> boolean, enable() -> boolean
---   (used when no snapshot exists; defaults to restore(nil)), persistent
---   (false for switches with no persisted state of their own).
--- @return table controller
function M.new(opts)
	if type(opts) ~= "table" or type(opts.features) ~= "table" then
		error("global feature switch needs a features list")
	end
	local storage = opts.storage
	if type(storage) ~= "table" or type(storage.get) ~= "function"
		or type(storage.set) ~= "function" or type(storage.delete) ~= "function" then
		error("global feature switch needs a storage with get, set and delete")
	end
	local features = {}
	local seen = {}
	for _, feature in ipairs(opts.features) do
		check_feature(feature)
		if seen[feature.id] then error("duplicate global feature '" .. feature.id .. "'") end
		seen[feature.id] = true
		features[#features + 1] = feature
	end

	local controller = {}

	--- The persisted snapshot, or nil when « Disable all » is not in force.
	--- @return table|nil
	local function snapshot()
		local value = storage.get(M.STORAGE_KEY, nil)
		return type(value) == "table" and value or nil
	end

	--- Whether « Disable all » is in force.
	--- @return boolean
	function controller.is_all_disabled()
		return snapshot() ~= nil
	end

	--- Switches every feature off, keeping every assignment.
	--- @return boolean True when every feature is off.
	function controller.disable_all()
		Logger.start(LOG, "Disabling every feature…")
		if snapshot() ~= nil then
			Logger.success(LOG, "Every feature is already disabled — the snapshot is kept.")
			return true
		end
		local captured = {}
		for _, feature in ipairs(features) do
			local ok, value = pcall(feature.capture)
			if not ok then
				Logger.error(LOG, "Could not read the state of '%s': %s — nothing changed.",
					feature.id, tostring(value))
				return false
			end
			if value ~= nil then captured[feature.id] = value end
		end
		-- Persisted first: a crash after this point still leaves Enable all able
		-- to restore what the user had.
		if storage.set(M.STORAGE_KEY, captured) ~= true then
			Logger.error(LOG, "The feature snapshot was not persisted — nothing changed.")
			return false
		end
		local switched = {}
		for _, feature in ipairs(features) do
			if captured[feature.id] ~= nil then
				if not step("Disabling '" .. feature.id .. "'", feature.disable) then
					for index = #switched, 1, -1 do
						local done = switched[index]
						step("Rolling back '" .. done.id .. "'", done.restore, captured[done.id])
					end
					storage.delete(M.STORAGE_KEY)
					Logger.error(LOG, "Disable all rolled back: '%s' could not be switched off.", feature.id)
					return false
				end
				switched[#switched + 1] = feature
			end
		end
		Logger.success(LOG, "Every feature disabled (%d switched off, assignments kept).", #switched)
		return true
	end

	--- Restores the features « Disable all » switched off, or switches every
	--- feature on when there is nothing to restore.
	--- @return boolean True when every feature is back.
	function controller.enable_all()
		Logger.start(LOG, "Enabling every feature…")
		local captured = snapshot()
		local failed = {}
		local restored = 0
		for _, feature in ipairs(features) do
			local ok
			if captured then
				if captured[feature.id] ~= nil then
					ok = step("Restoring '" .. feature.id .. "'", feature.restore, captured[feature.id])
					if not ok then failed[feature.id] = captured[feature.id] end
					restored = restored + 1
				end
			else
				ok = step("Enabling '" .. feature.id .. "'", feature.enable or feature.restore, nil)
				restored = restored + 1
				if not ok then failed[feature.id] = true end
			end
		end
		if next(failed) then
			if captured then storage.set(M.STORAGE_KEY, failed) end
			Logger.error(LOG, "Enable all incomplete — the features that failed are kept for a retry.")
			return false
		end
		if captured and storage.delete(M.STORAGE_KEY) ~= true then
			Logger.error(LOG, "The feature snapshot could not be cleared — Enable all will run again.")
			return false
		end
		Logger.success(LOG, "Every feature enabled (%d %s).", restored, captured and "restored" or "switched on")
		return true
	end

	--- Switches the runtime-only features off again while « Disable all » is in
	--- force: they carry no persisted state, so a restart would turn them back on.
	--- @return integer Number of features re-applied.
	function controller.reapply_after_boot()
		local captured = snapshot()
		if not captured then return 0 end
		local count = 0
		for _, feature in ipairs(features) do
			if feature.persistent == false and captured[feature.id] ~= nil then
				if step("Re-applying Disable all to '" .. feature.id .. "'", feature.disable) then
					count = count + 1
				end
			end
		end
		Logger.info(LOG, "Disable all is in force — %d runtime switch(es) re-applied.", count)
		return count
	end

	return controller
end

return M
