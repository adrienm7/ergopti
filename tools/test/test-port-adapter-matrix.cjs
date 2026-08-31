// tools/test/test-port-adapter-matrix.cjs

/**
 * ==============================================================================
 * MODULE: Port × Driver Adapter Matrix
 * DESCRIPTION:
 * Which ports each driver ships an adapter for is a pure filesystem fact that
 * spans all three trees, and nothing measured it. Each driver's own compliance
 * test loads its adapters and inspects the real method table — that is the right
 * check and it stays where it is, because only a runtime check catches an adapter
 * that fails to LOAD. But a per-driver test cannot see that a port present on two
 * drivers vanished from the third, because from inside one tree that is not an
 * event.
 *
 * This is the cross-tree half, and only that half. It reads directory entries; it
 * asserts nothing about behaviour.
 *
 * WHAT IS FROZEN:
 * 1. The matrix itself. 21 ports; Windows and macOS ship all 21, Linux 13. A port
 *    losing an adapter fails here, in the direction that matters — silently
 *    dropping one is how a capability becomes a claim.
 * 2. Every absence carries a reason. ADR-008 settled that a port is a contract
 *    for the drivers that need the capability, not a checklist — which makes an
 *    unexplained absence and a deliberate one look identical. They do not look
 *    identical here.
 * 3. No port is absent everywhere. A contract no driver implements is a contract
 *    describing nothing, and `contracts.json` would still report it as covered.
 *
 * WHY THE ABSENCES ARE WHAT THEY ARE: nine of Linux's were adapters DELETED under
 * ADR-008 because they had zero production callers — a `notifier.lua` nothing
 * called made the tree answer "does Linux notify?" wrongly by inspection. The
 * gate records that, so re-adding one without a caller is a decision rather than
 * an accident.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static/ergopti_plus');
const CONTRACTS = path.join(DRIVERS, '_shared/core/ports/contracts.json');

const EXT = { windows: '.ahk', macos: '.lua', linux: '.lua' };

// Every port a driver does NOT ship an adapter for, with the reason. An entry
// here is a decision; an unlisted absence is a finding.
const DECLARED_ABSENT = {
	linux: {
		AppLauncher: 'deleted under ADR-008 — zero production callers; the daemon launches nothing',
		HotkeyRegistrar: 'no global keyboard-grab API in userland; kanata owns the key path',
		KeyState: 'deleted under ADR-008 — zero production callers',
		MouseControl: 'deleted under ADR-008 — zero production callers; no gesture layer',
		NetworkInfo: 'deleted under ADR-008 — zero production callers',
		TextSender: 'deleted under ADR-008 — zero production callers; the transactional injector owns Linux output',
		TooltipRenderer: 'not implemented — no hotstring preview and no LLM prediction preview (README feature table)',
		WindowManager: 'deleted under ADR-008 — zero production callers'
	},
	windows: {},
	macos: {}
};

const errors = [];

/** PascalCase port name → the adapter file stem. */
function stemOf(port) {
	return port
		.replace(/([a-z0-9])([A-Z])/g, '$1_$2')
		.replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
		.toLowerCase();
}

const contracts = JSON.parse(fs.readFileSync(CONTRACTS, 'utf8')).ports;
const ports = Object.keys(contracts);

// Floor: an empty or truncated contracts.json would make every loop below run
// zero times and report success over nothing.
if (ports.length < 15) {
	errors.push(`contracts.json declares ${ports.length} port(s) — expected at least 15; the file is truncated or the parse is wrong`);
}




// ==================================================
// ==================================================
// ======= 1/ Build The Matrix ======================
// ==================================================
// ==================================================

const present = {};
for (const driver of Object.keys(EXT)) {
	present[driver] = new Set();
	const dir = path.join(DRIVERS, driver, 'adapters');
	if (!fs.existsSync(dir)) {
		errors.push(`${driver}/adapters/ does not exist — the tree moved and this gate measures nothing`);
		continue;
	}
	for (const port of ports) {
		if (fs.existsSync(path.join(dir, stemOf(port) + EXT[driver]))) present[driver].add(port);
	}
	if (present[driver].size === 0) {
		errors.push(`${driver} ships an adapter for none of the ${ports.length} ports — the stem mapping drifted`);
	}
}




// ==================================================
// ==================================================
// ======= 2/ Every Absence Is Declared =============
// ==================================================
// ==================================================

for (const driver of Object.keys(EXT)) {
	const declared = DECLARED_ABSENT[driver] || {};

	for (const port of ports) {
		if (present[driver].has(port)) {
			if (declared[port]) {
				errors.push(
					`${driver} now ships an adapter for ${port}, which is recorded as absent ("${declared[port]}"). ` +
						'Remove the entry — the reason is stale, and a stale reason is worse than none.'
				);
			}
			continue;
		}
		if (!declared[port]) {
			errors.push(
				`${driver} ships no adapter for ${port} and nothing records why. ADR-008 says a port is a ` +
					'contract for the drivers that need it — which makes a deliberate absence and a dropped ' +
					'one look identical unless the deliberate one is written down.'
			);
		}
	}

	for (const port of Object.keys(declared)) {
		if (!ports.includes(port)) {
			errors.push(`${driver} records an absence for "${port}", which is not a port in contracts.json — the note is stale`);
		}
	}
}




// ==================================================
// ==================================================
// ======= 3/ No Port Is Absent Everywhere ==========
// ==================================================
// ==================================================

for (const port of ports) {
	const shipped = Object.keys(EXT).filter((d) => present[d].has(port));
	if (shipped.length === 0) {
		errors.push(
			`${port} has no adapter on any driver. A contract nothing implements describes nothing, and ` +
				'contracts.json would still report it covered.'
		);
	}
}




// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the port × driver adapter matrix changed:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

const counts = Object.keys(EXT).map((d) => `${d} ${present[d].size}`).join(', ');
const everywhere = ports.filter((p) => Object.keys(EXT).every((d) => present[d].has(p))).length;
console.log(
	`\x1b[32m[OK] ${ports.length} port(s): ${counts}; ${everywhere} on all three, every absence declared with ` +
		'a reason, none absent everywhere.\x1b[0m'
);
