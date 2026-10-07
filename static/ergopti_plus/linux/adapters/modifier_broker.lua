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

--- Attaches once before any unowned native output is written.
--- @param writer table Actual Writer module.
--- @return table|nil broker
function M.attach(writer)
	if type(writer) ~= "table" or type(rawget(writer, "capture_output")) ~= "function" then return nil end
	if brokers[writer] then return brokers[writer] end
	local ports = {}
	for _, name in ipairs({ "capture_output", "output_view", "acquire_transaction", "transaction_view", "transaction_current",
		"transaction_emit", "dispatch_transaction", "commit_transaction", "retire_transaction", "close_owned" }) do
		if type(rawget(writer, name)) ~= "function" then return nil end
		ports[name] = rawget(writer, name)
	end
	local function ports_current()
		for name, callback in pairs(ports) do if rawget(writer, name) ~= callback then return false end end
		return true
	end
	local captured, capability = pcall(ports.capture_output)
	if not captured or not capability or not ports_current() then return nil end
	local observed, view = pcall(ports.output_view, capability)
	if not observed or type(view) ~= "table" or type(view.down) ~= "table"
		or next(view.down) ~= nil or not ports_current() then return nil end
	local broker = Custody.new(ports, capability)
	if not broker or not ports_current() then return nil end
	brokers[writer] = broker
	return broker
end

--- Returns only the already-installed owner, never refreshes its epoch.
--- @param writer table Channel identity.
--- @return table|nil broker
function M.for_channel(writer) return brokers[writer] end

--- Drops a retired channel binding after native destroy/close acknowledgement.
--- @param writer table Channel identity.
function M.detach(writer) brokers[writer] = nil end

--- Constructs the explicit recorder-only hook seam, without native authority.
--- @return table broker
function M.controlled() return Custody.new(nil, nil) end

return M
