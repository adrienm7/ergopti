--- _shared/core/network/engine/proxy_auth_relay_core.lua

--- ==============================================================================
--- MODULE: Shared Proxy Sign-In Relay Policy
--- DESCRIPTION:
--- Decides when a client goes through Ergopti's local authenticating relay
--- (docs/design/proxy-auth-relay.md) and speaks the relay's command line: the
--- probe that asks the selected proxy whether it demands an NTLM/Negotiate
--- sign-in, and the run that serves one child for its lifetime. Pure policy;
--- the platform owner runs the processes.
---
--- FEATURES & RATIONALE:
--- 1. Only a plain http relay without credentials is probed: a proxy URL with
---    userinfo is a Basic proxy the client answers itself, and a socks or https
---    relay is not one the relay can sign in to.
--- 2. Every deadline is the caller's, from the timings registry; the relay has
---    no default.
--- 3. The probe's answer is read against the closed sets of
---    _shared/core/network/data/proxy_auth_relay.json; anything else, an exit
---    that does not match its line, or a relay that could not run, is the
---    named refusal "relay_unavailable", never a silent direct start.
--- 4. Reasons and statuses never carry a URL, host, header or token.
--- ==============================================================================

local M = {}

--- The relay executable's file name in every installation.
M.EXECUTABLE_NAME = "ergopti-proxy-relay"

--- The caller-side refusal of a relay that ran and did not answer by contract.
M.UNAVAILABLE = "relay_unavailable"

--- The status a platform binding answers, without a child, when the relay is
--- not installed. The Go relay never prints it; until the relay ships in every
--- package, callers keep the proxy as named and log a WARNING.
M.NOT_INSTALLED = "not_installed"

--- Validates a decoded proxy_auth_relay.json.
--- @param contract any
--- @return boolean
local function valid_contract(contract)
	if type(contract) ~= "table" or contract.schema_version ~= 1 or type(contract.refusals) ~= "table"
		or type(contract.exit_codes) ~= "table" or type(contract.probe_statuses) ~= "table"
		or type(contract.schemes) ~= "table" then return false end
	for reason, key in pairs(contract.refusals) do
		if type(reason) ~= "string" or not reason:match("^[a-z][a-z_]*$") or type(key) ~= "string"
			or not key:match("^network%.relay%.[a-z_]+$") then return false end
	end
	return contract.refusals[M.UNAVAILABLE] ~= nil and contract.exit_codes.ok == 0
		and type(contract.exit_codes.refused) == "number" and type(contract.exit_codes.invalid_arguments) == "number"
end

--- Normalizes a plain DNS host or IPv4 literal.
--- @param host string
--- @return string|nil
local function plain_host(host)
	host = host:lower()
	if host == "" or #host > 253 or host:find("[^%w%.%-]") or host:find("%.%.") then return nil end
	return host
end

