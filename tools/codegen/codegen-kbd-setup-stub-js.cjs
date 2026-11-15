// tools/codegen/codegen-kbd-setup-stub-js.cjs

/**
 * ==============================================================================
 * MODULE: Generic Windows Layout Installer Codegen
 * DESCRIPTION:
 * Builds the generic, unsigned Windows layout installer
 * (tools/lib/kbd-dll/installer.cjs emitStubNsis) with makensis and writes it to
 * `_shared/ui/layout_editor/_generated/kbd_setup_stub.js` as a classic script
 * defining `LayoutKbdSetupStub` ({file, sha256, base64}), so the layout
 * editor puts it in the Windows package on the site and in the app windows,
 * which cannot run makensis.
 *
 * FEATURES & RATIONALE:
 * 1. One owner: the stub is only ever built here; the page never edits it.
 * 2. Deterministic: makensis gives the same bytes for the same script and
 *    version (CI installs NSIS through tools/ci/ubuntu_apt.py), no timestamp.
 * 3. Fail fast: no makensis, or a script it refuses, stops the generation.
 * ==============================================================================
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { shared } = require('../lib/paths.cjs');
const Installer = require('../lib/kbd-dll/installer.cjs');

const OUT_PATH = shared('ui', 'layout_editor', '_generated', 'kbd_setup_stub.js');
// Base64 characters per line of the generated file.
const LINE = 120;

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 * @throws {Error} When makensis is missing or refuses the script.
 */
function buildSource() {
	if (!Installer.makensisAvailable())
		throw new Error('makensis is required (tools/ci/ubuntu_apt.py nsis)');
	const stub = Installer.buildStub();
	const base64 = stub.bytes.toString('base64');
	const lines = [];
	for (let at = 0; at < base64.length; at += LINE)
		lines.push(`\t\t'${base64.slice(at, at + LINE)}'`);
	return [
		'// _shared/ui/layout_editor/_generated/kbd_setup_stub.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		'// Source: tools/lib/kbd-dll/installer.cjs (emitStubNsis), built by makensis',
		'// Run: npm run codegen:kbd-setup-stub:js',
		'// ==========================================',
		'',
		'// The generic Windows layout installer the layout editor puts in the Windows package.',
		'var LayoutKbdSetupStub = {',
		`\tfile: '${stub.file}',`,
		`\tsha256: '${crypto.createHash('sha256').update(stub.bytes).digest('hex')}',`,
		'\tbase64: [',
		lines.join(',\n'),
		"\t].join('')",
		'};',
		''
	].join('\n');
}

/** Writes the generated file. */
function main() {
	console.log('codegen:kbd-setup-stub:js — building the generic Windows layout installer…');
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:kbd-setup-stub:js — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildSource, OUT_PATH };
