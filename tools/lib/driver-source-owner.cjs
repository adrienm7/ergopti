// tools/lib/driver-source-owner.cjs

/**
 * ==============================================================================
 * MODULE: Driver Source Owner Lookup
 * DESCRIPTION:
 * Finds the one production file of a driver that a JS check reads, by its base
 * name or by a declaration it holds, instead of by a hard path. The structure
 * plan moves driver files into feature folders step by step; a check that
 * joins a folder path stops at ENOENT on the next move although the file and
 * the claim it checks are unchanged.
 *
 * FEATURES & RATIONALE:
 * 1. Tracked files only: an untracked scratch copy cannot become the owner.
 * 2. Production only: tests, fixtures, generated and vendored trees are never
 *    an owner, so a test that quotes the declaration cannot shadow it.
 * 3. Exactly one: no match or two matches throw, naming every candidate, so a
 *    lookup never picks one file of several silently.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { REPO_ROOT } = require('./paths.cjs');
const { gitPaths } = require('./git-paths.cjs');

const DRIVERS_REL = 'static/ergopti_plus';

// Folders under a driver root that hold no hand-written production source.
const NON_PRODUCTION = new Set(['tests', '_generated', 'vendor', 'build', 'docs']);

/**
 * The tracked production files of one driver, repository-relative.
 * @param {string} driver Driver folder name: windows, macos or linux.
 * @returns {string[]} Forward-slash repository paths.
 */
function driverProductionFiles(driver) {
	const root = `${DRIVERS_REL}/${driver}/`;
	const files = gitPaths(REPO_ROOT, ['ls-files', '--cached', '-z', '--', root])
		.map((rel) => rel.split(path.sep).join('/'))
		.filter((rel) => !NON_PRODUCTION.has(rel.slice(root.length).split('/')[0]));
	if (files.length === 0) throw new Error(`No tracked production file under ${root}.`);
	return files;
}

/**
 * Returns the single candidate or throws with every candidate named.
 * @param {string[]} hits Matching repository paths.
 * @param {string} what Description of the lookup for the error.
 * @returns {{rel: string, text: string}} The owner and its content.
 */
function single(hits, what) {
	if (hits.length !== 1)
		throw new Error(
			`${what} must match exactly one production file; found ${hits.length}: ` +
				(hits.join(', ') || '(none)')
		);
	return { rel: hits[0], text: fs.readFileSync(path.join(REPO_ROOT, hits[0]), 'utf8') };
}

/**
 * The one production file of a driver with this base name.
 * @param {string} driver Driver folder name.
 * @param {string} baseName File name with its extension, e.g. magic_key_source.lua.
 * @returns {{rel: string, text: string}} The owner and its content.
 */
function driverFileNamed(driver, baseName) {
	const hits = driverProductionFiles(driver).filter((rel) => path.posix.basename(rel) === baseName);
	return single(hits, `${driver} file ${baseName}`);
}

/**
 * The one production file of a driver, with this extension, whose content
 * matches a declaration pattern.
 * @param {string} driver Driver folder name.
 * @param {string} extension File extension with its dot, e.g. .ahk.
 * @param {RegExp} declaration Pattern only the owner holds.
 * @returns {{rel: string, text: string}} The owner and its content.
 */
function driverFileDefining(driver, extension, declaration) {
	const hits = driverProductionFiles(driver)
		.filter((rel) => rel.endsWith(extension))
		.filter((rel) => declaration.test(fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8')));
	return single(hits, `${driver} declaration ${declaration}`);
}

module.exports = { driverProductionFiles, driverFileNamed, driverFileDefining };
