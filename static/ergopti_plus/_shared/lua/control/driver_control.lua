--- _shared/lua/control/driver_control.lua

--- ==============================================================================
--- MODULE: Local Driver Control Policy (shared Lua)
--- DESCRIPTION:
--- The pure half of the local reload command shared by the macOS and Linux
--- drivers; windows/infra/driver_control.ahk is its AutoHotkey port and the
--- corpus under _shared/tests/corpus/control pins both. The declaration is
--- _shared/modules/control/driver_control.json.
---
--- FEATURES & RATIONALE:
--- 1. Authentication by a private token. The driver publishes a random token in
---    a session file inside a folder only its user can read; a request that does
---    not carry that exact token is refused, compared in constant time.
--- 2. Three separate outcomes. A result is "requested" (handed to the reload
---    owner), "refused" (with a closed reason) or "completed". The texts are
---    built here, byte for byte, so the three drivers and the tools agree.
--- 3. Completion belongs to the successor. Only the reloaded driver, once ready,
---    turns a pending result that names it as the successor into "completed":
---    the requester never takes a launch or an exit for a finished reload.
--- ==============================================================================

local M = {}

local NativePath = require("native_path")

local SPEC_KEYS = { "_comment", "schema", "max_request_bytes", "token_hex_length", "request_id_pattern",
	"files", "folders", "windows_message", "states", "reasons", "pending_ttl_seconds", "timeout_reason" }
local REQUEST_KEYS = { schema = true, token = true, request_id = true }
local RESULT_KEYS = { schema = true, request_id = true, state = true, driver_pid = true,
	successor_pid = true, reason = true, deadline = true }

-- The declared request_id pattern, as a Lua pattern: the JSON spells the same
-- character class in regular-expression syntax for the AHK port and the tools.
local REQUEST_ID_CLASS = "^[%w_%-]+$"
local REQUEST_ID_MAX = 64





-- ==============================
-- ==============================
-- ======= 1/ Declaration =======
-- ==============================
-- ==============================

local function is_integer(value)
	return type(value) == "number" and value == value and value % 1 == 0
end

local function list_set(list, where)
	if type(list) ~= "table" or #list == 0 then error("driver control: " .. where .. " must be a nonempty list", 2) end
	local set = {}
	for _, item in ipairs(list) do
		if type(item) ~= "string" or item == "" or set[item] then
			error("driver control: " .. where .. " holds an invalid or duplicate name", 2)
		end
		set[item] = true
	end
	return set
end

--- Validates the decoded declaration; a malformed one stops the caller.
--- @param spec table Decoded driver_control.json.
--- @return table spec The same table, with `state_set` and `reason_set` added.
function M.validate(spec)
	if type(spec) ~= "table" then error("driver control: the declaration is not an object", 2) end
	local allowed = {}
	for _, key in ipairs(SPEC_KEYS) do allowed[key] = true end
	for key in pairs(spec) do
		if not allowed[key] then error("driver control: unknown declaration key " .. tostring(key), 2) end
	end
	if spec.schema ~= 1 then error("driver control: unsupported declaration schema", 2) end
	if not is_integer(spec.max_request_bytes) or spec.max_request_bytes < 128 then
		error("driver control: max_request_bytes must be an integer of at least 128", 2)
	end
	if spec.token_hex_length ~= 64 then error("driver control: token_hex_length must be 64", 2) end
	if spec.request_id_pattern ~= "^[A-Za-z0-9_-]{1,64}$" then
		error("driver control: request_id_pattern differs from the policy this module enforces", 2)
	end
	local files = spec.files
	for _, key in ipairs({ "session", "request", "result" }) do
		if type(files) ~= "table" or type(files[key]) ~= "string" or not files[key]:match("^[%w_.]+$") then
			error("driver control: files." .. key .. " must be a plain file name", 2)
		end
	end
	for _, platform in ipairs({ "windows", "macos", "linux" }) do
		local folder = type(spec.folders) == "table" and spec.folders[platform] or nil
		if type(folder) ~= "table" or type(folder.base) ~= "string" or folder.base == ""
			or type(folder.segments) ~= "table" or #folder.segments == 0 then
			error("driver control: folders." .. platform .. " needs a base and segments", 2)
		end
	end
	if type(spec.windows_message) ~= "string" or spec.windows_message == "" then
		error("driver control: windows_message must be named", 2)
	end
	spec.state_set = list_set(spec.states, "states")
	spec.reason_set = list_set(spec.reasons, "reasons")
	for _, state in ipairs({ "requested", "claimed", "refused", "completed", "timeout" }) do
		if not spec.state_set[state] then error("driver control: state " .. state .. " is not declared", 2) end
	end
	if not is_integer(spec.pending_ttl_seconds) or spec.pending_ttl_seconds < 10 or spec.pending_ttl_seconds > 3600 then
		error("driver control: pending_ttl_seconds must be an integer from 10 to 3600", 2)
	end
	if type(spec.timeout_reason) ~= "string" or not spec.reason_set[spec.timeout_reason] then
		error("driver control: timeout_reason must be a declared reason", 2)
	end
	return spec
