--- adapters/apple_shortcuts_native.lua

--- ==============================================================================
--- MODULE: Signed Native Apple Shortcut Query Transport
--- DESCRIPTION:
--- Uses only the bundle-bound signed launcher and its native retirement protocol.
--- Structured data is private until the owned query group and helper settle.
--- Discovery is observable; the public service supplies no cancellation receipt.
--- ==============================================================================

local M = {}
local Helper = require("platform.remap.lease_helper")
local Shell = require("adapters.shell_runner")
local Owner = require("adapters.apple_shortcuts")
local Parameter = require("program_parameter")
local Json = require("json")
local hs = hs
local _active = {}
local PROTOCOL_BYTES = 90000

local function number(value)
	if type(value) ~= "number" or value < 0 or value ~= value then return nil end
	if type(math.type) == "function" and math.type(value) == "integer" then return tostring(value) end
	if value > 9007199254740991 then return nil end
	return string.format("%.17g", value)
end

local function identity(path)
	path = path or "/usr/bin/shortcuts"
	local ok, token = pcall(function()
		local first = hs.fs.symlinkAttributes(path)
		if type(first) ~= "table" or first.mode ~= "file" or type(first.permissions) ~= "string"
			or not first.permissions:find("x", 1, true) or hs.fs.pathToAbsolute(path) ~= path then return nil end
		local function fingerprint(value)
			if type(value) ~= "table" or value.mode ~= "file" then return nil end
			local parts = { path, value.permissions }
			for _, key in ipairs({ "dev", "ino", "uid", "gid", "size", "modification", "change" }) do
				local item = number(value[key]); if not item then return nil end
				parts[#parts + 1] = item
			end
			return table.concat(parts, "\n")
		end
		local captured = fingerprint(first)
		if not captured or fingerprint(hs.fs.attributes(path)) ~= captured
			or fingerprint(hs.fs.symlinkAttributes(path)) ~= captured or hs.fs.pathToAbsolute(path) ~= path then return nil end
		return captured
	end)
	return ok and token and { executable = path, token = token } or nil
end

local function query_helper()
	local ok, launcher = pcall(Helper.resolve)
	if not ok or type(launcher) ~= "string" or launcher:sub(-12) ~= "/ErgoptiPlus" then return nil end
	local helper = launcher:sub(1, -12) .. "ErgoptiAutomationQuery"
	local captured = identity(helper)
	return captured and helper or nil, captured
end

--- Reports shipped transport prerequisites without launching or granting consent.
--- @return boolean available
function M.available()
	local helper = query_helper()
	return type(helper) == "string" and type(hs) == "table" and type(hs.base64) == "table"
		and type(hs.base64.decode) == "function" and type(hs.task) == "table"
		and type(hs.task.new) == "function" and next(_active) == nil
end

local function query(request, done, admitted)
	if next(_active) ~= nil then return nil end
	local helper, captured_helper = query_helper()
	if not helper then return nil end
	local handle, raw, observers = {}, nil, {}
	local buffer, bytes, rows, payload = "", 0, 0, nil
	local held, receipt, status, physical, invalid, cancelled = false, false, nil, false, false, false
	local starting, started, finalized = false, false, false
	local function settled() return finalized or physical and receipt and not invalid and not starting and buffer == "" end
	local function notify()
		if finalized or not settled() then return end
		finalized = true; _active[handle] = nil
		local current_helper = identity(helper)
		local unchanged = current_helper and current_helper.token == captured_helper.token
		pcall(done, not cancelled and unchanged and status == 0 and payload and 0 or 1, unchanged and payload or nil, "")
		for _, callback in ipairs(observers) do pcall(callback) end
		observers = {}
	end
	local function cancel()
		cancelled = true
		if not raw then return false end
		if not started then
			local accepted = raw.terminate() == true
			physical, receipt, status = raw.isSettled() == true, true, nil
			notify(); return accepted
		end
		if physical then notify(); return settled() end
		return raw.close_input() == true
	end
	local function fail() invalid = true; payload, buffer = nil, ""; cancel() end
	local function allowed()
		local current = identity(helper)
		if not current or current.token ~= captured_helper.token then return false end
		if type(admitted) ~= "function" then return true end
		local called, ready = pcall(admitted)
		return called and ready == true and not cancelled
	end
	local function line(value)
		rows = rows + 1
		if rows > 5 or receipt or invalid then fail(); return end
		if value == "Q1 HELD" and not held then
			held = true
			if not allowed() or cancelled or raw.set_input("ACTIVATE\n") ~= true then cancel() end
		elseif value:sub(1, 8) == "Q1 DATA " and held and not payload then
			local called, decoded = pcall(hs.base64.decode, value:sub(9))
			if not called or type(decoded) ~= "string" or #decoded > Owner.MAX_BYTES then fail(); return end
			payload = decoded
		elseif value:match("^Q1 PENDING %d+$") then cancel()
		else
			local retired, refused = value:match("^Q1 RETIRED (%d+)$"), value:match("^Q1 REFUSED (%d+)$")
			local text = retired or refused; local code = tonumber(text)
			if not text or not code or tostring(code) ~= text or code > (retired and 255 or 2147483647)
				or refused and held then fail(); return end
			receipt, status = true, retired and code or nil
		end
	end
	local queued = {}
	local function consume(stdout, stderr)
		if finalized then return end
		if stderr ~= nil and stderr ~= "" then fail(); return end
		if stdout == nil or stdout == "" then return end
		if type(stdout) ~= "string" then fail(); return end
		bytes = bytes + #stdout
		if bytes > PROTOCOL_BYTES then fail(); return end
		if starting then queued[#queued + 1] = stdout; return end
		buffer = buffer .. stdout
		while true do
			local newline = buffer:find("\n", 1, true)
			if not newline then break end
			local value = buffer:sub(1, newline - 1); buffer = buffer:sub(newline + 1)
			line(value)
		end
		notify()
	end
	local args = { "--automation-query-worker", request.operation, tostring(request.nonce) }
	if request.id then args[#args + 1] = request.id end
	-- Reserve before native construction can reenter another picker/consumer.
	_active[handle] = true
	raw = Shell.spawn(helper, args, function(code, stdout, stderr)
		consume(stdout, stderr)
		physical = true
		if code ~= 0 then invalid = true end
		notify()
	end, function(_, stdout, stderr) consume(stdout, stderr); return true end, nil, true, true, PROTOCOL_BYTES)
	if type(raw) ~= "table" then return nil end
	raw.onSettled(function() physical = true; notify() end)
	function handle.start()
		if started or cancelled or not allowed() then cancel(); return false end
		starting, started = true, true
		local accepted = raw.start() == true
		starting = false
		local pending = queued; queued = {}
		for _, value in ipairs(pending) do bytes = bytes - #value; consume(value, "") end
		if not accepted then cancel() end
		notify(); return accepted and not cancelled and not invalid
	end
	function handle.terminate()
		if settled() then return true, "settled" end
		local accepted = cancel()
		return accepted, settled() and "settled" or accepted and "pending" or "refused"
	end
	function handle.isSettled() return settled() end
	function handle.hasCleanupDebt() return not settled() and (cancelled or invalid or physical) end
	function handle.onSettled(callback)
		if type(callback) ~= "function" then return false end
		if settled() then pcall(callback) else observers[#observers + 1] = callback end
		return true
	end
	return handle
end

--- Creates one actual picker owner; service retirement is unsupported by this API.
--- @return table|nil owner
function M.create()
	if not M.available() then return nil, "ports_unavailable" end
	return Owner.new({
		qualified = function(role) return role == "discovery" and M.available() end,
		identity = identity,
		query = query,
		-- The native role is readonly. No fire-and-forget run path is substituted.
		invoke = function() return nil end,
	})
end

--- Identifies only the canonical chosen-ID descriptor emitted by this provider.
--- @param executable string Existing literal program route.
--- @param arguments table Existing literal argument vector.
--- @return boolean reserved
function M.is_chosen_program(executable, arguments)
	return executable == "/usr/bin/shortcuts" and type(arguments) == "table"
		and arguments[1] == "run"
end

--- Revalidates a persisted chosen ID through the actual native role, then refuses
--- invocation because no remote service retirement receipt is defined by this API.
--- @param executable string Canonical native route.
--- @param arguments table Persisted literal arguments.
--- @param terminal function Closed business refusal after local query retirement.
--- @param admitted function Current consumer/source admission predicate.
--- @return table|nil handle Exact native query owner.
function M.revalidate_program(executable, arguments, terminal, admitted)
	local scalar = Json.encode({ version = 1, executable = executable, arguments = Json.array(arguments) })
	if not Parameter.parse(scalar, "hs") or not M.is_chosen_program(executable, arguments)
		or #arguments ~= 2 or not Owner.valid_identifier(arguments[2]) then return nil end
	local captured = identity()
	if not captured then return nil end
	local function allowed()
		local current = identity()
		local ok, ready = pcall(admitted)
		return current and current.token == captured.token and ok and ready == true
	end
	return query({ nonce = 1, operation = "revalidate", id = arguments[2] }, function(code, raw)
		-- Even observed ID presence cannot authorize remote automation execution.
		local packet = code == 0 and Owner.validate_reply(raw, {
			nonce = 1, operation = "revalidate", id = arguments[2],
		})
		local verified = packet ~= nil and allowed()
		terminal(false, nil, verified and "service_retirement_unqualified" or "query_refused")
	end, allowed)
end

return M
