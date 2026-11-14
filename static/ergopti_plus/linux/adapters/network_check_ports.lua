--- adapters/network_check_ports.lua

--- ==============================================================================
--- MODULE: Network Field Check Ports (Linux)
--- DESCRIPTION:
--- The ports of the shared network check (core/network/engine/field_check_network.lua)
--- bound to this driver: how the desktop's proxy settings are read, how a PAC
--- file is downloaded, how one request runs through the managed transport
--- (route lookup by GIO, then the managed curl engine, both owned and bounded) and
--- which route each origin of the managed Ollama daemon takes.
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

local Logger = require("core.logger.engine.shim")
local Timings = require("infra.timings")

local LOG = "adapters.network_check_ports"

--- Owner of the check's network operations; one check runs at a time.
M.OWNER = "field_check.network"

--- Budgets in milliseconds.
M.SETTINGS_TIMEOUT_SECONDS = 2
M.PAC_TIMEOUT_MS = 15000
M.LOOKUP_TIMEOUT_MS = 10000
M.REQUEST_TIMEOUT_MS = 20000

--- Largest answer read: a PAC is capped by the shared verdict, the feed is small
--- ([limits] network_check_body_bytes).
M.MAX_BODY_BYTES = Timings.count("limits", "network_check_body_bytes")

--- gsettings and kioslaverc readers, in the order their kinds are reported.
local GNOME_MODE = "gsettings get org.gnome.system.proxy mode 2>/dev/null"
local GNOME_PAC = "gsettings get org.gnome.system.proxy autoconfig-url 2>/dev/null"
local KDE_READERS = { "kreadconfig6", "kreadconfig5" }
local KDE_TYPE = " --file kioslaverc --group 'Proxy Settings' --key ProxyType 2>/dev/null"
local KDE_PAC = " --file kioslaverc --group 'Proxy Settings' --key 'Proxy Config Script' 2>/dev/null"

--- KDE ProxyType values.
local KDE_KINDS = { ["1"] = "manual", ["2"] = "pac", ["3"] = "discovery", ["4"] = "env" }

