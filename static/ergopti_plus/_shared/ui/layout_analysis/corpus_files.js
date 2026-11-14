// _shared/ui/layout_analysis/corpus_files.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Corpus Files
 * DESCRIPTION:
 * Turns a file the user picks into plain text, in the page: text formats as
 * they are, HTML without its markup, Word (.docx) and OpenDocument (.odt)
 * through their XML part. Nothing is uploaded.
 *
 * FEATURES & RATIONALE:
 * 1. No library: .docx and .odt are ZIP archives, read with a central
 *    directory walk and the browser's DecompressionStream for deflate.
 * 2. Fail fast: a format the page cannot read rejects with a stable code the
 *    page turns into a localized message (PDF: copy its text and paste it).
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS_FILES = (function () {
	'use strict';

	const TEXT_EXTENSIONS = ['txt', 'md', 'csv', 'tsv', 'json', 'tex'];
	const HTML_EXTENSIONS = ['html', 'htm'];
	// The XML part holding the text of each office format, and its paragraph tags.
	const OFFICE = {
		docx: { part: 'word/document.xml', paragraphs: ['p'] },
		odt: { part: 'content.xml', paragraphs: ['p', 'h'] }
	};
	const EOCD_SIGNATURE = 0x06054b50;
	const CENTRAL_SIGNATURE = 0x02014b50;
	const LOCAL_SIGNATURE = 0x04034b50;
	const STORED = 0;
	const DEFLATED = 8;

	/** A rejection the page localizes. */
	const failure = (code) => Object.assign(new Error(code), { code });

	/**
	 * The bytes of one entry of a ZIP archive.
	 * @param {ArrayBuffer} buffer - The archive.
	 * @param {string} name - The entry's path.
	 * @returns {Promise<Uint8Array>} Its uncompressed bytes.
	 */
	async function zipEntry(buffer, name) {
		const view = new DataView(buffer);
		let eocd = -1;
		for (let i = buffer.byteLength - 22; i >= 0; i--) {
			if (view.getUint32(i, true) === EOCD_SIGNATURE) {
				eocd = i;
				break;
			}
		}
		if (eocd < 0) throw failure('file_unreadable');
		const count = view.getUint16(eocd + 10, true);
		let offset = view.getUint32(eocd + 16, true);
		const decoder = new TextDecoder();
		for (let i = 0; i < count; i++) {
			if (view.getUint32(offset, true) !== CENTRAL_SIGNATURE) throw failure('file_unreadable');
			const method = view.getUint16(offset + 10, true);
			const size = view.getUint32(offset + 20, true);
			const nameLength = view.getUint16(offset + 28, true);
			const extraLength = view.getUint16(offset + 30, true);
			const commentLength = view.getUint16(offset + 32, true);
			const local = view.getUint32(offset + 42, true);
			const entryName = decoder.decode(new Uint8Array(buffer, offset + 46, nameLength));
			if (entryName === name) {
				if (view.getUint32(local, true) !== LOCAL_SIGNATURE) throw failure('file_unreadable');
				const start =
					local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
				const data = new Uint8Array(buffer, start, size);
				if (method === STORED) return data;
				if (method !== DEFLATED || typeof DecompressionStream !== 'function')
					throw failure('file_unreadable');
				const stream = new Blob([data])
					.stream()
					.pipeThrough(new DecompressionStream('deflate-raw'));
				return new Uint8Array(await new Response(stream).arrayBuffer());
			}
			offset += 46 + nameLength + extraLength + commentLength;
		}
		throw failure('file_unreadable');
	}

	/** The text of the paragraphs of an office XML part, one per line. */
	function officeText(xml, paragraphs) {
		const doc = new DOMParser().parseFromString(xml, 'application/xml');
		if (doc.getElementsByTagName('parsererror').length > 0) throw failure('file_unreadable');
		const lines = [];
		const wanted = new Set(paragraphs);
		const walk = (node) => {
			for (const child of node.children) {
				if (wanted.has(child.localName)) lines.push(child.textContent);
				else walk(child);
			}
		};
		walk(doc.documentElement);
		return lines.join('\n');
	}

	/**
	 * Reads a picked file as plain text.
	 * @param {File} file - The file.
	 * @returns {Promise<string>} Its text.
	 * @throws {Error} With code file_unsupported or file_unreadable.
	 */
	async function readText(file) {
		const extension = (file.name.split('.').pop() || '').toLowerCase();
		if (TEXT_EXTENSIONS.includes(extension)) return file.text();
		if (HTML_EXTENSIONS.includes(extension)) {
			const doc = new DOMParser().parseFromString(await file.text(), 'text/html');
			return doc.body ? doc.body.innerText || doc.body.textContent : '';
		}
		const office = OFFICE[extension];
		if (!office) throw failure('file_unsupported');
		const bytes = await zipEntry(await file.arrayBuffer(), office.part);
		return officeText(new TextDecoder().decode(bytes), office.paragraphs);
	}

	return { readText };
})();
