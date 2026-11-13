// tools/lib/layout-source-report.cjs

/**
 * ==============================================================================
 * MODULE: Layout Source Native Tooling Report
 * DESCRIPTION:
 * Augments the pure browser model with the actual admitted native export routes:
 * the macOS bundle of a structured source, and the Linux XKB and Windows KLC files.
 * A missing runtime or refused source stays unavailable with its concrete reason.
 * ==============================================================================
 */

'use strict';

const { loadLayoutSource } = require('./layout-source.cjs');
const { exportXkb } = require('./layout-source-xkb.cjs');
const { exportKlc } = require('./layout-source-klc.cjs');

// The .keylayout omissions the emulation table takes over; what it cannot
// perform comes back in its own not_emulated list.
const EMULATED_REASONS = new Set([
	'custom_modifier_not_in_keylayout',
	'modifier_not_in_keylayout',
	'shortcut_output_not_in_keylayout',
	'tap_hold_not_in_keylayout',
	'system_or_modifier_key_remap',
	'key_chord_not_in_keylayout',
	'action_not_in_keylayout'
]);

/**
 * Run target admission before claiming an artifact can be produced.
 * @param {object} document - A validated source.
 * @param {object} [icons] - PNG file name -> bytes for the macOS bundle icons.
 */
function targetReport(document, icons) {
	const source = loadLayoutSource();
	const reports = source.capabilities(document);
	// A structured source compiles through the shared generator; a preserved import
	// keeps the pure model's verdict on its original .keylayout.
	const macos = document.imported_keylayout
		? []
		: [
				{
					target: 'macos',
					artifact: 'bundle',
					compile: (doc) => source.exportMacos(doc, undefined, icons)
				}
			];
	for (const { target, artifact, compile } of [
		...macos,
		{ target: 'linux', artifact: 'xkb', compile: exportXkb },
		{ target: 'windows', artifact: 'klc', compile: exportKlc }
	]) {
		const index = reports.findIndex((entry) => entry.target === target);
		try {
			reports[index] = compile(document).report;
		} catch (error) {
			reports[index] = {
				target,
				status: 'unavailable',
				artifact,
				reason: error.message,
				blockers: [error.message],
				...(error.details ? { details: error.details } : {})
			};
		}
	}
	// The macOS and Linux drivers take a source through the layout composer host
	// (_shared/layouts/engine/composer/composer.lua): its compiled .keylayout is installed and
	// emulated, and its emulation table performs what that file leaves out; a
	// driver omits what neither carries.
	for (const [target, platform] of [
		['driver_macos', 'macos'],
		['driver_linux', 'linux']
	]) {
		const index = reports.findIndex((entry) => entry.target === target);
		try {
			const compiled = source.targetKeylayout(document, 'macos');
			const emulated = document.imported_keylayout
				? { not_emulated: [] }
				: source.compileEmulation(document, { platform });
			const omitted = compiled.omitted
				.filter((entry) => !EMULATED_REASONS.has(entry.reason))
				.concat(emulated.not_emulated);
			reports[index] = {
				target,
				status: omitted.length ? 'partial' : 'emulated',
				artifact: 'emulation',
				reason: 'compiled_keylayout_and_emulation_table_by_composer_host',
				blockers: [],
				omitted
			};
		} catch (error) {
			reports[index] = {
				target,
				status: 'unavailable',
				artifact: 'emulation',
				reason: error.message,
				blockers: [error.message]
			};
		}
	}
	return reports;
}

module.exports = { targetReport };
