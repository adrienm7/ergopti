// tools/codegen/codegen-registry-constants.cjs

/**
 * ==============================================================================
 * MODULE: Timing Registry Constants Codegen
 * DESCRIPTION:
 * Projects _shared/modules/timings/constants.toml onto the readers that cannot
 * parse it at runtime: macos/_generated/registry_limits.lua, the [limits] byte
 * caps for the macOS modules loaded before infra.timings exists, and
 * LauncherTimings.generated.swift, the [launcher] durations of the Swift
 * launcher's sleeps and polls.
 *
 * WHY THIS EXISTS:
 * infra.timings parses the registry through the TOML reader, whose cache
 * provider is adapters.toml_cache, and reports the load through infra.logger,
 * whose transport is adapters.log_transport. Those modules, and
 * adapters.shell_runner on the same early boot path, therefore kept typed
 * copies of their byte caps: a runtime read sits beneath its own reader, and a
 * lazy read on first use would re-enter the logger from inside its own flush.
 * A committed table has no dependency, so they read the registry value.
 * The Swift launcher cannot parse TOML before it has its bundle, and its tests
 * run without the shared tree, so its durations are generated the same way as
 * Identifiers.generated.swift.
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
const OUTPUT_SWIFT = path.join(
	SP,
	'macos/launcher/Sources/ErgoptiPlus/LauncherTimings.generated.swift'
);
// usleep takes a 32-bit microsecond count: the longest duration it can carry.
const MAX_LAUNCHER_MS = Math.floor(0xffffffff / 1000);

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

const launcher = registry.launcher;
if (launcher === null || typeof launcher !== 'object' || Object.keys(launcher).length === 0)
	fail('[launcher] must be a non-empty section.');
for (const [key, value] of Object.entries(launcher)) {
	if (!/^[a-z][a-z0-9_]*_ms$/.test(key))
		fail(`[launcher].${key} must be snake_case and end in _ms.`);
	if (!Number.isSafeInteger(value) || value < 1 || value > MAX_LAUNCHER_MS)
		fail(`[launcher].${key} must be an integer from 1 to ${MAX_LAUNCHER_MS} milliseconds.`);
}

/** The Swift member name of a [launcher] key: file_lock_retry_ms -> fileLockRetry. */
function swiftName(key) {
	return key.slice(0, -'_ms'.length).replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());
}

const swiftRows = Object.entries(launcher)
	.map(
		([key, value]) =>
			`\tstatic let ${swiftName(key)} = RegistryDuration(section: "launcher", key: "${key}", milliseconds: ${value})`
	)
	.join('\n');

const swift = `// Sources/ErgoptiPlus/LauncherTimings.generated.swift
// AUTO-GENERATED from ${SOURCE_REL}.
// DO NOT EDIT BY HAND — run \`npm run codegen:registry-constants\` to refresh.

// ==============================================================================
// MODULE: Launcher Timings
// DESCRIPTION:
// The [launcher] section of the timing registry: every sleep and poll interval
// of the launcher, its fixtures and its tests, in the units the sleep APIs take.
// ==============================================================================

import Foundation

/// One registry duration; the section and key name it in diagnostics.
struct RegistryDuration: Sendable {
	let section: String
	let key: String
	let milliseconds: UInt32

	/// For usleep; the generator bounds every value to a 32-bit count.
	var microseconds: useconds_t { useconds_t(milliseconds) * 1_000 }
	/// For Thread.sleep(forTimeInterval:) and deadlines.
	var seconds: TimeInterval { TimeInterval(milliseconds) / 1_000 }
	/// For Task.sleep(nanoseconds:).
	var nanoseconds: UInt64 { UInt64(milliseconds) * 1_000_000 }
}

enum LauncherTimings {
${swiftRows}
}
`;

fs.writeFileSync(OUTPUT_LUA, lua);
fs.writeFileSync(OUTPUT_SWIFT, swift);
console.log(`[OK] ${path.relative(ROOT, OUTPUT_LUA)} (${Object.keys(limits).length} limit(s))`);
console.log(
	`[OK] ${path.relative(ROOT, OUTPUT_SWIFT)} (${Object.keys(launcher).length} duration(s))`
);
