-- tools/diagnostics/macos_action_picker_pool_observer.lua
-- Private source-pinned READ-ONLY Lua observation for the native diagnostic.
-- No native, factory, pool function or product state is replaced here.
local M = {}

--- Reads only the current private session, without retaining its business owner.
--- @param picker table Actual source-loaded ActionPicker module.
--- @param source string Exact @path of the frozen ActionPicker init.lua.
--- @return table observation Actual native view and UCC only; no private lease.
function M.snapshot(picker, source)
	assert(type(picker) == "table" and type(picker.open) == "function")
	assert(debug.getinfo(picker.open, "S").source == source, "foreign ActionPicker owner")
	local session, found, index = nil, 0, 1
	while true do
		local name, value = debug.getupvalue(picker.open, index)
		if name == nil then break end
		if name == "_active_session" then session, found = value, found + 1 end
		index = index + 1
	end
	assert(found == 1 and type(session) == "table" and getmetatable(session) == nil,
		"exact source-pinned current session is unavailable")
	assert(not rawget(session, "closing") and not rawget(session, "retired"), "current session is revoked")
	local view, controller = rawget(session, "webview"), rawget(session, "usercontent")
	assert(type(view) == "userdata" and getmetatable(view) ~= nil, "actual native view is unavailable")
	assert(type(controller) == "userdata" and getmetatable(controller) ~= nil, "actual native UCC is unavailable")
	-- Do not return the session, receiver, on_confirm, token or mutable pool.
	return { view = view, controller = controller }
end

--- Invokes the actual registered frontend action through WebKit, not the receiver.
--- @param observation table Read-only snapshot of the native B view.
--- @param id string Registered plain action id, without a parameter editor.
--- @param completed function Receives (accepted, error, evaluation) for the supervisor.
function M.post_registered_action(observation, id, completed)
	local Json = require("json")
	local Result = require("adapters.webview_result")
	assert(type(id) == "string" and id ~= "" and type(completed) == "function")
	assert(getmetatable(observation.view) ~= nil, "B was consumed before its real frontend post")
	observation.view:evaluateJavaScript("doConfirm(" .. Json.quote(id) .. "); true", function(value, failure)
		local evaluation = { value_type = type(failure), metatable_type = type(getmetatable(failure)),
			result_type = type(value), result = value, value = failure }
		local accepted, detail = xpcall(function()
			assert(not Result.is_error(failure), "native frontend evaluation failed")
			assert(value == true, "native frontend completion was not primitive true")
		end, debug.traceback)
		completed(accepted, accepted and nil or detail, evaluation)
	end)
end

return M
