// tools/build/pin-ollama-release.cjs

/**
 * ==============================================================================
 * MODULE: Ollama Release Pin Tool
 * DESCRIPTION:
 * Measures the official Ollama archives that ollama_release.json pins: the
 * SHA-256 and size of each archive and the bytes its runtime takes once
 * unpacked, read from the archive's own listing without extracting anything.
 *
 * FEATURES & RATIONALE:
 * 1. The three drivers refuse an install before its download when the volume
 *    cannot hold the archive, the unpacked runtime and the registry margin
 *    (OLL-04, OLL-14 of the 2026-11-20 managed Ollama campaign). The unpacked
 *    size is the sum of the regular files of the listing: the zip central
 *    directory (Windows) or the tar headers behind gzip or zstd (macOS and
 *    Linux), with pax `size` records honored. Links and folders hold no bytes.
 * 2. It never downloads: it reads archives already in a folder, named by their
 *    pinned file names. `--check` refuses any pin that differs from the files;
 *    `--write` rewrites the three measured fields of every asset.
 * 3. A zip64 archive is refused rather than misread: no pinned Windows archive
 *    needs it, and its sizes live in records this reader does not parse.
 *
 * Usage:
 *   node tools/build/pin-ollama-release.cjs --archives <folder> [--check|--write]
 *     [--catalogue <ollama_release.json>]
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { pipeline } = require('node:stream/promises');

const CATALOGUE = path.resolve(
	__dirname,
	'../../static/ergopti_plus/_shared/ai/data/ollama_release.json'
);
// The fields this tool measures; every other field of an asset is the pin's own.
const MEASURED = ['sha256', 'bytes', 'unpacked_bytes'];
const TAR_BLOCK = 512;
const ZIP_END_SIGNATURE = 0x06054b50;
const ZIP_CENTRAL_SIGNATURE = 0x02014b50;
const ZIP_END_BYTES = 22;
const ZIP_COMMENT_MAX = 0xffff;
const ZIP64_MARKER = 0xffffffff;

// ========================================
// ========================================
// ======= 1/ Archive Listings =======
// ========================================
// ========================================

/**
 * Reads one byte range of an open file.
 * @param {number} fd An open file descriptor.
 * @param {number} position First byte.
 * @param {number} length Byte count.
 * @returns {Buffer}
 */
function readRange(fd, position, length) {
	const data = Buffer.alloc(length);
	let done = 0;
	while (done < length) {
		const read = fs.readSync(fd, data, done, length - done, position + done);
		if (read === 0) throw new Error('The archive ended before a range it declares.');
		done += read;
	}
	return data;
}

/**
 * The bytes of the regular files a zip archive holds, from its central
 * directory alone: only the archive's tail and that directory are read.
 * @param {string} file The archive on disk.
 * @returns {number}
 */
function zipUnpackedBytes(file) {
	const fd = fs.openSync(file, 'r');
	try {
		const fileSize = fs.fstatSync(fd).size;
		const floor = Math.max(0, fileSize - ZIP_END_BYTES - ZIP_COMMENT_MAX);
		const tail = readRange(fd, floor, fileSize - floor);
		let end = -1;
		for (let offset = tail.length - ZIP_END_BYTES; offset >= 0; offset -= 1) {
			if (tail.readUInt32LE(offset) === ZIP_END_SIGNATURE) {
				end = offset;
				break;
			}
		}
		if (end < 0) throw new Error('The zip archive has no end of central directory.');
		const entries = tail.readUInt16LE(end + 10);
		const size = tail.readUInt32LE(end + 12);
		const start = tail.readUInt32LE(end + 16);
		if (entries === 0xffff || size === ZIP64_MARKER || start === ZIP64_MARKER) {
			throw new Error('A zip64 archive is refused: its sizes are not in the central directory.');
		}
		if (start + size > floor + end)
			throw new Error('The zip central directory overruns its archive.');
		return zipDirectoryBytes(readRange(fd, start, size), entries);
	} finally {
		fs.closeSync(fd);
	}
}

/**
 * Sums the uncompressed sizes of a central directory's file entries.
 * @param {Buffer} data The central directory.
 * @param {number} entries The entry count its end record declares.
 * @returns {number}
 */
