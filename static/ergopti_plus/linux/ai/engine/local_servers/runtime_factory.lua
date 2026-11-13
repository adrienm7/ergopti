--- ai/engine/local_servers/runtime_factory.lua

--- ==============================================================================
--- MODULE: Native Linux Ollama Runtime Composition
--- DESCRIPTION:
--- Constructs source, file, process, HTTP and timer owners only when the user
--- requests local runtime repair. Construction never downloads, installs,
--- starts a process or changes a preference. Each injected module retains its
--- existing native lifetime and classified-source ownership.
--- ==============================================================================

local M = {}

-- ========================================
-- ======= 1/ Native Composition ===========
-- ========================================

--- Creates the actual per-user runtime composition after explicit UI intent.
--- @param engine table Lexical state/publication hooks and canonical backend key.
--- @param profiles table Existing profile preference writer.
--- @return table|nil owner Controller, source and read-only managed resolver.
--- @return string|nil reason Classified native construction refusal.
function M.new(engine, profiles)
	local native = require("luv")
	local Timings = require("core.timing.engine.timings")
	local resolver, reason = require("ai.engine.ollama.install_resolver").new()
	if not resolver then return nil, reason end
	local serve_environment, environment_reason = require("ai.engine.ollama.managed_ollama_environment").load()
	if not serve_environment then return nil, environment_reason end
	-- The daemon cannot evaluate a PAC: the desktop proxy is resolved for it.
	local proxy_policy, proxy_reason = require("core.network.engine.proxy_policy").load()
	if not proxy_policy then return nil, proxy_reason end
	local origins, origins_reason = require("core.network.engine.route_origins").client("ollama")
	if not origins then return nil, origins_reason end
	-- A proxy that demands an NTLM/Negotiate sign-in is answered by the local relay.
	local Relay = require("core.network.engine.proxy_auth_relay")
	local relay_policy, relay_reason = Relay.load()
	if not relay_policy then return nil, relay_reason end
	local source = require("ai.engine.local_servers.runtime_source").new({
		preferences = require("ai.engine.preferences"), profiles = profiles,
		writer = require("core.text.engine.toml_codec.writer"), manifest = require("menu.engine.manifest_reader"),
		engine = engine, backend_key = engine.backend_key,
		path = require("settings.engine.paths").config("config.toml"),
	})
	local process = require("ai.engine.policy.process_port").new(require("core.lifecycle.engine.native_worker_owner"),
		require("core.process.adapters.owned_process"), native, Timings.ms("llm", "poll_interval_ms"))
	local timer = require("ai.engine.local_servers.owned_timer").new(native, require("core.timing.engine.native_timer"))
	local installed = require("ai.engine.ollama.installed_runtime")
	local controller = require("ai.engine.local_servers.runtime_composition").new({
		source = source, resolver = resolver, installed = installed,
		file_factory = require("ai.engine.ollama.install_files"),
		archive_factory = require("updater.engine.archive_output"),
		admission = require("ai.engine.ollama.install_admission"),
		install_phase = require("ai.engine.ollama.install_phase"), process = process,
		http = require("core.network.adapters.http_client"), owned_timer = timer, timings = Timings,
		serve_environment = serve_environment,
		network = { policy = proxy_policy, lookup = require("core.network.adapters.system_proxy").lookup_owned,
			timeout_ms = Timings.ms("llm", "managed_proxy_lookup_timeout_ms"), origins = origins,
			relay = { policy = relay_policy, probe = Relay.probe, executable = Relay.executable,
				timings = Relay.timings, timeout_ms = Relay.timings().probe_ms },
			probe = require("core.network.adapters.tcp_probe").probe, relay_address = require("core.network.adapters.tcp_probe").relay_address,
			probe_timeout_ms = Timings.ms("llm", "managed_proxy_probe_timeout_ms") },
		environment = function()
			local values = native.os_environ()
			if type(values) ~= "table" then return nil end
			local keys = {}
			for key, value in pairs(values) do
				if type(key) ~= "string" or type(value) ~= "string" or key:find("=", 1, true) then return nil end
				keys[#keys + 1] = key
			end
			table.sort(keys)
			local rows = {}
			for _, key in ipairs(keys) do rows[#rows + 1] = key .. "=" .. values[key] end
			return rows
		end,
	})
	local owner = { controller = controller, source = source }
	--- Captures read-only native managed runtime identities before offering UI.
	--- @return table verdict Installed, missing or classified unavailable.
	function owner.resolve() return installed.capture(resolver) end
	return owner
end

return M
