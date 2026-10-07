--- infra/http_redirect_receipt.lua

--- ==============================================================================
--- MODULE: Private Single-Hop Native Redirect Receipt
--- DESCRIPTION:
--- Preserves bounded native observations and exact ownership receipts.
--- ==============================================================================

--- Private curl single-hop metadata on the existing bounded stderr owner.
local M = {}
local MARKER = "ERGOPTI_GET_REDIRECT_JSON:"

function M.write_out()
	-- JSON is the final native field. Raw URLs precede it and must round-trip
	-- exactly; older native JSON writers can lose non-ASCII/control bytes.
	return "%{stderr}\n" .. MARKER .. "\n%{url_effective}\n%{redirect_url}\n%{json}\n"
end
function M.allowance(maximum, url_maximum) return maximum + 2 * url_maximum + #MARKER + 5 end

--- Admits only the final complete JSON frame after actual process/pipe EOFs.
--- Returned URLs are private; the managed parent removes this field at publish.
function M.attach(request, result)
	if not request.single_hop_redirect then return result end
	if request.exited ~= true or request.stdout_eof ~= true or request.stderr_eof ~= true
		or request.exit_code ~= 0 or request.exit_signal ~= 0 then return result end
	local tail = request.stderr_tail:gsub("\nERGOPTI_HTTP_STATUS:%d%d%d\n?$", "")
		:gsub("\nERGOPTI_PROXY_STATUS:%d%d%d:[01?]\n?$", "")
	local effective, redirected, bytes = tail:match("\n" .. MARKER .. "\n([^\n]*)\n([^\n]*)\n([^\n]*)\n$")
	if not bytes or #bytes > request.single_hop_receipt_bytes
		or #effective > request.single_hop_url_bytes or #redirected > request.single_hop_url_bytes then return result end
	local loaded, json = pcall(require, "json")
	if not loaded or type(json) ~= "table" then return result end
	local decode = json.decode_lossless or json.decode
	if type(decode) ~= "function" then return result end
	local decoded, packet = pcall(decode, bytes)
	if not decoded or type(packet) ~= "table" then return result end
	local redirect_url = packet.redirect_url
	-- Curl emits explicit JSON null when no Location exists. It proves no
	-- target only when the independently emitted raw field is also empty.
	if redirected == "" and type(json.is_null) == "function" and json.is_null(redirect_url) then
		redirect_url = ""
	end
	if packet.http_code ~= result.status
		or (packet.response_code ~= nil and packet.response_code ~= result.status)
		or packet.exitcode ~= request.exit_code or packet.num_redirects ~= 0
		or type(packet.url_effective) ~= "string" or type(redirect_url) ~= "string"
		or packet.url_effective ~= effective or redirect_url ~= redirected
		or #packet.url_effective > request.single_hop_url_bytes or #redirect_url > request.single_hop_url_bytes then
		return result
	end
	result.redirect_receipt = {
		format = "curl-single-hop-v1", http_status = packet.http_code,
		curl_exit = packet.exitcode, num_redirects = 0,
		effective_url = packet.url_effective, redirect_url = redirect_url,
	}
	return result
end

--- Parses complete native response header frames from the owned header pipe.
--- CONNECT and interim frames precede the final response; duplicate ETags refuse association.
function M.response_etag(bytes, status, validate)
	if type(bytes) ~= "string" or type(validate) ~= "function" then return nil end
	local position, final = 1, nil
	while position <= #bytes do
		local boundary = bytes:find("\r\n\r\n", position, true)
		if not boundary then return nil end
		local block = bytes:sub(position, boundary - 1)
		local code, rest = block:match("^HTTP/%d[%.%d]* (%d%d%d)[^\r\n]*\r\n(.*)$")
		if not code then
			code = block:match("^HTTP/%d[%.%d]* (%d%d%d)[^\r\n]*$")
			rest = ""
		end
		if not code then return nil end
		local observed = { status = tonumber(code), present = false }
		for line in (rest .. "\r\n"):gmatch("([^\r\n]*)\r\n") do
			if line ~= "" then
				local name, value = line:match("^([^: \t]+):[ \t]*(.*)$")
				if not name then return nil end
				if name:lower() == "etag" then
					if observed.present then return nil end
					value = value:gsub("[ \t]+$", "")
					if value == "" or validate("ETag", value) ~= true then return nil end
					observed.present, observed.value = true, value
				end
			end
		end
		final, position = observed, boundary + 4
	end
	return final and final.status == status and final or nil
end

return M
