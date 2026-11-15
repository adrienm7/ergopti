// _shared/ui/layout_editor/workspace.js

/**
 * ==============================================================================
 * MODULE: Layout Editor Workspace
 * DESCRIPTION:
 * The personal layouts « Éditer » keeps open in its tabs, and how they survive
 * a reload, F5 or a crash: the editor page saves this workspace as the user
 * types, through a store its host gives (the website's IndexedDB store below,
 * the app's user data folder through the host's studio_workspace messages),
 * and restores every tab from it on the next mount. It also writes and reads
 * the backup archive of every tab (one ZIP of Ergopti TOML sources).
 *
 * FEATURES & RATIONALE:
 * 1. The format of record: each tab is kept as its Ergopti TOML source (the
 *    text LayoutSourceIO.serialize writes, an imported .keylayout included),
 *    with whether it differs from the file last saved. Nothing else is stored,
 *    so a restored tab is exactly what « Save » would have written.
 * 2. Fail fast, never lose: a stored workspace that does not read is refused
 *    with a stable code; the page then shows why and stops saving over it.
 * 3. Local only: the store is the browser's or the app's; nothing is sent to
 *    a server. The website asks navigator.storage.persist() so the browser
 *    does not evict the layouts under storage pressure, and says so when it
 *    is refused.
 * 4. Pure classic script: the page and the Node tests run it unchanged; the
 *    IndexedDB store takes the window it runs in.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
var LayoutEditorWorkspace = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	// The schema of the stored workspace.
	const SCHEMA = 1;
	// How long the editor waits after the last change before it saves, so a burst
	// of edits (typing a name, dragging characters) is one write.
	const AUTOSAVE_DELAY_MS = 300;
	// The backup archive's name; its files are <layout id>.toml.
	const BACKUP_FILENAME = 'ergopti-studio-layouts.zip';
	// The IndexedDB database, object store and key of the website's workspace.
	const DB_NAME = 'ergopti-studio';
	const DB_STORE = 'workspace';
	const DB_KEY = 'editor';
	// The files a backup or an import reads: Ergopti sources and macOS layouts.
	const IMPORTED = /\.(toml|keylayout)$/i;

	// ZIP records (PKWARE APPNOTE), the ones the reader walks.
	const LOCAL_SIGNATURE = 0x04034b50;
	const CENTRAL_SIGNATURE = 0x02014b50;
	const END_SIGNATURE = 0x06054b50;
	const END_SIZE = 22;
	const MAX_COMMENT = 0xffff;
	const STORED = 0;
	const DEFLATED = 8;
	const ENCRYPTED = 0x0001;

	/** A refusal with a stable code, as the editor's other modules raise them. */
	class WorkspaceError extends Error {
		constructor(code, path) {
			super(`${code}: ${path}`);
			this.code = code;
			this.path = path;
		}
	}

	// ====================================
	// ======= 2/ The stored text =========
	// ====================================

	/**
	 * The stored text of a workspace.
	 * @param {{text: string, dirty: boolean}[]} tabs - Each tab's TOML source.
	 * @param {number} active - The index of the tab shown.
	 * @returns {string}
	 */
	function serialize(tabs, active) {
		if (!Array.isArray(tabs) || tabs.length === 0)
			throw new WorkspaceError('workspace_invalid', 'tabs');
		if (!Number.isInteger(active) || active < 0 || active >= tabs.length)
			throw new WorkspaceError('workspace_invalid', 'active');
		return JSON.stringify({
			schema: SCHEMA,
			active,
			tabs: tabs.map((tab, index) => {
				if (typeof tab.text !== 'string' || tab.text === '')
					throw new WorkspaceError('workspace_invalid', `tabs[${index}].text`);
				return { text: tab.text, dirty: tab.dirty === true };
			})
		});
	}

	/**
	 * Reads a stored workspace.
	 * @param {string} text
	 * @returns {{active: number, tabs: {text: string, dirty: boolean}[]}}
	 * @throws {WorkspaceError} workspace_invalid naming the first field that does not read.
	 */
	function parse(text) {
		let data;
		try {
			data = JSON.parse(text);
		} catch (error) {
			throw new WorkspaceError('workspace_invalid', 'json');
		}
		if (!data || typeof data !== 'object' || data.schema !== SCHEMA)
			throw new WorkspaceError('workspace_invalid', 'schema');
		if (!Array.isArray(data.tabs) || data.tabs.length === 0)
			throw new WorkspaceError('workspace_invalid', 'tabs');
		const tabs = data.tabs.map((tab, index) => {
			if (!tab || typeof tab.text !== 'string' || tab.text === '' || typeof tab.dirty !== 'boolean')
				throw new WorkspaceError('workspace_invalid', `tabs[${index}]`);
			return { text: tab.text, dirty: tab.dirty };
		});
		if (!Number.isInteger(data.active) || data.active < 0 || data.active >= tabs.length)
			throw new WorkspaceError('workspace_invalid', 'active');
		return { active: data.active, tabs };
	}

	// ====================================
	// ======= 3/ The website store =======
	// ====================================

	/** One IndexedDB request as a promise. */
	function settled(request) {
		return new Promise((resolve, reject) => {
			request.onsuccess = () => resolve(request.result);
			request.onerror = () =>
				reject(new WorkspaceError('workspace_store_failed', String(request.error)));
		});
	}

	/**
	 * The website's store: the workspace text in the browser's IndexedDB, on
	 * this device only, with persistent storage asked for once.
	 * @param {Window} win - The page's window.
	 * @returns {{load: function(): Promise<string|null>, save: function(string): Promise<void>,
	 *   persist: function(): Promise<boolean>}}
	 * @throws {WorkspaceError} workspace_store_unavailable when the browser has no IndexedDB.
	 */
	function indexedDbStore(win) {
		if (!win.indexedDB) throw new WorkspaceError('workspace_store_unavailable', 'indexedDB');
		let opened = null;
		const database = () => {
			if (!opened) {
				const request = win.indexedDB.open(DB_NAME, SCHEMA);
				request.onupgradeneeded = () => request.result.createObjectStore(DB_STORE);
				opened = settled(request).catch((error) => {
					// A refused open (a private window that forbids it) is retried next time.
					opened = null;
					throw error;
				});
			}
			return opened;
		};
		const run = (mode, action) =>
			database().then((db) =>
				settled(action(db.transaction(DB_STORE, mode).objectStore(DB_STORE)))
			);
		return {
			load: () =>
				run('readonly', (store) => store.get(DB_KEY)).then((value) =>
					typeof value === 'string' ? value : null
				),
			save: (text) => run('readwrite', (store) => store.put(text, DB_KEY)).then(() => undefined),
			// Whether the browser keeps the layouts under storage pressure.
			persist: () =>
				win.navigator.storage && typeof win.navigator.storage.persist === 'function'
					? win.navigator.storage.persist().then((granted) => granted === true)
					: Promise.resolve(false)
		};
	}

	// ====================================
	// ======= 4/ The backup archive ======
	// ====================================

	/**
	 * The backup archive of every tab: one <layout id>.toml per tab, a second
	 * tab of the same id numbered (<id>-2.toml).
	 * @param {{id: string, text: string}[]} sources
	 * @returns {{filename: string, bytes: Uint8Array}}
	 */
	function backup(sources) {
		const used = new Set();
		const files = sources.map((source) => {
			let name = `${source.id}.toml`;
			for (let n = 2; used.has(name); n += 1) name = `${source.id}-${n}.toml`;
			used.add(name);
			return { path: name, text: source.text, encoding: 'utf8' };
		});
		return { filename: BACKUP_FILENAME, bytes: LayoutZipWriter.pack(files) };
	}

	/** Inflates a raw DEFLATE stream with the browser's own decompressor. */
	function inflate(bytes, name) {
		if (typeof DecompressionStream !== 'function')
			return Promise.reject(new WorkspaceError('backup_deflate_unsupported', name));
		const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
		return new Response(stream).arrayBuffer().then((buffer) => new Uint8Array(buffer));
	}

	/**
	 * The .toml and .keylayout files of a ZIP archive (a backup, or one made by
	 * another tool: stored or deflated entries), in archive order.
	 * @param {Uint8Array} bytes
	 * @returns {Promise<{name: string, text: string}[]>}
	 * @throws {WorkspaceError} backup_invalid naming the record that does not read.
	 */
	async function readArchive(bytes) {
		const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
		const fail = (path) => {
			throw new WorkspaceError('backup_invalid', path);
		};
		let end = -1;
		const lowest = Math.max(0, bytes.length - END_SIZE - MAX_COMMENT);
		for (let at = bytes.length - END_SIZE; at >= lowest; at -= 1)
			if (view.getUint32(at, true) === END_SIGNATURE) {
				end = at;
				break;
			}
		if (end < 0) fail('end_of_central_directory');
		const count = view.getUint16(end + 10, true);
		let at = view.getUint32(end + 16, true);
		const names = new TextDecoder('utf-8', { fatal: true });
		const files = [];
		for (let index = 0; index < count; index += 1) {
			if (at + 46 > bytes.length || view.getUint32(at, true) !== CENTRAL_SIGNATURE)
				fail(`central[${index}]`);
			const flags = view.getUint16(at + 8, true);
			const method = view.getUint16(at + 10, true);
			const crc = view.getUint32(at + 16, true);
			const packed = view.getUint32(at + 20, true);
			const size = view.getUint32(at + 24, true);
			const nameLength = view.getUint16(at + 28, true);
			const skip = nameLength + view.getUint16(at + 30, true) + view.getUint16(at + 32, true);
			const local = view.getUint32(at + 42, true);
			let name;
			try {
				name = names.decode(bytes.subarray(at + 46, at + 46 + nameLength));
			} catch (error) {
				fail(`central[${index}].name`);
			}
			at += 46 + skip;
			// A folder, or a file the editor does not open, is not a layout.
			const base = name.split('/').pop();
			if (!IMPORTED.test(base)) continue;
			if (flags & ENCRYPTED) fail(name);
			if (local + 30 > bytes.length || view.getUint32(local, true) !== LOCAL_SIGNATURE) fail(name);
			const start =
				local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
			if (start + packed > bytes.length) fail(name);
			const data = bytes.subarray(start, start + packed);
			let content;
			if (method === STORED) content = data;
			else if (method === DEFLATED) content = await inflate(data, name);
			else fail(name);
			if (content.length !== size || LayoutZipWriter.crc32(content) !== crc) fail(name);
			files.push({ name: base, text: new TextDecoder('utf-8').decode(content) });
		}
		return files;
	}

	return {
		SCHEMA,
		AUTOSAVE_DELAY_MS,
		BACKUP_FILENAME,
		IMPORTED,
		WorkspaceError,
		serialize,
		parse,
		indexedDbStore,
		backup,
		readArchive
	};
})();
