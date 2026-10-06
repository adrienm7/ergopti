--- modules/gestures/program_owner.lua

--- Private user programs use the shared native worker lifecycle policy.
local Runner = require("adapters.program_runner")
local Worker = require("native_worker_owner")
local Parameter = require("program_parameter")
local Timings = require("infra.timings")
local Logger = require("logger.shim")
local loaded, Native = pcall(require, "luv")
if not loaded then Native = nil end
local M = {}
local LOG = "modules.gestures.program_owner"

function M.available()
	return Runner.supported() and type(Native) == "table" and type(Native.new_timer) == "function"
end

--- Builds the private program policy over native/test IO ports.
--- @param capture function Returns a private scalar and its admission callback.
--- @param ports table|nil Native/test ports, never user configuration.
function M.new(capture, ports)
	ports = ports or {}
	return Worker.new(capture, {
		runner = ports.runner or Runner,
		native = ports.native or Native,
		parse = function(value) return Parameter.parse(value, "linux") end,
		timeout_ms = Timings.ms("gestures", "aux_shell_timeout_ms"),
		retry_ms = Timings.ms("gestures", "aux_shell_cleanup_retry_ms"),
		observed = function(code)
			if code ~= 0 then Logger.error(LOG, "Private user program exited with status %d.", code) end
		end,
	})
end

return M
