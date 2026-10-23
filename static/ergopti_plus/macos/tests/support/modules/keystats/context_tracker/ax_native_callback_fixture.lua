--- tests/support/modules/keystats/context_tracker/ax_native_callback_fixture.lua

--- Models the documented observer callback order and native observer equality.
local Base = require("tests.support.modules.keystats.context_tracker.ax_focus_refusal_fixture")
local M = {}

--- Owns a healthy runtime plus exact native callback and field-value controls.
---@param callback function Receives the existing public runtime.
---@return ... results Original callback results.
function M.with_runtime(callback)
	return Base.with_runtime(function(runtime)
		-- Reattach through the real public boundary so the inherited AX field is
		-- the field installed by this fixture, rather than its parent's bootstrap.
		runtime.pause()
		runtime.resume()
		local field = assert(runtime.hs.axuielement.applicationElementForPID(runtime.native.pid)
			:attributeValue("AXFocusedUIElement"))
		local original_attribute = field.attributeValue
		runtime.native.field_value = ""
		field.attributeValue = function(self, attribute)
			if attribute == "AXValue" then return runtime.native.field_value end
			return original_attribute(self, attribute)
		end
		local controls = { field = field, original_attribute = original_attribute,
			records = {}, failures = {}, equality_calls = 0 }
		local originals, identities = {}, {}
		local function native_equal(left, right)
			controls.equality_calls = controls.equality_calls + 1
			return identities[left] ~= nil and rawequal(identities[left], identities[right])
		end
		function controls.alias(owner)
			owner = owner or assert(runtime.state.ax_observer)
			assert(type(owner) == "table", "This portable fixture models native observer userdata with tables")
			if identities[owner] == nil then
				originals[#originals + 1] = { owner = owner, metatable = getmetatable(owner) }
				assert(getmetatable(owner) == nil, "The inherited observer has an unexpected metatable")
				identities[owner] = {}
				setmetatable(owner, { __eq = native_equal })
			end
			local alias = {}
			identities[alias] = identities[owner]
			return setmetatable(alias, { __eq = native_equal, __index = owner })
		end
		function controls.emit(event, watcher, element, observer_callback)
			local owner = assert(runtime.state.ax_observer)
			observer_callback = observer_callback or assert(owner.observer_callback)
			return observer_callback(watcher or owner, element or field, event, {})
		end
		local owner, token, original_clock
		function controls.bind()
			assert(owner == nil, "The callback fixture has one physical subscription owner")
			-- The inherited pause fixture holds time fixed between timer pumps. A
			-- live native clock progresses between the channel's strict samples.
			original_clock = runtime.hs.timer.absoluteTime
			local reads = 0
			runtime.hs.timer.absoluteTime = function()
				reads = reads + 1
				return original_clock() + reads
			end
			owner = {}
			local accepted
			accepted, token = runtime.tracker.bind_physical_correlated_context_observer(owner, 128,
				function(record) controls.records[#controls.records + 1] = record; return true end,
				function(reason) controls.failures[#controls.failures + 1] = reason end,
				function() return runtime.engine.may_persist() end)
			assert(accepted == true, "The actual physical context subscription must commit")
		end
		assert(runtime.ax_native == nil)
		runtime.ax_native = controls
		local result = table.pack(xpcall(function() return callback(runtime) end, debug.traceback))
		local detached, detach_result = true, true
		if owner ~= nil and token ~= nil then
			detached, detach_result = pcall(runtime.tracker.unbind_physical_context_observer, owner, token)
		end
		-- Restore every exact port before the inherited engine/control finally runs,
		-- including after a test assertion raises while a physical observer is bound.
		for _, original in ipairs(originals) do setmetatable(original.owner, original.metatable) end
		field.attributeValue = original_attribute
		if original_clock ~= nil then runtime.hs.timer.absoluteTime = original_clock end
		runtime.ax_native = nil
		if not detached or detach_result ~= true then error("Callback fixture subscription cleanup refused", 0) end
		if not result[1] then error(result[2], 0) end
		return table.unpack(result, 2, result.n)
	end)
end

return M
