// tools/test/test-reload-gate-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Reload Gate Single Source
 * DESCRIPTION:
 * The macOS and Linux drivers hold an automatic reload through the shared
 * `_shared/core/lifecycle/engine/reload/gate.lua`: while Git rewrites the tree
 * (index.lock and the multi-step markers) and until a bulk burst settled. The
 * Windows developer source watcher (`core/lifecycle/engine/dev_source.ahk`)
 * cannot run that Lua, so it keeps the same policy in AutoHotkey, its bulk
 * threshold and settle window read from the shared timing registry. This gate
 * pins the copies together: the Git markers, the bulk threshold and the bulk
 * settle window must match, or one driver reloads mid-checkout while the
 * others wait.
 *
 * ROOT CAUSE ENCODED:
 * The Windows watcher had neither signal and reloaded on the first file of a
 * 651-file fast-forward; the successor booted from a half-updated tree.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const GATE = path.join(ROOT, 'static/ergopti_plus/_shared/core/lifecycle/engine/reload/gate.lua');
const WINDOWS = path.join(ROOT, 'static/ergopti_plus/windows/core/lifecycle/engine/dev_source.ahk');
const REGISTRY = path.join(ROOT, 'static/ergopti_plus/_shared/core/timing/data/constants.toml');

const errors = [];

function must(match, label) {
	if (!match) {
		errors.push(`${label} not found`);
		return null;
	}
	return match;
}

function quoted(text) {
	return [...text.matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}

const gate = fs.readFileSync(GATE, 'utf8');
const windows = fs.readFileSync(WINDOWS, 'utf8');
const registry = fs.readFileSync(REGISTRY, 'utf8').replace(/\r\n/g, '\n');

// ── 1. Git markers ────────────────────────────────────────────────────────
const gateMarkers = must(gate.match(/local GIT_MARKERS = \{([\s\S]*?)\}/), 'gate.lua GIT_MARKERS');
const gateProbes = must(
	gate.match(/local GIT_REBASE_PROBES = \{([\s\S]*?)\}/),
	'gate.lua GIT_REBASE_PROBES'
);
const windowsMarkers = must(
	windows.match(/global DEV_SOURCE_GIT_MARKERS := \[([\s\S]*?)\]/),
	'dev_source.ahk DEV_SOURCE_GIT_MARKERS'
);
if (gateMarkers && gateProbes && windowsMarkers) {
	const expected = [...quoted(gateMarkers[1]), ...quoted(gateProbes[1])];
	const actual = quoted(windowsMarkers[1]).map((m) => m.replace(/\\/g, '/'));
	if (expected.length < 2 || JSON.stringify(expected) !== JSON.stringify(actual)) {
		errors.push(
			`Git markers differ: gate.lua ${JSON.stringify(expected)}, Windows ${JSON.stringify(actual)}`
		);
	}
}

// ── 2. Bulk threshold and settle window ───────────────────────────────────
// Windows reads both from the shared registry; the registry copy is pinned here.
function registryValue(section, key) {
	const block = registry.match(
		new RegExp(`^\\[${section}\\]\\n([\\s\\S]*?)(?=^\\[|(?![\\s\\S]))`, 'm')
	);
	const line = block && block[1].match(new RegExp(`^${key} = (\\d+)$`, 'm'));
	return must(line, `constants.toml [${section}] ${key}`);
}
const gateThreshold = must(gate.match(/M\.BULK_THRESHOLD = (\d+)/), 'gate.lua BULK_THRESHOLD');
const gateSettle = must(gate.match(/M\.BULK_SETTLE_SEC = ([\d.]+)/), 'gate.lua BULK_SETTLE_SEC');
const windowsThreshold = registryValue('ui', 'dev_source_bulk_threshold');
const windowsSettle = registryValue('ui', 'dev_source_bulk_settle_ms');
for (const read of [
	'TimingsGet("ui", "dev_source_bulk_threshold")',
	'TimingsGet("ui", "dev_source_bulk_settle_ms")'
]) {
	if (!windows.includes(read)) errors.push(`dev_source.ahk does not read ${read}`);
}
if (gateThreshold && windowsThreshold && gateThreshold[1] !== windowsThreshold[1]) {
	errors.push(
		`Bulk threshold differs: gate.lua ${gateThreshold[1]}, registry ${windowsThreshold[1]}`
	);
}
if (
	gateSettle &&
	windowsSettle &&
	Math.round(parseFloat(gateSettle[1]) * 1000) !== parseInt(windowsSettle[1], 10)
) {
	errors.push(`Bulk settle differs: gate.lua ${gateSettle[1]} s, registry ${windowsSettle[1]} ms`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] The Windows developer reload gate diverged from gate.lua:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] Reload gate single source: Windows dev_source.ahk matches gate.lua (Git markers, bulk threshold, bulk settle).\x1b[0m'
);