function zipDirectoryBytes(data, entries) {
	let total = 0;
	let offset = 0;
	for (let index = 0; index < entries; index += 1) {
		if (offset + 46 > data.length || data.readUInt32LE(offset) !== ZIP_CENTRAL_SIGNATURE) {
			throw new Error(`The zip central directory entry ${index} is malformed.`);
		}
		const unpacked = data.readUInt32LE(offset + 24);
		const nameLength = data.readUInt16LE(offset + 28);
		const extraLength = data.readUInt16LE(offset + 30);
		const commentLength = data.readUInt16LE(offset + 32);
		if (unpacked === ZIP64_MARKER) throw new Error('A zip64 entry is refused.');
		const name = data.toString('utf8', offset + 46, offset + 46 + nameLength);
		if (!name.endsWith('/')) total += unpacked;
		offset += 46 + nameLength + extraLength + commentLength;
	}
	if (offset !== data.length)
		throw new Error('The zip central directory size disagrees with its entries.');
	return total;
}

/**
 * Reads the pax records of an extended header block.
 * @param {Buffer} body The pax data.
 * @returns {Map<string, string>}
 */
function paxRecords(body) {
	const records = new Map();
	let offset = 0;
	while (offset < body.length) {
		const space = body.indexOf(0x20, offset);
		if (space < 0) throw new Error('A pax record has no length.');
		const length = Number(body.toString('ascii', offset, space));
		if (!Number.isInteger(length) || length <= 0 || offset + length > body.length) {
			throw new Error('A pax record length is malformed.');
		}
		const text = body.toString('utf8', space + 1, offset + length - 1);
		const equals = text.indexOf('=');
		if (equals < 0) throw new Error('A pax record has no value.');
		records.set(text.slice(0, equals), text.slice(equals + 1));
		offset += length;
	}
	return records;
}

/**
 * Decodes a tar numeric field, octal or GNU base-256.
 * @param {Buffer} field The raw header field.
 * @returns {number}
 */
function tarNumber(field) {
	if (field[0] & 0x80) {
		let value = 0;
		for (let index = 1; index < field.length; index += 1) value = value * 256 + field[index];
		if (!Number.isSafeInteger(value)) throw new Error('A tar size exceeds a safe integer.');
		return value;
	}
	const text = field.toString('ascii').replace(/\0.*$/s, '').trim();
	if (text === '') return 0;
	if (!/^[0-7]+$/.test(text)) throw new Error('A tar numeric field is malformed.');
	return parseInt(text, 8);
}

/**
 * Sums the regular files of a tar stream, header by header.
 */
class TarCounter {
	constructor() {
		this.pending = Buffer.alloc(0);
		this.skip = 0;
		this.collect = null;
		this.paxSize = null;
		this.globalSize = null;
		this.total = 0;
		this.ended = false;
	}

	/** @param {Buffer} chunk Decompressed tar bytes. */
	push(chunk) {
		this.pending = this.pending.length ? Buffer.concat([this.pending, chunk]) : chunk;
		while (!this.ended) {
			if (this.skip > 0) {
				const taken = Math.min(this.skip, this.pending.length);
				if (this.collect) this.collect.parts.push(this.pending.subarray(0, taken));
				this.pending = this.pending.subarray(taken);
				this.skip -= taken;
				if (this.skip > 0) return;
				if (this.collect) this._finishCollect();
				continue;
			}
			if (this.pending.length < TAR_BLOCK) return;
			const header = this.pending.subarray(0, TAR_BLOCK);
			this.pending = this.pending.subarray(TAR_BLOCK);
			this._header(header);
		}
	}

	_finishCollect() {
		const { kind, length, parts } = this.collect;
		const body = Buffer.concat(parts).subarray(0, length);
		this.collect = null;
		if (kind === 'x' || kind === 'g') {
			const size = paxRecords(body).get('size');
			const value = size === undefined ? null : Number(size);
			if (value !== null && !Number.isSafeInteger(value))
				throw new Error('A pax size is malformed.');
			if (kind === 'x') this.paxSize = value;
			else this.globalSize = value;
		}
	}

	_header(header) {
		if (header.every((byte) => byte === 0)) {
			this.ended = true;
			return;
		}
		let sum = 0;
		for (let index = 0; index < TAR_BLOCK; index += 1) {
			sum += index >= 148 && index < 156 ? 0x20 : header[index];
		}
		if (sum !== tarNumber(header.subarray(148, 156)))
			throw new Error('A tar header checksum is wrong.');
		const kind = String.fromCharCode(header[156] || 0x30);
		let size = tarNumber(header.subarray(124, 136));
		if (kind === 'x' || kind === 'g' || kind === 'L' || kind === 'K') {
			this.skip = Math.ceil(size / TAR_BLOCK) * TAR_BLOCK;
			this.collect = { kind, length: size, parts: [] };
			if (this.skip === 0) this._finishCollect();
			return;
		}
		const override = this.paxSize ?? this.globalSize;
		if (override !== null) size = override;
		this.paxSize = null;
		if (kind === '0' || kind === '7') this.total += size;
		// Links, folders and devices carry no data blocks.
		const blocks = kind === '0' || kind === '7' ? size : 0;
		this.skip = Math.ceil(blocks / TAR_BLOCK) * TAR_BLOCK;
	}

