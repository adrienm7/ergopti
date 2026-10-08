--- adapters/native_bootstrap_pty.lua

--- ==============================================================================
--- MODULE: Native Bootstrap PTY Adapter
--- DESCRIPTION:
--- Prepares the bundle-bound source fence and private operation receipt for a
--- Python-free bootstrap. Child exit alone never releases native ownership.
--- ==============================================================================

local M = {}
local Helper = require("platform.remap.lease_helper")
local FileSystem = require("adapters.file_system")
local Crypto = require("adapters.crypto")
local Json = require("json")
local Receipt = require("core.llm.native_pty_receipt")
local Logger = require("infra.logger")
local hs = hs
local LOG = "adapters.native_bootstrap_pty"

local function fixed_failure()
	Logger.error(LOG, "Native bootstrap source or receipt operation refused.")
end

local function identity(path)
	local ok, attributes, classification = pcall(FileSystem.classify_no_follow, path)
	if not ok or classification ~= "ok" or type(attributes) ~= "table" or attributes.mode ~= "file"
		or type(attributes.dev) ~= "number" or type(attributes.ino) ~= "number" then return nil end
	return attributes
end

local function matches(path, expected)
	local actual = identity(path)
	return actual ~= nil and expected ~= nil and actual.dev == expected.dev and actual.ino == expected.ino
end

--- Prepares exact private input without spawning a child or changing a venv.
--- A partial descriptor is also returned on failure so cleanup is never lost.
--- @param source_path string Bundle-owned bootstrap pathname.
--- @param environment table Dense key/value pairs for the fixed shell child.
--- @param timeout_ms number Original caller bootstrap budget.
--- @return table|nil handle Private receipt and input owner.
--- @return boolean prepared Exact input ready for native dispatch.
function M.prepare(source_path, environment, timeout_ms)
	if type(source_path) ~= "string" or type(environment) ~= "table"
		or type(timeout_ms) ~= "number" or timeout_ms <= 0 or timeout_ms > 9007199254740991
		or timeout_ms % 1 ~= 0 then return nil, false end
	local count, names = 0, {}
	for index, pair in pairs(environment) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #environment
			or type(pair) ~= "table" or #pair ~= 2 or type(pair[1]) ~= "string" or type(pair[2]) ~= "string"
			or names[pair[1]] or pair[1]:find("\0", 1, true) or pair[2]:find("\0", 1, true) then return nil, false end
		local fields = 0
		for field in pairs(pair) do
			if field ~= 1 and field ~= 2 then return nil, false end
			fields = fields + 1
		end
		if fields ~= 2 or pair[1] == "" then return nil, false end
		count = count + 1
		names[pair[1]] = true
	end
	if count ~= #environment then return nil, false end
	local resolved, executable = pcall(Helper.resolve)
	if not resolved or type(executable) ~= "string" then return nil, false end
	local read_ok, source, read_status = pcall(FileSystem.read_with_status, source_path, fixed_failure)
	if not read_ok or read_status ~= "ok" or type(source) ~= "string" then return nil, false end
	local digest = Crypto.sha256_bytes(source, fixed_failure)
	if type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, false end
	local generated, nonce = pcall(function() return hs.host.uuid() end)
	if not generated or type(nonce) ~= "string" or #nonce ~= 36 or not nonce:match("^[%w%-]+$") then return nil, false end
	local allocated, path = pcall(FileSystem.create_secure_temp_file)
	if not allocated or type(path) ~= "string" then return nil, false end
	local observed = identity(path)
	local attempted, retired, cleaned, expected, cleanup_retry = false, false, false, "", nil
	local handle = { executable = executable, arguments = { "--managed-pty-worker", string.format("%.0f", timeout_ms) } }
	local function cleanup()
		if cleaned then return true end
		if cleanup_retry ~= nil then
			local ok, settled = pcall(cleanup_retry)
			if ok and settled == true then cleaned = true; return true end
			return false
		end
		if not matches(path, observed) then return false end
		local ok, removed, _, _, retry = pcall(FileSystem.remove_if_unchanged,
			path, { status = "ok", content = expected }, fixed_failure,
			function() return matches(path, observed) end)
		if ok and removed == true then cleaned = true; return true end
		if ok and type(retry) == "function" then cleanup_retry = retry end
		return false
	end
	function handle.rollback()
		if attempted then return false end
		return cleanup()
	end
	function handle.bind_input(task)
		if attempted or cleaned or type(handle.input) ~= "string" then return false end
		local ok, assigned = pcall(function() return task:setInput(handle.input) end)
		return ok and assigned == task
	end
	function handle.mark_start_attempted()
		if attempted or cleaned then return false end
		attempted = true
		return true
	end
	function handle.settle(callback_status)
		if cleaned then return true end
		if not attempted then return false end
		if not retired then
			if not matches(path, observed) then return false end
			local current = identity(path)
			if type(current) ~= "table" or type(current.size) ~= "number"
				or current.size > Receipt.maximum_bytes then return false end
			local read_ok, raw, status = pcall(FileSystem.read_with_status, path, fixed_failure)
			if not read_ok or status ~= "ok" or not matches(path, observed)
				or Receipt.retired(raw, Json.decode, nonce, callback_status) ~= true then return false end
			expected, retired = raw, true
		end
		return cleanup()
	end
	if not observed or observed.size ~= 0 then return handle, false end
	local pairs = {}
	for index, pair in ipairs(environment) do pairs[index] = Json.array(pair) end
	local encoded, input = pcall(Json.encode, {
		version = 1, source_path = source_path, source_sha256 = digest,
		environment = Json.array(pairs), timeout_ms = timeout_ms, receipt_path = path, nonce = nonce,
	})
	if not encoded or type(input) ~= "string" or #input > 65535 then return handle, false end
	handle.input = input .. "\n"
	return handle, true
end

return M
