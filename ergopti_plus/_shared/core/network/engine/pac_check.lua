--- _shared/core/network/engine/pac_check.lua

--- ==============================================================================
--- MODULE: Shared PAC Reachability Check
--- DESCRIPTION:
--- Judges the answer of a proxy auto-config (PAC) URL the way the managed
--- downloader does: HTTP 200, a bounded size, strict UTF-8 and a
--- FindProxyForURL function. The probes of the three drivers fetch the PAC and
--- share this verdict, so the diagnostics name the step that would fail instead
--- of a generic network error (issue #101). The PAC URL itself is never part of
--- the verdict: it names the company's intranet.
---
--- FEATURES & RATIONALE:
--- 1. The size limit mirrors native_pac.max_script_bytes of proxy_policy.json.
--- 2. UTF-8 is validated byte by byte because LuaJIT has no utf8 library.
--- 3. A UTF-8 or UTF-16 byte-order mark is accepted, as the managed fetch does.
--- ==============================================================================

local Utf8 = require("core.lifecycle.engine.compat.utf8")
local M = {}

M.MAX_BYTES = 1048576

--- Whether `text` is strictly valid UTF-8 (no overlong form, no surrogate).
--- @param text string
--- @return boolean
local function valid_utf8(text)
	local index, size = 1, #text
	while index <= size do
		local first = text:byte(index)
		local extra, minimum
		if first < 0x80 then
			extra, minimum = 0, 0
		elseif first >= 0xC2 and first <= 0xDF then
			extra, minimum = 1, 0x80
		elseif first >= 0xE0 and first <= 0xEF then
			extra, minimum = 2, 0x800
		elseif first >= 0xF0 and first <= 0xF4 then
			extra, minimum = 3, 0x10000
		else
			return false
		end
		local code = extra == 0 and first or (first % (2 ^ (6 - extra)))
		for offset = 1, extra do
			local byte = text:byte(index + offset)
			if not byte or byte < 0x80 or byte > 0xBF then return false end
			code = code * 64 + (byte - 0x80)
		end
		if code < minimum or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then return false end
		index = index + extra + 1
	end
	return true
end

--- Decode the same bounded UTF-16 image as the managed fetch, without repair.
--- @param text string Bytes following the BOM.
--- @param big boolean Whether the source is big-endian.
--- @return string|nil text
--- @return string|nil reason
local function decode_utf16(text, big)
	if #text % 2 ~= 0 then return nil, "PAC UTF-16 has an incomplete code unit" end
	local parts, size, index = {}, 0, 1
	local function unit(at)
		local first, second = text:byte(at, at + 1)
		if not second then return nil end
		return big and first * 256 + second or second * 256 + first
	end
	while index <= #text do
		local code = unit(index)
		index = index + 2
		if code >= 0xD800 and code <= 0xDBFF then
			local low = unit(index)
			if not low or low < 0xDC00 or low > 0xDFFF then return nil, "PAC encoding is invalid" end
			code = 0x10000 + (code - 0xD800) * 0x400 + low - 0xDC00
			index = index + 2
		elseif code >= 0xDC00 and code <= 0xDFFF then
			return nil, "PAC encoding is invalid"
		end
		if code == 0 then return nil, "PAC contains a null character" end
		local encoded = Utf8.char(code)
		size = size + #encoded
		if size > M.MAX_BYTES then return nil, "PAC normalized UTF-8 is over the byte limit" end
		parts[#parts + 1] = encoded
	end
	return table.concat(parts)
end

--- Judges one PAC answer.
--- @param status number|nil HTTP status, nil or 0 when the request failed.
--- @param body string|nil Response body.
--- @param transport_error string|nil The HTTP client's reason for a failed request.
--- @return string state "ok" or "error"
--- @return string text Value (ok) or detail (error), without any URL.
function M.judge(status, body, transport_error)
	status = tonumber(status) or 0
	if status ~= 200 then
		if status > 0 then return "error", "PAC download: HTTP " .. status end
		-- The transport reason is the only clue a field log carries (issue #104).
		return "error", type(transport_error) == "string" and transport_error ~= ""
			and ("PAC download failed: " .. transport_error) or "PAC download failed"
	end
	local text, reason = M.decode(body)
	if not text then return "error", reason end
	local utf16 = body:sub(1, 2) == "\255\254" or body:sub(1, 2) == "\254\255"
	return "ok", string.format("HTTP 200, %d bytes, %s, FindProxyForURL found", #body, utf16 and "UTF-16" or "UTF-8")
end

--- Decodes the body of a PAC download to the UTF-8 script an engine runs,
--- with the bounds and encodings the managed download admits.
--- @param body string|nil Response body of an HTTP 200.
--- @return string|nil script
--- @return string|nil reason Detail without any URL.
function M.decode(body)
	if type(body) ~= "string" or body == "" then return nil, "PAC is empty" end
	local bytes = #body
	if bytes > M.MAX_BYTES then
		return nil, string.format("PAC is %d bytes, over the %d byte limit", bytes, M.MAX_BYTES)
	end
	local text, reason
	if body:sub(1, 2) == "\255\254" or body:sub(1, 2) == "\254\255" then
		text, reason = decode_utf16(body:sub(3), body:byte(1) == 254)
		if not text then return nil, reason end
	else
		text = body:sub(1, 3) == "\239\187\191" and body:sub(4) or body
		if not valid_utf8(text) then
			return nil, "PAC is not UTF-8 (the managed download refuses it)"
		end
	end
	if text == "" then return nil, "PAC is empty" end
	if text:find("\0", 1, true) then return nil, "PAC contains a null character" end
	if not text:find("FindProxyForURL", 1, true) then
		return nil, "PAC does not define FindProxyForURL"
	end
	return text
end

--- Appends to a PAC failure detail what a driver whose downloads fall back to
--- a direct connection (proxy_policy.json "pac_unavailable_fallback") does next,
--- so the diagnostics do not read as "every download is refused".
--- @param detail string The detail judge() returned.
--- @return string
function M.with_direct_fallback(detail)
	return tostring(detail) .. "; downloads then try a direct connection"
end

--- Extracts the PAC URL from `scutil --proxy` text (macOS).
--- @param text string
--- @return string|nil
function M.url_from_scutil(text)
	if type(text) ~= "string" then return nil end
	if not text:find("ProxyAutoConfigEnable%s*:%s*1") then return nil end
	return text:match("ProxyAutoConfigURLString%s*:%s*(%S+)")
end

return M
