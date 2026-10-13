--- modules/keylogger/physical_protocol.lua

--- Distinguishes unsupported producers from malformed physical input.
local M = {}
local Wire = require("modules.keylogger.physical_wire")
local Loss = {}
Loss.__index = Loss
function Loss:__tostring() return "Physical stream lost: " .. self.reason end
local Refusal = {}
Refusal.__index = Refusal

--- The stream envelope version, independent of its baseline descriptor version.
M.OPENING_VERSION = 1

--- Formats a stable explanation while retaining a typed machine-readable reason.
---@return string message
function Refusal:__tostring() return self.message end

--- Raises a terminal producer refusal rather than a retryable stream failure.
---@param code string Explicit unavailable reason.
---@param message string Diagnostic explanation.
---@param details table|nil Refusal metadata.
function M.unavailable(code, message, details)
	local failure = { code = code, message = message }
	for key, value in pairs(details or {}) do failure[key] = value end
	error(setmetatable(failure, Refusal), 0)
end

--- Requires a valid version field, classifying unsupported versions explicitly.
---@param kind string Opening or baseline descriptor.
---@param received any Producer version field.
---@param expected integer The version this consumer implements.
function M.require_version(kind, received, expected)
	assert(type(received) == "number" and received % 1 == 0 and received > 0,
		"Invalid physical " .. kind .. " version")
	if received ~= expected then
		M.unavailable("unsupported_" .. kind .. "_version",
			"Unsupported physical " .. kind .. " version", { expected = expected, received = received })
	end
end

--- Recognizes only refusals created by this protocol owner, never error text.
---@param failure any Original protected-call failure.
---@return boolean unavailable
function M.is_unavailable(failure) return getmetatable(failure) == Refusal end

--- Accepts only the actual six-field envelope from the original opened producer.
--- No error text, exit code or caller-created table is a retryable loss.
function M.loss(frame, identity)
	Wire.fields(frame, { "version", "kind", "coverage", "incarnation", "lease", "reason" })
	M.require_version("loss", frame.version, M.OPENING_VERSION)
	assert(frame.kind == "lost" and frame.coverage == identity.coverage
		and frame.incarnation == identity.incarnation and frame.lease == identity.lease,
		"Physical loss identity was refused")
	assert(frame.reason == "overflow" or frame.reason == "sequence_exhausted"
		or frame.reason == "interrupted", "Unknown physical loss reason")
	error(setmetatable({ reason = frame.reason }, Loss), 0)
end

function M.is_loss(failure) return getmetatable(failure) == Loss end

return M
