// tools/lib/layout-source-xkb.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source XKB Export
 * DESCRIPTION:
 * Compiles an admitted imported source through the shared Lua converter. Assets
 * and source travel as explicit input; the API returns artifacts without writing
 * files or installing anything. Its report describes document-specific losses.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { REPO_ROOT, shared } = require('./paths.cjs');
const { loadLayoutSource } = require('./layout-source.cjs');

/** Compile all artifacts before a caller publishes any output. */
function exportXkb(document) {
	const source = loadLayoutSource();
	const imported = source.conversionSource(document);
	const metadata = document.exports?.linux || {};
	const id = metadata.name ?? document.layout.id;
	const description = metadata.description ?? document.layout.name;
	if (!/^[a-z][a-z0-9_]*$/.test(id))
		throw new Error('exports.linux.name must be a source identifier');
	// The existing converter interpolates this into an XKB quoted string.
	if (/["\\\u0000-\u001f\u007f-\u009f]/u.test(description))
		throw new Error('exports.linux.description contains an unsupported XKB string character');
	const data = path.join(REPO_ROOT, 'static', 'ergopti', 'linux', 'xkb_generation', 'data');
	const keysyms = JSON.parse(fs.readFileSync(path.join(data, 'key_sym.json'), 'utf8'));
	const types = fs.readFileSync(path.join(data, 'xkb_types.txt'), 'utf8');
	const result = spawnSync('lua', [path.join(__dirname, 'layout_source_xkb.lua'), shared()], {
		encoding: 'utf8',
		input: JSON.stringify({
			xml: imported.text,
			convention: imported.convention,
			layout_id: id,
			display_name: description,
			keycodes: JSON.parse(
				fs.readFileSync(shared('modules', 'layouts', 'mac_keycodes.json'), 'utf8')
			),
			keysyms: keysyms.keysyms,
			locale_extended_prefixes: keysyms.locale_extended_prefixes,
			template: fs.readFileSync(path.join(data, 'xkb_symbols.txt'), 'utf8'),
			types
		}),
		timeout: 30000,
		maxBuffer: 16 * 1024 * 1024
	});
	if (result.error) throw new Error(`xkb_runtime: ${result.error.message}`);
	if (result.status !== 0) throw new Error(`xkb_runtime: ${result.stderr.trim()}`);
	const output = JSON.parse(result.stdout);
	if (!output.ok) {
		const error = new Error(output.reason);
		error.details = output;
		throw error;
	}
	const report = {
		target: 'linux',
		status: 'partial',
		artifact: 'xkb',
		reason: 'seven_level_character_projection',
		blockers: [],
		name: id,
		description,
		...output.projection,
		system_key_codes: output.system_key_codes,
		limitations: [
			'Only the character-key table is generated; listed system/keypad codes keep their installed behavior.',
			'Option maps to AltGr; Linux Alt, Control and Super use the Command shortcut level.',
			'Listed empty cells emit NoSymbol and may inherit XKB symbols; source key disabling is not compiled.',
			'Listed unbound character actions use the converter Unicode keysym fallback, without a physical source action binding.',
			'XCompose requires client support and the exported Compose file; native macOS dead-key fallback and cancellation are not certified.',
			'Registry-specific keysym hints, driver features and installation are outside this source export.'
		]
	};
	return {
		report,
		files: new Map([
			[`${id}.xkb`, output.symbols],
			[`${id}.XCompose`, output.compose],
			['xkb_types.txt', types],
			['export.json', `${JSON.stringify(report, null, 2)}\n`]
		])
	};
}

/** Augment the pure browser model's report with the installed tooling route. */
function targetReport(document) {
	const reports = loadLayoutSource().capabilities(document);
	const index = reports.findIndex((entry) => entry.target === 'linux');
	try {
		reports[index] = exportXkb(document).report;
	} catch (error) {
		reports[index] = {
			target: 'linux',
			status: 'unavailable',
			artifact: 'xkb',
			reason: error.message,
			blockers: [error.message],
			...(error.details ? { details: error.details } : {})
		};
	}
	return reports;
}

module.exports = { exportXkb, targetReport };
