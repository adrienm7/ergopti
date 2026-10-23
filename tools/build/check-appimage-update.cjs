// tools/build/check-appimage-update.cjs

/**
 * ==============================================================================
 * MODULE: AppImage Update Information Check
 * DESCRIPTION:
 * Owns the update information an AppImage carries and proves, on the packaged
 * files, that AppImageUpdate can find and apply a newer release.
 *
 * FEATURES & RATIONALE:
 * 1. One source: UPDATE_INFORMATION is the string appimagetool embeds (-u) and
 *    the string this check expects in the ELF section `.upd_info`. The
 *    packager reads it through --print-update-information.
 * 2. The embedded string must match: an AppImage built without -u carries an
 *    empty section and silently never updates.
 * 3. The `.zsync` file published beside it must name the asset the release
 *    actually carries (its URL header is a relative file name: a zsync made
 *    from the pre-rename file name would point at an asset that does not
 *    exist), state the length of that AppImage, and carry block checksums.
 * 4. Pure parsers (parseUpdateInformation, readEmbeddedUpdateInformation,
 *    parseZsyncHeader, verify) take buffers, so the logic is tested on any host.
 *
 * Usage:
 *   node tools/build/check-appimage-update.cjs <AppImage> <AppImage.zsync>
 *   node tools/build/check-appimage-update.cjs --print-update-information
 *   node tools/build/check-appimage-update.cjs --print-appimage-asset
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

/** The release asset names, shared with the release assembly and the site. */
const APPIMAGE_ASSET = 'ErgoptiPlus-x86_64.AppImage';
const ZSYNC_ASSET = `${APPIMAGE_ASSET}.zsync`;
/** gh-releases-zsync|owner|repository|release|asset glob (the glob matches the .zsync asset). */
const UPDATE_INFORMATION =
	'gh-releases-zsync|adrienm7|ergopti|latest|ErgoptiPlus-*x86_64.AppImage.zsync';

/** Name of the ELF section appimagetool writes the update information into. */
const UPDATE_SECTION = '.upd_info';

/**
 * Splits and validates an update information string.
 * @param {string} text The gh-releases-zsync string.
 * @returns {{owner: string, repository: string, release: string, pattern: string}}
 * @throws {Error} When the shape is not gh-releases-zsync with five fields.
 */
function parseUpdateInformation(text) {
	const fields = String(text).split('|');
	if (fields.length !== 5 || fields[0] !== 'gh-releases-zsync' || fields.some((f) => f === '')) {
		throw new Error(
			`update information is not gh-releases-zsync|owner|repository|release|asset: "${text}"`
		);
	}
	return { owner: fields[1], repository: fields[2], release: fields[3], pattern: fields[4] };
}

/**
 * Whether a file name matches a release asset glob ("*" only).
 * @param {string} pattern Asset glob.
 * @param {string} name File name.
 * @returns {boolean}
 */
function globMatches(pattern, name) {
	const source = pattern
		.split('*')
		.map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&'))
		.join('.*');
	return new RegExp(`^${source}$`).test(name);
}

/**
 * Reads the update information embedded in an AppImage's ELF section.
 * @param {Buffer} image The AppImage (an ELF64 little-endian runtime plus payload).
 * @returns {string|null} The embedded string, null when the section is absent.
 * @throws {Error} When the file is not an ELF64 little-endian image.
 */
function readEmbeddedUpdateInformation(image) {
	if (
		image.length < 64 ||
		image.readUInt32BE(0) !== 0x7f454c46 ||
		image[4] !== 2 ||
		image[5] !== 1
	) {
		throw new Error('the AppImage is not an ELF64 little-endian file');
	}
	const sectionTable = Number(image.readBigUInt64LE(0x28));
	const entrySize = image.readUInt16LE(0x3a);
	const count = image.readUInt16LE(0x3c);
	const namesIndex = image.readUInt16LE(0x3e);
	if (sectionTable === 0 || entrySize < 64 || count === 0 || namesIndex >= count) return null;
	const section = (index) => {
		const at = sectionTable + index * entrySize;
		if (at + 64 > image.length) throw new Error('the ELF section table is truncated');
		return {
			name: image.readUInt32LE(at),
			offset: Number(image.readBigUInt64LE(at + 0x18)),
			size: Number(image.readBigUInt64LE(at + 0x20))
		};
	};
	const names = section(namesIndex);
	for (let index = 0; index < count; index++) {
		const entry = section(index);
		const start = names.offset + entry.name;
		const end = image.indexOf(0, start);
		if (image.toString('latin1', start, end) !== UPDATE_SECTION) continue;
		if (entry.offset + entry.size > image.length)
			throw new Error('the update section is truncated');
		const raw = image.subarray(entry.offset, entry.offset + entry.size);
		const nul = raw.indexOf(0);
		return raw.toString('utf8', 0, nul < 0 ? raw.length : nul);
	}
	return null;
}

