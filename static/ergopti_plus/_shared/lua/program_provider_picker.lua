--- _shared/lua/program_provider_picker.lua

--- Session-owned discovery for the shared program picker. Native adapters own
--- enumeration; the saved action remains the existing executable/argv scalar.
local M = {}
local retirement_debt = {}
local capturing = false
local retiring = 0

--- Projects translated discovery labels without copying policy into the drivers.
--- @param get function Native locale accessor.
--- @return table labels Page vocabulary.
function M.strings(get)
	local labels = {}
	for field, key in pairs({
		label = "label", manual = "manual", hint = "hint", unavailable = "unavailable",
		changed = "changed", empty = "empty", truncated = "truncated",
	}) do
		labels[field] = get("dialog.action_picker.program_provider_" .. key)
	end
	labels.unavailableBinding = get("platform_reason.program_runner_unavailable")
	return labels
end

--- Captures a private discovery owner without making discovery a picker prerequisite.
--- @param adapter table Native provider factory.
--- @return table state Private owner and public, path-free inventory.
local function capture(adapter)
	local state = { packet = { unavailable = true } }
	for owner in pairs(retirement_debt) do
		local ok, retired = pcall(owner.invalidate)
		if ok and retired == true then retirement_debt[owner] = nil end
	end
	if next(retirement_debt) ~= nil then return state end
	if type(adapter) ~= "table" or type(adapter.create) ~= "function" then return state end
	local ok, owner = pcall(adapter.create)
	if not ok or type(owner) ~= "table" or type(owner.discover) ~= "function"
		or type(owner.resolve) ~= "function" or type(owner.invalidate) ~= "function" then return state end
	local discovered, packet = pcall(owner.discover)
	if not discovered or type(packet) ~= "table" then
		M.close({ owner = owner })
		return state
	end
	state.owner, state.packet = owner, packet
	return state
end

--- Serializes native factory callbacks so discovery cannot acquire overlapping owners.
--- @param adapter table Native provider factory.
--- @return table state Private owner and public inventory.
function M.capture(adapter)
	if capturing or retiring > 0 then return { packet = { unavailable = true } } end
	capturing = true
	local ok, state = pcall(capture, adapter)
	capturing = false
	return ok and state or { packet = { unavailable = true } }
end

--- Adds asynchronous readonly automation inventory to an existing picker session.
--- The ordinary file provider stays the owner of executable/argument assignment.
--- @param state table Existing private picker state.
--- @param adapter table Native asynchronous automation factory.
--- @param changed function Called after the same session's inventory changes.
--- @return boolean accepted
local function capture_automation(state, adapter, changed)
	if type(state) ~= "table" or type(state.packet) ~= "table" or state.automation ~= nil
		or type(changed) ~= "function" then return false end
	local function publish(packet)
		local choices = {}
		if packet then
			for _, choice in ipairs(packet.choices) do
				choices[#choices + 1] = { key = "automation:" .. choice.key, provider = choice.provider,
					label = choice.label, available = false }
			end
		end
		state.automation_packet = { title = "Apple Shortcuts", choices = choices,
			truncated = packet and packet.truncated or false }
		changed(state.automation_packet)
	end
	if next(retirement_debt) ~= nil or type(adapter) ~= "table" or type(adapter.create) ~= "function" then
		publish(nil); return false
	end
	local automation = {}
	state.automation = automation
	publish(nil)
	if state.automation ~= automation then return false end
	local created, owner = pcall(adapter.create)
	if not created or type(owner) ~= "table" or type(owner.discover) ~= "function"
		or type(owner.invalidate) ~= "function" then publish(nil); return false end
	if state.automation ~= automation then M.close({ owner = owner }); return false end
	automation.owner = owner
	local started, accepted = pcall(owner.discover, function(packet)
		if state.automation ~= automation or automation.owner ~= owner then return end
		publish(packet)
	end)
	if not started or accepted ~= true then publish(nil); return false end
	return true
end

--- Serializes asynchronous factory construction with ordinary file capture.
--- @param state table Existing private picker state.
--- @param adapter table Native asynchronous automation factory.
--- @param changed function Session-owned inventory callback.
--- @return boolean accepted
function M.capture_automation(state, adapter, changed)
	if capturing or retiring > 0 then return false end
	capturing = true
	local ok, accepted = pcall(capture_automation, state, adapter, changed)
	capturing = false
	return ok and accepted == true
end

--- Resolves an opaque choice only against the owner captured for this window.
--- @param state table Discovery state.
--- @param id string Selected action identifier.
--- @param body table Native-decoded page message.
--- @return boolean admitted
--- @return string|nil parameter Existing persisted scalar, or the manual value.
function M.confirm(state, id, body)
	-- A readonly automation inventory is visible but cannot promise service
	-- cancellation. Forged page messages never bypass the same unavailable gate.
	if type(body.providerKey) == "string" and body.providerKey:sub(1, 11) == "automation:" then return false end
	if body.providerKey == nil then
		return true, type(body.parameter) == "string" and body.parameter or nil
	end
	if id ~= "run_program" or type(body.providerKey) ~= "string"
		or body.providerKey == "" or not state or not state.owner then return false end
	local ok, scalar = pcall(state.owner.resolve, body.providerKey, body.programArguments)
	return ok and type(scalar) == "string", ok and scalar or nil
end

--- Invalidates retained choices when the owning picker actually closes.
--- @param state table|nil Discovery state.
function M.close(state)
	if not state then return true end
	local automation_retired = true
	if state.automation then
		local automation = state.automation
		state.automation = nil
		automation_retired = M.close(automation)
	end
	if not state.owner then return automation_retired end
	local owner = state.owner
	if type(owner.invalidate) ~= "function" then return false end
	retirement_debt[owner] = true
	state.owner = nil
	retiring = retiring + 1
	local ok, retired = pcall(owner.invalidate)
	retiring = retiring - 1
	if ok and retired == true then retirement_debt[owner] = nil; return automation_retired end
	return false
end

return M
