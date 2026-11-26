// _shared/ui/layout_analysis/pdf_text.js

/**
 * ==============================================================================
 * MODULE: PDF Text Reader
 * DESCRIPTION:
 * Reads the text of a PDF in the page, never uploading it, so the Comparer
 * can analyse a layout on it (corpus_files.js readText). No library: the
 * page already inflates .docx and .odt archives with the browser's
 * DecompressionStream, and a PDF's text sits in deflated content streams.
 *
 * FEATURES & RATIONALE:
 * 1. Objects, including those packed in object streams (PDF 1.5), and
 *    FlateDecode streams; a stream with another filter (an image) is skipped.
 * 2. Each page's fonts, inherited from its parents: a ToUnicode map gives the
 *    characters of its codes (LibreOffice, Word, Chrome's Skia write one); a
 *    simple font without one reads its bytes as Windows-1252.
 * 3. The text operators (Tj, TJ, ', ") in page order. The pen is followed
 *    with each font's glyph widths: a move to another baseline starts a new
 *    line, a move past the end of the text shown is a space, and a move within
 *    a word (Chrome places each glyph run apart) is nothing.
 * 4. Fail fast: an encrypted file (pdf_encrypted), a file that is not a PDF
 *    or cannot be parsed (file_unreadable), or one that holds no text, such
 *    as a scan (pdf_no_text), is refused with its code.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS_PDF = (function () {
	'use strict';

	// A TJ gap wider than this many thousandths of an em reads as a space.
	const SPACE_GAP = 200;
	// A pen move past the text shown wider than this share of the font size is a space.
	const WORD_GAP = 0.2;
	// A baseline move larger than this share of the font size is a new line.
	const LINE_GAP = 0.5;
	// How deep page trees and nested Form XObjects are followed.
	const MAX_DEPTH = 32;
	// The glyph width a font that states none is read with, in thousandths of an em.
	const DEFAULT_WIDTH = 1000;
	const LIGATURES = ['ff', 'fi', 'fl', 'ffi', 'ffl', 'st', 'st'];
	const CP1252_HIGH = '€\u0081‚ƒ„…†‡ˆ‰Š‹Œ\u008dŽ\u008f\u0090‘’“”•–—˜™š›œ\u009džŸ';

	/** A rejection the page localizes. */
	const failure = (code) => Object.assign(new Error(code), { code });

	/** One byte per character: the PDF's own encoding of its structure. */
	function binary(bytes) {
		let out = '';
		const CHUNK = 0x8000;
		for (let i = 0; i < bytes.length; i += CHUNK)
			out += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
		return out;
	}

	/** Inflates a FlateDecode stream. */
	async function inflate(bytes) {
		if (typeof DecompressionStream !== 'function') throw failure('file_unreadable');
		const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
		return new Uint8Array(await new Response(stream).arrayBuffer());
	}

	// ======================
	// ======= Objects ======
	// ======================

	/**
	 * Every object of the file: its dictionary text and, for a stream, its
	 * decoded bytes (null when its filter is not FlateDecode).
	 * @returns {Promise<Map<number, {dict: string, data: Uint8Array|null}>>}
	 */
	async function objects(bytes, text) {
		const out = new Map();
		const pattern = /(\d+)\s+\d+\s+obj\b/g;
		let match;
		const starts = [];
		while ((match = pattern.exec(text)))
			starts.push({ id: Number(match[1]), at: pattern.lastIndex });
		for (const { id, at } of starts) {
			const end = text.indexOf('endobj', at);
			if (end < 0) continue;
			const streamAt = text.indexOf('stream', at);
			if (streamAt < 0 || streamAt > end) {
				out.set(id, { dict: text.slice(at, end), data: null });
				continue;
			}
			let dataAt = streamAt + 'stream'.length;
			if (text[dataAt] === '\r') dataAt++;
			if (text[dataAt] === '\n') dataAt++;
			let dataEnd = text.lastIndexOf('endstream', end);
			if (dataEnd < dataAt) continue;
			while (dataEnd > dataAt && (text[dataEnd - 1] === '\n' || text[dataEnd - 1] === '\r'))
				dataEnd--;
			const dict = text.slice(at, streamAt);
			const raw = bytes.subarray(dataAt, dataEnd);
			const filter = /\/Filter\s*(\[\s*)?\/(\w+)/.exec(dict);
			let data = null;
			if (!filter) data = raw;
			else if (filter[2] === 'FlateDecode' && !/\/DecodeParms/.test(dict))
				data = await inflate(raw).catch(() => null);
			out.set(id, { dict, data });
		}
		// Objects packed in object streams: N pairs « id offset », then the objects.
		for (const object of [...out.values()]) {
			if (!/\/Type\s*\/ObjStm/.test(object.dict) || !object.data) continue;
			const body = binary(object.data);
			const count = Number((/\/N\s+(\d+)/.exec(object.dict) || [])[1]);
			const first = Number((/\/First\s+(\d+)/.exec(object.dict) || [])[1]);
			const header = body.slice(0, first).trim().split(/\s+/).map(Number);
			for (let i = 0; i < count; i++) {
				const id = header[2 * i];
				const from = first + header[2 * i + 1];
				const to = i + 1 < count ? first + header[2 * i + 3] : body.length;
				if (!out.has(id)) out.set(id, { dict: body.slice(from, to), data: null });
			}
		}
		return out;
	}

	/** The object a reference « n 0 R » in a dictionary entry names. */
	function ref(dict, key, all) {
		const match = new RegExp(`/${key}\\s+(\\d+)\\s+\\d+\\s+R`).exec(dict);
		return match ? all.get(Number(match[1])) : undefined;
	}

	/** The text of a dictionary entry: an inline << >> or the object a reference names. */
	function entry(dict, key, all) {
		const at = dict.search(new RegExp(`/${key}\\b`));
		if (at < 0) return null;
		const rest = dict.slice(at + key.length + 1).trimStart();
		if (rest.startsWith('<<')) {
			let depth = 0;
			for (let i = 0; i < rest.length - 1; i++) {
				if (rest.startsWith('<<', i)) {
					depth++;
					i++;
				} else if (rest.startsWith('>>', i)) {
					depth--;
					i++;
					if (depth === 0) return rest.slice(2, i - 1);
				}
			}
			return null;
		}
		const target = ref(dict, key, all);
		return target ? target.dict : null;
	}

	// ======================
	// ======= Fonts ========
	// ======================

	/** A ToUnicode CMap: code (hex) → characters, and the byte length of a code. */
	function cmap(text) {
		const map = new Map();
		const utf16 = (hex) => {
			let out = '';
			for (let i = 0; i + 4 <= hex.length; i += 4)
				out += String.fromCharCode(parseInt(hex.slice(i, i + 4), 16));
			return out;
		};
		let width = 0;
		for (const block of text.matchAll(/begincodespacerange([\s\S]*?)endcodespacerange/g)) {
			const first = /<([0-9A-Fa-f]+)>/.exec(block[1]);
			if (first) width = first[1].length / 2;
		}
		for (const block of text.matchAll(/beginbfchar([\s\S]*?)endbfchar/g))
			for (const pair of block[1].matchAll(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>/g)) {
				map.set(pair[1].toLowerCase(), utf16(pair[2]));
				width = width || pair[1].length / 2;
			}
		for (const block of text.matchAll(/beginbfrange([\s\S]*?)endbfrange/g))
			for (const range of block[1].matchAll(
				/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]*>|\[[^\]]*\])/g
			)) {
				const low = parseInt(range[1], 16);
				const high = parseInt(range[2], 16);
				const digits = range[1].length;
				width = width || digits / 2;
				const key = (code) => code.toString(16).padStart(digits, '0');
				if (range[3].startsWith('[')) {
					const targets = [...range[3].matchAll(/<([0-9A-Fa-f]*)>/g)];
					targets.forEach((target, k) => map.set(key(low + k), utf16(target[1])));
				} else {
					const start = range[3].slice(1, -1);
					const base = parseInt(start.slice(-4), 16);
					for (let code = low; code <= high && code - low < 0x10000; code++)
						map.set(key(code), utf16(start.slice(0, -4)) + String.fromCharCode(base + code - low));
				}
			}
		return { map, width: width || 1 };
	}

	/** The numbers of an array entry: inline [ ] or the object a reference names. */
	function arrayText(dict, key, all) {
		const inline = new RegExp(`/${key}\\s*\\[`).exec(dict);
		if (inline) {
			let depth = 0;
			for (let i = inline.index + inline[0].length - 1; i < dict.length; i++) {
				if (dict[i] === '[') depth++;
				if (dict[i] === ']' && --depth === 0) return dict.slice(inline.index + inline[0].length, i);
			}
			return null;
		}
		const target = ref(dict, key, all);
		if (!target) return null;
		const body = target.dict.trim();
		return body.startsWith('[') ? body.slice(1, body.lastIndexOf(']')) : null;
	}

	/**
	 * A font's glyph widths by code, in thousandths of an em: a simple font's
	 * /FirstChar and /Widths, a Type0 font's descendant /W and /DW.
	 */
	function fontWidths(font, all) {
		const widths = new Map();
		let fallback = DEFAULT_WIDTH;
		if (/\/Subtype\s*\/Type0/.test(font.dict)) {
			const kids = arrayText(font.dict, 'DescendantFonts', all);
			const child = kids && /(\d+)\s+\d+\s+R/.exec(kids);
			const descendant = child ? all.get(Number(child[1])) : null;
			if (!descendant) return { widths, fallback };
			const dw = /\/DW\s+([\d.]+)/.exec(descendant.dict);
			if (dw) fallback = Number(dw[1]);
			const w = arrayText(descendant.dict, 'W', all);
			if (w) {
				const tokens = w.match(/\[|\]|[-\d.]+/g) || [];
				for (let i = 0; i < tokens.length; ) {
					const first = Number(tokens[i]);
					if (tokens[i + 1] === '[') {
						let k = i + 2;
						for (let code = first; tokens[k] !== ']' && k < tokens.length; k++, code++)
							widths.set(code, Number(tokens[k]));
						i = k + 1;
					} else {
						const last = Number(tokens[i + 1]);
						for (let code = first; code <= last && code - first < 0x10000; code++)
							widths.set(code, Number(tokens[i + 2]));
						i += 3;
					}
				}
			}
			return { widths, fallback };
		}
		const firstChar = Number((/\/FirstChar\s+(\d+)/.exec(font.dict) || [])[1] || 0);
		const list = arrayText(font.dict, 'Widths', all);
		if (list)
			(list.match(/[-\d.]+/g) || []).forEach((value, k) =>
				widths.set(firstChar + k, Number(value))
			);
		const missing = /\/MissingWidth\s+([\d.]+)/.exec(font.dict);
		return { widths, fallback: missing ? Number(missing[1]) : fallback };
	}

	/** One font of a resource dictionary: its character map and glyph widths. */
	function readFont(font, all) {
		const unicode = ref(font.dict, 'ToUnicode', all);
		return Object.assign(
			unicode && unicode.data
				? cmap(binary(unicode.data))
				: { map: null, width: /\/Subtype\s*\/Type0/.test(font.dict) ? 2 : 1 },
			fontWidths(font, all)
		);
	}

	/**
	 * What a content stream draws with: the fonts and Form XObjects of its
	 * resource dictionaries, the nearest first (a page's own, then its parents').
	 * @param {string[]} dicts - Resource dictionaries' texts.
	 * @returns {{fonts: Map<string, object>, forms: Map<string, object>}}
	 */
	function resources(dicts, all) {
		const fonts = new Map();
		const forms = new Map();
		for (const dict of dicts) {
			const fontDict = entry(dict, 'Font', all);
			if (fontDict)
				for (const match of fontDict.matchAll(/\/([^\s/<>[\]()]+)\s+(\d+)\s+\d+\s+R/g)) {
					const font = all.get(Number(match[2]));
					if (font && !fonts.has(match[1])) fonts.set(match[1], readFont(font, all));
				}
			const xobjects = entry(dict, 'XObject', all);
			if (xobjects)
				for (const match of xobjects.matchAll(/\/([^\s/<>[\]()]+)\s+(\d+)\s+\d+\s+R/g)) {
					const form = all.get(Number(match[2]));
					if (form && form.data && /\/Subtype\s*\/Form/.test(form.dict) && !forms.has(match[1]))
						forms.set(match[1], form);
				}
		}
		return { fonts, forms };
	}

	/** A page's resource dictionaries: its own, then its parents' (inherited). */
	function pageResources(page, all) {
		const dicts = [];
		let node = page;
		for (let depth = 0; node && depth < MAX_DEPTH; depth++) {
			const own = entry(node.dict, 'Resources', all);
			if (own) dicts.push(own);
			node = ref(node.dict, 'Parent', all);
		}
		return resources(dicts, all);
	}

	/** The advance of a string's bytes in a font, in thousandths of an em. */
	function advance(bytes, font) {
		if (!font) return bytes.length * DEFAULT_WIDTH;
		let total = 0;
		const step = font.width || 1;
		for (let i = 0; i + step <= bytes.length; i += step) {
			let code = 0;
			for (let k = 0; k < step; k++) code = code * 256 + bytes[i + k];
			total += font.widths.has(code) ? font.widths.get(code) : font.fallback;
		}
		return total;
	}

	/** The characters of a string's bytes in a font. */
	function decode(bytes, font) {
		if (!font || !font.map) {
			let out = '';
			for (const byte of bytes)
				out += byte >= 0x80 && byte < 0xa0 ? CP1252_HIGH[byte - 0x80] : String.fromCharCode(byte);
			return out;
		}
		let out = '';
		for (let i = 0; i + font.width <= bytes.length; i += font.width) {
			let key = '';
			for (let k = 0; k < font.width; k++) key += bytes[i + k].toString(16).padStart(2, '0');
			const chars = font.map.get(key);
			if (chars !== undefined) out += chars;
		}
		return out;
	}

	// ==========================
	// ======= Content ==========
	// ==========================

	/** The bytes of a literal string « ( ) » from `at` (after the paren), and where it ends. */
	function literal(text, at) {
		const bytes = [];
		let depth = 1;
		let i = at;
		const ESCAPES = { n: 10, r: 13, t: 9, b: 8, f: 12, '(': 40, ')': 41, '\\': 92 };
		while (i < text.length) {
			const c = text[i];
			if (c === '\\') {
				const next = text[i + 1];
				if (next in ESCAPES) {
					bytes.push(ESCAPES[next]);
					i += 2;
				} else if (/[0-7]/.test(next)) {
					const octal = /^[0-7]{1,3}/.exec(text.slice(i + 1))[0];
					bytes.push(parseInt(octal, 8) & 0xff);
					i += 1 + octal.length;
				} else if (next === '\r' || next === '\n') {
					i += next === '\r' && text[i + 2] === '\n' ? 3 : 2;
				} else i += 1;
				continue;
			}
			if (c === '(') depth++;
			if (c === ')' && --depth === 0) return { bytes, end: i + 1 };
			bytes.push(c.charCodeAt(0) & 0xff);
			i++;
		}
		return { bytes, end: i };
	}

	/**
	 * The text a content stream shows, with what it draws with; a Form XObject
	 * it draws (Do) is read in place with its own resources.
	 */
	function contentText(text, drawn, all, depth) {
		const fonts = drawn.fonts;
		let out = '';
		let font = null;
		let size = 1;
		let leading = 0;
		// The text line matrix origin and scale, and the pen after the text shown.
		let lineX = 0;
		let lineY = 0;
		let scale = 1;
		let penX = null;
		let penY = null;
		const operands = [];
		const em = () => Math.abs(size * scale) || 1;
		const newline = () => {
			if (out && !out.endsWith('\n')) out += '\n';
		};
		const space = () => {
			if (out && !/\s$/.test(out)) out += ' ';
		};
		// Where the next text starts, once a move set it; checked against where
		// the previous text ended when that text is shown (a run sets its matrix,
		// then moves, before it shows anything).
		let moved = false;
		const moveTo = (x, y) => {
			lineX = x;
			lineY = y;
			moved = true;
		};
		const show = (bytes) => {
			if (moved || penX === null) {
				if (penX !== null) {
					if (Math.abs(lineY - penY) > LINE_GAP * em()) newline();
					else if (lineX - penX > WORD_GAP * em()) space();
					else if (lineX < penX - 2 * em()) newline();
				}
				penX = lineX;
				penY = lineY;
				moved = false;
			}
			out += decode(bytes, font);
			penX += (advance(bytes, font) / 1000) * size * scale;
		};
		const number = (k) => Number((operands[operands.length - k] || {}).token);
		let i = 0;
		while (i < text.length) {
			const c = text[i];
			if (c === '%') {
				while (i < text.length && text[i] !== '\n' && text[i] !== '\r') i++;
			} else if (c === '(') {
				const read = literal(text, i + 1);
				operands.push({ bytes: read.bytes });
				i = read.end;
			} else if (c === '<' && text[i + 1] !== '<') {
				const end = text.indexOf('>', i);
				const hex = text.slice(i + 1, end).replace(/\s+/g, '');
				const bytes = [];
				for (let k = 0; k < hex.length; k += 2)
					bytes.push(parseInt(hex.slice(k, k + 2).padEnd(2, '0'), 16));
				operands.push({ bytes });
				i = end + 1;
			} else if (c === '[') {
				operands.push({ array: true });
				i++;
			} else if (c === ']') {
				// The array's items since its opening bracket.
				const items = [];
				while (operands.length && !operands[operands.length - 1].array)
					items.unshift(operands.pop());
				operands.pop();
				operands.push({ items });
				i++;
			} else if (/\s/.test(c)) {
				i++;
			} else {
				const word = /^[^\s()<>[\]{}/%]+|^\/[^\s()<>[\]{}/%]*|^<<|^>>|^[{}]/.exec(
					text.slice(i, i + 128)
				);
				const token = word ? word[0] : c;
				i += token.length;
				if (token.startsWith('/') || /^[-+.\d]/.test(token)) {
					operands.push({ token });
					continue;
				}
				switch (token) {
					case 'Tf': {
						const name = operands.find((o) => o.token && o.token.startsWith('/'));
						font = name ? fonts.get(name.token.slice(1)) || null : null;
						size = number(1) || 1;
						break;
					}
					case 'TL':
						leading = number(1) || 0;
						break;
					case 'BT':
						lineX = 0;
						lineY = 0;
						scale = 1;
						break;
					case 'Tm':
						scale = Math.hypot(number(6), number(5)) || 1;
						moveTo(number(2), number(1));
						break;
					case 'Td':
						moveTo(lineX + number(2) * scale, lineY + number(1) * scale);
						break;
					case 'TD':
						leading = -number(1);
						moveTo(lineX + number(2) * scale, lineY + number(1) * scale);
						break;
					case 'T*':
						moveTo(lineX, lineY - leading * scale);
						break;
					case 'Tj':
						if (operands.length) show(operands[operands.length - 1].bytes || []);
						break;
					case 'Do': {
						const name = operands.find((o) => o.token && o.token.startsWith('/'));
						const form = name ? drawn.forms.get(name.token.slice(1)) : null;
						if (form && depth < MAX_DEPTH) {
							const own = entry(form.dict, 'Resources', all);
							newline();
							out += contentText(
								binary(form.data),
								own ? resources([own], all) : drawn,
								all,
								depth + 1
							);
							newline();
						}
						break;
					}
					case "'":
					case '"':
						moveTo(lineX, lineY - leading * scale);
						if (operands.length) show(operands[operands.length - 1].bytes || []);
						break;
					case 'TJ': {
						const array = operands[operands.length - 1];
						for (const item of (array && array.items) || []) {
							if (item.bytes) show(item.bytes);
							else if (item.token) {
								const shift = Number(item.token);
								if (penX !== null) penX -= (shift / 1000) * size * scale;
								if (shift < -SPACE_GAP) space();
							}
						}
						break;
					}
					default:
						break;
				}
				operands.length = 0;
			}
		}
		return out;
	}

	/**
	 * Reads the text of a PDF.
	 * @param {ArrayBuffer} buffer - The file's bytes.
	 * @returns {Promise<string>} Its text, page after page.
	 * @throws {Error} pdf_encrypted, pdf_no_text or file_unreadable.
	 */
	async function read(buffer) {
		const bytes = new Uint8Array(buffer);
		const text = binary(bytes);
		if (!text.startsWith('%PDF-')) throw failure('file_unreadable');
		if (/\/Encrypt\s/.test(text)) throw failure('pdf_encrypted');
		const all = await objects(bytes, text);
		const pages = [...all.values()].filter((o) => /\/Type\s*\/Page(?![s\w])/.test(o.dict));
		// Page order: as the page tree lists them (Kids), else as stored.
		const pageIds = new Map([...all.entries()].map(([id, o]) => [o, id]));
		const order = [];
		const walk = (node, depth) => {
			if (!node || depth > MAX_DEPTH) return;
			if (/\/Type\s*\/Page(?![s\w])/.test(node.dict)) return order.push(node);
			const kids = /\/Kids\s*\[([^\]]*)\]/.exec(node.dict);
			if (!kids) return;
			for (const kid of kids[1].matchAll(/(\d+)\s+\d+\s+R/g))
				walk(all.get(Number(kid[1])), depth + 1);
		};
		const root = [...all.values()].find(
			(o) => /\/Type\s*\/Pages\b/.test(o.dict) && !/\/Parent\s/.test(o.dict)
		);
		walk(root, 0);
		const sequence =
			order.length === pages.length ? order : pages.sort((a, b) => pageIds.get(a) - pageIds.get(b));
		const parts = [];
		for (const page of sequence) {
			const drawn = pageResources(page, all);
			const contents = /\/Contents\s*(\[[^\]]*\]|\d+\s+\d+\s+R)/.exec(page.dict);
			if (!contents) continue;
			let streamText = '';
			for (const id of contents[1].matchAll(/(\d+)\s+\d+\s+R/g)) {
				const stream = all.get(Number(id[1]));
				if (stream && stream.data) streamText += `${binary(stream.data)}\n`;
			}
			parts.push(contentText(streamText, drawn, all, 0));
		}
		const out = parts
			.join('\n')
			// Typographic ligatures (ﬁ, ﬄ…) are their letters for a keyboard.
			.replace(/[\uFB00-\uFB06]/g, (ligature) => LIGATURES[ligature.charCodeAt(0) - 0xfb00])
			.replace(/[ \t]+\n/g, '\n')
			.replace(/\n{3,}/g, '\n\n')
			.trim();
		if (!/\p{L}/u.test(out)) throw failure('pdf_no_text');
		return out;
	}

	return { read };
})();

// Node (tests) reads the module through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_ANALYSIS_PDF;