end

--- The control folder of one platform, or nil when its base is not set.
--- @param spec table Validated declaration.
--- @param platform string "windows", "macos" or "linux".
--- @param getenv function Environment reader.
--- @param app_folder string The application folder name (app_dirs).
--- @param separator string Path separator.
--- @return string|nil folder, string|nil reason
function M.folder(spec, platform, getenv, app_folder, separator)
	local declared = spec.folders[platform]
	if declared == nil then error("driver control: no folder for " .. tostring(platform), 2) end
	local base = getenv(declared.base)
	if type(base) ~= "string" or base == "" then return nil, declared.base .. " is not set" end
	local parts = { NativePath.without_trailing_separators(base) }
	for _, segment in ipairs(declared.segments) do
		parts[#parts + 1] = segment == "{app}" and app_folder or segment
	end
	return table.concat(parts, separator)
end





-- ===========================
-- ===========================
-- ======= 2/ Requests =======
-- ===========================
-- ===========================

--- Whether text is a token of the declared shape: lowercase hexadecimal.
--- @param spec table
--- @param text any
--- @return boolean
function M.is_token(spec, text)
	return type(text) == "string" and #text == spec.token_hex_length and text:match("^[0-9a-f]+$") ~= nil
end

--- Compares two tokens without stopping at the first differing character.
--- @param a string
--- @param b string
--- @return boolean
function M.same_token(a, b)
	if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
	local diff = 0
	for index = 1, #a do
		if a:byte(index) ~= b:byte(index) then diff = diff + 1 end
	end
	return diff == 0
end

local function is_request_id(value)
	return type(value) == "string" and #value >= 1 and #value <= REQUEST_ID_MAX
		and value:match(REQUEST_ID_CLASS) ~= nil
end

--- Admits one request text against the session token.
--- @param spec table Validated declaration.
--- @param text string Raw request bytes.
--- @param token string This session's token.
--- @param json_decode function Decoder returning a table or raising.
--- @return string|nil request_id, string|nil reason, string|nil echoed_id
---   On refusal, reason is "malformed" or "unauthenticated" and echoed_id the
---   request's own valid identifier when it had one.
function M.parse_request(spec, text, token, json_decode)
	if not M.is_token(spec, token) then error("driver control: the session token is malformed", 2) end
	if type(text) ~= "string" or #text == 0 or #text > spec.max_request_bytes then return nil, "malformed" end
	local ok, request = pcall(json_decode, text)
	if not ok or type(request) ~= "table" then return nil, "malformed" end
	local echoed = is_request_id(request.request_id) and request.request_id or nil
	for key in pairs(request) do
		if not REQUEST_KEYS[key] then return nil, "malformed", echoed end
	end
	-- The raw text must spell the schema as the integer itself: a decoder may
	-- read true or 1.0 as the same value, and the AutoHotkey port cannot tell.
	local integer_schema = text:match('"schema"%s*:%s*' .. spec.schema .. '%s*[,}]') ~= nil
	if request.schema ~= spec.schema or not integer_schema or not echoed or type(request.token) ~= "string" then
		return nil, "malformed", echoed
	end
	if not M.is_token(spec, request.token) or not M.same_token(request.token, token) then
		return nil, "unauthenticated", echoed
	end
	return echoed
end





-- ==========================
-- ==========================
-- ======= 3/ Results =======
-- ==========================
-- ==========================

--- The session file text the requester reads.
--- @param spec table
--- @param driver string "windows", "macos" or "linux".
--- @param pid integer Driver process id.
--- @param token string Fresh session token.
--- @return string text
function M.session_text(spec, driver, pid, token)
	if spec.folders[driver] == nil then error("driver control: unknown driver " .. tostring(driver), 2) end
	if not is_integer(pid) or pid <= 0 then error("driver control: the session needs a process id", 2) end
	if not M.is_token(spec, token) then error("driver control: the session token is malformed", 2) end
	return string.format('{"schema":%d,"driver":"%s","pid":%d,"token":"%s"}\n', spec.schema, driver, pid, token)
end

--- Builds one result text; an inconsistent result stops the caller.
--- A `requested` result either names its successor or, when a restart cannot
--- name it beforehand, carries no successor and a deadline (Unix seconds).
--- @param spec table Validated declaration.
--- @param fields table { request_id = string|nil, state, driver_pid, successor_pid,
---   reason, deadline }
--- @return string text
function M.result_text(spec, fields)
	local state, reason = fields.state, fields.reason
	if not spec.state_set[state] then error("driver control: unknown result state " .. tostring(state), 2) end
	if fields.request_id ~= nil and not is_request_id(fields.request_id) then
		error("driver control: invalid result request id", 2)
	end
	if fields.request_id == nil and state ~= "refused" then
		error("driver control: only a refusal may lack its request id", 2)
	end
	if not is_integer(fields.driver_pid) or fields.driver_pid <= 0 then
		error("driver control: the result needs the writing driver's process id", 2)
	end
	local successor, deadline = fields.successor_pid, fields.deadline
	if deadline ~= nil and (not is_integer(deadline) or deadline <= 0) then
		error("driver control: the deadline must be a positive integer", 2)
	end
	local id = fields.request_id ~= nil and ('"' .. fields.request_id .. '"') or "null"
	local tail
	if state == "refused" or state == "timeout" then
		if successor ~= nil then error("driver control: a " .. state .. " names no successor", 2) end
		if deadline ~= nil then error("driver control: a " .. state .. " carries no deadline", 2) end
		if not spec.reason_set[reason] then error("driver control: unknown refusal reason " .. tostring(reason), 2) end
		-- The deadline reason belongs to the timeout alone, and a timeout takes no other.
		if (state == "timeout") ~= (reason == spec.timeout_reason) then
			error("driver control: reason " .. tostring(reason) .. " does not fit a " .. state, 2)
		end
		tail = string.format(',"reason":"%s"', reason)
	else
		if reason ~= nil then error("driver control: only a refusal carries a reason", 2) end
		if state == "requested" and successor == nil then
			if deadline == nil then error("driver control: a pending request carries its deadline", 2) end
			tail = string.format(',"successor_pid":null,"deadline":%d', deadline)
		else
			if not is_integer(successor) or successor <= 0 then
				error("driver control: a " .. state .. " result names its successor", 2)
			end
			if state == "claimed" then
				if deadline == nil then error("driver control: a claim keeps the deadline", 2) end
			elseif deadline ~= nil then
				error("driver control: a " .. state .. " result carries no deadline", 2)
			end
			if (state == "completed" or state == "claimed") and successor ~= fields.driver_pid then
				error("driver control: " .. state .. " is written by the successor itself", 2)
			end
			tail = string.format(',"successor_pid":%d', successor)
			if state == "claimed" then tail = tail .. string.format(',"deadline":%d', deadline) end
		end
	end
	return string.format('{"schema":%d,"request_id":%s,"state":"%s","driver_pid":%d%s}\n',
		spec.schema, id, state, fields.driver_pid, tail)
end

--- The completion a freshly ready driver owes, or nil.
--- @param spec table Validated declaration.
--- @param text string|nil Current result file bytes.
--- @param own_pid integer This process id.
--- @param json_decode function
--- @return string|nil completed_text
function M.completion(spec, text, own_pid, json_decode)
	if type(text) ~= "string" or text == "" or #text > spec.max_request_bytes then return nil end
	local ok, result = pcall(json_decode, text)
	if not ok or type(result) ~= "table" then return nil end
	for key in pairs(result) do
		if not RESULT_KEYS[key] then return nil end
	end
	if result.schema ~= spec.schema or result.state ~= "requested" or not is_request_id(result.request_id)
		or not is_integer(result.successor_pid) or result.successor_pid ~= own_pid then
		return nil
	end
	return M.result_text(spec, { request_id = result.request_id, state = "completed",
		driver_pid = own_pid, successor_pid = own_pid })
end

--- What a freshly ready driver owes the pending result, if anything.
--- The named-successor rule of `completion` stays; a record without a
--- successor is claimed by the first driver that reads it before its deadline,
--- and past the deadline it becomes a timeout, never a completion.
--- @param spec table Validated declaration.
--- @param text string|nil Current result file bytes.
--- @param own_pid integer This process id.
--- @param now integer Unix time in seconds.
--- @param json_decode function
--- @return string|nil kind "claimed", "completed" or "timeout".
--- @return string|nil text The result to publish.
function M.resolve(spec, text, own_pid, now, json_decode)
	if type(text) ~= "string" or text == "" or #text > spec.max_request_bytes then return nil end
	local ok, result = pcall(json_decode, text)
	if not ok or type(result) ~= "table" then return nil end
	for key in pairs(result) do
		if not RESULT_KEYS[key] then return nil end
	end
	if result.schema ~= spec.schema or not is_request_id(result.request_id) then return nil end
	local function write(state, extra)
		extra.request_id, extra.state, extra.driver_pid = result.request_id, state, own_pid
		return state, M.result_text(spec, extra)
	end
	-- A decoder may answer null with nil or with its own sentinel table.
	local successor_unknown = result.successor_pid == nil or type(result.successor_pid) == "table"
	if result.state == "requested" and successor_unknown then
		-- The raw text must say null: an absent field is a malformed record.
		if not text:find('"successor_pid"%s*:%s*null') or not is_integer(result.deadline) or result.deadline <= 0 then
			return nil
		end
		if now > result.deadline then return write("timeout", { reason = spec.timeout_reason }) end
		return write("claimed", { successor_pid = own_pid, deadline = result.deadline })
	end
	if result.state == "claimed" and result.successor_pid == own_pid and is_integer(result.deadline)
		and result.driver_pid == own_pid then
		if now > result.deadline then return write("timeout", { reason = spec.timeout_reason }) end
		return write("completed", { successor_pid = own_pid })
	end
	local completed = M.completion(spec, text, own_pid, json_decode)
	if completed then return "completed", completed end
	return nil
end

return M
