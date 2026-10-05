--- modules/llm/runtime_factory.lua

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
	local Timings = require("infra.timings")
	local resolver, reason = require("modules.llm.ollama_install_resolver").new()
	if not resolver then return nil, reason end
	local source = require("modules.llm.runtime_source").new({
		preferences = require("infra.llm_preferences"), profiles = profiles,
		writer = require("toml_codec.writer"), manifest = require("infra.manifest_reader"),
		engine = engine, backend_key = engine.backend_key,
		path = require("infra.config_paths").config("config.toml"),
	})
	local process = require("llm.process_port").new(require("native_worker_owner"),
		require("adapters.owned_process"), native, Timings.ms("llm", "poll_interval_ms"))
	local timer = require("modules.llm.owned_timer").new(native, require("infra.native_timer"))
	local installed = require("modules.llm.ollama_installed_runtime")
	local controller = require("modules.llm.runtime_composition").new({
		source = source, resolver = resolver, installed = installed,
		file_factory = require("modules.llm.ollama_install_files"),
		admission = require("modules.llm.ollama_install_admission"),
		install_phase = require("llm.ollama_install_phase"), process = process,
		http = require("adapters.http_client"), owned_timer = timer, timings = Timings,
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
