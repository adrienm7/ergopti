--- tests/support/remap_menu_runtime_inputs.lua

--- ==============================================================================
--- MODULE: Scoped Remap Menu Intent Inputs
--- DESCRIPTION:
--- Supplies old menu models with actual declared settings intent while their
--- entire test body retains the genuine settings owner. It grants no native
--- readiness, controller, task or installed-helper capability.
--- ==============================================================================

local with_fixture = require("tests.support.remap_transaction_fixture")
local M = {}

--- Binds one test module's model inputs to a live, scoped settings owner.
--- @param original table Existing test registration/assertion owner.
--- @return table helpers Original assertions with scoped case registration.
--- @return table ports Pure settings intent inputs, valid only inside the case.
function M.bind(original)
	local active
	local helpers = setmetatable({}, { __index = original })
	local function snapshot(bindings)
		local saved = {}
		for name, value in pairs(bindings) do saved[name] = value end
		return saved
	end
	local function restore(bindings, saved)
		for name in pairs(bindings) do
			if rawget(saved, name) == nil then bindings[name] = nil end
		end
		for name, value in pairs(saved) do bindings[name] = value end
	end
	local function with_runtime_inputs(body)
		assert(active == nil, "runtime intent inputs already have a scoped owner")
		local caller_loaded, caller_preload = snapshot(package.loaded), snapshot(package.preload)
		local caller_hs = rawget(_G, "hs")
		local scoped = table.pack(pcall(function()
			return with_fixture(function(fixture)
				active = fixture.load_enabled_remap()
				local fixture_loaded, fixture_preload = snapshot(package.loaded), snapshot(package.preload)
				local fixture_hs = rawget(_G, "hs")
				local names, seen = {}, {}
				for _, bindings in ipairs({ caller_loaded, fixture_loaded, caller_preload, fixture_preload }) do
					for name in pairs(bindings) do
						if type(name) == "string" and not seen[name] then
							seen[name] = true
							names[#names + 1] = name
						end
					end
				end
				table.sort(names)
				local outcome = table.pack(pcall(function()
					return original.with_stub_scope(names, function()
						restore(package.loaded, caller_loaded)
						restore(package.preload, caller_preload)
						_G.hs = caller_hs
						return body()
					end)
				end))
				restore(package.loaded, fixture_loaded)
				restore(package.preload, fixture_preload)
				_G.hs = fixture_hs
				active = nil
				if not outcome[1] then error(outcome[2], 0) end
				return table.unpack(outcome, 2, outcome.n)
			end)
		end))
		restore(package.loaded, caller_loaded)
		restore(package.preload, caller_preload)
		_G.hs = caller_hs
		active = nil
		if not scoped[1] then error(scoped[2], 0) end
		return table.unpack(scoped, 2, scoped.n)
	end
	function helpers.it(name, body)
		if active ~= nil then return original.it(name, body) end
		return original.it(name, function() return with_runtime_inputs(body) end)
	end
	--- Scopes construction performed before case registration to one actual owner.
	--- Nested explicit scopes are refused; cases reuse the live enclosing owner.
	--- @param body function Existing construction, callbacks and assertions.
	--- @return function scoped Original callback inside the same intent lifetime.
	function helpers.scoped_runtime_inputs(body)
		assert(type(body) == "function", "runtime intent scope requires its original callback")
		return function(...)
			local args = table.pack(...)
			return with_runtime_inputs(function() return body(table.unpack(args, 1, args.n)) end)
		end
	end
	local ports = {}
	for _, name in ipairs({ "get_runtime", "shared_runtime_selected", "runtime_unavailable_reason" }) do
		ports[name] = function()
			assert(active, "runtime intent inputs require their live scoped settings owner")
			return active[name]()
		end
	end
	return helpers, ports
end

return M
