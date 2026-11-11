// _shared/ui/layout_editor/zip_writer.js

/**
 * ==============================================================================
 * MODULE: Layout Editor ZIP Writer
 * DESCRIPTION:
 * Packs a few generated text files into one stored (uncompressed) ZIP archive,
 * written from the PKWARE APPNOTE format description, so the website can
 * download a multi-file export such as the macOS bundle as one file. Pure
 * classic script: the page and the Node tests run it unchanged.
 *
 * FEATURES & RATIONALE:
 * 1. Stored entries only: the exports are small text files; no compressor is
 *    vendored for them.
 * 2. Deterministic: every entry carries the same fixed DOS date, so the same
 *    source always yields the same bytes.
 * 3. File names are UTF-8 (general purpose flag bit 11); text is encoded as
 *    each file declares (UTF-8, or UTF-16LE for macOS .strings).
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
var LayoutZipWriter = (function () {
	'use strict';

	const LOCAL_SIGNATURE = 0x04034b50;
	const CENTRAL_SIGNATURE = 0x02014b50;
	const END_SIGNATURE = 0x06054b50;
	const VERSION = 20;
	const UTF8_NAMES = 0x0800;
	// 1980-01-01 00:00, the first DOS date: no clock reaches the archive.
	const DOS_TIME = 0;
	const DOS_DATE = (0 << 9) | (1 << 5) | 1;
	const MAX_ENTRIES = 0xffff;
	const MAX_SIZE = 0xffffffff;

	let crcTable = null;

	/** The CRC-32 (IEEE 802.3) of some bytes. */
	function crc32(bytes) {
		if (!crcTable) {
			crcTable = new Uint32Array(256);
			for (let n = 0; n < 256; n++) {
				let c = n;
				for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
				crcTable[n] = c >>> 0;
			}
		}
		let crc = 0xffffffff;
		for (const byte of bytes) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
		return (crc ^ 0xffffffff) >>> 0;
	}

	/** A text as the bytes its file declares. */
	function encode(text, encoding) {
		if (encoding === 'utf8') return new TextEncoder().encode(text);
		if (encoding === 'utf16le') {
			const bytes = new Uint8Array(text.length * 2);
			for (let i = 0; i < text.length; i++) {
				const unit = text.charCodeAt(i);
				bytes[2 * i] = unit & 0xff;
				bytes[2 * i + 1] = unit >>> 8;
			}
			return bytes;
		}
		throw new Error(`zip: unknown encoding ${encoding}`);
	}

	/**
	 * Packs files into a stored ZIP archive.
	 * @param {{path: string, text: string, encoding: 'utf8'|'utf16le'}[]} files
	 * @returns {Uint8Array}
	 */
	function pack(files) {
		if (files.length > MAX_ENTRIES) throw new Error('zip: too many entries');
		const parts = [];
		const central = [];
		let offset = 0;
		const header = (size) => {
			const buffer = new ArrayBuffer(size);
			return { bytes: new Uint8Array(buffer), view: new DataView(buffer) };
		};
		for (const file of files) {
			if (!file.path || file.path.startsWith('/') || file.path.split('/').includes('..'))
				throw new Error(`zip: unsafe path ${file.path}`);
			const name = new TextEncoder().encode(file.path);
			const data = encode(file.text, file.encoding);
			if (data.length > MAX_SIZE || offset > MAX_SIZE) throw new Error('zip: archive too large');
			const crc = crc32(data);
			const local = header(30);
			local.view.setUint32(0, LOCAL_SIGNATURE, true);
			local.view.setUint16(4, VERSION, true);
			local.view.setUint16(6, UTF8_NAMES, true);
			local.view.setUint16(8, 0, true);
			local.view.setUint16(10, DOS_TIME, true);
			local.view.setUint16(12, DOS_DATE, true);
			local.view.setUint32(14, crc, true);
			local.view.setUint32(18, data.length, true);
			local.view.setUint32(22, data.length, true);
			local.view.setUint16(26, name.length, true);
			local.view.setUint16(28, 0, true);
			const record = header(46);
			record.view.setUint32(0, CENTRAL_SIGNATURE, true);
			record.view.setUint16(4, VERSION, true);
			record.view.setUint16(6, VERSION, true);
			record.view.setUint16(8, UTF8_NAMES, true);
			record.view.setUint16(10, 0, true);
			record.view.setUint16(12, DOS_TIME, true);
			record.view.setUint16(14, DOS_DATE, true);
			record.view.setUint32(16, crc, true);
			record.view.setUint32(20, data.length, true);
			record.view.setUint32(24, data.length, true);
			record.view.setUint16(28, name.length, true);
			record.view.setUint32(42, offset, true);
			parts.push(local.bytes, name, data);
			central.push(record.bytes, name);
			offset += 30 + name.length + data.length;
		}
		const centralSize = central.reduce((sum, part) => sum + part.length, 0);
		const end = header(22);
		end.view.setUint32(0, END_SIGNATURE, true);
		end.view.setUint16(8, files.length, true);
		end.view.setUint16(10, files.length, true);
		end.view.setUint32(12, centralSize, true);
		end.view.setUint32(16, offset, true);
		const all = [...parts, ...central, end.bytes];
		const out = new Uint8Array(all.reduce((sum, part) => sum + part.length, 0));
		let at = 0;
		for (const part of all) {
			out.set(part, at);
			at += part.length;
		}
		return out;
	}

	return { crc32, encode, pack };
})();
