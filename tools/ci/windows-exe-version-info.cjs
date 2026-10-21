// tools/ci/windows-exe-version-info.cjs
// Owns the expected version resource of ErgoptiPlus.exe. The identity fields
// are read from the Ahk2Exe directives in ErgoptiPlus.ahk, so the source stays
// their only owner; the version is the build's stamped BUNDLE_VERSION.
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../..');
const ENTRY = 'static/ergopti_plus/windows/ErgoptiPlus.ahk';
const BUNDLE = 'static/ergopti_plus/windows/infra/bundle.ahk';
const UNSTAMPED_VERSION = '0.0.0-dev';

// Ahk2Exe directive -> Windows FileVersionInfo property.
const IDENTITY_DIRECTIVES = Object.freeze({
	SetProductName: 'ProductName',
	SetCompanyName: 'CompanyName',
	SetDescription: 'FileDescription',
	SetCopyright: 'LegalCopyright',
	SetOrigFilename: 'OriginalFilename',
	SetInternalName: 'InternalName'
});

/**
 * Reads the identity directives declared in the driver entry.
 * @param {string} [root] The repository root.
 * @returns {Record<string, string>} FileVersionInfo property -> value.
 */
function readDeclaredIdentity(root = ROOT) {
	const source = fs.readFileSync(path.join(root, ENTRY), 'utf8');
	const identity = {};
	for (const [directive, property] of Object.entries(IDENTITY_DIRECTIVES)) {
		const matches = [...source.matchAll(new RegExp(`^;@Ahk2Exe-${directive} (.+)$`, 'gm'))];
		if (matches.length !== 1)
			throw new Error(
				`${ENTRY} must declare ;@Ahk2Exe-${directive} exactly once, found ${matches.length}.`
			);
		const value = matches[0][1].trim();
		if (value === '') throw new Error(`;@Ahk2Exe-${directive} must not be empty.`);
		identity[property] = value;
	}
	return identity;
}

/**
 * The full expected version resource for a build.
 * @param {string} version The stamped release version, or '' for an unstamped build.
 * @param {string} [root] The repository root.
 * @returns {Record<string, string>}
 */
function expectedVersionInfo(version, root = ROOT) {
	if (typeof version !== 'string') throw new TypeError('The build version must be a string.');
	const stamped = version === '' ? UNSTAMPED_VERSION : version;
	return { ...readDeclaredIdentity(root), FileVersion: stamped, ProductVersion: stamped };
}

module.exports = {
	ENTRY,
	BUNDLE,
	UNSTAMPED_VERSION,
	IDENTITY_DIRECTIVES,
	readDeclaredIdentity,
	expectedVersionInfo
};

if (require.main === module) {
	const args = process.argv.slice(2);
	if (args.length !== 2 || args[0] !== '--version') {
		process.stderr.write('Usage: node tools/ci/windows-exe-version-info.cjs --version <version>\n');
		process.exit(2);
	}
	process.stdout.write(JSON.stringify(expectedVersionInfo(args[1])) + '\n');
}
