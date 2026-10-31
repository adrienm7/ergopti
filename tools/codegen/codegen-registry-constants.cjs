// tools/codegen/codegen-registry-constants.cjs

/**
 * ==============================================================================
 * MODULE: Timing Registry Constants Codegen
 * DESCRIPTION:
 * Projects _shared/modules/timings/constants.toml onto the readers that cannot
 * parse it at runtime: macos/_generated/registry_limits.lua, the [limits] byte
 * caps for the macOS modules loaded before infra.timings exists.
 *
 * WHY THIS EXISTS:
 * infra.timings parses the registry through the TOML reader, whose cache
 * provider is adapters.toml_cache, and reports the load through infra.logger,
 * whose transport is adapters.log_transport. Those modules, and
 * adapters.shell_runner on the same early boot path, therefore kept typed
 * copies of their byte caps: a runtime read sits beneath its own reader, and a
 * lazy read on first use would re-enter the logger from inside its own flush.
 * A committed table has no dependency, so they read the registry value.
 *
 * USAGE:  node tools/codegen/codegen-registry-constants.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE_REL = '_shared/modules/timings/constants.toml';
const OUTPUT_LUA = path.join(SP, 'macos/_generated/registry_limits.lua');

/** Stops generation with one exact reason. */
function fail(message) {
	console.error(`[ERROR] ${SOURCE_REL}: ${message}`);
	process.exit(1);
}

const registry = toml.parse(fs.readFileSync(path.join(SP, SOURCE_REL), 'utf8'));
const limits = registry.limits;
if (limits === null || typeof limits !== 'object' || Object.keys(limits).length === 0)
	fail('[limits] must be a non-empty section.');
for (const [key, value] of Object.entries(limits)) {
	if (!/^[a-z][a-z0-9_]*_bytes$/.test(key))
		fail(`[limits].${key} must be snake_case and end in _bytes.`);
	if (!Number.isSafeInteger(value) || value < 1)
		fail(`[limits].${key} must be a positive integer.`);
}

const rows = Object.entries(limits)
	.map(([key, value]) => `\t${key} = ${value},`)
	.join('\n');

const lua = `--- _generated/registry_limits.lua
--- AUTO-GENERATED from ${SOURCE_REL}.
--- DO NOT EDIT BY HAND — run \`npm run codegen:registry-constants\` to refresh.

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
${rows}
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
`;

fs.writeFileSync(OUTPUT_LUA, lua);
console.log(`[OK] ${path.relative(ROOT, OUTPUT_LUA)} (${Object.keys(limits).length} limit(s))`);
