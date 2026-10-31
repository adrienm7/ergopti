--- _generated/registry_limits.lua
--- AUTO-GENERATED from _shared/modules/timings/constants.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:registry-constants` to refresh.

--- ==============================================================================
--- MODULE: Registry Byte Limits (Hammerspoon)
--- DESCRIPTION:
--- The [limits] section of the timing registry as a dependency-free table, for
--- the modules loaded before infra.timings (the logger transport, the TOML cache,
--- the shell runner). Every other module reads the same keys through
--- infra.timings.
---
--- USAGE:
---   local RegistryLimits = require("_generated.registry_limits")
---   local CAP_BYTES = RegistryLimits.count("limits", "process_output_bytes")
--- ==============================================================================

local VALUES = {
	process_output_bytes = 65536,
	declaration_file_bytes = 65536,
	changelog_source_bytes = 4194304,
	journal_recovery_turn_bytes = 65536,
	layer_file_bytes = 65536,
	number_row_level_text_bytes = 1024,
	release_list_body_bytes = 2097152,
	file_digest_output_bytes = 1024,
	crash_report_head_bytes = 65536,
	input_source_id_bytes = 1024,
	network_check_body_bytes = 1048577,
	program_catalogue_bytes = 65536,
	http_diagnostic_bytes = 65536,
	proxy_packet_bytes = 65536,
	shortcuts_reply_bytes = 65536,
	log_prepare_tick_bytes = 65536,
	shell_captured_output_bytes = 4194304,
	toml_source_chunk_bytes = 65536,
}

local M = {}

--- The value of one [limits] key, failing fast on a key the registry lacks.
--- @param section string Always "limits": the call shape of infra.timings.count.
--- @param key string The [limits] key.
--- @return integer
function M.count(section, key)
	if section ~= "limits" then
		error(string.format("[registry_limits] only [limits] is generated, not [%s]", tostring(section)))
	end
	local value = VALUES[key]
	if type(value) ~= "number" then
		error(string.format("[registry_limits] missing key [limits].%s in constants.toml", tostring(key)))
	end
	return value
end

return M
