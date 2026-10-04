--- modules/keylogger/physical_protocol.lua

--- Distinguishes unsupported producers from malformed physical input.
local M = {}
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

return M
