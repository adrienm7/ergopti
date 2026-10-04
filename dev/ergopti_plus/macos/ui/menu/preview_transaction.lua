--- ui/menu/preview_transaction.lua

--- ==============================================================================
--- MODULE: Preview Menu Mutation Transaction
--- DESCRIPTION:
--- Acquires the existing global writer fence before changing a preview flag.
--- Native refusal and disk refusal retain their exact runtime inverse until
--- it is acknowledged; persistence remains the ordinary preference owner.
--- ==============================================================================

local M = {}
local Logger = require("infra.logger")
local LOG = "menu.preview_transaction"
local KEYS = {
	preview_star_enabled = true,
	preview_autocorrect_enabled = true,
	preview_ai_enabled = true,
	preview_colored_tooltips = true,
}

--- Creates a preview mutation owner using the current native and disk owners.
--- @param options table State, keymap, admission, pause and raw save ports.
--- @return table owner Toggle and retained compensation operations.
function M.new(options)
	assert(type(options) == "table" and type(options.state) == "table", "preview state required")
	for _, name in ipairs({ "admission", "paused", "save_prefs" }) do
		assert(type(options[name]) == "function", "preview port missing: " .. name)
	end
	local debt = nil
	local owner, claim = {}, {}
	local function invoke(setter, value)
		local called, accepted = xpcall(function() return setter(value) end, debug.traceback)
		if not called or accepted ~= true then
			Logger.warn(LOG, "Preview runtime mutation was not acknowledged: %s.", tostring(accepted))
			return false
		end
		return true
	end
	function claim.pending() return debt ~= nil end
	function claim.retry_restore()
		if debt == nil then return true end
		options.state[debt.key] = debt.prior
		if invoke(debt.setter, debt.prior) ~= true then return false end
		debt = nil
		return true
	end
	function owner.pending() return claim.pending() end
	function owner.retry_restore()
		return options.admission("Preview preference recovery", claim.retry_restore, claim) == true
	end
	--- Publishes a preview toggle only after native and durable acknowledgement.
	--- @param key string One of the four owned preview flags.
	--- @return boolean committed
	function owner.toggle(key)
		if KEYS[key] ~= true then return false end
		return options.admission("Preview preference: " .. key, function()
			if options.paused() ~= false then return false end
			if debt ~= nil and claim.retry_restore() ~= true then return false end
			local prior = options.state[key]
			local setter = type(options.keymap) == "table" and options.keymap["set_" .. key] or nil
			if type(prior) ~= "boolean" or type(setter) ~= "function" then return false end
			debt = { key = key, prior = prior, setter = setter }
			if invoke(setter, not prior) ~= true then
				claim.retry_restore()
				return false
			end
			options.state[key] = not prior
			local called, committed = xpcall(options.save_prefs, debug.traceback)
			if not called or committed ~= true then
				-- The ordinary save owner restores its complete checkpoint first.
				-- Confirm this native inverse too; a refused restore retains the fence.
				claim.retry_restore()
				return false
			end
			debt = nil
			return true
		end, claim) == true
	end
	return owner
end

return M