--- Builds the policy from the decoded contract.
--- @param contract table Decoded proxy_auth_relay.json.
--- @return table|nil policy, string|nil reason
function M.new(contract)
	if not valid_contract(contract) then return nil, "proxy-auth-relay-contract-invalid" end
	local statuses, schemes = {}, {}
	for _, status in ipairs(contract.probe_statuses) do statuses[status] = true end
	for _, scheme in ipairs(contract.schemes) do schemes[scheme] = true end
	local refusals, exits = contract.refusals, contract.exit_codes
	local policy = {}

	--- The upstream the relay may sign in to, nil when the relay does not apply.
	--- @param proxy any A route plan relay ("http://host:port", "socks5://...").
	--- @return string|nil upstream
	function policy.upstream(proxy)
		if type(proxy) ~= "string" then return nil end
		local host, port = proxy:match("^http://([^/@:%s]+):(%d+)/?$")
		host = host and plain_host(host) or nil
		port = tonumber(port)
		if not host or not port or port < 1 or port > 65535 then return nil end
		return "http://" .. host .. ":" .. tostring(port)
	end

	--- The CONNECT authority of an https origin.
	--- @param origin any "https://host"
	--- @return string|nil authority
	function policy.authority(origin)
		local host = type(origin) == "string" and origin:match("^https://([^/?#@:%s]+)$") or nil
		host = host and plain_host(host) or nil
		return host and host .. ":443" or nil
	end

	--- Validates the caller's deadlines.
	--- @param timings table { dial_ms, handshake_ms, idle_ms? }
	--- @param idle boolean Whether the idle deadline is required.
	--- @return boolean
	local function valid_timings(timings, idle)
		if type(timings) ~= "table" then return false end
		for _, name in ipairs(idle and { "dial_ms", "handshake_ms", "idle_ms" } or { "dial_ms", "handshake_ms" }) do
			local value = timings[name]
			if type(value) ~= "number" or value <= 0 or value % 1 ~= 0 then return false end
		end
		return true
	end

	--- The probe's arguments (after the executable).
	--- @return table|nil args
	function policy.probe_args(upstream, authority, timings)
		if policy.upstream(upstream) ~= upstream or type(authority) ~= "string"
			or not authority:match("^[%w%.%-]+:%d+$") or not valid_timings(timings, false) then return nil end
		return { "probe", "--upstream", upstream, "--authority", authority,
			"--dial-timeout-ms", tostring(timings.dial_ms), "--handshake-timeout-ms", tostring(timings.handshake_ms) }
	end

	--- The run's arguments (after the relay executable) that serve one child.
	--- @param upstream string
	--- @param variables table Proxy variable names the child reads.
	--- @param timings table { dial_ms, handshake_ms, idle_ms }
	--- @param executable string The child.
	--- @param args table The child's arguments.
	--- @return table|nil args
	function policy.run_args(upstream, variables, timings, executable, args)
		if policy.upstream(upstream) ~= upstream or type(variables) ~= "table" or #variables == 0
			or not valid_timings(timings, true) or type(executable) ~= "string" or executable == ""
			or type(args) ~= "table" then return nil end
		local out = { "run", "--upstream", upstream }
		for _, name in ipairs(variables) do
			if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then return nil end
			out[#out + 1] = "--variable"
			out[#out + 1] = name
		end
		for _, item in ipairs({ "--dial-timeout-ms", tostring(timings.dial_ms), "--handshake-timeout-ms",
			tostring(timings.handshake_ms), "--idle-timeout-ms", tostring(timings.idle_ms), "--", executable }) do
			out[#out + 1] = item
		end
		for _, item in ipairs(args) do
			if type(item) ~= "string" then return nil end
			out[#out + 1] = item
		end
		return out
	end

	--- Reads a finished probe child.
	--- @param exit_code any The child's exit code, nil when it never ran.
	--- @param stdout any Its standard output.
	--- @return table|nil answer { status = "not_needed"|"required", scheme? }
	--- @return string|nil reason A closed refusal when answer is nil.
	function policy.read_probe(exit_code, stdout)
		if type(exit_code) ~= "number" or type(stdout) ~= "string" then return nil, M.UNAVAILABLE end
		local line = stdout:match("^(%b{})\r?\n?$")
		local status = line and line:match('^{"schema":1,"status":"([a-z_]+)"') or nil
		if not status or not statuses[status] then return nil, M.UNAVAILABLE end
		local rest = line:sub(#('{"schema":1,"status":"' .. status .. '"') + 1)
		local scheme = rest:match('^,"scheme":"([a-z]+)"')
		local reason = rest:match('^,"reason":"([a-z_]+)"}$')
		if status == "refused" then
			if exit_code ~= exits.refused and exit_code ~= exits.invalid_arguments then return nil, M.UNAVAILABLE end
			if not reason or not refusals[reason] or reason == M.UNAVAILABLE then return nil, M.UNAVAILABLE end
			return nil, reason
		end
		if exit_code ~= exits.ok then return nil, M.UNAVAILABLE end
		if status == "required" then
			if not scheme or not schemes[scheme] or rest ~= ',"scheme":"' .. scheme .. '"}' then return nil, M.UNAVAILABLE end
			return { status = status, scheme = scheme }, nil
		end
		if rest ~= "}" then return nil, M.UNAVAILABLE end
		return { status = status }, nil
	end

	--- The locale key that explains a refusal to the user.
	--- @param reason any
	--- @return string key
	function policy.message_key(reason)
		return refusals[reason] or refusals[M.UNAVAILABLE]
	end

	--- Whether a reason is one of the closed refusals.
	--- @param reason any
	--- @return boolean
	function policy.is_refusal(reason) return refusals[reason] ~= nil end

	return policy
end

return M