	/** @returns {number} The bytes of the regular files, once the end marker was read. */
	result() {
		if (!this.ended) throw new Error('The tar stream ended before its end marker.');
		return this.total;
	}
}

/**
 * The decompressor of a pinned tar archive, by its file name.
 * @param {string} name The pinned file name.
 * @returns {import('node:stream').Transform}
 */
function tarDecompressor(name) {
	if (/\.(tgz|tar\.gz)$/.test(name)) return zlib.createGunzip();
	if (/\.tar\.zst$/.test(name)) {
		if (typeof zlib.createZstdDecompress !== 'function') {
			throw new Error('This Node has no zstd decompressor; use Node 22.15 or later.');
		}
		return zlib.createZstdDecompress();
	}
	throw new Error(`No listing reader for ${name}.`);
}

/**
 * Measures one archive: its SHA-256, size and unpacked bytes.
 * @param {string} file The archive on disk.
 * @param {string} name Its pinned file name, which names the format.
 * @returns {Promise<{sha256: string, bytes: number, unpacked_bytes: number}>}
 */
async function measureArchive(file, name = path.basename(file)) {
	const hash = crypto.createHash('sha256');
	let bytes = 0;
	if (name.endsWith('.zip')) {
		for await (const chunk of fs.createReadStream(file)) {
			hash.update(chunk);
			bytes += chunk.length;
		}
		return { sha256: hash.digest('hex'), bytes, unpacked_bytes: zipUnpackedBytes(file) };
	}
	const counter = new TarCounter();
	await pipeline(
		fs.createReadStream(file),
		async function* tap(source) {
			for await (const chunk of source) {
				hash.update(chunk);
				bytes += chunk.length;
				yield chunk;
			}
		},
		tarDecompressor(name),
		async (tar) => {
			for await (const chunk of tar) counter.push(chunk);
		}
	);
	return { sha256: hash.digest('hex'), bytes, unpacked_bytes: counter.result() };
}

// ========================================
// ========================================
// ======= 2/ Pin Check and Write =======
// ========================================
// ========================================

/**
 * Measures every pinned asset found in a folder and compares or rewrites the pin.
 * @param {{catalogue: string, archives: string, write: boolean}} options
 * @returns {Promise<string[]>} The differences found; empty when the pin holds.
 */
async function pin({ catalogue, archives, write }) {
	const release = JSON.parse(fs.readFileSync(catalogue, 'utf8'));
	const differences = [];
	for (const [id, asset] of Object.entries(release.assets)) {
		const measured = await measureArchive(path.join(archives, asset.filename), asset.filename);
		for (const field of MEASURED) {
			if (asset[field] !== measured[field]) {
				differences.push(`${id}.${field}: pinned ${asset[field]}, measured ${measured[field]}`);
				if (write) asset[field] = measured[field];
			}
		}
	}
	if (write && differences.length) {
		fs.writeFileSync(catalogue, `${JSON.stringify(release, null, '\t')}\n`);
	}
	return differences;
}

/** Reads the command line, measures, and exits non-zero on a differing check. */
async function main(argv) {
	const value = (flag) => {
		const index = argv.indexOf(flag);
		return index >= 0 ? argv[index + 1] : undefined;
	};
	const archives = value('--archives');
	if (!archives) throw new Error('--archives <folder> is required.');
	const write = argv.includes('--write');
	if (write && argv.includes('--check')) throw new Error('--check and --write exclude each other.');
	const differences = await pin({ catalogue: value('--catalogue') ?? CATALOGUE, archives, write });
	for (const line of differences) console.log(line);
	if (!write && differences.length) {
		throw new Error(`${differences.length} pinned field(s) differ from the archives.`);
	}
	console.log(write ? `Pinned ${differences.length} field(s).` : 'The pin matches the archives.');
}

if (require.main === module) {
	main(process.argv.slice(2)).catch((error) => {
		console.error(error.message);
		process.exit(1);
	});
}

module.exports = { measureArchive, pin, zipUnpackedBytes, TarCounter };
