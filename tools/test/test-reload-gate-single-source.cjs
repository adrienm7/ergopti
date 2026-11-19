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
 * pins the copies together: the Git markers, the bulk threshold, the bulk
 * settle window and the stale-lock report delay must match, or one driver
 * reloads mid-checkout while the others wait. Every Lua reload watcher must
 * also route its Git hold through gate.lua's step_git_hold, which never
 * expires a hold.
 *
 * ROOT CAUSE ENCODED:
 * The Windows watcher had neither signal and reloaded on the first file of a
 * 651-file fast-forward; the successor booted from a half-updated tree. The
 * Linux watcher reloaded through a lock still present after 60 s of quiet,
 * which loads a half-updated tree in the middle of a long rebase.
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

// ── 3. Stale-lock report delay ────────────────────────────────────────────
const gateReport = must(
	gate.match(/M\.GIT_HOLD_REPORT_SEC = (\d+)/),
	'gate.lua GIT_HOLD_REPORT_SEC'
);
const windowsReport = registryValue('ui', 'dev_source_git_hold_report_ms');
if (!windows.includes('TimingsGet("ui", "dev_source_git_hold_report_ms")')) {
	errors.push('dev_source.ahk does not read TimingsGet("ui", "dev_source_git_hold_report_ms")');
}
if (
	gateReport &&
	windowsReport &&
	parseInt(gateReport[1], 10) * 1000 !== parseInt(windowsReport[1], 10)
) {
	errors.push(
		`Stale-lock report differs: gate.lua ${gateReport[1]} s, registry ${windowsReport[1]} ms`
	);
}

// ── 4. Lua watchers share the never-expiring hold ─────────────────────────
// A watcher that counts its own deferrals can grow a cap that reloads through
// a live lock, as the Linux one did; the shared transition has no such exit.
for (const rel of [
	'static/ergopti_plus/linux/core/fs/engine/file_watchers.lua',
	'static/ergopti_plus/macos/core/fs/engine/file_watchers.lua',
	'static/ergopti_plus/macos/menu/ui/builder/watchers.lua'
]) {
	const source = fs.readFileSync(path.join(ROOT, rel), 'utf8');
	for (const call of ['reload_gate.step_git_hold(', 'reload_gate.log_git_hold(']) {
		if (!source.includes(call)) errors.push(`${rel} does not call ${call.slice(0, -1)}`);
	}
	if (/MAX_DEFERRALS|WARN_DEFERRALS|defer_count/.test(source)) {
		errors.push(`${rel} keeps its own Git deferral counter instead of step_git_hold`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] The Windows developer reload gate diverged from gate.lua:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] Reload gate single source: Windows dev_source.ahk matches gate.lua (Git markers, bulk threshold, bulk settle, stale-lock report), and every Lua watcher holds through step_git_hold.\x1b[0m'
);
