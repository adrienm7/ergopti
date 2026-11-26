--- core/network/engine/managed_http_protocol.lua

--- ==============================================================================
--- MODULE: Managed HTTP Worker Protocol (macOS)
--- DESCRIPTION:
--- Pure reader and writer of the launcher's native HTTP worker protocol
--- (launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift, role
--- --managed-http-worker): the request it reads on stdin, the frames it writes
--- on stdout, and the managed-network receipt each of its closed terminal
--- reasons proves.
---
--- FEATURES & RATIONALE:
--- 1. One owner of the reason → receipt table: the update check (UPD-13) and
---    the Versions-window staging script (UPD-11) both read the worker's closed
---    reasons, so both map them here, never twice.
--- 2. Native evidence only: the worker classifies the NSURLSession and CFNetwork
---    error codes itself (managedHTTPFailure). A reason this table does not name
---    proves nothing and gives an empty receipt, which the shared contract
---    (_shared/core/network/engine/failure.lua) classifies as unknown. No text
---    is ever read for a cause.
--- 3. Fail fast: a stream that is not exactly one optional head, its body and
---    one terminal frame is refused whole; a truncated pipe never becomes a
---    successful empty answer.
--- 4. PURE Lua (5.4): no hs, no io, no OS calls.
--- ==============================================================================

local Json = require("core.text.engine.json")

local M = {}

-- Frame tags of ManagedHTTPFrame: the response head, a body chunk, the terminal
M.TAG_HEAD = 72
M.TAG_BODY = 68
M.TAG_TERMINAL = 67

-- A frame's length prefix: big-endian, counting the tag byte
local PREFIX_FORMAT = ">I4"
local PREFIX_BYTES = string.packsize(PREFIX_FORMAT)

-- ManagedHTTPFrame.maximumPayload: a frame's payload is strictly below it
M.MAXIMUM_PAYLOAD = 65536

-- ManagedHTTPRequest.parse admits at most this many request headers
M.MAXIMUM_HEADERS = 128

-- The managed-network receipt (_shared/core/network/data/managed_network.json
-- fields) each closed reason proves: the worker's terminal reasons, and the
-- file reasons its bootstrap download adds (ManagedBootstrapDownload.swift).
-- Only offline, certificate and proxy name a cause; the others are recorded
-- with an unknown provenance, so the contract names none.
local RECEIPTS = {
	offline = { backend = "urlsession", stage = "connect", failure_provenance = "verified",
		network_status = "disconnected" },
	certificate = { backend = "urlsession", stage = "tls", failure_provenance = "verified",
		tls_verification = "enforced", tls_status = "untrusted_certificate" },
	proxy = { backend = "urlsession", stage = "proxy_resolve", failure_provenance = "verified",
		proxy_resolution_status = "unavailable" },
	connect = { backend = "urlsession", stage = "connect", failure_provenance = "unknown" },
	http = { backend = "urlsession", stage = "http", failure_provenance = "unknown" },
	file_create = { backend = "native_fs", stage = "file_create", failure_provenance = "unknown" },
	file_write = { backend = "native_fs", stage = "file_write", failure_provenance = "unknown" },
	file_publish = { backend = "native_fs", stage = "file_rename", failure_provenance = "unknown" },
	cleanup = { backend = "native_fs", stage = "file_remove", failure_provenance = "unknown" },
}

--- The receipt one closed worker reason proves: a fresh copy, or an empty
--- receipt (an unknown cause) for a reason this table does not name.
--- @param reason any The terminal frame's reason.
--- @return table receipt Fields of managed_network.json.
function M.failure_receipt(reason)
	local receipt = {}
	local known = type(reason) == "string" and RECEIPTS[reason] or nil
	if known then
		for key, value in pairs(known) do receipt[key] = value end
	end
	return receipt
end

