--- adapters/network_check_ports.lua

--- ==============================================================================
--- MODULE: Network Field Check Ports (Linux)
--- DESCRIPTION:
--- The three ports of the shared network check (network/field_check_network.lua)
--- bound to this driver: how the desktop's proxy settings are read, how a PAC
--- file is downloaded, and how one request runs through the managed transport
--- (route lookup by GIO, then the managed curl engine, both owned and bounded).
---
--- FEATURES & RATIONALE:
--- 1. The managed path, not a probe of its own. The route lookup is the GIO
---    lookup the updater and the downloads use (adapters/system_proxy.lua) and
---    the request goes through adapters/http_client.lua, so the answer is the
---    one a real download would get behind the same company proxy.
--- 2. Settings are read where the desktop keeps them: the proxy environment
---    variables the shared policy declares, GNOME's gsettings and KDE's
---    kioslaverc. Only the kinds are reported; the PAC address is handed to the
---    PAC fetch and nowhere else.
--- 3. Closed vocabulary. Every value is a token (kinds, native failure stages,
---    HTTP status classes); no URL, host, proxy address or error text escapes.
--- 4. One request, small and public: the repository's releases Atom feed, the
---    resource the update check falls back to when the REST API is blocked.
--- 5. Every collaborator is injectable, so the suite replays each failure
---    without a network, a desktop or a shell.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.network_check_ports"

--- Owner of the check's network operations; one check runs at a time.
M.OWNER = "field_check.network"

--- Budgets in milliseconds.
M.SETTINGS_TIMEOUT_SECONDS = 2
M.PAC_TIMEOUT_MS = 15000
M.LOOKUP_TIMEOUT_MS = 10000
M.REQUEST_TIMEOUT_MS = 20000

--- Largest answer read: a PAC is capped by the shared verdict, the feed is small.
M.MAX_BODY_BYTES = 1048576 + 1

--- gsettings and kioslaverc readers, in the order their kinds are reported.
local GNOME_MODE = "gsettings get org.gnome.system.proxy mode 2>/dev/null"
local GNOME_PAC = "gsettings get org.gnome.system.proxy autoconfig-url 2>/dev/null"
local KDE_READERS = { "kreadconfig6", "kreadconfig5" }
local KDE_TYPE = " --file kioslaverc --group 'Proxy Settings' --key ProxyType 2>/dev/null"
local KDE_PAC = " --file kioslaverc --group 'Proxy Settings' --key 'Proxy Config Script' 2>/dev/null"

--- KDE ProxyType values.
local KDE_KINDS = { ["1"] = "manual", ["2"] = "pac", ["3"] = "discovery", ["4"] = "env" }

--- Strips the quotes of a GVariant string and refuses anything that is not one.
--- @param text any
--- @return string|nil
local function unquote(text)
	if type(text) ~= "string" then return nil end
	local value = text:match("^%s*'(.*)'%s*$")
	if value == nil or value == "" then return nil end
	return value
end

--- The real collaborators.
--- @return table
local function native()
	return {
		environment = function() return require("infra.proxy_policy").environment() end,
		exec = function(command)
			local Shell = require("adapters.shell_runner")
			local ok, output = Shell.exec_checked("timeout " .. M.SETTINGS_TIMEOUT_SECONDS .. " " .. command)
			if not ok then return nil end
			return ((output or ""):gsub("%s+$", ""))
		end,
		has_command = function(name) return require("adapters.shell_runner").has_command(name) end,
		http_get = function(url, headers, options, callback)
			return require("adapters.http_client").get(url, headers, options, callback)
		end,
		lookup = function(url, options, callback)
			return require("adapters.system_proxy").lookup_owned(url, options, callback)
		end,
		feed_url = function()
			local Paths = require("infra.paths")
			local Json = require("json")
			local handle = io.open(Paths.shared("modules/updater/defaults.json"), "rb")
			if not handle then return nil end
			local raw = handle:read("*a")
			handle:close()
			local ok, defaults = pcall(Json.decode, raw)
			if not ok then return nil end
			local sources = require("updater.release_sources").resolve(defaults)
			return sources and sources.feed_url or nil
		end,
	}
end

