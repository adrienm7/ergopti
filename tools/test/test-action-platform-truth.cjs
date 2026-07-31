// tools/test/test-action-platform-truth.cjs

/**
 * ==============================================================================
 * MODULE: Action Platform Declaration Guard
 * DESCRIPTION:
 * `_shared/modules/actions/actions.toml` declares a `platform` for every
 * action. That declaration is not documentation — the macOS picker filters on
 * it, so it decides what a user can bind.
 *
 * ROOT CAUSE ENCODED:
 * Four actions macOS has always implemented — select_line, teleport_mouse,
 * spotlight_mouse, toggle_capslock — were declared platform = "ahk". They live
 * in the keyboard-SHORTCUT layer rather than the gesture registry, so the
 * declaration was true of the gesture and false of the feature, and the shared
 * catalogue read as "macOS does not have this" for four things it ships. Nothing
 * could notice, because the declaration and the registry are in different
 * languages in different trees.
 *
 * Two failures are possible and both are caught here:
 *   - Declared for a platform that has NO handler → the picker offers a row that
 *     does nothing, because execute_single() refuses an action it cannot find.
 *   - Implemented on a platform the declaration excludes → the feature exists and
 *     is unreachable, which is what these four were.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const TOML = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');
const MAC_ACTIONS = path.join(SP, 'macos', 'modules', 'gestures', 'actions.lua');

/**
 * Parses the `[sg_actions.<id>] / [ax_actions.<id>]` blocks and their platform.
 * @returns {{kind: string, id: string, platform: string}[]}
 */
function declarations() {
	const lines = fs.readFileSync(TOML, 'utf8').split(/\r?\n/);
	const out = [];
	for (let i = 0; i < lines.length; i++) {
		const m = lines[i].match(/^\[(sg_actions|ax_actions)\.([\w.]+)\]/);
		if (!m) continue;
		let platform = 'all';
		let isHeader = false;
		for (let j = i + 1; j < lines.length; j++) {
			if (/^\[/.test(lines[j])) break;
			const p = lines[j].match(/^platform\s*=\s*"([^"]+)"/);
			if (p) platform = p[1];
			if (/^is_header\s*=\s*true/.test(lines[j])) isHeader = true;
		}
		// A header is a picker separator, not a dispatchable action, and an id
		// beginning with "_" is a driver-specific placeholder that build_sg_names
		// expands rather than dispatches. Neither can have a handler by design.
		if (isHeader || m[2].startsWith('_')) continue;
		out.push({ kind: m[1], id: m[2], platform });
	}
	return out;
}

const macSrc = fs.readFileSync(MAC_ACTIONS, 'utf8');
const macSg = new Set([...macSrc.matchAll(/\bsg\(\s*"([\w.]+)"/g)].map((m) => m[1]));
const macAx = new Set([...macSrc.matchAll(/\bax\(\s*"([\w.]+)"/g)].map((m) => m[1]));

// Actions registered from the generated table count as registered. 27 of them
// used to be written out as `sg("word_next", function() … end)` and are now
// installed by a loop over _generated/gesture_emit_actions.lua, so a scan that
// only looks for literal sg() calls concludes macOS has no handler for them —
// and reports a row that works perfectly as "a row that does nothing".
const MAC_GENERATED = path.join(SP, 'macos', '_generated', 'gesture_emit_actions.lua');
if (fs.existsSync(MAC_GENERATED)) {
	const gen = fs.readFileSync(MAC_GENERATED, 'utf8');
	for (const m of gen.matchAll(/id\s*=\s*"([\w.]+)"/g)) macSg.add(m[1]);
}

const decls = declarations();
const errors = [];

if (decls.length < 80) {
	errors.push(`parsed only ${decls.length} action declaration(s) — the TOML shape changed, and this guard is reading nothing`);
}
if (macSg.size < 50) {
	errors.push(`found only ${macSg.size} macOS sg() registration(s) — the registry shape changed`);
}

for (const d of decls) {
	const registered = d.kind === 'sg_actions' ? macSg.has(d.id) : macAx.has(d.id);
	const claimsMac = d.platform === 'all' || d.platform === 'hs';

	if (claimsMac && !registered) {
		errors.push(
			`${d.kind}.${d.id}: declared platform="${d.platform}" but macOS registers no handler. ` +
				'The picker will offer it and execute_single() will refuse it — a row that does nothing.'
		);
	}
	if (!claimsMac && registered) {
		errors.push(
			`${d.kind}.${d.id}: macOS registers a handler but the declaration is platform="${d.platform}", ` +
				'so the picker filters it out. The feature exists and is unreachable.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Action platform declarations disagree with the macOS registry:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

const macClaims = decls.filter((d) => d.platform === 'all' || d.platform === 'hs').length;
console.log(
	`\x1b[32m[OK] ${decls.length} action declaration(s); the ${macClaims} that claim macOS all have a ` +
		`handler, and no macOS handler is hidden by its declaration.\x1b[0m`
);
