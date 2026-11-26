--- modules/shortcuts/layer_wheel.lua

--- ==============================================================================
--- MODULE: Navigation Layer Wheel Owner
--- DESCRIPTION:
--- Owns the scroll eventtap that runs the navigation layer's wheel bindings
--- (layers.toml WheelUp, WheelDown…), which Karabiner-Elements cannot take.
---
--- FEATURES & RATIONALE:
--- 1. Not a Shortcut: the wheel belongs to the layer, as on Windows and Linux,
---    where only the layer gates it. The Shortcuts switch pauses the bindings
---    layer whole, so this owner lives outside it: switching Shortcuts off
---    leaves the wheel bound (BNM-1 of the 2026-11-17 parity pass).
--- 2. Held Back by a Script Pause: ScriptControl pauses this owner as its own
---    step, which releases the scroll tap; the resume binds it again.
--- 3. Derived from the File: a layer that binds no wheel direction holds no
---    scroll tap, and a direction it leaves unbound scrolls. Read at start,
---    at resume, and when a layers.toml writer reconciles it.
--- 4. Exact Fence: a callback retained by a refused delete is inert as soon as
---    the owner is stopped or paused.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")

local LOG = "shortcuts.layer_wheel"

-- The aggregate Shortcuts start owns the wheel; only its stop releases it.
local started = false
-- ScriptControl's pause, independent of the Shortcuts switch.
local script_paused = false
-- The live native owner returned by bind_layer_wheel, or nil.
local owner = nil
local wheel_slots = { vertical = {}, horizontal = {} }





-- ===================================
-- ===================================
-- ======= 1/ Layer Wheel Data =======
-- ===================================
-- ===================================

--- Whether a wheel turn may run a binding now.
--- @return boolean admitted
local function delivery_admitted()
	return started == true and script_paused ~= true
end

--- Reads the layer's wheel bindings from layers.toml.
--- @return boolean bound True when the layer binds at least one wheel direction.
local function load_wheel()
	-- Required here, not at load: the layer data reads the configuration folder.
	local ok, layer = xpcall(function() return require("platform.remap.nav_layer").load() end,
		debug.traceback)
	if not ok or type(layer) ~= "table" or type(layer.wheel) ~= "table" then
		-- NavLayer.load() raises only on a broken shipped registry or vocabulary,
		-- which the Karabiner regeneration reports too: no wheel runs meanwhile.
		Logger.error(LOG, "The navigation layer's wheel bindings could not be read: %s.", tostring(layer))
		wheel_slots = { vertical = {}, horizontal = {} }
		return false
	end
	wheel_slots = layer.wheel
	for _, directions in pairs(wheel_slots) do
		if next(directions) ~= nil then return true end
	end
	return false
end

--- The loaded binding for one direction of the wheel. Memory only: asked
--- inside the scroll eventtap.
--- @param axis string "vertical" or "horizontal".
--- @param direction number 1 or -1.
--- @return table|nil slot
local function wheel_slot(axis, direction)
	local directions = wheel_slots[axis]
	return directions and directions[direction] or nil
end





-- ===================================
-- ===================================
-- ======= 2/ Native Ownership =======
-- ===================================
-- ===================================

--- Releases the scroll tap. A refused delete retains the exact handle, behind
--- the delivery fence, for the next release.
--- @return boolean released
local function release()
	if owner == nil then return true end
	local ok, result = pcall(function() return owner:delete() end)
	if ok and result == true then
		owner = nil
		Logger.debug(LOG, "The navigation layer's wheel released the scroll wheel.")
		return true
	end
	Logger.error(LOG, "The navigation layer's wheel could not release the scroll wheel (%s); retained for retry.",
		tostring(result))
	return false
end

--- Takes the scroll tap once.
--- @return boolean acquired
local function acquire()
	if owner ~= nil then return true end
	local ok, obj = xpcall(function()
		-- Required here, not at load: the Shortcuts facade loads this owner,
		-- and the eventtap layer is only needed once a direction is bound.
		return require("modules.shortcuts.actions.system").bind_layer_wheel(delivery_admitted, wheel_slot)
	end, debug.traceback)
	local object_type = type(obj)
	if ok and (object_type == "table" or object_type == "userdata") then
		owner = obj
		Logger.debug(LOG, "The navigation layer's wheel took the scroll wheel.")
		return true
	end
	Logger.error(LOG, "The navigation layer's wheel could not take the scroll wheel: %s; "
		.. "the next save of the layer or resume retries it.", tostring(obj))
	return false
end

--- Binds or releases the scroll tap as layers.toml binds a direction or none.
--- @return boolean settled True when the native owner matches the file.
local function apply()
	if load_wheel() then return acquire() end
	return release()
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Starts the owner with the Shortcuts subsystem, whatever its switch. A
--- refused tap is logged and leaves every other shortcut running.
--- @return boolean committed False only when a prior handle cannot be released.
function M.start()
	if started then
		Logger.debug(LOG, "M.start() already active — ignoring duplicate start.")
		return true
	end
	Logger.start(LOG, "Starting the navigation layer's wheel…")
	started = true
	if script_paused then
		Logger.success(LOG, "The navigation layer's wheel started behind the script pause.")
		return true
	end
	if apply() ~= true and owner ~= nil then return false end
	Logger.success(LOG, "The navigation layer's wheel started (%s).",
		owner ~= nil and "bound" or "unbound")
	return true
end

--- Stops the owner with the Shortcuts subsystem.
--- @return boolean settled True once the scroll tap is released.
function M.stop()
	Logger.start(LOG, "Stopping the navigation layer's wheel…")
	started = false
	if release() ~= true then return false end
	Logger.success(LOG, "The navigation layer's wheel stopped.")
	return true
end

--- ScriptControl's pause step: releases the scroll tap until resume().
--- @return boolean settled
function M.pause()
	script_paused = true
	return release()
end

--- ScriptControl's resume step: binds the scroll tap again when the layer
--- binds a wheel direction. A refused tap is logged, as at start.
--- @return boolean committed False only when a retained handle cannot be released.
function M.resume()
	script_paused = false
	if not started then return true end
	if apply() ~= true and owner ~= nil then return false end
	return true
end

--- Reconciles the owner after layers.toml was written: the bound owner runs
--- the file's bindings from its next turn of the wheel, and the owner binds or
--- releases as the file binds a direction or none. A stopped or paused owner
--- reads the file again at its start or resume.
--- @return boolean committed
function M.reconcile()
	if not delivery_admitted() then return true end
	return apply()
end

--- @return boolean bound True when the scroll tap is owned right now.
function M.is_bound()
	return owner ~= nil
end

return M
