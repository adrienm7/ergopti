--- adapters/process_runner.lua

--- ==============================================================================
--- MODULE: Asynchronous Process Runner (Linux)
--- DESCRIPTION:
--- Preserves the layout client's argv/result API while the canonical native
--- owner retains child exit, process-group absence and every handle close ACK.
--- Shutdown closes admission before cancelling the captured operations; no
--- callback can restart an installer or publish UI after that boundary.
--- ==============================================================================

local M = {}
local Logger = require("logger.shim")
local ShellRunner = require("adapters.shell_runner")
local OwnedProcess = require("adapters.owned_process")
local available, Native = pcall(require, "luv")
if not available then Native = nil end

local LOG = "adapters.process_runner"
local DEFAULT_TIMEOUT_MS = 30000
local DEFAULT_MAX_OUTPUT_BYTES = 65536
local claims = {}
local stopping = false

M.HAS_ASYNC = Native ~= nil




-- ====================================
-- ====================================
-- ======= 1/ Result Delivery ==========
-- ====================================
-- ====================================

--- Preserves the public result vocabulary without losing native ENOENT.
--- @param claim table Originating command and limits.
--- @param result table Canonical physically settled result.
--- @return table
local function public_result(claim, result)
	local operation = claim.operation
	local reason = result.error
	local code = tonumber(result.exit_code) or -1
	if reason == "native process dispatch failed" then
		reason = "cannot start " .. claim.program .. ": native process dispatch failed"
	elseif reason == "native handle allocation failed" then
		reason = "libuv handle allocation failed"
	elseif reason == "native output watch refused" or reason == "native process deadline refused" then
		reason = "process supervision could not start"
		code = -1
	elseif reason == "native process group outlived leader" then
		reason = claim.program .. " did not finish: native process group outlived leader"
	elseif reason == "process deadline exceeded" then
		reason = claim.program .. " did not finish within " .. tostring(claim.timeout_ms) .. " ms"
		code = -1
	elseif reason == "process output exceeds its bound" then
		reason = claim.program .. " output exceeds its limit"
		code = -1
	elseif reason == "process exited unsuccessfully" then
		reason = claim.program .. " exited with code " .. tostring(code)
	end
	return { exit_code = code, stdout = result.stdout or "", stderr = result.stderr or "",
		error = reason, not_found = operation and operation.not_found == true or false }
end

--- Releases a settled claim before any business callback can reenter.
--- @param claim table Exact retained constructor/operation.
local function retire(claim)
	if claim.constructing or claim.uncertain or not claims[claim] then return end
	local operation = claim.operation
	if not operation or operation:is_settled() ~= true then return end
	claims[claim] = nil
	if stopping or claim.delivered or not claim.result then return end
	claim.delivered = true
	local ok, err = pcall(claim.callback, public_result(claim, claim.result))
	if not ok then Logger.error(LOG, "Process callback raised: %s.", tostring(err)) end
end




-- ====================================
-- ====================================
-- ======= 2/ Public API ==============
-- ====================================
-- ====================================

--- Runs one program without blocking the daemon's grabbed keyboard.
--- Normal success/error callbacks occur exactly once after physical retirement.
--- Terminal shutdown cancels delivery and permanently refuses new admission.
--- @param program string Executable name or absolute path.
--- @param args table String argument vector.
--- @param options table|nil { timeout_ms?, max_output_bytes? }
--- @param callback function Receives { exit_code, stdout, stderr, error, not_found }.
--- @return boolean dispatched Whether process supervision was admitted.
function M.run(program, args, options, callback)
	if type(callback) ~= "function" then error("ProcessRunner.run(): callback must be a function", 2) end
	if stopping then return false end
	local function reject(message)
		Logger.error(LOG, "Cannot run %s: %s.", tostring(program), message)
		if not stopping then pcall(callback, { exit_code = -1, stdout = "", stderr = "", error = message, not_found = false }) end
		return false
	end
	local refusal = ShellRunner.validate_spawn_args(program, args)
	if refusal ~= "" then return reject("argument vector refused: " .. refusal) end
	if not Native or type(Native.update_time) ~= "function" then return reject("asynchronous processes are unavailable") end
	options = type(options) == "table" and options or {}
	local claim = { program = program, callback = callback, constructing = true,
		timeout_ms = tonumber(options.timeout_ms) or DEFAULT_TIMEOUT_MS }
	claims[claim] = true
	-- Anchor only a new operation's relative deadline. A stalled old uv clock
	-- must never consume the next installer's budget before its first tick.
	local refreshed = pcall(Native.update_time)
	if not refreshed or stopping then
		claim.constructing = false
		claims[claim] = nil
		return stopping and false or reject("process supervision could not start")
	end
	local called, operation = pcall(OwnedProcess.start, program, args, {
		owner = "process_runner:" .. tostring(claim), timeout_ms = claim.timeout_ms,
		max_output_bytes = tonumber(options.max_output_bytes) or DEFAULT_MAX_OUTPUT_BYTES,
		authorized = function() return not stopping and claims[claim] == true end,
	}, function(result)
		claim.result = result
		retire(claim)
	end)
	claim.constructing = false
	if not called or type(operation) ~= "table" then
		-- A throwing constructor may already have acquired native resources.
		-- Keep this uncertain debt; no result can manufacture physical ACK.
		claim.uncertain = true
		Logger.error(LOG, "Process constructor did not return its native owner.")
		return false
	end
	claim.operation = operation
	operation:on_settled(function() retire(claim) end)
	if stopping then operation:cancel() end
	retire(claim)
	return not stopping and operation.started == true and operation.error == nil
end

--- Reports retained constructor/process debt without changing admission.
--- @return boolean
function M.is_settled() return next(claims) == nil end

--- Permanently closes admission and retains every native cancellation until ACK.
--- @return boolean acknowledged Child exit, group absence and all close callbacks.
function M.shutdown()
	stopping = true
	local captured = {}
	for claim in pairs(claims) do captured[#captured + 1] = claim end
	for _, claim in ipairs(captured) do
		local operation = claim.operation
		if operation and claims[claim] then
			local ok = pcall(operation.cancel, operation)
			if not ok then pcall(Logger.error, LOG, "Process cancellation did not return its native receipt.") end
			retire(claim)
		end
	end
	return next(claims) == nil
end

return M