--- The real collaborators.
--- @return table
local function native()
	return {
		environment = function() return require("infra.proxy_policy").environment() end,
		exec = function(command)
			local Shell = require("adapters.shell_runner")
			local ok, output = Shell.exec_checked("timeout " .. M.SETTINGS_TIMEOUT_SECONDS .. " " .. command)
			if not ok then return nil end
			if command == GNOME_MODE or command == GNOME_PAC then
				local value, refusal = require("infra.gvariant_string").decode(output)
				if value == nil then error(refusal, 0) end
				return value
			end
			return ((output or ""):gsub("%s+$", ""))
		end,
		has_command = function(name) return require("adapters.shell_runner").has_command(name) end,
		http_get = function(url, headers, options, callback)
			return require("adapters.http_client").get(url, headers, options, callback)
		end,
		lookup = function(url, options, callback)
			return require("adapters.system_proxy").lookup_owned(url, options, callback)
		end,
		-- The origins the managed Ollama daemon contacts, and the shared selection rules.
		ollama_origins = function() return require("infra.route_origins").client("ollama") end,
		-- The sign-in relay the daemon's start probes (docs/design/proxy-auth-relay.md).
		relay = function() return require("infra.proxy_auth_relay") end,
		selection = function(receipt)
			local policy, reason = require("infra.proxy_policy").load()
			if not policy then return nil, reason end
			return policy.selection(receipt)
		end,
		feed_url = function()
			local Paths = require("core.fs.engine.paths")
			local Json = require("core.text.engine.json")
			local handle = require("core.fs.engine.regular_file_reader").open_source(Paths.shared("updater/data/defaults.json"))
			if not handle then return nil end
			local raw = handle:read("*a")
			local closed = handle:close()
			if type(raw) ~= "string" or not closed then return nil end
			local ok, defaults = pcall(Json.decode, raw)
			if not ok then return nil end
			local sources = require("updater.engine.release_sources").resolve(defaults)
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
		local mode = deps.exec(GNOME_MODE)
		if mode == "auto" then
			add("gnome_pac")
			local address = deps.exec(GNOME_PAC)
			if type(address) == "string" and address ~= "" then pac_url = pac_url or address end
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
		local status = tonumber(receipt.http_status)
		if receipt.stage == "http" and status and status > 0 then
			return "http_" .. tostring(math.floor(status))
		end
	end
	local status = type(result) == "table" and tonumber(result.status) or nil
	if status and status > 0 then
		return "http_" .. tostring(math.floor(status))
	end
	if type(result) == "table" and result.error == "timeout" then return "timeout" end
	return "failed"
end

--- Builds the ports.
--- @param deps table|nil Test doubles for the native collaborators.
--- @return table ports { proxy_settings, fetch_pac, chain, route_plan, relay, relay_probe }
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
		-- The HTTP callback owns completion, including synchronous refusal.
		-- Its boolean return reports dispatch only; shutdown suppresses delivery.
		deps.http_get(url, {}, {
			owner = M.OWNER, timeout_ms = M.PAC_TIMEOUT_MS, max_body_bytes = M.MAX_BODY_BYTES,
			follow_redirects = true,
		}, function(result)
			result = type(result) == "table" and result or {}
			-- The step tokens stay fixed, so the transport reason is logged here.
			if (tonumber(result.status) or 0) == 0 then
				Logger.warn(LOG, "PAC download failed: %s.", tostring(result.error))
			end
			callback(tonumber(result.status), result.body)
		end)
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
			deps.http_get(url, {}, {
				owner = M.OWNER, timeout_ms = M.REQUEST_TIMEOUT_MS, max_body_bytes = M.MAX_BODY_BYTES,
				follow_redirects = true, https_only = true,
			}, finish_request)
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

	--- The route the system settings name for each origin of the managed Ollama daemon,
	--- looked up one after the other exactly as the daemon's start does. The daemon
	--- takes the first selection of each origin; DIRECT, or a machine without a
	--- desktop proxy source, is a direct route.
	local function route_plan(callback)
		local origins = deps.ollama_origins()
		if type(origins) ~= "table" or #origins == 0 then
			callback({ failure = "route-origins-unavailable" })
			return
		end
		local entries = {}
		local function failure_of(reason)
			return type(reason) == "string" and reason:match("^proxy%-%l[%l%-]+$") and reason or "proxy-lookup-failed"
		end
		local function dispatch(index)
			local _, refusal = deps.lookup(origins[index], { owner = M.OWNER .. ".plan", timeout_ms = M.LOOKUP_TIMEOUT_MS },
				function(receipt)
					local choices, selection_error = deps.selection(receipt)
					if not choices then
						callback({ failure = failure_of(selection_error) })
						return
					end
					local first = choices[1]
					entries[index] = { origin = origins[index], route = first.mode == "selected" and first.proxy or "direct" }
					if index == #origins then callback({ entries = entries }) else dispatch(index + 1) end
				end)
			if refusal then callback({ failure = failure_of(refusal) }) end
		end
		dispatch(1)
	end

	--- Probes the relay the plan selected for the registry, as the daemon's start
	--- does: not needed, required with its scheme, or a closed refusal.
	-- Partial test collaborators keep the real binding.
	local Binding = deps.relay and deps.relay() or require("infra.proxy_auth_relay")
	local function relay_probe(upstream, callback)
		local policy = Binding.load()
		local origins = deps.ollama_origins()
		local authority = policy and type(origins) == "table" and policy.authority(origins[1]) or nil
		if not authority then callback(nil, "relay_unavailable"); return end
		local _, refusal = Binding.probe(upstream, authority, { owner = M.OWNER .. ".relay",
			timeout_ms = Binding.timings().probe_ms, authorized = function() return true end }, callback)
		if refusal then callback(nil, "relay_unavailable") end
	end

	local relay_policy = assert(Binding.load(), "the shared relay contract is unreadable")
	return { proxy_settings = proxy_settings, fetch_pac = fetch_pac, chain = chain, route_plan = route_plan,
		relay = relay_policy, relay_probe = relay_probe }
end

return M
