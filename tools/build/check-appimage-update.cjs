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
const { createHash } = require('node:crypto');
const path = require('node:path');
const { md4 } = require('../lib/md4.cjs');

/** The release asset names, shared with the release assembly and the site. */
const APPIMAGE_ASSET = 'ErgoptiPlus-x86_64.AppImage';
const ZSYNC_ASSET = `${APPIMAGE_ASSET}.zsync`;
/** gh-releases-zsync|owner|repository|release|asset glob (the glob matches the .zsync asset). */
const UPDATE_INFORMATION =
	'gh-releases-zsync|adrienm7|ergopti|latest|ErgoptiPlus-*x86_64.AppImage.zsync';

/** Name of the ELF section appimagetool writes the update information into. */
const UPDATE_SECTION = '.upd_info';
// zsyncmake uses 2 or 4 KiB for release images; cap untrusted metadata before
// allocating the padded final block, while allowing much larger real blocks.
const MAX_BLOCK_SIZE = 16 * 1024 * 1024;

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
	if (names.offset + names.size > image.length)
		throw new Error('the ELF section name table is truncated');
	for (let index = 0; index < count; index++) {
		const entry = section(index);
		if (entry.name >= names.size) throw new Error('the ELF section name is out of bounds');
		const start = names.offset + entry.name;
		const end = image.indexOf(0, start);
		if (end < 0 || end >= names.offset + names.size)
			throw new Error('the ELF section name is not terminated within its table');
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

/** Compute the zsync rolling and MD4 checksums of the padded image blocks. */
function* zsyncBlockRecords(image, blocksize, weakLength, strongLength) {
	for (let offset = 0; offset < image.length; offset += blocksize) {
		const chunk = image.subarray(offset, Math.min(offset + blocksize, image.length));
		const block =
			chunk.length === blocksize
				? chunk
				: Buffer.concat([chunk, Buffer.alloc(blocksize - chunk.length)]);
		let a = 0,
			b = 0;
		for (let index = 0; index < block.length; index++) {
			a = (a + block[index]) & 0xffff;
			b = (b + (block.length - index) * block[index]) & 0xffff;
		}
		const weak = Buffer.alloc(4);
		weak.writeUInt16BE(a, 0);
		weak.writeUInt16BE(b, 2);
		yield Buffer.concat([weak.subarray(4 - weakLength), md4(block).subarray(0, strongLength)]);
	}
}

function zsyncBlockSums(image, blocksize, weakLength, strongLength) {
	return Buffer.concat([...zsyncBlockRecords(image, blocksize, weakLength, strongLength)]);
}

/**
 * Verifies an AppImage and its .zsync against the published update contract.
 * @param {Buffer} image The AppImage.
 * @param {Buffer} zsync Its .zsync file.
 * @returns {string[]} Problems; empty when the pair is valid.
 */
function verify(image, zsync) {
	const problems = [];
	if (image.length >= 20 && image.readUInt16LE(0x12) !== 62)
		problems.push('the AppImage ELF architecture is not x86-64');
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
	// zsync2 accepts powers of two and defaults missing Hash-Lengths to 1,4,16.
	// It then reads one weak and one strong checksum for each target block.
	const blocksizeText = header.get('Blocksize') ?? '';
	const blocksize = Number(blocksizeText);
	const validBlocksize =
		/^[0-9]+$/.test(blocksizeText) &&
		Number.isSafeInteger(blocksize) &&
		blocksize > 0 &&
		blocksize <= MAX_BLOCK_SIZE &&
		(BigInt(blocksize) & (BigInt(blocksize) - 1n)) === 0n;
	if (!validBlocksize) problems.push('zsync Blocksize is missing or invalid');
	const lengthsText = header.get('Hash-Lengths') ?? '1,4,16';
	const lengthsMatch = /^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*$/.exec(lengthsText);
	const lengths = lengthsMatch?.slice(1).map(Number);
	const validLengths =
		lengths &&
		lengths.every(Number.isSafeInteger) &&
		lengths[0] >= 1 &&
		lengths[0] <= 2 &&
		lengths[1] >= 1 &&
		lengths[1] <= 4 &&
		lengths[2] >= 3 &&
		lengths[2] <= 16;
	if (!validLengths) problems.push('zsync Hash-Lengths is malformed or out of range');
	const sha1 = header.get('SHA-1') ?? '';
	if (!/^[0-9a-f]{40}$/.test(sha1)) problems.push('zsync SHA-1 is missing or malformed');
	else if (sha1 !== createHash('sha1').update(image).digest('hex'))
		problems.push('zsync SHA-1 does not match the AppImage');
	const checksumBytes = Number(header.get('__blocks'));
	if (checksumBytes <= 0) problems.push('the .zsync file carries no block checksums');
	else if (validBlocksize && validLengths) {
		const actual = zsync.subarray(zsync.indexOf('\n\n') + 2);
		const expectedLength = Math.ceil(image.length / blocksize) * (lengths[1] + lengths[2]);
		if (actual.length < expectedLength)
			problems.push('the .zsync file has truncated block checksums');
		else if (actual.length !== expectedLength)
			problems.push('the .zsync file has unexpected extra block checksums');
		else {
			let offset = 0;
			for (const expected of zsyncBlockRecords(image, blocksize, lengths[1], lengths[2])) {
				if (!actual.subarray(offset, offset + expected.length).equals(expected)) {
					problems.push('the .zsync block checksums do not match the AppImage');
					break;
				}
				offset += expected.length;
			}
		}
	}
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
	zsyncBlockSums,
	readEmbeddedUpdateInformation,
	verify
};
