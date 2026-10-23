--- _shared/lua/network/pac_check.lua

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

--- Judges one PAC answer.
--- @param status number|nil HTTP status, nil or 0 when the request failed.
--- @param body string|nil Response body.
--- @return string state "ok" or "error"
--- @return string text Value (ok) or detail (error), without any URL.
function M.judge(status, body)
	status = tonumber(status) or 0
	if status ~= 200 then
		return "error", status > 0 and ("PAC download: HTTP " .. status) or "PAC download failed"
	end
	if type(body) ~= "string" or body == "" then return "error", "PAC is empty" end
	local bytes = #body
	if bytes > M.MAX_BYTES then
		return "error", string.format("PAC is %d bytes, over the %d byte limit", bytes, M.MAX_BYTES)
	end
	local utf16 = body:sub(1, 2) == "\255\254" or body:sub(1, 2) == "\254\255"
	if not utf16 then
		local text = body:sub(1, 3) == "\239\187\191" and body:sub(4) or body
		if not valid_utf8(text) then
			return "error", "PAC is not UTF-8 (the managed download refuses it)"
		end
		if not text:find("FindProxyForURL", 1, true) then
			return "error", "PAC does not define FindProxyForURL"
		end
	end
	return "ok", string.format("HTTP 200, %d bytes, %s, FindProxyForURL found", bytes, utf16 and "UTF-16" or "UTF-8")
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
