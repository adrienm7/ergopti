// tools/lib/layout-source-report.cjs

/**
 * ==============================================================================
 * MODULE: Layout Source Native Tooling Report
 * DESCRIPTION:
 * Augments the pure browser model with the actual admitted native export routes.
 * A missing runtime or refused source stays unavailable with its concrete reason.
 * ==============================================================================
 */

'use strict';

const { loadLayoutSource } = require('./layout-source.cjs');
const { exportXkb } = require('./layout-source-xkb.cjs');
const { exportKlc } = require('./layout-source-klc.cjs');

/** Run target admission before claiming an artifact can be produced. */
function targetReport(document) {
	const reports = loadLayoutSource().capabilities(document);
	for (const { target, artifact, compile } of [
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
	return reports;
}

module.exports = { targetReport };
