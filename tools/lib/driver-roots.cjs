// tools/lib/driver-roots.cjs

/**
 * ==============================================================================
 * MODULE: Driver Root Discovery
 * DESCRIPTION:
 * The drivers under static/ergopti_plus are the folders that hold a _generated
 * tree and are not the shared one. Gates used to find them by an adapters/
 * folder, which the structure plan empties step by step into the feature
 * folders; _generated stays at every driver's root.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

/** The folder every driver holds at its root and the shared tree never names a driver by. */
const MARKER = '_generated';

/**
 * True when a tracked path, split under static/ergopti_plus, is inside a
 * driver's marker folder: ["windows", "_generated", "x.ahk"].
 * @param {string[]} parts The path's segments below the drivers' root.
 * @returns {boolean}
 */
function isDriverMarkerPath(parts) {
	return parts.length >= 3 && parts[1] === MARKER && !parts[0].startsWith('_');
}

/**
 * The driver folder names under a drivers' root, sorted.
 * @param {string} driversRoot Absolute path of static/ergopti_plus.
 * @returns {string[]} The driver names, e.g. ["linux", "macos", "windows"].
 */
function driverNames(driversRoot) {
	return fs
		.readdirSync(driversRoot, { withFileTypes: true })
		.filter(
			(e) =>
				e.isDirectory() &&
				!e.name.startsWith('_') &&
				fs.existsSync(path.join(driversRoot, e.name, MARKER))
		)
		.map((e) => e.name)
		.sort();
}

module.exports = { driverNames, isDriverMarkerPath };
