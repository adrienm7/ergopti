// tools/ci/windows-exe-version-info.cjs
// Owns the version resource of ErgoptiPlus.exe. The identity fields come from
// tools/lib/app-metadata.cjs, shared with the macOS and Linux packages, and
// reach Ahk2Exe as the directives of the generated include
// windows/_generated/exe_version_info.ahk; the version is the build's stamped
// BUNDLE_VERSION and the copyright ends at its stamped BUNDLE_BUILD_YEAR.
'use strict';
const path = require('node:path');

const { app } = require('../lib/identifiers.cjs');
const metadata = require('../lib/app-metadata.cjs');

const ROOT = path.resolve(__dirname, '../..');
const ENTRY = `static/ergopti_plus/windows/${app.ahk}`;
const BUNDLE = 'static/ergopti_plus/windows/core/lifecycle/engine/bundle.ahk';
const INCLUDE = 'static/ergopti_plus/windows/_generated/exe_version_info.ahk';
const UNSTAMPED_VERSION = '0.0.0-dev';

// Ahk2Exe directive -> Windows FileVersionInfo property.
const IDENTITY_DIRECTIVES = Object.freeze({
	SetProductName: 'ProductName',
	SetCompanyName: 'CompanyName',
	SetDescription: 'FileDescription',
	SetCopyright: 'LegalCopyright',
	SetOrigFilename: 'OriginalFilename',
	SetInternalName: 'InternalName',
	// Ahk2Exe has no SetComments: Set writes any property, from a real string table row.
	'Set Comments,': 'Comments'
});

/**
 * The identity fields of the exe for a build of the given year.
 * @param {number} endYear The year of the commit built.
 * @returns {Record<string, string>} FileVersionInfo property -> value.
 */
function identity(endYear) {
	const meta = metadata.readMetadata();
	return {
		ProductName: meta.productName,
		CompanyName: meta.publisher,
		FileDescription: `${meta.productName}: ${meta.summary}`,
		LegalCopyright: metadata.copyrightNotice(endYear, meta),
		OriginalFilename: app.exe,
		InternalName: app.name,
		Comments: `Website: ${meta.homepage} - Support: ${meta.issues}`
	};
}

/**
 * Renders the generated include. The copyright ends at the year the CI stamps
 * into bundle.ahk (U_BundleBuildYear, read there from the line before its Let);
 * an unstamped local build, or one of the first year, names the first year alone.
 * @returns {string}
 */
function renderInclude() {
	const meta = metadata.readMetadata();
	const fields = identity(meta.firstYear);
	const lines = [];
	for (const [directive, property] of Object.entries(IDENTITY_DIRECTIVES)) {
		const value = fields[property];
		// A comma splits a Set directive, % and ~ open a deref and ; a comment.
		if (/[,%~;\r\n]/.test(value))
			throw new Error(`${property} cannot be a directive value: ${JSON.stringify(value)}`);
		if (property !== 'LegalCopyright') lines.push(`;@Ahk2Exe-${directive} ${value}`);
	}
	const notice = fields.LegalCopyright.replace(`${meta.firstYear}`, '%U_CopyrightYears%');
	if (notice === fields.LegalCopyright) throw new Error('the notice does not name its first year.');
	lines.push(
		`;@Ahk2Exe-Let U_CopyrightYears = ${meta.firstYear}–%U_BundleBuildYear%`,
		`;@Ahk2Exe-Let U_CopyrightYears = %U_CopyrightYears~–(_{2}BUNDLE_BUILD_YEAR_{2}|${meta.firstYear})$~%`,
		`;@Ahk2Exe-SetCopyright ${notice}`
	);
	return (
		'﻿; _generated/exe_version_info.ahk\n' +
		'; AUTO-GENERATED from tools/lib/app-metadata.cjs (LICENSE, CNAME and\n' +
		'; _shared/core/text/data/app_metadata.json).\n' +
		'; DO NOT EDIT BY HAND — run `npm run codegen:exe-version-info` to refresh.\n' +
		';\n' +
		'; The version resource of the compiled exe (file Properties > Details), as\n' +
		'; Ahk2Exe directives: plain comments for the interpreter. Included right after\n' +
		'; core/lifecycle/engine/bundle.ahk, whose stamped BUNDLE_BUILD_YEAR ends the\n' +
		'; copyright and whose BUNDLE_VERSION sets the version.\n' +
		lines.join('\n') +
		'\n'
	);
}

/**
 * The full expected version resource for a build.
 * @param {string} version The stamped release version, or '' for an unstamped build.
 * @param {number} endYear The stamped build year, or the first year for an unstamped build.
 * @returns {Record<string, string>}
 */
function expectedVersionInfo(version, endYear) {
	if (typeof version !== 'string') throw new TypeError('The build version must be a string.');
	const stamped = version === '' ? UNSTAMPED_VERSION : version;
	return { ...identity(endYear), FileVersion: stamped, ProductVersion: stamped };
}

/** JSON whose non-ASCII characters are escaped, so any console code page reads it. */
function asciiJson(value) {
	return JSON.stringify(value).replace(
		/[\u007f-￿]/g,
		(character) => `\\u${character.charCodeAt(0).toString(16).padStart(4, '0')}`
	);
}

module.exports = {
	ENTRY,
	BUNDLE,
	INCLUDE,
	UNSTAMPED_VERSION,
	IDENTITY_DIRECTIVES,
	identity,
	renderInclude,
	expectedVersionInfo,
	asciiJson
};

if (require.main === module) {
	const args = process.argv.slice(2);
	if (args.length !== 2 || args[0] !== '--version') {
		process.stderr.write('Usage: node tools/ci/windows-exe-version-info.cjs --version <version>\n');
		process.exit(2);
	}
	process.stdout.write(asciiJson(expectedVersionInfo(args[1], metadata.buildYear())) + '\n');
}
