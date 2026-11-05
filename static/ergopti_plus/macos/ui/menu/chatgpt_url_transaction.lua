--- ui/menu/chatgpt_url_transaction.lua

--- ==============================================================================
--- MODULE: ChatGPT URL Mutation Owner
--- DESCRIPTION:
--- Enters the existing global writer fence before changing the ChatGPT URL.
--- The ordinary preference transaction owns publication and whole-state rollback;
--- this owner retains the exact native inverse until it is acknowledged.
--- ==============================================================================

local M = {}
local Logger = require("infra.logger")
local LOG = "menu.chatgpt_url_transaction"

local function valid_url(value)
	return type(value) == "string" and value ~= ""
end

--- Creates the ChatGPT URL owner around the existing native and disk owners.
--- @param options table State, shortcuts, admission, pause and ordinary save ports.
--- @return table owner Mutation and retained compensation operations.
function M.new(options)
	assert(type(options) == "table" and type(options.state) == "table", "ChatGPT URL state required")
	for _, name in ipairs({ "admission", "paused", "save_prefs" }) do
		assert(type(options[name]) == "function", "ChatGPT URL port missing: " .. name)
	end
	local debt = nil
	local owner, claim = {}, {}
	local function observe(getter)
		local called, value = pcall(getter)
		if not called or not valid_url(value) then return nil end
		return value
	end
	local function apply(setter, getter, value)
		local called, accepted = xpcall(function() return setter(value) end, debug.traceback)
		if not called or accepted ~= true or observe(getter) ~= value then
			Logger.warn(LOG, "ChatGPT URL runtime mutation was not acknowledged.")
			return false
		end
		return true
	end
	function claim.pending() return debt ~= nil end
	local function restore(retire)
		if debt == nil then return true end
		local current_state = options.state.chatgpt_url
		if current_state ~= debt.state and current_state ~= debt.candidate then return false end
		local shortcuts = options.shortcuts
		if not rawequal(shortcuts, debt.shortcuts) or shortcuts.set_chatgpt_url ~= debt.setter
			or shortcuts.get_chatgpt_url ~= debt.getter then return false end
		local current = observe(debt.getter)
		if current ~= debt.runtime and current ~= debt.candidate then
			Logger.warn(LOG, "ChatGPT URL recovery refused an unrelated runtime value.")
			return false
		end
		if apply(debt.setter, debt.getter, debt.runtime) ~= true then return false end
		options.state.chatgpt_url = debt.state
		if retire then debt = nil end
		return true
	end
	function claim.retry_restore() return restore(true) end
	function owner.pending() return claim.pending() end
	--- Protects the ordinary rollback from overwriting an unrelated baseline.
	--- The caller already holds this owner's global writer admission. The inverse
	--- remains retained until the entire ordinary rollback has returned.
	--- @return boolean restored Exact native inverse acknowledgement.
	function owner.restore_runtime() return restore(false) end
	--- Keep the ordinary rollback from replacing the independently captured
	--- effective runtime URL with a different saved spelling (for example "").
	function owner.rollback_modules(core_modules)
		if debt == nil or type(core_modules) ~= "table"
			or core_modules.shortcuts_mod ~= debt.shortcuts then return nil end
		local modules = {}
		for key, value in pairs(core_modules) do modules[key] = value end
		modules.shortcuts_mod = setmetatable({ set_chatgpt_url = function() return true end },
			{ __index = debt.shortcuts })
		return modules
	end
	function owner.retry_restore()
		return options.admission("ChatGPT URL recovery", claim.retry_restore, claim) == true
	end
	--- Publishes a ChatGPT URL only after native and durable acknowledgement.
	--- @param url string Configured ChatGPT URL.
	--- @return boolean committed
	function owner.set(url)
		if not valid_url(url) then return false end
		return options.admission("ChatGPT URL preference", function()
			if options.paused() ~= false then return false end
			if debt ~= nil and claim.retry_restore() ~= true then return false end
			local shortcuts = options.shortcuts
			local setter = type(shortcuts) == "table" and shortcuts.set_chatgpt_url or nil
			local getter = type(shortcuts) == "table" and shortcuts.get_chatgpt_url or nil
			if type(setter) ~= "function" or type(getter) ~= "function"
				or (options.state.chatgpt_url ~= nil and type(options.state.chatgpt_url) ~= "string") then return false end
			local prior_runtime = observe(getter)
			if prior_runtime == nil or options.paused() ~= false then return false end
			debt = { state = options.state.chatgpt_url, runtime = prior_runtime, candidate = url,
				shortcuts = shortcuts, setter = setter, getter = getter }
			if apply(setter, getter, url) ~= true then
				claim.retry_restore()
				return false
			end
			options.state.chatgpt_url = url
			local called, committed = xpcall(options.save_prefs, debug.traceback)
			if not called or committed ~= true then
				-- The ordinary transaction restores its whole acknowledged checkpoint.
				-- Its ordinary runtime sync can refuse, so prove this inverse too.
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
