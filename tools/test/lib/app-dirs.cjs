// tools/test/lib/app-dirs.cjs

/**
 * ==============================================================================
 * MODULE: Application Folders for Node Tools
 * DESCRIPTION:
 * Reads _shared/core/fs/data/paths/app_dirs.toml, the one declaration of the
 * Ergopti folders, for the Node tests and tools that must name a folder of a
 * driver (a startup smoke's logs, a fixture home) without spelling it.
 *
 * FEATURES & RATIONALE:
 * 1. One Source: the drivers read the same TOML through their generated files
 *    (tools/codegen/codegen-app-dirs.cjs); a Node caller reads the TOML itself
 *    so it cannot drift from them.
 * 2. Fail Fast: a missing table or segment list throws instead of guessing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { parse } = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const APP_DIRS = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'core',
	'fs',
	'data',
	'paths',
	'app_dirs.toml'
);

/** The parsed app_dirs.toml. */
function loadAppDirs() {
	return parse(fs.readFileSync(APP_DIRS, 'utf8'));
}

const data = loadAppDirs();

/**
 * The folder name of one OS: `Ergopti` on macOS and Windows, `ergopti` on Linux.
 * @param {'macos'|'windows'|'linux'} osName
 * @returns {string}
 */
function folderName(osName) {
	return osName === 'linux' ? data.app.linux_folder_name : data.app.folder_name;
}

/**
 * The segments of a dotted table (e.g. "logs.windows"), "{app}" resolved.
 * @param {string} dotted Table name.
 * @param {'macos'|'windows'|'linux'} osName OS whose folder name "{app}" means.
 * @param {string} [key] Segment list key, "segments" by default.
 * @returns {string[]}
 */
function segments(dotted, osName, key = 'segments') {
	let table = data;
	for (const part of dotted.split('.')) {
		table = table[part];
		if (!table || typeof table !== 'object')
			throw new Error(`app_dirs.toml has no [${dotted}] table`);
	}
	const list = table[key];
	if (!Array.isArray(list) || list.length === 0)
		throw new Error(`app_dirs.toml [${dotted}] ${key} must be a non-empty list`);
	return list.map((segment) => segment.replace('{app}', folderName(osName)));
}

module.exports = { APP_DIRS, data, folderName, loadAppDirs, segments };
