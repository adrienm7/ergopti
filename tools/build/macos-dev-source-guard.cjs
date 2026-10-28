// tools/build/macos-dev-source-guard.cjs

/**
 * ==============================================================================
 * MODULE: macOS Developer Source Build Guard
 * DESCRIPTION:
 * Refuses an ErgoptiPlus.app built with ERGOPTI_DEV_SOURCE=1. Its launcher runs
 * the Lua of one repository clone (Info.plist key dev_source.plist_key of
 * _shared/data/identifiers.json), so it must never be archived, receipted,
 * installed by CI or published.
 *
 * USAGE: node tools/build/macos-dev-source-guard.cjs <ErgoptiPlus.app>
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { shared } = require('../lib/paths.cjs');

/** The launcher Info.plist key a developer source build carries. */
function developerSourceKey() {
	const key = JSON.parse(fs.readFileSync(shared('data/identifiers.json'), 'utf8')).dev_source
		?.plist_key;
	if (typeof key !== 'string' || !/^[A-Za-z][A-Za-z0-9]*$/.test(key))
		throw new Error('identifiers.json declares no valid dev_source.plist_key.');
	return key;
}

/**
 * Throws when the application is a developer source build. The launcher plist
 * is generated as XML; any other form cannot be proven free of the key.
 * @param {string} application Absolute path of the .app bundle.
 */
function refuseDeveloperSource(application) {
	if (typeof application !== 'string' || !path.isAbsolute(application))
		throw new Error('An absolute application path is required.');
	const bytes = fs.readFileSync(path.join(application, 'Contents', 'Info.plist'));
	const text = bytes.toString('utf8');
	if (bytes.subarray(0, 6).toString('latin1') === 'bplist' || !/<plist[\s>]/.test(text))
		throw new Error(`${application}: Info.plist is not an XML property list.`);
	const key = developerSourceKey();
	if (text.includes(`<key>${key}</key>`))
		throw new Error(
			`${application} is a developer source build (${key}); it is never archived, installed or published.`
		);
}

if (require.main === module) {
	if (process.argv.length !== 3) throw new Error('Expected the application bundle path.');
	refuseDeveloperSource(path.resolve(process.argv[2]));
	console.log('[OK] not a developer source build: ' + process.argv[2]);
}

module.exports = { developerSourceKey, refuseDeveloperSource };