--- Reads the kinds of proxy configured and the PAC address, if any.
--- @param deps table
--- @return table { kinds = string, pac_url = string|nil }
function M.read_settings(deps)
	local kinds, seen, pac_url = {}, {}, nil
	local function add(kind)
		if not seen[kind] then
			seen[kind] = true
			kinds[#kinds + 1] = kind
		end
	end
	local ok, environment = pcall(deps.environment)
	if ok and type(environment) == "table" then
		for _, value in pairs(environment) do
			if type(value) == "string" and value ~= "" then add("env"); break end
		end
	end
	if deps.has_command("gsettings") then
		local mode = unquote(deps.exec(GNOME_MODE))
		if mode == "auto" then
			add("gnome_pac")
			pac_url = pac_url or unquote(deps.exec(GNOME_PAC))
		elseif mode == "manual" then
			add("gnome_manual")
		end
	end
	for _, reader in ipairs(KDE_READERS) do
		if deps.has_command(reader) then
			local kind = KDE_KINDS[tostring(deps.exec(reader .. KDE_TYPE) or "")]
			if kind == "pac" then
				add("kde_pac")
				local script = deps.exec(reader .. KDE_PAC)
				if type(script) == "string" and script ~= "" then pac_url = pac_url or script end
			elseif kind == "manual" then
				add("kde_manual")
			elseif kind == "discovery" then
				add("kde_discovery")
			end
			break
		end
	end
	return { kinds = #kinds > 0 and table.concat(kinds, "+") or "none", pac_url = pac_url }
end

--- Maps a failed managed request to the closed token the report names.
--- @param result table The http_client result.
--- @return string token
function M.failure_token(result)
	local receipt = type(result) == "table" and result.failure_receipt or nil
	if type(receipt) == "table" then
		if receipt.stage == "tls" then return "certificate" end
		if receipt.stage == "proxy_resolve" then return "proxy_resolve" end
		if receipt.stage == "proxy_connect" then return "proxy_connect" end
		if receipt.stage == "connect" then return "connect" end
		if receipt.stage == "http" and tonumber(receipt.http_status) and receipt.http_status > 0 then
			return "http_" .. tostring(math.floor(receipt.http_status))
		end
	end
	if type(result) == "table" and tonumber(result.status) and result.status > 0 then
		return "http_" .. tostring(math.floor(result.status))
	end
	if type(result) == "table" and result.error == "timeout" then return "timeout" end
	return "failed"
end

--- Builds the ports.
--- @param deps table|nil Test doubles for the native collaborators.
--- @return table ports { proxy_settings, fetch_pac, chain }
function M.new(deps)
	deps = deps or native()

	local function proxy_settings(callback)
		local ok, settings = pcall(M.read_settings, deps)
		if not ok then
			Logger.warn(LOG, "The desktop proxy settings could not be read.")
			callback({ failure = "unreadable" })
			return
		end
		callback(settings)
	end

	local function fetch_pac(url, callback)
		local started = deps.http_get(url, {}, {
			owner = M.OWNER, timeout_ms = M.PAC_TIMEOUT_MS, max_body_bytes = M.MAX_BODY_BYTES,
			follow_redirects = true,
		}, function(result)
			result = type(result) == "table" and result or {}
			callback(tonumber(result.status), result.body)
		end)
		if started == false then callback(nil, nil) end
	end

	local function chain(callback)
		local url = deps.feed_url()
		if type(url) ~= "string" then
			callback(nil, {})
			return
		end
		local steps = {}
		local function finish_request(result)
			if type(result) == "table" and result.ok == true then
				steps.tls = { state = "pass", value = "trusted" }
				steps.transfer = { state = (tonumber(result.status) or 0) < 400 and "pass" or "fail",
					value = "http_" .. tostring(math.floor(tonumber(result.status) or 0)) }
			else
				local token = M.failure_token(result)
				steps.tls = token == "certificate" and { state = "fail", value = "certificate" }
					or { state = "skip", value = "not_reached" }
				steps.transfer = { state = "fail", value = token }
			end
			steps.digest = { state = "skip", value = "get_only" }
			callback(0, steps)
		end
		local function request()
			local started = deps.http_get(url, {}, {
				owner = M.OWNER, timeout_ms = M.REQUEST_TIMEOUT_MS, max_body_bytes = M.MAX_BODY_BYTES,
				follow_redirects = true, https_only = true,
			}, finish_request)
			if started == false then finish_request(nil) end
		end
		local _, refusal = deps.lookup(url, { owner = M.OWNER .. ".route", timeout_ms = M.LOOKUP_TIMEOUT_MS },
			function(receipt)
				if type(receipt) == "table" and receipt.ok == true then
					local direct = type(receipt.proxies) == "table" and receipt.proxies[1] == "direct://"
					steps.route_lookup = { state = "pass", value = direct and "selected_direct" or "selected_proxy" }
				else
					local reason = type(receipt) == "table" and receipt.error or nil
					steps.route_lookup = { state = "fail",
						value = type(reason) == "string" and reason:match("^proxy%-%l[%l%-]+$") and reason or "proxy-lookup-failed" }
				end
				request()
			end)
		if refusal then
			steps.route_lookup = { state = "fail", value = refusal }
			request()
		end
	end

	return { proxy_settings = proxy_settings, fetch_pac = fetch_pac, chain = chain }
end

return M