--- The exact request bytes the worker reads on stdin. Header names are kept
--- in sorted order so one request always encodes to the same bytes.
--- @param url string Absolute https URL.
--- @param headers table|nil Name → value.
--- @param seconds integer The request's budget and idle bound, which the
---   worker requires to equal its two arguments.
--- @return string|nil json
--- @return string|nil error
function M.encode_request(url, headers, seconds)
	if type(url) ~= "string" or not url:match("^https://[^/%s]+") then
		return nil, "the managed HTTP worker needs an absolute https URL"
	end
	if math.type(seconds) ~= "integer" or seconds <= 0 then
		return nil, "the managed HTTP worker needs a positive whole number of seconds"
	end
	local names, seen = {}, {}
	for name, value in pairs(headers or {}) do
		if type(name) ~= "string" or type(value) ~= "string" then
			return nil, "request headers must be strings"
		end
		local lower = name:lower()
		if seen[lower] then return nil, "duplicate request header " .. name end
		seen[lower] = true
		names[#names + 1] = name
	end
	if #names > M.MAXIMUM_HEADERS then return nil, "too many request headers" end
	table.sort(names)
	local pairs_list = {}
	for index, name in ipairs(names) do pairs_list[index] = Json.array({ name, headers[name] }) end
	local encoded = Json.encode({
		version = 1, url = url, method = "GET", headers = Json.array(pairs_list),
		timeout = seconds, idle_timeout = seconds, direct = false,
	})
	if type(encoded) ~= "string" or #encoded > M.MAXIMUM_PAYLOAD then
		return nil, "the request does not fit the worker's input bound"
	end
	return encoded
end

--- Splits the worker's stdout into frames.
--- @param bytes string
--- @return table|nil frames { tag, payload }
--- @return string|nil error
local function split_frames(bytes)
	local frames, offset = {}, 1
	while offset <= #bytes do
		if offset + PREFIX_BYTES > #bytes then return nil, "a truncated frame prefix" end
		local count = string.unpack(PREFIX_FORMAT, bytes, offset)
		if count < 1 or count > M.MAXIMUM_PAYLOAD then return nil, "a frame length out of bounds" end
		local tag_at = offset + PREFIX_BYTES
		local finish = tag_at + count - 1
		if finish > #bytes then return nil, "a truncated frame" end
		frames[#frames + 1] = { tag = bytes:byte(tag_at), payload = bytes:sub(tag_at + 1, finish) }
		offset = finish + 1
	end
	return frames
end

--- Reads the head frame's JSON.
--- @param payload string
--- @return table|nil head { status, headers }
local function read_head(payload)
	local head = Json.decode(payload)
	if type(head) ~= "table" or head.version ~= 1 or math.type(head.status) ~= "integer"
		or head.status < 100 or head.status > 599 or type(head.headers) ~= "table" then return nil end
	local headers = {}
	for _, pair in ipairs(head.headers) do
		if type(pair) ~= "table" or #pair ~= 2 or type(pair[1]) ~= "string" or type(pair[2]) ~= "string"
			or headers[pair[1]] ~= nil then return nil end
		headers[pair[1]] = pair[2]
	end
	return { status = head.status, headers = headers }
end

--- Reads the terminal frame's JSON.
--- @param payload string
--- @return table|nil terminal { success, reason, stage }
local function read_terminal(payload)
	local terminal = Json.decode(payload)
	if type(terminal) ~= "table" or terminal.version ~= 1 or type(terminal.success) ~= "boolean"
		or type(terminal.reason) ~= "string" or not terminal.reason:match("^[a-z_]+$") then return nil end
	local stage = terminal.native_refusal_stage
	if stage ~= nil and (type(stage) ~= "string" or not stage:match("^native_[a-z_]+$")) then return nil end
	if terminal.success ~= (terminal.reason == "complete") then return nil end
	return { success = terminal.success, reason = terminal.reason, stage = stage }
end

--- Decodes one complete worker stdout: an optional head, the body chunks after
--- it, and exactly one terminal frame, last.
--- @param bytes string The worker's whole stdout.
--- @return table|nil response { status|nil, headers|nil, body, terminal = { success, reason, stage } }
--- @return string|nil error
function M.decode(bytes)
	if type(bytes) ~= "string" then return nil, "no worker output" end
	local frames, split_error = split_frames(bytes)
	if not frames then return nil, split_error end
	local head, terminal, body = nil, nil, {}
	for index, frame in ipairs(frames) do
		if terminal then return nil, "a frame after the terminal frame" end
		if frame.tag == M.TAG_HEAD then
			if head or #body > 0 then return nil, "a second or late response head" end
			head = read_head(frame.payload)
			if not head then return nil, "a malformed response head" end
		elseif frame.tag == M.TAG_BODY then
			if not head then return nil, "a body chunk before the response head" end
			body[#body + 1] = frame.payload
		elseif frame.tag == M.TAG_TERMINAL then
			terminal = read_terminal(frame.payload)
			if not terminal then return nil, "a malformed terminal frame" end
			if index ~= #frames then return nil, "a frame after the terminal frame" end
		else
			return nil, "an unknown frame tag " .. tostring(frame.tag)
		end
	end
	if not terminal then return nil, "no terminal frame" end
	if terminal.success and not head then return nil, "a success without a response head" end
	return {
		status = head and head.status or nil,
		headers = head and head.headers or nil,
		body = table.concat(body),
		terminal = terminal,
	}
end

--- The HTTP port result (core/network/adapters/http_client.lua's shape) of
--- one finished worker: { ok, status, body, headers, error, failure_receipt }.
--- A failed transfer carries status 0, its English cause and the receipt its
--- closed reason proves; a stream that does not decode carries no receipt.
--- @param exit_code any The worker's exit status.
--- @param bytes string|nil Its whole stdout.
--- @return table result
function M.result(exit_code, bytes)
	local response, decode_error = M.decode(bytes)
	if not response then
		return { ok = false, status = 0, headers = {},
			error = string.format("the managed HTTP worker exited %s with %s", tostring(exit_code), decode_error) }
	end
	local terminal = response.terminal
	if terminal.success then
		if exit_code ~= 0 then
			return { ok = false, status = 0, headers = {},
				error = string.format("the managed HTTP worker exited %s after a complete answer", tostring(exit_code)) }
		end
		return { ok = response.status >= 200 and response.status <= 299, status = response.status,
			body = response.body, headers = response.headers }
	end
	return { ok = false, status = 0, headers = {},
		error = string.format("native %s%s (exit %s)", terminal.reason,
			terminal.stage and (" at " .. terminal.stage) or "", tostring(exit_code)),
		failure_receipt = M.failure_receipt(terminal.reason) }
end

return M
