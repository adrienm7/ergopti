--- _shared/lua/config_binding_publication.lua

--- ==============================================================================
--- MODULE: Native Binding Publication Authority
--- DESCRIPTION:
--- Captures each native constructor's genuine accessor once. Read-only consumers
--- judge a binding only while the same plain registered module still exports
--- that accessor; replaced or withdrawn ownership remains unjudged without IO.
--- ==============================================================================

local M = {}
local domains = { keyboard = {}, script = {}, tap = {} }
-- LuaJIT has no ephemeron tables. The live native module retains its accessor;
-- neither ledger may retain a withdrawn module through its getter closure.
local initialized = setmetatable({}, { __mode = "k" })

--- Registers an authentic native constructor's accessor exactly once, without IO.
--- @param domain string Fixed binding family: keyboard, script or tap.
--- @param module_name string Actual native package namespace.
--- @param owner table Plain native module being constructed.
--- @param getter function Its genuine source-bound accessor.
function M.register(domain, module_name, owner, getter)
	local family = domains[domain]
	assert(family ~= nil and type(module_name) == "string" and module_name ~= ""
		and type(owner) == "table" and getmetatable(owner) == nil and type(getter) == "function"
		and rawequal(rawget(owner, "published_binding_catalogue"), getter) and not initialized[owner],
		"config_binding_publication: invalid or repeated native registration")
	local current = rawget(package.loaded, module_name)
	assert(type(current) ~= "table" or rawequal(current, owner),
		"config_binding_publication: another native owner is registered")
	local registered = family[module_name]
	if registered == nil then
		registered = setmetatable({}, { __mode = "kv" })
		family[module_name] = registered
	end
	registered[owner], initialized[owner] = getter, true
end

--- Checks the raw registered module and exported accessor without invoking either.
--- @param domain string Fixed binding family.
--- @param module_name string Actual native package namespace.
--- @param owner table|nil Currently loaded native module.
--- @return boolean current
function M.owner_is_current(domain, module_name, owner)
	local family = domains[domain]
	local registered = family and family[module_name]
	return type(owner) == "table" and getmetatable(owner) == nil
		and rawequal(rawget(package.loaded, module_name), owner)
		and registered ~= nil and registered[owner] ~= nil
		and rawequal(rawget(owner, "published_binding_catalogue"), registered[owner])
end

--- Reads only an authentic current accessor, never a public replacement.
--- @param domain string Fixed binding family.
--- @param module_name string Actual native package namespace.
--- @param owner table|nil Currently loaded native module.
--- @return table|nil catalogue Withdrawn or source-unavailable owners are unjudged.
function M.current(domain, module_name, owner)
	if not M.owner_is_current(domain, module_name, owner) then return nil end
	return domains[domain][module_name][owner]()
end

return M