/**
 * Parses the text header of a .zsync file (everything before the blank line).
 * @param {Buffer} file The .zsync file.
 * @returns {Map<string, string>} Header fields by name.
 * @throws {Error} When the header is not terminated or a line is malformed.
 */
function parseZsyncHeader(file) {
	const end = file.indexOf('\n\n');
	if (end < 0) throw new Error('the .zsync header has no terminating blank line');
	const fields = new Map();
	for (const line of file.toString('latin1', 0, end).split('\n')) {
		const at = line.indexOf(': ');
		if (at < 0) throw new Error(`malformed .zsync header line: "${line}"`);
		fields.set(line.slice(0, at), line.slice(at + 2));
	}
	fields.set('__blocks', String(file.length - end - 2));
	return fields;
}

/**
 * Verifies an AppImage and its .zsync against the published update contract.
 * @param {Buffer} image The AppImage.
 * @param {Buffer} zsync Its .zsync file.
 * @returns {string[]} Problems; empty when the pair is valid.
 */
function verify(image, zsync) {
	const problems = [];
	let embedded = null;
	try {
		embedded = readEmbeddedUpdateInformation(image);
	} catch (error) {
		problems.push(error.message);
	}
	if (embedded === null) problems.push(`the AppImage has no ${UPDATE_SECTION} section`);
	else if (embedded !== UPDATE_INFORMATION) {
		problems.push(`embedded update information "${embedded}" differs from "${UPDATE_INFORMATION}"`);
	}
	let header;
	try {
		header = parseZsyncHeader(zsync);
	} catch (error) {
		problems.push(error.message);
		return problems;
	}
	if (header.get('Filename') !== APPIMAGE_ASSET) {
		problems.push(`zsync Filename is "${header.get('Filename')}", expected ${APPIMAGE_ASSET}`);
	}
	if (header.get('URL') !== APPIMAGE_ASSET) {
		problems.push(
			`zsync URL is "${header.get('URL')}": it must be the released asset name ${APPIMAGE_ASSET}`
		);
	}
	if (header.get('Length') !== String(image.length)) {
		problems.push(
			`zsync Length ${header.get('Length')} differs from the AppImage size ${image.length}`
		);
	}
	if (!/^[0-9a-f]{40}$/.test(header.get('SHA-1') ?? ''))
		problems.push('zsync SHA-1 is missing or malformed');
	if (Number(header.get('__blocks')) <= 0)
		problems.push('the .zsync file carries no block checksums');
	if (!globMatches(parseUpdateInformation(UPDATE_INFORMATION).pattern, ZSYNC_ASSET)) {
		problems.push(`the update pattern does not match the published asset ${ZSYNC_ASSET}`);
	}
	return problems;
}

/** Command line entry. */
function main(argv) {
	if (argv[0] === '--print-update-information') {
		process.stdout.write(UPDATE_INFORMATION);
		return 0;
	}
	if (argv[0] === '--print-appimage-asset') {
		process.stdout.write(APPIMAGE_ASSET);
		return 0;
	}
	if (argv.length !== 2) {
		console.error('usage: check-appimage-update.cjs <AppImage> <AppImage.zsync>');
		return 2;
	}
	const problems = verify(fs.readFileSync(argv[0]), fs.readFileSync(argv[1]));
	if (problems.length > 0) {
		for (const problem of problems) console.error(`[ERR] ${path.basename(argv[0])}: ${problem}`);
		return 1;
	}
	console.log(
		`[OK] ${path.basename(argv[0])} carries its update information and ${path.basename(argv[1])} matches it.`
	);
	return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = {
	APPIMAGE_ASSET,
	ZSYNC_ASSET,
	UPDATE_INFORMATION,
	UPDATE_SECTION,
	globMatches,
	parseUpdateInformation,
	parseZsyncHeader,
	readEmbeddedUpdateInformation,
	verify
};
