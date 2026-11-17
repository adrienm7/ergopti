// _shared/ui/layout_analysis/corpus_files.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Corpus Files
 * DESCRIPTION:
 * Turns a file the user picks into plain text, in the page: text formats as
 * they are, HTML without its markup, Word (.docx) and OpenDocument (.odt)
 * through their XML part. Nothing is uploaded. Also loads the n-gram tables
 * of a built-in corpus, for every page that analyses (the Comparer, the
 * editor's analysis panel).
 *
 * FEATURES & RATIONALE:
 * 1. No library: .docx and .odt are ZIP archives, read with a central
 *    directory walk and the browser's DecompressionStream for deflate.
 * 2. Fail fast: a format the page cannot read rejects with a stable code the
 *    page turns into a localized message. A PDF's text is read by
 *    pdf_text.js; a locked or scanned PDF is refused with its own code.
 * 3. A built-in corpus's script path is relative to this folder; it resolves
 *    against this script's own URL, so a page in another folder loads it too.
 *    A host that inlines its pages (the macOS and Linux app windows have no
 *    base URL to load from) defines LAYOUT_ANALYSIS_HOST.loadCorpus(id): a
 *    promise resolved once window.LAYOUT_ANALYSIS_CORPORA[id] is set. Tables
 *    already loaded are used as they are.
 * 4. The Studio's shared state: the keyboard format its editor and Comparer
 *    share (stored once for both), the layout the site's editor hands to the
 *    Comparer framed beside it (this tab's storage, taken once), and the
 *    layouts open in « Éditer », which the Comparer lists and follows; the
 *    layout the optimizer hands to « Éditer » the same way; the text modes
 *    of « My typing » (the keys typed or the final text) both pages follow.
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
	// This folder's URL, read while the script runs. A Node context has none,
	// and neither has a script the macOS and Linux hosts inline (its src is
	// empty): there the host loads the corpora (LAYOUT_ANALYSIS_HOST.loadCorpus).
	const BASE =
		typeof document !== 'undefined' && document.currentScript && document.currentScript.src
			? new URL('.', document.currentScript.src).href
			: null;
	const loadedScripts = new Map();
	// The Comparer's saved settings (weights, ideal finger load…), which the
	// editor's analysis panel reads so both score alike.
	const SETTINGS_KEY = 'ergopti.layout_analysis.v1';
	// How long a pasted or typed corpus text rests before the Comparer and the
	// Optimiser read it, so each keystroke does not restart the analysis.
	const TEXT_DEBOUNCE_MS = 400;
	// Which text each layout types (maintainer, 2026-11-17), stored as the
	// Comparer's textMode: the keys typed (the raw text, hotstring abbreviations
	// included), the final text (after hotstring expansions and AI completions),
	// or the final text except the layouts ticked « + » (Ergopti+ hotstrings),
	// which type the keys typed. The editor panel follows the same choice.
	const TEXT_MODES = Object.freeze({ typed: 'typed', final: 'final', mixed: 'mixed' });

	/**
	 * The tables the layouts not ticked « + » type: a corpus of two texts (« My
	 * typing » since schema 2: the keys typed at the top level, the final text
	 * under `final`) gives its final text in the final and mixed modes, its keys
	 * typed in the typed mode; a corpus of one text gives it in every mode.
	 * @param {object} tables - A corpus's n-gram tables.
	 * @param {string} mode - A TEXT_MODES value.
	 * @returns {object} The tables to analyse.
	 * @throws {Error} On an unknown mode.
	 */
	function plainTables(tables, mode) {
		if (!Object.values(TEXT_MODES).includes(mode))
			throw new Error(`layout_analysis: unknown text mode ${mode}`);
		return tables.final && mode !== TEXT_MODES.typed ? tables.final : tables;
	}

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
	 * @throws {Error} With code file_unsupported, file_unreadable, pdf_encrypted or pdf_no_text.
	 */
	async function readText(file) {
		const extension = (file.name.split('.').pop() || '').toLowerCase();
		if (TEXT_EXTENSIONS.includes(extension)) return file.text();
		if (HTML_EXTENSIONS.includes(extension)) {
			const doc = new DOMParser().parseFromString(await file.text(), 'text/html');
			return doc.body ? doc.body.innerText || doc.body.textContent : '';
		}
		if (extension === 'pdf') return window.LAYOUT_ANALYSIS_PDF.read(await file.arrayBuffer());
		const office = OFFICE[extension];
		if (!office) throw failure('file_unsupported');
		const bytes = await zipEntry(await file.arrayBuffer(), office.part);
		return officeText(new TextDecoder().decode(bytes), office.paragraphs);
	}

	/** Loads a script of this folder once. */
	function loadScript(path) {
		if (!BASE)
			throw new Error(
				'layout_analysis: corpus_files.js has no script URL (an inlined page needs LAYOUT_ANALYSIS_HOST.loadCorpus)'
			);
		const src = new URL(path, BASE).href;
		if (!loadedScripts.has(src))
			loadedScripts.set(
				src,
				new Promise((resolve, reject) => {
					const script = document.createElement('script');
					script.src = src;
					script.onload = resolve;
					script.onerror = () => {
						loadedScripts.delete(src);
						reject(new Error(src));
					};
					document.head.append(script);
				})
			);
		return loadedScripts.get(src);
	}

	/**
	 * The n-gram tables of a built-in corpus, loaded once.
	 * @param {{id: string, script: string}} corpus - An entry of LAYOUT_ANALYSIS_DATA.corpora.
	 * @returns {Promise<object>} Its {chars, bigrams, trigrams} tables.
	 * @throws {Error} When the script fails to load or defines no tables.
	 */
	async function builtinTables(corpus) {
		const loaded = () =>
			window.LAYOUT_ANALYSIS_CORPORA && window.LAYOUT_ANALYSIS_CORPORA[corpus.id];
		if (loaded()) return loaded();
		const host = window.LAYOUT_ANALYSIS_HOST || {};
		if (typeof host.loadCorpus === 'function') await host.loadCorpus(corpus.id);
		else await loadScript(corpus.script);
		const tables = loaded();
		if (!tables) throw new Error(`layout_analysis: ${corpus.script} defines no ${corpus.id}`);
		return tables;
	}

	// ===================================
	// ======= Studio shared state =======
	// ===================================

	// The keyboard format (100 %, TKL…) the Studio's editor and Comparer share: in
	// the app they are one page, on the site two framed pages of one origin, so
	// the choice is stored once for both (coordinator, 2026-11-15).
	const FORMAT_KEY = 'ergopti.studio.keyboard_format.v1';
	// The layout the site's editor hands to its Comparer: « Compare with other
	// layouts » stores it here for this tab, then the framing page opens the
	// Comparer, which takes it once.
	const HANDOFF_KEY = 'ergopti.studio.compare_handoff.v1';
	// The layouts open in « Éditer », for the Comparer's list (library shape): the
	// same page hears the event, the site's other frame the storage key.
	const EDITOR_LAYOUTS_KEY = 'ergopti.studio.editor_layouts.v1';
	const EDITOR_LAYOUTS_EVENT = 'ergopti-studio:editor-layouts';
	// The message the editor's frame posts to the site's Studio to open « Comparer ».
	const OPEN_COMPARER_MESSAGE = 'ergopti-studio:open-comparer';
	// A layout another Studio tool (the optimizer) hands to « Éditer » for this
	// tab, and the message that asks the site's Studio to open « Éditer ».
	const EDITOR_HANDOFF_KEY = 'ergopti.studio.editor_handoff.v1';
	const OPEN_EDITOR_MESSAGE = 'ergopti-studio:open-editor';

	/**
	 * The keyboard format chosen in the Studio, if storage keeps one.
	 * @returns {string|null} A keyboard_formats id, unchecked: the caller validates it.
	 */
	function savedFormat() {
		try {
			return window.localStorage.getItem(FORMAT_KEY);
		} catch {
			// A private window or blocked storage: no shared choice, the default applies.
			return null;
		}
	}

	/** Stores the keyboard format chosen in either tab of the Studio. */
	function saveFormat(id) {
		try {
			window.localStorage.setItem(FORMAT_KEY, id);
		} catch {
			// Unavailable storage keeps the choice for this page only.
		}
	}

	/**
	 * Hands a layout (library shape) to the Comparer of this tab.
	 * @throws {Error} studio_handoff_failed when the tab's storage refuses it.
	 */
	function handOff(layout) {
		try {
			window.sessionStorage.setItem(HANDOFF_KEY, JSON.stringify(layout));
		} catch {
			throw failure('studio_handoff_failed');
		}
	}

	/**
	 * Takes the layout handed to the Comparer, once.
	 * @returns {object|null} The layout, or null when none waits.
	 */
	function takeHandoff() {
		let text = null;
		try {
			text = window.sessionStorage.getItem(HANDOFF_KEY);
			window.sessionStorage.removeItem(HANDOFF_KEY);
		} catch {
			return null;
		}
		return text === null ? null : JSON.parse(text);
	}

	/**
	 * Hands a layout (library shape) to « Éditer » of this tab, which opens it in
	 * a new tab of its own.
	 * @throws {Error} studio_handoff_failed when the tab's storage refuses it.
	 */
	function handOffToEditor(layout) {
		try {
			window.sessionStorage.setItem(EDITOR_HANDOFF_KEY, JSON.stringify(layout));
		} catch {
			throw failure('studio_handoff_failed');
		}
	}

	/**
	 * Takes the layout handed to « Éditer », once.
	 * @returns {object|null} The layout, or null when none waits.
	 */
	function takeEditorHandoff() {
		let text = null;
		try {
			text = window.sessionStorage.getItem(EDITOR_HANDOFF_KEY);
			window.sessionStorage.removeItem(EDITOR_HANDOFF_KEY);
		} catch {
			return null;
		}
		return text === null ? null : JSON.parse(text);
	}

	/**
	 * Tells the Comparer which layouts « Éditer » has open (library shape).
	 * @param {object[]} layouts
	 */
	function publishEditorLayouts(layouts) {
		try {
			window.localStorage.setItem(EDITOR_LAYOUTS_KEY, JSON.stringify(layouts));
		} catch (error) {
			// The same page still hears the event; another frame keeps its last list.
			console.warn(`layout studio: the editor's layouts are not stored (${error.name})`);
		}
		window.dispatchEvent(new CustomEvent(EDITOR_LAYOUTS_EVENT, { detail: layouts }));
	}

	/**
	 * Calls back with the layouts « Éditer » has open: the stored list now, then
	 * every change, from this page or another frame of the Studio.
	 * @param {function(object[]): void} listener
	 */
	function onEditorLayouts(listener) {
		const read = () => {
			try {
				const text = window.localStorage.getItem(EDITOR_LAYOUTS_KEY);
				return text === null ? [] : JSON.parse(text);
			} catch {
				return [];
			}
		};
		listener(read());
		window.addEventListener(EDITOR_LAYOUTS_EVENT, (event) => listener(event.detail));
		window.addEventListener('storage', (event) => {
			if (event.key === EDITOR_LAYOUTS_KEY) listener(read());
		});
	}

	return {
		SETTINGS_KEY,
		TEXT_DEBOUNCE_MS,
		TEXT_MODES,
		plainTables,
		publishEditorLayouts,
		onEditorLayouts,
		OPEN_COMPARER_MESSAGE,
		OPEN_EDITOR_MESSAGE,
		handOffToEditor,
		takeEditorHandoff,
		readText,
		builtinTables,
		savedFormat,
		saveFormat,
		handOff,
		takeHandoff
	};
})();
