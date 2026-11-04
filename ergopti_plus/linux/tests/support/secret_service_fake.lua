--- tests/support/secret_service_fake.lua

--- ==============================================================================
--- MODULE: In-Memory Secret Service
--- DESCRIPTION:
--- Stands in for secret-tool behind modules/llm/api_token_store.lua, with the
--- results the real tool gives: a missing item reads as "absent", an absent
--- item deletes as success. A test can make the service unavailable or refuse
--- a store, and reads what it holds.
--- ==============================================================================

local M = {}

local STORE = "modules.llm.api_token_store"

--- A fresh fake service and the backend that serves it.
--- @return table fake { items, unavailable_reason, store_refusal, lookup_refusal, calls }
--- @return table backend
local function new_fake()
	local fake = { items = {}, calls = {}, unavailable_reason = nil, store_refusal = nil, lookup_refusal = nil }
	return fake, {
		unavailable = function() return fake.unavailable_reason end,
		store = function(name, token)
			fake.calls[#fake.calls + 1] = "store " .. name
			if fake.store_refusal then return false, fake.store_refusal end
			fake.items[name] = token
			return true
		end,
		lookup = function(name)
			fake.calls[#fake.calls + 1] = "lookup " .. name
			if fake.lookup_refusal then return nil, fake.lookup_refusal end
			if fake.items[name] == nil then return nil, "absent" end
			return fake.items[name]
		end,
		clear = function(name)
			fake.calls[#fake.calls + 1] = "clear " .. name
			fake.items[name] = nil
			return true
		end,
	}
end

--- Installs a fresh fake service on the loaded store and returns it.
--- @return table fake
function M.install()
	local fake, backend = new_fake()
	require(STORE)._set_backend_for_test(backend)
	return fake
end

--- Gives every load of the store its own fresh fake (tests/run.lua), as
--- runner_home gives the suite its own HOME: a suite run on a desktop must
--- never write a test key into the developer's keyring, even from a module a
--- test reloads.
function M.isolate()
	package.preload[STORE] = function()
		local path = assert(package.searchpath(STORE, package.path), "the token store is on the path")
		local Store = assert(loadfile(path))(STORE)
		local _, backend = new_fake()
		Store._set_backend_for_test(backend)
		return Store
	end
end

--- The number of items the fake holds.
--- @param fake table
--- @return number
function M.count(fake)
	local count = 0
	for _ in pairs(fake.items) do count = count + 1 end
	return count
end

--- Puts back an empty fake: the suite never falls through to secret-tool.
function M.uninstall()
	M.install()
end

return M
