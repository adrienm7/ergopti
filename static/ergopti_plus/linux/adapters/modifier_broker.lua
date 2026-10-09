--- adapters/modifier_broker.lua

--- ==============================================================================
--- MODULE: Shared Output Custody Wiring (Linux)
--- DESCRIPTION:
--- Captures the exact acknowledged Writer capability and transport ports once.
--- Generic source/producer policy belongs to the shared custody owner.
--- ==============================================================================

local M = {}
local Custody = require("input.modifier_custody")
local brokers = setmetatable({}, { __mode = "k" })
local binding_observers = setmetatable({}, { __mode = "k" })

--- Attaches once before any unowned native output is written.
--- @param writer table Actual Writer module.
--- @return table|nil broker
function M.attach(writer)
	if type(writer) ~= "table" or type(rawget(writer, "capture_output")) ~= "function" then return nil end
	if brokers[writer] then return brokers[writer] end
	local ports = {}
	local observer_factory = rawget(writer, "capture_output_observer")
	if type(observer_factory) == "function" then ports.capture_output_observer = observer_factory end
	for _, name in ipairs({ "capture_output", "output_view", "acquire_transaction", "transaction_view", "transaction_current",
		"transaction_emit", "dispatch_transaction", "commit_transaction", "retire_transaction", "close_owned" }) do
		if type(rawget(writer, name)) ~= "function" then return nil end
		ports[name] = rawget(writer, name)
	end
	local function ports_current()
		if rawget(writer, "capture_output_observer") ~= observer_factory then return false end
		for name, callback in pairs(ports) do if rawget(writer, name) ~= callback then return false end end
		return true
	end
	local captured, capability, issued_factory = pcall(ports.capture_output)
	if not captured or not capability or not ports_current() then return nil end
	-- A native issuer returns its original factory alongside the capability.
	-- Scripted transports retain output compatibility but cannot mint input proof.
	local captured_observer, captured_retirement_observer = false, false
	if type(issued_factory) == "function" and issued_factory == ports.capture_output_observer then
		local observed, observer, retirement_observer = pcall(ports.capture_output_observer, capability, ports.capture_output)
		if observed and type(observer) == "function" then captured_observer = observer end
		if observed and type(retirement_observer) == "function" then captured_retirement_observer = retirement_observer end
	end
	if not ports_current() then return nil end
	local observed, view = pcall(ports.output_view, capability)
	if not observed or type(view) ~= "table" or type(view.down) ~= "table"
		or next(view.down) ~= nil or not ports_current() then return nil end
	local broker = Custody.new(ports, capability, captured_observer, captured_retirement_observer)
	if not broker or not ports_current() then return nil end
	local names = { "view", "has_debt", "output_current", "output_retired", "retire" }
	local original = {}; for _, name in ipairs(names) do original[name] = rawget(broker, name) end
	binding_observers[writer] = function(exact)
		if exact ~= broker then return false end
		for _, name in ipairs(names) do
			local port = original[name]
			if type(port) ~= "function" or rawget(broker, name) ~= port then return false end
		end
		return true
	end
	brokers[writer] = broker
	return broker
end

--- Returns only the already-installed owner, never refreshes its epoch.
--- @param writer table Channel identity.
--- @return table|nil broker
--- @return function|nil observer Original private binding; no IO or new rights.
function M.for_channel(writer)
	local broker = brokers[writer]
	if not broker then return nil end
	return broker, binding_observers[writer]
end

--- Drops a retired channel binding after native destroy/close acknowledgement.
--- @param writer table Channel identity.
function M.detach(writer) brokers[writer], binding_observers[writer] = nil, nil end

--- Constructs the explicit recorder-only hook seam, without native authority.
--- @return table broker
function M.controlled() return Custody.new(nil, nil) end

return M
