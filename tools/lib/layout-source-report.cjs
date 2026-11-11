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

/** Run target admission before claiming an artifact can be produced. */
function targetReport(document) {
	const source = loadLayoutSource();
	const reports = source.capabilities(document);
	// A structured source compiles through the shared generator; a preserved import
	// keeps the pure model's verdict on its original .keylayout.
	const macos = document.imported_keylayout
		? []
		: [{ target: 'macos', artifact: 'bundle', compile: (doc) => source.exportMacos(doc) }];
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
	// (_shared/lua/layouts/composer.lua): its compiled .keylayout is installed and
	// emulated, so a driver carries what that file carries and omits the rest.
	for (const target of ['driver_macos', 'driver_linux']) {
		const index = reports.findIndex((entry) => entry.target === target);
		try {
			const compiled = source.targetKeylayout(document, 'macos');
			reports[index] = {
				target,
				status: compiled.omitted.length ? 'partial' : 'emulated',
				artifact: 'emulation',
				reason: 'compiled_keylayout_installed_by_composer_host',
				blockers: [],
				omitted: compiled.omitted
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
