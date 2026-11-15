// _shared/ui/layout_editor/editor_page.js

/**
 * ==============================================================================
 * MODULE: Layout Editor Page
 * DESCRIPTION:
 * The unified layout editor: one page that edits every layer of the Ergopti
 * layout source (character levels, user modifiers, the navigation layer),
 * its dead keys, per-key Caps Lock modes, physical remapping, shortcuts that
 * send another chord, tap-holds and export settings, with a live typing
 * preview, a Unicode palette and printable key stickers. The website mounts
 * it standalone (index.html); ErgoptiPlus mounts the same code in its layout
 * manager window. Each host supplies only how a file is opened and saved.
 *
 * FEATURES & RATIONALE:
 * 1. Format through one module: the page never reads or writes TOML or XML;
 *    LayoutSourceIO does, and LayoutEditorModel applies the edits.
 * 2. Nothing is lost silently: an imported .keylayout stays verbatim until
 *    the user converts it, and the conversion lists what it drops; exports
 *    show the format owner's per-target report, refusals included.
 * 3. Every visible string is a locale key (21 locales, _shared/core/i18n/data/locales).
 * 4. Live analysis: a page that loads the layout analysis scripts
 *    (layout_analysis/analysis_panel.js and its dependencies) gets the
 *    analysis panel beside the board, updated after every render.
 * 5. One clear hierarchy: the primary toolbar (New, Open, Save, Undo, Redo),
 *    the layer selector (the four character levels always shown, a missing one
 *    added in one click), the board with its preview and the key inspector,
 *    then the secondary tools in tabs. A host's side panel (the Studio's
 *    analysis) goes in the persistent slot the mount returns as sideSlot; the
 *    root fires layout-editor:rendered after each render.
 * 6. Several personal layouts, never lost: each layout has its own tab (« + »
 *    opens a blank one, a copy of another layout or a file), with its own undo
 *    history. A host that gives a workspace store (host.workspace: the
 *    website's IndexedDB, the app's user data folder) gets every tab and its
 *    unsaved edits saved as the user types and restored on the next mount
 *    (LayoutEditorWorkspace); « Export all » and « Import » back them up as one
 *    ZIP of Ergopti sources.
 * 7. Live key heatmap: the analysis panel's « Key colours » (onHeat) colours
 *    the board's own keys from green to red by what each costs, the tooltip
 *    naming its worst pairs; every edit re-analyses and recolours.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
var LayoutEditorPage = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const PREFIX = 'layout_editor.';
	const MAPPING_CHOICES = ['none', 'text', 'dead_key', 'action', 'key', 'disabled'];
	const BUILTIN_MODIFIERS = ['shift', 'control', 'alt', 'meta', 'caps_lock', 'kana'];
	// Ranges of the Unicode palette; the block name is a locale key.
	const PALETTE_BLOCKS = [
		{ id: 'latin1', from: 0x00a1, to: 0x00ff },
		{ id: 'latin_extended_a', from: 0x0100, to: 0x017f },
		{ id: 'combining', from: 0x0300, to: 0x036f },
		{ id: 'greek', from: 0x0391, to: 0x03c9 },
		{ id: 'punctuation', from: 0x2010, to: 0x205e },
		{ id: 'currency', from: 0x20a0, to: 0x20c0 },
		{ id: 'arrows', from: 0x2190, to: 0x21ff },
		{ id: 'math', from: 0x2200, to: 0x22ff }
	];
	const STICKER_LAYERS = ['base', 'shift', 'altgr', 'shift_altgr'];
	// Physical modifier keys and the sided modifier ids the format names them by.
	const SIDED_MODIFIERS = {
		ShiftLeft: 'shift_left',
		ShiftRight: 'shift_right',
		AltLeft: 'alt_left',
		AltRight: 'alt_right',
		ControlLeft: 'control_left',
		ControlRight: 'control_right',
		MetaLeft: 'meta_left',
		MetaRight: 'meta_right'
	};
	// The key that names a built-in or sided modifier of the source on the layer chips.
	const MODIFIER_NAME_KEYS = {
		shift: 'ShiftLeft',
		shift_left: 'ShiftLeft',
		shift_right: 'ShiftRight',
		control: 'ControlLeft',
		control_left: 'ControlLeft',
		control_right: 'ControlRight',
		alt: 'AltLeft',
		alt_left: 'AltLeft',
		alt_right: 'AltRight',
		meta: 'MetaLeft',
		meta_left: 'MetaLeft',
		meta_right: 'MetaRight',
		caps_lock: 'CapsLock'
	};
	const TAP_HOLD_THRESHOLD_STEP = 10;
	// The OS whose emulation table the preview performs when neither the scope
	// nor the host names one (the website): macOS, whose .keylayout holds the
	// fewest records, so the preview shows every emulated one. Decided by the
	// coordinator on 2026-11-11, to review by the maintainer.
	const PREVIEW_PLATFORM = 'macos';
	// Exact sticker sizes the print accepts, in millimetres (keycaps are about 18 mm).
	const STICKER_MIN_MM = 8;
	// The smallest font a key label shrinks to before it is cut with an ellipsis.
	const LEGEND_MIN_PX = 9;
	// The levels of another layout a layer can be filled from (the composer's levels).
	const FILL_LEVELS = ['base', 'shift', 'altgr', 'shift_altgr', 'command'];
	const STICKER_MAX_MM = 30;
	// The secondary tools under the board, in tab order; the first one opens by default.
	const TOOLS = [
		'details',
		'layers',
		'modifiers',
		'dead_keys',
		'fill',
		'navigation',
		'windows',
		'export',
		'stickers'
	];
	// The drag data type of a character from the palette or the name search.
	const CHAR_DRAG_TYPE = 'application/x-ergopti-character';

	// ============================
	// ======= 2/ Helpers =========
	// ============================

	/** Translates a locale key; an unknown key shows itself so the gap is visible. */
	function t(key, values) {
		const strings = window._i18n_strings || {};
		let text = typeof strings[key] === 'string' ? strings[key] : key;
		for (const [name, value] of Object.entries(values || {}))
			text = text.split(`{${name}}`).join(String(value));
		return text;
	}
	const tl = (key, values) => t(PREFIX + key, values);

	/**
	 * A declaration of the shared value schema, by its generated key name.
	 * @param {string} name - Its KEY constant, e.g. LAYOUT_SOURCE_KEYS_VIRTUAL_KEY.
	 * @returns {object} The declaration (type, min, max).
	 */
	function declared(name) {
		const V = window.ErgoptiValueCheck;
		return V.entryFor(V.SCHEMA, V.KEY[name]);
	}

	/**
	 * Reads a typed number through the shared value check (_shared/ui/
	 * value_check.js, generated from the one schema the three drivers read).
	 * A refusal shows the localized text naming the accepted range in the
	 * message line and yields undefined, so nothing is applied.
	 * @param {HTMLInputElement} input - The field.
	 * @param {string} key - Its declaration in the shared value schema.
	 * @param {function} notify - Shows an error message.
	 * @returns {number|undefined} The admitted value.
	 */
	function checkedNumber(input, key, notify) {
		const V = window.ErgoptiValueCheck;
		const entry = V.entryFor(V.SCHEMA, key);
		const typed = V.parseEntry(entry, input.value);
		if (typed.ok) return typed.value;
		notify(
			'error',
			V.renderMessage(V.messageParts(entry, typed), (k) => t(k))
		);
		return undefined;
	}

	/** Creates an element; attributes starting with "on" bind listeners. */
	function el(tag, attributes, children) {
		const node = document.createElement(tag);
		for (const [name, value] of Object.entries(attributes || {})) {
			if (value === undefined || value === null || value === false) continue;
			if (name.startsWith('on')) node.addEventListener(name.slice(2), value);
			else if (name === 'text') node.textContent = value;
			else if (name === 'value') node.value = value;
			else if (name === 'checked') node.checked = Boolean(value);
			else node.setAttribute(name, value === true ? '' : value);
		}
		for (const child of [].concat(children || []))
			if (child !== null && child !== undefined && child !== false)
				node.append(typeof child === 'string' ? document.createTextNode(child) : child);
		return node;
	}

	function select(options, value, onchange, attributes) {
		return el(
			'select',
			Object.assign({ onchange: (event) => onchange(event.target.value) }, attributes || {}),
			options.map(([id, label]) => el('option', { value: id, selected: id === value }, label))
		);
	}

	/** A visible rendering of typed text: controls and spaces get a symbol. */
	/** A labelled checkbox that reports its state without redrawing the page. */
	function checkbox(id, label, checked, onchange) {
		return el('label', { class: 'le-check' }, [
			el('input', {
				type: 'checkbox',
				id,
				checked,
				onchange: (event) => onchange(event.target.checked)
			}),
			label
		]);
	}

	// The shared legend formatter (_generated/key_legend.js, from the site's keyLegend.js).
	const visible = KEY_LEGEND.visibleText;

	/** Whether a mapping is a dead key, which every board marks (KEY_LEGEND.DEAD_KEY_CLASS). */
	function isDeadKey(mapping) {
		return Boolean(mapping) && LayoutEditorModel.kindOf(mapping) === 'dead_key';
	}

	/** A short legend for a mapping on the board. */
	function legend(mapping, doc) {
		if (!mapping) return '';
		const kind = LayoutEditorModel.kindOf(mapping);
		if (kind === 'text') return visible(mapping.text);
		if (kind === 'dead_key') {
			// The bare accent; a dead key typing nothing alone shows its name.
			const dead = (doc.dead_keys || []).find((entry) => entry.id === mapping.dead_key);
			const accent = dead && dead.terminator ? KEY_LEGEND.deadKeyText(dead.terminator) : '';
			return accent || (dead && dead.name) || mapping.dead_key;
		}
		if (kind === 'action') return actionLabel(mapping.action);
		if (kind === 'key') return (mapping.modifiers || []).concat([keyName(mapping.key)]).join('+');
		return '⊘';
	}

	function actionLabel(id) {
		const data = LAYER_EDITOR_DATA;
		const entry = data && data.actions[id];
		return entry ? t(entry.label_key) : id;
	}

	// How key names read: the OS scope being edited, else the host's OS, else
	// OS-neutral names (the website states no OS); the base layer's characters
	// are the legends of character keys (set by each render).
	let keyView = null;

	function keyName(code) {
		return keyView ? LayerModel.keyLegend(code, keyView) : code;
	}

	/** The key-name view for a document and an OS scope. */
	function makeKeyView(doc, platform) {
		const legends = {};
		const base = (doc.layers || []).find((layer) => layer.id === 'base');
		if (base)
			for (const [code, mapping] of Object.entries(base.keys))
				if (typeof mapping.text === 'string' && mapping.text !== '')
					legends[code] = visible(mapping.text);
		return { os: platform, data: LAYER_EDITOR_DATA, t, legends };
	}

	/** The translated refusal of an edit or a file. */
	function problemText(error) {
		const code = error && error.code ? error.code : 'unexpected';
		const message = tl(`error.${code}`);
		const text = message === PREFIX + `error.${code}` ? tl('error.generic', { code }) : message;
		return error && error.path ? `${text} (${error.path})` : text;
	}

	// ============================
	// ======= 3/ State ===========
	// ============================

	/**
	 * Mounts the editor.
	 * @param {HTMLElement} root - The element the editor fills.
	 * @param {{saveFile: function(string, string, string): Promise<void>,
	 *   initial?: string|null, onClose?: function}} host - saveFile(filename,
	 *   text, mime) stores a file; initial is a source text to open; install({source,
	 *   keylayout}) and platform ('macos'|'linux') when the host installs layouts;
	 *   emulate(payload) the same way when its layout emulation can type the source
	 *   without installing it;
	 *   savedStatus names the message shown after a save; onClose leaves the editor;
	 *   exportAssets() resolves what the XKB and KLC downloads run (standalone.js)
	 *   on a host that can fetch them; startFrom names the start source (a
	 *   loadSources or built-in id) the editor copies when it has no initial text
	 *   and no restored workspace; compare(layout) receives the edited layout from
	 *   the analysis panel's « Compare with other layouts » (the app's Studio);
	 *   workspace {load(): Promise<string|null>, save(text): Promise,
	 *   persist?(): Promise<boolean>} keeps the tabs (LayoutEditorWorkspace).
	 * @returns {{open: function(string, string): void, current: function(): object}}
	 */
	function mount(root, host) {
		const data = LAYER_EDITOR_DATA;
		const state = {
			history: LayoutEditorModel.createHistory(
				LayoutSourceIO.create('my_layout', tl('default_name'))
			),
			layer: 'base',
			platform: '',
			selected: null,
			// The keyboard format shown (analysis_model.json keyboard_formats, the
			// Comparer's too): each hides the blocks it lacks.
			format: LAYOUT_ANALYSIS.defaultKeyboardFormat(),
			deadKey: null,
			paletteBlock: PALETTE_BLOCKS[0].id,
			// Whether the palette is unfolded, so a render keeps it open.
			paletteOpen: false,
			// The name search: query, result cap and the last answer (null before a search).
			nameSearch: { query: '', limit: UnicodeNames.DEFAULT_LIMIT, answer: null, failed: false },
			// The text the character magnifier shows ('' shows its hint).
			magnified: '',
			// Whether the magnified text is a dead key's: its bare accent, marked.
			magnifiedDead: false,
			presses: [],
			locked: new Set(),
			heldCustom: new Set(),
			// The preview's web emulation and the source and OS it was built for.
			typist: null,
			message: null,
			// A pending question: { text, onYes }. In-page, because a webview
			// host may not show window.confirm (WKWebView needs a UI delegate).
			confirm: null,
			// Whether the exact import refused the file, so the approximate one is offered.
			approximate: false,
			// The board drawn: ISO or ANSI geometry (the source itself is described on ISO).
			board: 'iso',
			// A mapping copied with « Copy », pasted on another key.
			clipboard: null,
			// Sticker size: null fits the page, a number is the key size in millimetres.
			stickerMm: null,
			// Layers printed on each sticker (null: the four usual levels the source has),
			// and whether a Shift legend that is only the capital is hidden.
			stickerLayers: null,
			stickerHideCase: false,
			// KbdEdit's automatic case mapping: a letter fills its other case on the
			// Shift partner layer, keeping a mapped cell unless overwrite is set.
			autoCase: true,
			caseOverwrite: false,
			// Layouts a layer can be filled from (null until asked), and whether the
			// host's registry list failed: its error, or null (the references remain).
			fillSources: null,
			fillUnavailable: null,
			// « New » shows where a new layout starts from: blank or another layout.
			starting: false,
			// Physical modifier keys held in the preview, as sided modifier ids.
			heldSides: new Set(),
			// The secondary tool shown under the board (one of TOOLS).
			tool: TOOLS[0],
			// The key inspector's groups unfolded by the user (see inspectorGroup).
			openGroups: new Set(),
			// The « Shortcuts » view: the board shows each key's shortcut overrides
			// instead of a layer, and the inspector edits them.
			shortcutView: false,
			// The override loaded in the shortcut form by « Edit » (null: a new one).
			shortcutDraft: null,
			// The choices made so far in that form ({key, modifiers, send_key,
			// send_modifiers}), kept here so a render before « Add » keeps them.
			shortcutForm: null,
			// The key whose shortcut_key the next board click chooses (null: none).
			pickingShortcutKey: null,
			// The keyboard an imported .keylayout is described on, and the key
			// held for an imported navigation layer ('' until chosen).
			importConvention: 'iso',
			navHold: '',
			lost: null,
			dirty: false,
			// The open layouts: each tab's own history and whether it differs from the
			// file last saved. state.history and state.dirty are the shown tab's.
			tabs: [],
			active: 0,
			// The workspace store's state: 'none' (the host keeps no tabs), 'loading'
			// (the stored tabs are being read), 'saving', 'saved' or 'failed'; blocked
			// when the stored workspace did not read, so nothing is saved over it.
			// error is the refusal itself, translated when shown (the locale can arrive later).
			workspace: { status: host.workspace ? 'loading' : 'none', blocked: false, error: null },
			persisted: null,
			// The analysis panel's key colours ({values, max, titles}), null when off.
			heat: null
		};
		state.tabs.push({ history: state.history, dirty: false });
		const doc = () => state.history.current();
		// The live analysis beside the board, on the pages that load its scripts.
		const analysisPanel =
			typeof window.LAYOUT_ANALYSIS_PANEL === 'object'
				? window.LAYOUT_ANALYSIS_PANEL.create({
						onCompare: typeof host.compare === 'function' ? host.compare : null,
						format: () => state.format
					})
				: null;

		function apply(edit) {
			try {
				state.history.push(edit(doc()));
				state.dirty = true;
				state.message = null;
			} catch (error) {
				state.message = { kind: 'error', text: problemText(error) };
			}
			render();
		}

		function notify(kind, text) {
			state.message = { kind, text };
			render();
		}

		/**
		 * Calls the host as a promise. A host call that throws at once (the Lua VM
		 * of the downloads missing from the page) rejects it instead, so every
		 * caller's error branch shows the reason; Promise.resolve(host.x()) ran
		 * the call before any promise existed and the click failed in silence.
		 * @param {function(): *} call - The host call.
		 * @returns {Promise<*>}
		 */
		function fromHost(call) {
			return new Promise((resolve) => resolve(call()));
		}

		/**
		 * Commits the edit of the focused field, if any: a field commits on blur, and its
		 * change must apply to the document it was typed in, before that document is
		 * replaced or its node leaves the page.
		 */
		function commitFocused() {
			const focused = document.activeElement;
			if (
				focused &&
				focused !== root &&
				root.contains(focused) &&
				typeof focused.blur === 'function'
			)
				focused.blur();
		}

		/** Shows another document: what was selected or typed belongs to the one left. */
		function resetView(next, lost) {
			state.layer = (next.layers || []).some((l) => l.id === 'base') ? 'base' : null;
			state.selected = null;
			state.presses = [];
			state.lost = lost || null;
			state.deadKey = null;
			state.approximate = false;
			// A shortcut being edited or chosen belongs to the document replaced: an
			// « Edit » kept across an open once applied to the new file's override.
			state.shortcutDraft = null;
			state.shortcutForm = null;
			state.pickingShortcutKey = null;
		}

		// How many documents replace() opened: the opening start keeps one the user opened.
		let replacements = 0;

		function replace(next, lost) {
			// The edit belongs to the document being replaced: commit it there first.
			commitFocused();
			replacements += 1;
			state.history.reset(next);
			resetView(next, lost);
			state.dirty = false;
		}

		// ============================
		// ======= 4b/ Tabs ===========
		// ============================

		// Each document's TOML source, written once per document (documents are immutable).
		const sourceTexts = new WeakMap();
		function sourceText(document) {
			if (!sourceTexts.has(document)) sourceTexts.set(document, LayoutSourceIO.serialize(document));
			return sourceTexts.get(document);
		}

		/** The tab at an index, the shown one read from the live state. */
		function tabAt(index) {
			return index === state.active
				? { history: state.history, dirty: state.dirty }
				: state.tabs[index];
		}

		/** Writes the shown tab's history and state back into its tab. */
		function keepActive() {
			state.tabs[state.active] = tabAt(state.active);
		}

		/** Shows one tab (the caller kept the current one first). */
		function showTab(index) {
			const tab = state.tabs[index];
			state.active = index;
			state.history = tab.history;
			state.dirty = tab.dirty;
			state.starting = false;
			state.confirm = null;
			resetView(doc(), null);
		}

		function switchTab(index) {
			if (index === state.active) return;
			commitFocused();
			keepActive();
			showTab(index);
			state.message = null;
			render();
		}

		/** A tab for a document, with a history of its own. */
		function newTab(document, dirty) {
			return { history: LayoutEditorModel.createHistory(document), dirty };
		}

		/** A blank layout, as « New » makes it. */
		function blankDoc() {
			return LayoutSourceIO.create('my_layout', tl('default_name'));
		}

		/** « + »: a blank layout in a new tab, with « Start from » open to pick another. */
		function addTab() {
			commitFocused();
			keepActive();
			state.tabs.push(newTab(blankDoc(), false));
			showTab(state.tabs.length - 1);
			state.message = null;
			state.starting = true;
			if (state.fillSources === null) loadFillSources();
			render();
		}

		function closeTab(index) {
			const run = () => {
				commitFocused();
				keepActive();
				state.tabs.splice(index, 1);
				if (state.tabs.length === 0) state.tabs.push(newTab(blankDoc(), false));
				const shown = index < state.active ? state.active - 1 : state.active;
				showTab(Math.min(shown, state.tabs.length - 1));
				render();
			};
			const tab = tabAt(index);
			if (tab.dirty)
				ask(tl('tabs.close_confirm', { name: tab.history.current().layout.name }), run);
			else run();
		}

		/** « Export all »: one ZIP of every tab's source, for a backup or another machine. */
		function exportTabs() {
			keepActive();
			let archive;
			try {
				archive = LayoutEditorWorkspace.backup(
					state.tabs.map((tab) => ({
						id: tab.history.current().layout.id,
						text: sourceText(tab.history.current())
					}))
				);
			} catch (error) {
				notify('error', problemText(error));
				return;
			}
			fromHost(() => host.saveBinary(archive.filename, archive.bytes, 'application/zip')).then(
				() =>
					notify('ok', tl('tabs.exported', { count: state.tabs.length, name: archive.filename })),
				(error) => notify('error', problemText(error))
			);
		}

		/** The document of one imported file: an Ergopti source or a .keylayout. */
		function importedDoc(name, text) {
			if (/\.keylayout$/i.test(name)) {
				const id = LayoutSourceIO.identifierFrom(name.replace(/\.keylayout$/i, ''), 'layout');
				return LayoutSourceIO.importKeylayout(text, id, state.importConvention);
			}
			const parsed = LayoutSourceIO.parse(text);
			if (!parsed.ok) throw parsed.error;
			return parsed.doc;
		}

		/**
		 * « Import »: every layout of the chosen files (sources, .keylayout files and
		 * backups) in new tabs; a file that does not read is named, the others open.
		 */
		async function importTabs(input) {
			const files = [...(input.files || [])];
			input.value = '';
			if (files.length === 0) return;
			const entries = [];
			const refused = [];
			for (const file of files) {
				try {
					if (/\.zip$/i.test(file.name))
						entries.push(
							...(await LayoutEditorWorkspace.readArchive(new Uint8Array(await file.arrayBuffer())))
						);
					else if (LayoutEditorWorkspace.IMPORTED.test(file.name))
						entries.push({ name: file.name, text: await file.text() });
					else throw { code: 'import_unsupported', path: file.name };
				} catch (error) {
					refused.push(`${file.name}: ${problemText(error)}`);
				}
			}
			commitFocused();
			keepActive();
			const first = state.tabs.length;
			for (const entry of entries) {
				try {
					state.tabs.push(newTab(importedDoc(entry.name, entry.text), false));
				} catch (error) {
					refused.push(`${entry.name}: ${problemText(error)}`);
				}
			}
			if (state.tabs.length > first) showTab(first);
			const imported = tl('tabs.imported', { count: state.tabs.length - first });
			if (refused.length)
				notify('error', `${imported} ${tl('tabs.import_refused', { files: refused.join(' · ') })}`);
			else notify('ok', imported);
		}

		// ============================
		// ======= 4c/ Autosave =======
		// ============================

		let autosaveTimer = null;
		// The text last stored, and whether a save is running or another is due after it.
		let storedText = null;
		// What that text was made from: each tab's document and state, and the tab shown.
		let storedShape = null;
		let saving = false;
		let saveAgain = false;

		function autosaveText() {
			const workspace = state.workspace;
			if (workspace.status === 'none') return '';
			if (workspace.status === 'failed')
				return tl('tabs.autosave.failed', { reason: problemText(workspace.error) });
			if (workspace.status === 'loading') return tl('tabs.autosave.loading');
			const text = tl(
				workspace.status === 'saving' ? 'tabs.autosave.saving' : 'tabs.autosave.saved'
			);
			return state.persisted === false ? `${text} ${tl('tabs.autosave.not_persistent')}` : text;
		}

		/** Shows the store's state without a render (a render would schedule another save). */
		function showAutosave() {
			const node = root.querySelector('#le-autosave');
			if (!node) return;
			node.textContent = autosaveText();
			node.className = `le-autosave ${state.workspace.status}`;
		}

		/** Whether the tabs can be saved now: the host keeps them and they were read. */
		function autosaves() {
			return (
				Boolean(host.workspace) && state.workspace.status !== 'loading' && !state.workspace.blocked
			);
		}

		/** What the stored text depends on; documents are immutable, so identity is enough. */
		function workspaceShape() {
			return [state.active].concat(
				...state.tabs.map((stored, index) => {
					const tab = tabAt(index);
					return [tab.history.current(), tab.dirty];
				})
			);
		}

		function sameShape(a, b) {
			return (
				a !== null && b !== null && a.length === b.length && a.every((part, i) => part === b[i])
			);
		}

		/** Saves after the delay when a tab changed; the status says a save is due at once. */
		function scheduleAutosave() {
			if (!autosaves() || sameShape(workspaceShape(), storedShape)) return;
			clearTimeout(autosaveTimer);
			autosaveTimer = setTimeout(flushAutosave, LayoutEditorWorkspace.AUTOSAVE_DELAY_MS);
			if (state.workspace.status !== 'failed') {
				state.workspace.status = 'saving';
				showAutosave();
			}
		}

		/** Saves every tab now when they changed since the last save; one save at a time. */
		function flushAutosave() {
			clearTimeout(autosaveTimer);
			autosaveTimer = null;
			if (!autosaves()) return;
			if (saving) {
				saveAgain = true;
				return;
			}
			const shape = workspaceShape();
			let text;
			try {
				text = LayoutEditorWorkspace.serialize(
					state.tabs.map((stored, index) => {
						const tab = tabAt(index);
						return { text: sourceText(tab.history.current()), dirty: tab.dirty };
					}),
					state.active
				);
			} catch (error) {
				state.workspace.status = 'failed';
				state.workspace.error = error;
				showAutosave();
				return;
			}
			if (text === storedText) {
				storedShape = shape;
				state.workspace.status = 'saved';
				showAutosave();
				return;
			}
			saving = true;
			state.workspace.status = 'saving';
			showAutosave();
			fromHost(() => host.workspace.save(text))
				.then(
					() => {
						storedText = text;
						storedShape = shape;
						// Saved, unless a change came while the save ran.
						state.workspace.status = saveAgain ? 'saving' : 'saved';
					},
					(error) => {
						state.workspace.status = 'failed';
						state.workspace.error = error;
					}
				)
				.then(() => {
					saving = false;
					showAutosave();
					if (saveAgain) {
						saveAgain = false;
						flushAutosave();
					}
				});
		}

		/** A stored workspace that does not read: say why and never save over it. */
		function refuseWorkspace(error) {
			state.workspace = { status: 'failed', blocked: true, error };
			state.message = {
				kind: 'error',
				text: tl('tabs.restore_failed', { reason: problemText(error) }),
				// Translated again when the locale arrives after the refusal.
				translate: () => tl('tabs.restore_failed', { reason: problemText(error) })
			};
		}

		/**
		 * Restores the stored tabs; a tab edited before they arrived stays after them.
		 * @param {string|null} text - The stored workspace, null before the first save.
		 * @returns {boolean} Whether tabs were restored (the caller renders).
		 */
		function restoreWorkspace(text) {
			if (text === null) {
				state.workspace.status = 'saved';
				return false;
			}
			let stored;
			let restored;
			try {
				stored = LayoutEditorWorkspace.parse(text);
				restored = stored.tabs.map((tab, index) => {
					const parsed = LayoutSourceIO.parse(tab.text);
					if (!parsed.ok)
						throw { code: parsed.error.code, path: `${index + 1}: ${parsed.error.path}` };
					return newTab(parsed.doc, tab.dirty);
				});
			} catch (error) {
				refuseWorkspace(error);
				return false;
			}
			commitFocused();
			keepActive();
			const edited = state.tabs.filter((tab) => tab.dirty);
			state.tabs = restored.concat(edited);
			storedText = text;
			state.workspace.status = 'saved';
			showTab(edited.length ? state.tabs.length - 1 : stored.active);
			storedShape = edited.length ? null : workspaceShape();
			return true;
		}

		/** The open tabs, « + », the workspace's state and the backup of every tab. */
		function tabBar() {
			const tabs = state.tabs.map((stored, index) => {
				const tab = tabAt(index);
				const name = tab.history.current().layout.name;
				const active = index === state.active;
				return el('span', { class: `le-layout-tab-item${active ? ' active' : ''}` }, [
					el('button', {
						type: 'button',
						class: 'le-layout-tab',
						role: 'tab',
						'data-tab': String(index),
						'aria-selected': String(active),
						title: tl(tab.dirty ? 'toolbar.unsaved' : 'toolbar.saved'),
						text: `${name}${tab.dirty ? ' •' : ''}`,
						onclick: () => switchTab(index)
					}),
					el('button', {
						type: 'button',
						class: 'le-layout-tab-close',
						'data-close-tab': String(index),
						'aria-label': tl('tabs.close', { name }),
						title: tl('tabs.close', { name }),
						text: '×',
						onclick: () => closeTab(index)
					})
				]);
			});
			const importInput = el('input', {
				type: 'file',
				id: 'le-tabs-import-file',
				accept: '.toml,.keylayout,.zip',
				multiple: true,
				hidden: true,
				onchange: (event) => importTabs(event.target)
			});
			return el('div', { class: 'le-layout-tabs', id: 'le-layout-tabs' }, [
				el(
					'div',
					{ class: 'le-layout-tab-list', role: 'tablist', 'aria-label': tl('tabs.label') },
					[
						...tabs,
						el('button', {
							type: 'button',
							id: 'le-tab-add',
							class: 'le-layout-tab-add',
							'aria-label': tl('tabs.add'),
							title: tl('tabs.add'),
							text: '+',
							onclick: addTab
						})
					]
				),
				el('span', {
					class: `le-autosave ${state.workspace.status}`,
					id: 'le-autosave',
					role: 'status',
					text: autosaveText()
				}),
				host.saveBinary
					? el('button', {
							type: 'button',
							id: 'le-tabs-export',
							text: tl('tabs.export_all'),
							onclick: exportTabs
						})
					: null,
				el('button', {
					type: 'button',
					id: 'le-tabs-import',
					text: tl('tabs.import'),
					onclick: () => importInput.click()
				}),
				importInput
			]);
		}

		// ============================
		// ======= 4/ Files ===========
		// ============================

		function openText(name, text) {
			if (/\.keylayout$/i.test(name)) {
				const convention = state.importConvention;
				try {
					const id = LayoutSourceIO.identifierFrom(name.replace(/\.keylayout$/i, ''), 'layout');
					replace(LayoutSourceIO.importKeylayout(text, id, convention));
					notify('ok', tl('status.imported', { name }));
				} catch (error) {
					notify('error', problemText(error));
				}
				return;
			}
			const parsed = LayoutSourceIO.parse(text);
			if (!parsed.ok) return notify('error', problemText(parsed.error));
			replace(parsed.doc);
			notify('ok', tl('status.opened', { name }));
		}

		/** Opens a file through the host's native panel (macOS), where the webview shows none. */
		function pickWithHost() {
			fromHost(() => host.pickFile()).then(
				(picked) => {
					if (picked && typeof picked.text === 'string') openText(picked.filename, picked.text);
				},
				(error) => notify('error', problemText(error))
			);
		}

		function readFile(input, onText) {
			const file = input.files && input.files[0];
			if (!file) return;
			file.text().then(
				(text) => onText(file.name, text),
				(error) => notify('error', problemText({ code: 'file_unreadable', path: String(error) }))
			);
			input.value = '';
		}

		function save(filename, text, mime) {
			fromHost(() => host.saveFile(filename, text, mime)).then(
				() => {
					if (/\.toml$/.test(filename) && filename !== 'layers.toml') state.dirty = false;
					notify('ok', tl(host.savedStatus || 'status.saved', { name: filename }));
				},
				(error) => notify('error', problemText(error))
			);
		}

		function saveSource() {
			try {
				save(`${doc().layout.id}.toml`, LayoutSourceIO.serialize(doc()), 'application/toml');
			} catch (error) {
				notify('error', problemText(error));
			}
		}

		function importNav(name, text) {
			commitFocused();
			const hold = state.navHold;
			if (!hold) return notify('error', problemText({ code: 'nav_hold_key_missing', path: '' }));
			try {
				state.history.push(LayoutSourceIO.withNavLayer(doc(), text, [hold], data));
				state.layer = LayoutSourceIO.NAV_LAYER;
				state.dirty = true;
				notify('ok', tl('status.nav_imported', { name }));
			} catch (error) {
				notify('error', problemText(error));
			}
		}

		function ask(text, onYes) {
			state.confirm = { text, onYes };
			render();
		}

		function adoptConverted(converted) {
			state.history.push(converted.doc);
			state.lost = converted.lost;
			state.approximate = false;
			state.layer = 'base';
			state.dirty = true;
			notify('ok', tl('status.converted'));
		}

		function convertImport() {
			try {
				adoptConverted(LayoutSourceIO.convertImport(doc()));
			} catch (error) {
				// The exact importer refused: offer the approximate conversion, never silently.
				state.approximate = true;
				notify('error', problemText(error));
			}
		}

		function approximateImport() {
			try {
				adoptConverted(LayoutSourceIO.approximateImport(doc()));
			} catch (error) {
				notify('error', problemText(error));
			}
		}

		// ============================
		// ======= 5/ Toolbar =========
		// ============================

		/** The primary actions: the file, the history and, in a window, Close. */
		function toolbar() {
			const fileInput = el('input', {
				type: 'file',
				id: 'le-open-file',
				accept: '.toml,.keylayout',
				hidden: true,
				onchange: (event) => readFile(event.target, openText)
			});
			// Always in the page, so a navigation layer file can be read from any tool.
			const navInput = el('input', {
				type: 'file',
				id: 'le-nav-file',
				accept: '.toml',
				hidden: true,
				onchange: (event) => readFile(event.target, importNav)
			});
			const button = (id, label, onclick, extra) =>
				el('button', Object.assign({ type: 'button', id, text: label, onclick }, extra || {}));
			return el(
				'div',
				{ class: 'le-toolbar', role: 'toolbar', 'aria-label': tl('toolbar.label') },
				[
					el('div', { class: 'le-toolbar-group' }, [
						button(
							'le-new',
							tl('btn.new'),
							() => {
								state.starting = !state.starting;
								if (state.starting && state.fillSources === null) loadFillSources();
								else render();
							},
							{ 'aria-expanded': String(state.starting) }
						),
						button('le-open', tl('btn.open'), () =>
							host.pickFile ? pickWithHost() : fileInput.click()
						),
						button('le-save', tl('btn.save'), saveSource, { class: 'primary' }),
						fileInput,
						navInput
					]),
					el('div', { class: 'le-toolbar-group' }, [
						button(
							'le-undo',
							tl('btn.undo'),
							() => {
								state.history.undo();
								render();
							},
							{ disabled: !state.history.canUndo() }
						),
						button(
							'le-redo',
							tl('btn.redo'),
							() => {
								state.history.redo();
								render();
							},
							{ disabled: !state.history.canRedo() }
						)
					]),
					el('span', { class: 'le-toolbar-spacer' }),
					el('span', {
						class: `le-doc-state${state.dirty ? ' dirty' : ''}`,
						id: 'le-doc-state',
						text: `${doc().layout.name}${state.dirty ? ' •' : ''}`,
						title: tl(state.dirty ? 'toolbar.unsaved' : 'toolbar.saved')
					}),
					host.onClose ? button('le-close', tl('btn.close'), host.onClose) : null
				]
			);
		}

		function messageBar() {
			const parts = [];
			if (state.confirm) {
				const question = state.confirm;
				const answer = (yes) => {
					state.confirm = null;
					if (yes) question.onYes();
					else render();
				};
				parts.push(
					el('div', { class: 'le-confirm', id: 'le-confirm', role: 'alertdialog' }, [
						el('p', { text: question.text }),
						el('button', {
							type: 'button',
							id: 'le-confirm-yes',
							class: 'primary',
							text: tl('btn.confirm'),
							onclick: () => answer(true)
						}),
						el('button', {
							type: 'button',
							id: 'le-confirm-no',
							text: tl('btn.cancel'),
							onclick: () => answer(false)
						})
					])
				);
			}
			if (state.message)
				parts.push(
					el('p', {
						class: `le-message ${state.message.kind}`,
						id: 'le-message',
						role: 'status',
						text: state.message.text
					})
				);
			if (LayoutSourceIO.isPreserved(doc()))
				parts.push(
					el('div', { class: 'le-preserved', id: 'le-preserved' }, [
						el('p', { text: tl('preserved_note') }),
						el('button', {
							type: 'button',
							id: 'le-convert',
							text: tl('btn.convert'),
							onclick: () => ask(tl('convert_confirm'), convertImport)
						}),
						state.approximate
							? el('button', {
									type: 'button',
									id: 'le-convert-approximate',
									text: tl('btn.convert_approximate'),
									onclick: () => ask(tl('convert_approximate_confirm'), approximateImport)
								})
							: null
					])
				);
			if (state.lost)
				parts.push(
					el(
						'ul',
						{ class: 'le-lost', id: 'le-lost' },
						state.lost.map((code) => el('li', { text: tl(`lost.${code}`) }))
					)
				);
			return el('div', { class: 'le-messages' }, parts);
		}

		// ============================
		// ======= 6/ Metadata ========
		// ============================

		/** The layout's name, description, author and how a .keylayout is read. */
		function metadata() {
			const layout = doc().layout;
			const field = (name, id) =>
				el('label', { class: 'le-field' }, [
					tl(`meta.${name}`),
					el('input', {
						type: 'text',
						id,
						value: layout[name] || '',
						onchange: (event) =>
							apply((d) => LayoutEditorModel.setLayout(d, { [name]: event.target.value }))
					})
				]);
			return el('section', { class: 'le-panel le-meta', id: 'le-meta' }, [
				el('h2', { text: tl('tools.details') }),
				el('div', { class: 'le-form-grid' }, [
					field('name', 'le-name'),
					field('author', 'le-author'),
					el('label', { class: 'le-field le-wide' }, [
						tl('meta.description'),
						el('input', {
							type: 'text',
							id: 'le-description',
							value: layout.description || '',
							onchange: (event) =>
								apply((d) => LayoutEditorModel.setLayout(d, { description: event.target.value }))
						})
					]),
					el('label', { class: 'le-field' }, [
						tl('import_convention'),
						select(
							[
								['iso', tl('physical.iso')],
								['ansi', tl('physical.ansi')]
							],
							state.importConvention,
							(value) => {
								state.importConvention = value;
							},
							{ id: 'le-import-convention' }
						)
					])
				]),
				el('p', { class: 'le-note', text: tl('meta.id', { id: layout.id }) })
			]);
		}

		// ============================
		// ======= 7/ Layers ==========
		// ============================

		function modifierOptions() {
			return BUILTIN_MODIFIERS.concat((doc().modifiers || []).map((m) => m.id));
		}

		/**
		 * The layer of the document that holds one of the four character levels: the
		 * layer of that id, else the one reached by the same modifiers (AltGr is
		 * Alt or Right Alt), else null.
		 */
		function levelLayer(level) {
			const layers = LayoutEditorModel.layers(doc());
			const byId = layers.find((layer) => layer.id === level.id);
			if (byId) return byId;
			const altgr = (id) => (id === 'alt_right' ? 'alt' : id);
			const wanted = level.required.slice().sort().join('+');
			return layers.find((layer) => layer.required.map(altgr).sort().join('+') === wanted) || null;
		}

		/**
		 * A layer's readable name: its modifiers as the keycaps name them (« Maj +
		 * Verr. Maj »), a modifier no key names keeping its id; a layer reached by
		 * no modifier keeps its id.
		 */
		function layerLabel(layer) {
			if (!layer.required.length) return layer.id;
			return layer.required.map(modifierLabel).join(' + ');
		}

		/** A modifier as the keycaps name it; one no key names keeps its id. */
		function modifierLabel(mod) {
			const code = MODIFIER_NAME_KEYS[mod];
			if (!code) return mod;
			const name = keyName(code);
			if (name !== code) return name;
			// A key each OS names its own way (Meta) when the view states no OS.
			const names = LayoutEditorModel.PLATFORMS.map((os) =>
				LayerModel.keyLegend(code, Object.assign({}, keyView, { os }))
			).filter((each) => each !== code);
			return names.length ? [...new Set(names)].join(' / ') : mod;
		}

		/** A chord as the keycaps name it: Ctrl + Maj + C. */
		function chordLabel(modifiers, code) {
			return modifiers
				.map(modifierLabel)
				.concat([keyName(code)])
				.join(' + ');
		}

		/** The key every other combination of a key acts as (keys.<code>.shortcut_key), or null. */
		function shortcutKeyOf(code) {
			const entry = (doc().keys || {})[code];
			return entry && typeof entry.shortcut_key === 'string' ? entry.shortcut_key : null;
		}

		/** A key as its cap reads: one letter in capitals (« C »), else its name. */
		function capLabel(code) {
			const name = keyName(code);
			// A letter or digit key the layout does not map yet reads as its position (KeyC: « C »).
			const position = name === code ? /^(?:Key|Digit)(.)$/.exec(code) : null;
			if (position) return position[1];
			return Array.from(name).length === 1 ? name.toUpperCase() : name;
		}

		/** A key's tooltip in the shortcut view: what it acts as, then each override. */
		function shortcutTitle(code, actsAs, overrides) {
			const lines = overrides.map(
				(entry) =>
					`${chordLabel(entry.modifiers, entry.key)} → ${chordLabel(entry.send_modifiers, entry.send_key)}`
			);
			if (actsAs) lines.unshift(`${keyName(code)}: ${tl('shortcut.act_as')} ${capLabel(actsAs)}`);
			return lines.length ? lines.join('\n') : `${keyName(code)}: ${tl('shortcut.same')}`;
		}

		/** The overrides of one key, in the order the source lists them. */
		function keyShortcuts(code) {
			return (doc().shortcuts || []).filter((entry) => entry.key === code);
		}

		/** Selects a layer and redraws. */
		function showLayer(id) {
			state.layer = id;
			state.shortcutView = false;
			render();
		}

		/** Shows the « Shortcuts » view. */
		function showShortcuts() {
			state.shortcutView = true;
			state.shortcutDraft = null;
			state.shortcutForm = null;
			state.pickingShortcutKey = null;
			render();
		}

		/**
		 * The layer selector: the four character levels always shown (a missing one
		 * is added by choosing it), then every other layer of the layout.
		 */
		function layerBar() {
			const preserved = LayoutSourceIO.isPreserved(doc());
			const current = state.shortcutView ? null : state.layer;
			const levelIds = new Set();
			const levels = LayoutSourceIO.LEVEL_LAYERS.map((level) => {
				const layer = levelLayer(level);
				const label = tl(`fill.level.${level.id}`);
				if (layer) {
					levelIds.add(layer.id);
					return el('button', {
						type: 'button',
						role: 'tab',
						class: `le-tab${layer.id === current ? ' active' : ''}`,
						'aria-selected': String(layer.id === current),
						'data-layer': layer.id,
						'data-level': level.id,
						title: layer.required.join('+') || tl('layer.no_modifier'),
						text: label,
						onclick: () => showLayer(layer.id)
					});
				}
				return el('button', {
					type: 'button',
					class: 'le-tab missing',
					'data-level': level.id,
					disabled: preserved,
					title: tl('layer.level_missing', { layer: label }),
					'aria-label': tl('layer.level_missing', { layer: label }),
					text: `+ ${label}`,
					onclick: () => {
						apply((d) => LayoutEditorModel.addLayer(d, level.id, level.required, []));
						if (doc().layers.some((l) => l.id === level.id)) showLayer(level.id);
					}
				});
			});
			const others = LayoutEditorModel.layers(doc())
				.filter((layer) => !levelIds.has(layer.id))
				.map((layer) =>
					el('button', {
						type: 'button',
						role: 'tab',
						class: `le-tab${layer.id === current ? ' active' : ''}`,
						'aria-selected': String(layer.id === current),
						'data-layer': layer.id,
						title: `${layer.id} (${layer.required.join('+') || tl('layer.no_modifier')})`,
						text: layerLabel(layer),
						onclick: () => showLayer(layer.id)
					})
				);
			const scope = select(
				[['', tl('scope.all')]].concat(
					LayoutEditorModel.PLATFORMS.map((p) => [p, tl(`scope.${p}`)])
				),
				state.platform,
				(value) => {
					state.platform = value;
					render();
				},
				{ id: 'le-scope' }
			);
			return el('section', { class: 'le-layerbar', id: 'le-layerbar' }, [
				el('div', { class: 'le-layer-pick' }, [
					el('span', { class: 'le-label', id: 'le-layers-label', text: tl('layer.selector') }),
					el(
						'div',
						{
							class: 'le-tabs le-segmented',
							role: 'tablist',
							'aria-labelledby': 'le-layers-label'
						},
						levels
					),
					others.length
						? el('div', { class: 'le-tabs le-other-layers', role: 'tablist' }, others)
						: null,
					preserved
						? null
						: el('button', {
								type: 'button',
								role: 'tab',
								id: 'le-shortcut-view',
								class: `le-tab le-shortcut-tab${state.shortcutView ? ' active' : ''}`,
								'aria-selected': String(state.shortcutView),
								title: tl('shortcut.view_title'),
								text: tl('shortcut.view'),
								onclick: showShortcuts
							}),
					preserved
						? null
						: el('button', {
								type: 'button',
								class: 'le-link',
								id: 'le-manage-layers',
								text: tl('layer.manage'),
								onclick: () => showTool('layers')
							})
				]),
				el('div', { class: 'le-view' }, [
					el('label', { class: 'le-inline' }, [tl('scope.label'), scope]),
					el('label', { class: 'le-inline' }, [
						tl('board.label'),
						select(
							[
								['iso', tl('physical.iso')],
								['ansi', tl('physical.ansi')]
							],
							state.board,
							(value) => {
								state.board = value;
								render();
							},
							{ id: 'le-board-form' }
						)
					]),
					el('label', { class: 'le-inline' }, [
						t('layout_analysis.format.label'),
						select(
							LAYOUT_ANALYSIS.keyboardFormats().map((format) => [
								format.id,
								t(`layout_analysis.format.${format.id}`)
							]),
							state.format,
							(value) => {
								state.format = value;
								render();
							},
							{ id: 'le-board-format' }
						)
					])
				])
			]);
		}

		/** Adds, removes and empties layers. */
		function layersTool() {
			const idInput = el('input', {
				type: 'text',
				id: 'le-layer-id',
				placeholder: tl('layer.id_placeholder')
			});
			const checks = modifierOptions().map((id) =>
				el('label', { class: 'le-check' }, [el('input', { type: 'checkbox', value: id }), id])
			);
			const addForm = el('div', { class: 'le-subpanel le-add', id: 'le-layer-add-form' }, [
				el('h3', { text: tl('layer.add') }),
				idInput,
				el('div', { class: 'le-checks', id: 'le-layer-required' }, checks),
				el('button', {
					type: 'button',
					id: 'le-layer-add',
					text: tl('btn.add'),
					onclick: () => {
						const required = checks
							.map((c) => c.firstChild)
							.filter((c) => c.checked)
							.map((c) => c.value);
						const id = idInput.value.trim();
						apply((d) => LayoutEditorModel.addLayer(d, id, required, []));
						if (doc().layers.some((l) => l.id === id)) showLayer(id);
					}
				})
			]);
			const others = LayoutEditorModel.layers(doc()).filter((layer) => layer.id !== state.layer);
			const moveTarget = select(
				others.map((layer) => [layer.id, layer.id]),
				others.length ? others[0].id : '',
				() => {},
				{ id: 'le-move-target' }
			);
			const moveAll = (keep) => () => {
				const from = state.layer;
				apply((d) => LayoutEditorModel.transferLayer(d, from, moveTarget.value, keep));
			};
			const current =
				state.layer && others.length
					? el('div', { class: 'le-subpanel le-add', id: 'le-move-all' }, [
							el('h3', { text: tl('layer.move_all') }),
							el('label', { class: 'le-inline' }, [tl('layer.move_target'), moveTarget]),
							el('div', { class: 'le-buttons' }, [
								el('button', {
									type: 'button',
									id: 'le-move-layer',
									text: tl('btn.move'),
									onclick: moveAll(false)
								}),
								el('button', {
									type: 'button',
									id: 'le-copy-layer',
									text: tl('btn.copy'),
									onclick: moveAll(true)
								})
							]),
							state.layer !== 'base'
								? el('button', {
										type: 'button',
										id: 'le-layer-remove',
										class: 'danger',
										text: tl('layer.remove', { id: state.layer }),
										onclick: () => {
											const removed = state.layer;
											apply((d) => LayoutEditorModel.removeLayer(d, removed));
											if (!doc().layers.some((l) => l.id === removed)) showLayer('base');
										}
									})
								: null
						])
					: null;
			return el('section', { class: 'le-panel', id: 'le-layers' }, [
				el('h2', { text: tl('tools.layers') }),
				el('div', { class: 'le-subpanels' }, [addForm, current])
			]);
		}

		/** Imports a navigation layer (layers.toml) as a layer held by one key. */
		function navigationTool() {
			const keyOptions = [['', tl('nav_hold_placeholder')]].concat(
				data.keys.filter((k) => k.kind === 'key').map((k) => [k.code, keyName(k.code)])
			);
			return el('section', { class: 'le-panel', id: 'le-navigation' }, [
				el('h2', { text: tl('tools.navigation') }),
				el('p', { class: 'le-note', text: tl('nav.note') }),
				el('div', { class: 'le-buttons' }, [
					el('label', { class: 'le-inline' }, [
						tl('nav_hold'),
						select(
							keyOptions,
							state.navHold,
							(value) => {
								state.navHold = value;
							},
							{ id: 'le-nav-hold' }
						)
					]),
					el('button', {
						type: 'button',
						id: 'le-nav-import',
						text: tl('btn.nav_import'),
						disabled: LayoutSourceIO.isPreserved(doc()),
						onclick: () => root.querySelector('#le-nav-file').click()
					})
				])
			]);
		}

		/** Sticker printing: size, levels and the print button. */
		function stickersTool() {
			return el('section', { class: 'le-panel', id: 'le-sticker-tool' }, [
				el('h2', { text: tl('tools.stickers') }),
				el('p', { class: 'le-note', text: tl('sticker.note') }),
				el('div', { class: 'le-buttons' }, [
					el('label', { class: 'le-inline' }, [
						tl('sticker.size'),
						el('input', {
							type: 'number',
							id: 'le-sticker-mm',
							min: STICKER_MIN_MM,
							max: STICKER_MAX_MM,
							placeholder: tl('sticker.fit'),
							value: state.stickerMm === null ? '' : state.stickerMm,
							onchange: (event) => {
								const mm = Number(event.target.value);
								state.stickerMm =
									event.target.value === '' || !(mm >= STICKER_MIN_MM && mm <= STICKER_MAX_MM)
										? null
										: mm;
								render();
							}
						})
					]),
					el('button', {
						type: 'button',
						id: 'le-print',
						class: 'primary',
						text: tl('btn.print'),
						onclick: () => window.print()
					})
				]),
				LayoutSourceIO.isPreserved(doc()) ? null : stickerOptions()
			]);
		}

		/** Shows one secondary tool. */
		function showTool(id) {
			state.tool = id;
			render();
			const tab = root.querySelector(`#le-tool-tab-${id}`);
			if (tab) tab.scrollIntoView({ block: 'nearest' });
		}

		/** The secondary tools: one tab strip, one panel shown at a time. */
		function tools() {
			const preserved = LayoutSourceIO.isPreserved(doc());
			const builders = {
				details: metadata,
				layers: preserved ? null : layersTool,
				modifiers: preserved ? null : modifiersPanel,
				dead_keys: preserved ? null : deadKeysPanel,
				fill: preserved ? null : fillPanel,
				navigation: navigationTool,
				windows: preserved ? null : windowsPanel,
				export: exportPanel,
				stickers: stickersTool
			};
			const shown = TOOLS.filter((id) => builders[id]);
			const active = shown.includes(state.tool) ? state.tool : shown[0];
			const tabs = shown.map((id) =>
				el('button', {
					type: 'button',
					role: 'tab',
					id: `le-tool-tab-${id}`,
					class: `le-tool-tab${id === active ? ' active' : ''}`,
					'data-tool': id,
					'aria-selected': String(id === active),
					'aria-controls': 'le-tool-panel',
					text: tl(`tools.${id}`),
					onclick: () => showTool(id)
				})
			);
			return el('section', { class: 'le-tools', id: 'le-tools' }, [
				el(
					'div',
					{ class: 'le-tool-tabs', role: 'tablist', 'aria-label': tl('tools.label') },
					tabs
				),
				el(
					'div',
					{
						class: 'le-tool-panel',
						id: 'le-tool-panel',
						role: 'tabpanel',
						'aria-labelledby': `le-tool-tab-${active}`
					},
					builders[active]()
				)
			]);
		}

		// ============================
		// ======= 8/ Board ===========
		// ============================

		function currentMapping(code) {
			if (!state.layer || LayoutSourceIO.isPreserved(doc())) return null;
			const found = LayoutEditorModel.mappingAt(doc(), state.layer, code, state.platform || null);
			return found ? found : null;
		}

		function editableLayer() {
			return Boolean(state.layer) && !state.shortcutView && !LayoutSourceIO.isPreserved(doc());
		}

		function copyMapping(code) {
			const found = currentMapping(code);
			state.clipboard = found ? JSON.parse(JSON.stringify(found.mapping)) : null;
			notify('ok', tl(found ? 'status.copied' : 'status.copied_empty', { key: keyName(code) }));
		}

		function pasteMapping(code) {
			apply((d) =>
				LayoutEditorModel.setMapping(d, state.layer, code, state.clipboard, state.platform || null)
			);
		}

		/** Ctrl/Cmd+C and Ctrl/Cmd+V on a focused key copy and paste its mapping. */
		function clipboardKey(event, code) {
			if (!editableLayer() || !(event.ctrlKey || event.metaKey)) return;
			if (event.key === 'c') copyMapping(code);
			else if (event.key === 'v') pasteMapping(code);
			else return;
			event.preventDefault();
		}

		function board() {
			const form = state.board;
			const hidden = LAYOUT_ANALYSIS.formatHiddenKeys(state.format);
			const keys = data.keys.filter(
				(k) => k.kind === 'key' && k.geometry && k.geometry[form] && !hidden.has(k.code)
			);
			const width = Math.max(...keys.map((k) => k.geometry[form].col + k.geometry[form].width));
			// A format without the function row starts at the number row.
			const top = Math.min(...keys.map((k) => k.geometry[form].row));
			const height =
				Math.max(...keys.map((k) => k.geometry[form].row + (k.geometry[form].height || 1))) - top;
			const container = el('div', {
				class: 'le-board',
				id: 'le-board',
				// The stylesheet sizes one key unit to the width available (style.css, Board).
				style: `--le-cols:${width};--le-rows:${height}`
			});
			const remap = doc().remap || {};
			for (const key of keys) {
				const g = key.geometry[form];
				const overrides = state.shortcutView ? keyShortcuts(key.code) : [];
				const actsAs = state.shortcutView ? shortcutKeyOf(key.code) : null;
				const found = state.shortcutView ? null : currentMapping(key.code);
				// In the shortcut view a key shows its overrides, or « = » for « same as the base key ».
				const label = state.shortcutView
					? actsAs
						? overrides.length
							? `${capLabel(actsAs)} +${overrides.length}`
							: capLabel(actsAs)
						: overrides.length
							? overrides
									.map((entry) => `→ ${chordLabel(entry.send_modifiers, entry.send_key)}`)
									.join(' · ')
							: '='
					: found
						? legend(found.mapping, doc())
						: '';
				const classes = ['le-key'];
				if (found) classes.push(found.scope === 'all' ? 'mapped' : 'platform');
				if (!state.shortcutView && isDeadKey(found && found.mapping)) classes.push('dead');
				if (state.shortcutView) classes.push(overrides.length || actsAs ? 'overridden' : 'same');
				if (state.pickingShortcutKey && key.code !== state.pickingShortcutKey)
					classes.push('pickable');
				if (key.code === state.selected) classes.push('selected');
				if (Object.prototype.hasOwnProperty.call(remap, key.code)) classes.push('remapped');
				container.append(
					el(
						'button',
						{
							type: 'button',
							class: classes.join(' '),
							'data-code': key.code,
							// The full label, which a long one only shows here once fitted.
							title: state.shortcutView
								? shortcutTitle(key.code, actsAs, overrides)
								: label
									? `${keyName(key.code)}: ${label}`
									: keyName(key.code),
							style: `--x:${g.col};--y:${g.row - top};--w:${g.width};--h:${g.height || 1}`,
							draggable: editableLayer() ? 'true' : null,
							onclick: () => {
								// « Pick on the board »: this click chooses the key to act as.
								const picking = state.pickingShortcutKey;
								if (picking) {
									state.pickingShortcutKey = null;
									if (key.code !== picking)
										return apply((d) => LayoutEditorModel.setShortcutKey(d, picking, key.code));
									return render();
								}
								state.selected = key.code;
								render();
							},
							onkeydown: (event) => clipboardKey(event, key.code),
							...magnifyOn(
								magnifiedText(found && found.mapping),
								!state.shortcutView && isDeadKey(found && found.mapping)
							),
							ondragstart: (event) => event.dataTransfer.setData('text/plain', key.code),
							ondragover: (event) => event.preventDefault(),
							// KbdEdit's drop: a plain drop swaps the two keys, Ctrl (or Alt) copies.
							ondrop: (event) => {
								event.preventDefault();
								if (!editableLayer()) return;
								// A character dragged from the palette or the name search maps the key to it.
								const char = event.dataTransfer.getData(CHAR_DRAG_TYPE);
								if (char)
									return apply((d) =>
										LayoutEditorModel.setMapping(
											d,
											state.layer,
											key.code,
											{ text: char },
											state.platform || null
										)
									);
								const from = event.dataTransfer.getData('text/plain');
								if (!from) return;
								const keep = event.ctrlKey || event.altKey;
								apply((d) =>
									LayoutEditorModel.transferMapping(
										d,
										state.layer,
										from,
										key.code,
										state.platform || null,
										keep
									)
								);
							}
						},
						[
							el('span', {
								class:
									!state.shortcutView && isDeadKey(found && found.mapping)
										? `le-legend ${KEY_LEGEND.DEAD_KEY_CLASS}`
										: 'le-legend',
								text: label
							}),
							// Only a key with a printed name (Tab, Shift, Esc) shows it: a character
							// key shows the selected layer's value alone, never the base character
							// or its raw code; the tooltip still names it.
							el('span', {
								class: 'le-code',
								text: key.character || keyName(key.code) === key.code ? '' : keyName(key.code)
							})
						]
					)
				);
			}
			const media = data.keys.filter((k) => k.kind === 'key' && !k.geometry);
			const mediaRow = el(
				'div',
				{ class: 'le-media' },
				media.map((key) =>
					el('button', {
						type: 'button',
						class: `le-chip${key.code === state.selected ? ' selected' : ''}`,
						'data-code': key.code,
						text: `${keyName(key.code)} ${legend((currentMapping(key.code) || {}).mapping, doc())}`.trim(),
						onclick: () => {
							state.selected = key.code;
							render();
						}
					})
				)
			);
			return el('section', { class: 'le-board-wrap' }, [
				el('div', { class: 'le-board-scroll' }, container),
				mediaRow
			]);
		}

		// ============================
		// ======= 9/ Inspector =======
		// ============================

		function mappingEditor(code) {
			const found = currentMapping(code);
			const mapping = found ? found.mapping : null;
			let kind = mapping ? LayoutEditorModel.kindOf(mapping) : 'none';
			const area = el('div', { class: 'le-mapping-fields' });
			const deadOptions = (doc().dead_keys || []).map((d) => [d.id, d.name || d.id]);
			const actionOptions = Object.keys(data.actions).map((id) => [id, actionLabel(id)]);
			const keyOptions = data.keys
				.filter((k) => k.kind === 'key')
				.map((k) => [k.code, keyName(k.code)]);
			const fields = {
				text: el('input', {
					type: 'text',
					id: 'le-text',
					value: mapping && mapping.text !== undefined ? mapping.text : ''
				}),
				dead_key: select(deadOptions, mapping && mapping.dead_key, () => {}, { id: 'le-dead' }),
				action: select(actionOptions, mapping && mapping.action, () => {}, { id: 'le-action' }),
				key: select(keyOptions, mapping && mapping.key, () => {}, { id: 'le-send-key' })
			};
			const sendModifiers = modifierOptions().map((id) =>
				el('label', { class: 'le-check' }, [
					el('input', {
						type: 'checkbox',
						value: id,
						checked: Boolean(mapping && (mapping.modifiers || []).includes(id))
					}),
					id
				])
			);
			function showFields() {
				area.replaceChildren();
				if (kind === 'text') area.append(fields.text, palette(fields.text));
				if (kind === 'dead_key')
					area.append(
						deadOptions.length
							? fields.dead_key
							: el('p', { class: 'le-note', text: tl('dead.none_yet') })
					);
				if (kind === 'action') area.append(fields.action);
				if (kind === 'key')
					area.append(fields.key, el('div', { class: 'le-checks' }, sendModifiers));
			}
			showFields();
			const kindSelect = select(
				MAPPING_CHOICES.map((choice) => [choice, tl(`kind.${choice}`)]),
				kind,
				(value) => {
					kind = value;
					showFields();
				},
				{ id: 'le-kind' }
			);
			function built() {
				if (kind === 'none') return null;
				if (kind === 'text') return { text: fields.text.value };
				if (kind === 'dead_key') return { dead_key: fields.dead_key.value };
				if (kind === 'action') return { action: fields.action.value };
				if (kind === 'key') {
					const modifiers = sendModifiers
						.map((c) => c.firstChild)
						.filter((c) => c.checked)
						.map((c) => c.value);
					return modifiers.length
						? { key: fields.key.value, modifiers }
						: { key: fields.key.value };
				}
				return { disabled: true };
			}
			return el('div', { class: 'le-group' }, [
				el('h3', {
					text: tl('inspector.mapping', {
						layer: state.layer,
						scope: state.platform ? tl(`scope.${state.platform}`) : tl('scope.all')
					})
				}),
				kindSelect,
				area,
				el('div', { class: 'le-checks' }, [
					checkbox('le-auto-case', tl('case.auto'), state.autoCase, (on) => {
						state.autoCase = on;
					}),
					checkbox('le-case-overwrite', tl('case.overwrite'), state.caseOverwrite, (on) => {
						state.caseOverwrite = on;
					})
				]),
				el('button', {
					type: 'button',
					id: 'le-apply',
					class: 'primary',
					text: tl('btn.apply'),
					onclick: () =>
						apply((d) =>
							state.autoCase
								? LayoutEditorModel.setMappingWithCase(
										d,
										state.layer,
										code,
										built(),
										state.platform || null,
										state.caseOverwrite
									)
								: LayoutEditorModel.setMapping(
										d,
										state.layer,
										code,
										built(),
										state.platform || null
									)
						)
				}),
				el('button', {
					type: 'button',
					id: 'le-copy',
					text: tl('btn.copy'),
					onclick: () => copyMapping(code)
				}),
				el('button', {
					type: 'button',
					id: 'le-paste',
					text: tl('btn.paste'),
					disabled: state.clipboard === null,
					onclick: () => pasteMapping(code)
				}),
				el('p', { class: 'le-note', text: tl('drag_hint') })
			]);
		}

		/** Where a character is typed in the source: every layer and key whose text holds it. */
		function locate() {
			const input = el('input', {
				type: 'text',
				id: 'le-locate',
				size: 8,
				placeholder: tl('palette.locate_placeholder')
			});
			const results = el('ul', { class: 'le-list', id: 'le-locate-results' });
			const run = () => {
				const raw = input.value.trim();
				const hexForm = /^U\+([0-9A-Fa-f]{1,6})$/.exec(raw);
				const point = hexForm ? parseInt(hexForm[1], 16) : null;
				const valid = point === null || (point <= 0x10ffff && (point < 0xd800 || point > 0xdfff));
				if (!raw || !valid)
					return notify('error', problemText({ code: 'codepoint_invalid', path: raw }));
				const wanted = point === null ? raw : String.fromCodePoint(point);
				const found = [];
				for (const layer of doc().layers || [])
					for (const [code, mapping] of Object.entries(layer.keys))
						if (typeof mapping.text === 'string' && mapping.text.includes(wanted))
							found.push(`${layer.id} · ${keyName(code)}`);
				results.replaceChildren(
					...(found.length ? found : [tl('palette.locate_none')]).map((text) => el('li', { text }))
				);
			};
			return el('span', { class: 'le-inline' }, [
				input,
				el('button', {
					type: 'button',
					id: 'le-locate-run',
					text: tl('palette.locate'),
					onclick: run
				}),
				results
			]);
		}

		function palette(target) {
			const block = PALETTE_BLOCKS.find((b) => b.id === state.paletteBlock);
			const grid = el('div', { class: 'le-palette-grid', id: 'le-palette' });
			for (let point = block.from; point <= block.to; point++) {
				const char = String.fromCodePoint(point);
				grid.append(
					el('button', {
						type: 'button',
						class: 'le-glyph',
						title: UnicodeNames.codeLabel(point),
						text: visible(char),
						draggable: 'true',
						ondragstart: (event) => event.dataTransfer.setData(CHAR_DRAG_TYPE, char),
						onclick: () => {
							target.value += char;
							target.focus();
						},
						...magnifyOn(char)
					})
				);
			}
			const hex = el('input', { type: 'text', id: 'le-codepoint', placeholder: 'U+00E9', size: 8 });
			return el(
				'details',
				{
					class: 'le-palette',
					open: state.paletteOpen,
					ontoggle: (event) => {
						state.paletteOpen = event.target.open;
					}
				},
				[
					el('summary', { text: tl('palette.title') }),
					select(
						PALETTE_BLOCKS.map((b) => [b.id, tl(`palette.block.${b.id}`)]),
						state.paletteBlock,
						(value) => {
							state.paletteBlock = value;
							render();
						},
						{ id: 'le-palette-block' }
					),
					locate(),
					hex,
					el('button', {
						type: 'button',
						text: tl('palette.insert'),
						onclick: () => {
							const point = parseInt(hex.value.replace(/^U\+/i, ''), 16);
							if (
								!Number.isInteger(point) ||
								point < 0 ||
								point > 0x10ffff ||
								(point >= 0xd800 && point <= 0xdfff)
							)
								return notify('error', problemText({ code: 'codepoint_invalid', path: hex.value }));
							target.value += String.fromCodePoint(point);
						}
					}),
					grid,
					nameSearch(target)
				]
			);
		}

		// ===================================
		// ======= 9b/ Unicode names =========
		// ===================================

		/** Listeners that show a text in the character magnifier while it is hovered or focused. */
		function magnifyOn(text, dead) {
			const show = () => magnify(text, dead);
			return { onmouseenter: show, onfocus: show };
		}

		/** The text a key shows on the board, for the magnifier: its characters, not a symbol. */
		function magnifiedText(mapping) {
			if (!mapping) return '';
			const kind = LayoutEditorModel.kindOf(mapping);
			if (kind === 'text') return mapping.text;
			if (kind === 'dead_key') {
				const dead = (doc().dead_keys || []).find((entry) => entry.id === mapping.dead_key);
				return dead && dead.terminator ? dead.terminator : '';
			}
			return '';
		}

		/** Loads the names table if the page lacks it, then runs then(); a failure is shown. */
		function withNames(then) {
			if (UnicodeNames.available()) return then();
			UnicodeNames.ensure().then(then, () => {
				state.nameSearch.failed = true;
				then();
			});
		}

		/** Shows a text in the magnifier, updating it in place (no full render on hover). */
		function magnify(text, dead) {
			state.magnified = text || '';
			state.magnifiedDead = Boolean(dead);
			const node = root.querySelector('#le-magnifier');
			if (!node) return;
			if (state.magnified && !UnicodeNames.available() && !state.nameSearch.failed)
				return withNames(() => {
					const current = root.querySelector('#le-magnifier');
					if (current) current.replaceWith(magnifier());
				});
			node.replaceWith(magnifier());
		}

		function copyText(text) {
			const done = () => notify('ok', tl('magnifier.copied', { text: visible(text) }));
			const fallback = () => {
				const area = el('textarea', { class: 'le-copy-buffer', 'aria-hidden': 'true' });
				area.value = text;
				document.body.append(area);
				area.select();
				const copied = document.execCommand && document.execCommand('copy');
				area.remove();
				if (copied) done();
				else notify('error', problemText({ code: 'copy_failed', path: '' }));
			};
			if (navigator.clipboard && navigator.clipboard.writeText)
				navigator.clipboard.writeText(text).then(done, fallback);
			else fallback();
		}

		/** KbdEdit's character magnifier: a large glyph with each code point, name and block. */
		function magnifier() {
			const text = state.magnified;
			if (!text)
				return el('aside', { class: 'le-magnifier', id: 'le-magnifier' }, [
					el('h3', { text: tl('magnifier.title') }),
					el('p', { class: 'le-note', text: tl('magnifier.hint') })
				]);
			const named = UnicodeNames.available();
			const rows = Array.from(text).map((char) => {
				const point = char.codePointAt(0);
				const name = named ? UnicodeNames.nameOf(point) : null;
				const block = named ? UnicodeNames.blockOf(point) : null;
				return el('li', { class: 'le-magnifier-row' }, [
					el('code', { text: UnicodeNames.codeLabel(point) }),
					' ',
					el('span', {
						class: 'le-magnifier-name',
						text: named
							? name || tl('magnifier.unnamed')
							: tl(state.nameSearch.failed ? 'names.unavailable' : 'names.loading')
					}),
					block ? el('span', { class: 'le-magnifier-block', text: ` · ${block}` }) : null
				]);
			});
			return el('aside', { class: 'le-magnifier', id: 'le-magnifier' }, [
				el('h3', { text: tl('magnifier.title') }),
				el('div', {
					class: state.magnifiedDead
						? `le-magnifier-glyph ${KEY_LEGEND.DEAD_KEY_CLASS}`
						: 'le-magnifier-glyph',
					id: 'le-magnifier-glyph',
					text: state.magnifiedDead ? KEY_LEGEND.deadKeyText(text) : visible(text)
				}),
				el('ul', { class: 'le-list', id: 'le-magnifier-rows' }, rows),
				el('button', {
					type: 'button',
					id: 'le-magnifier-copy',
					text: tl('magnifier.copy'),
					onclick: () => copyText(text)
				})
			]);
		}

		/** The search's answer as clickable cells, or its state. */
		function nameResults(target) {
			const search = state.nameSearch;
			const box = el('div', { class: 'le-name-results', id: 'le-name-results' });
			if (search.failed) {
				box.append(el('p', { class: 'le-message error', text: tl('names.unavailable') }));
				return box;
			}
			if (!search.answer) return box;
			const { results, truncated } = search.answer;
			box.append(
				el('p', {
					class: 'le-note',
					id: 'le-name-count',
					text: results.length
						? tl(truncated ? 'names.truncated' : 'names.count', { count: results.length })
						: tl('names.none')
				}),
				el(
					'div',
					{ class: 'le-palette-grid' },
					results.map((result) =>
						el('button', {
							type: 'button',
							class: 'le-glyph',
							'data-point': result.code,
							title: `${result.code} ${result.name}`,
							text: visible(result.char),
							draggable: 'true',
							ondragstart: (event) => event.dataTransfer.setData(CHAR_DRAG_TYPE, result.char),
							onclick: () => {
								target.value += result.char;
								target.focus();
							},
							...magnifyOn(result.char)
						})
					)
				)
			);
			return box;
		}

		/** Search characters by name, alias, glyph or code point, with `*` and `?` wildcards. */
		function nameSearch(target) {
			const search = state.nameSearch;
			const query = el('input', {
				type: 'search',
				id: 'le-name-search',
				value: search.query,
				placeholder: tl('names.placeholder'),
				onkeydown: (event) => {
					if (event.key === 'Enter') {
						event.preventDefault();
						run();
					}
				}
			});
			const limit = el('input', {
				type: 'number',
				id: 'le-name-limit',
				min: 1,
				max: UnicodeNames.MAX_LIMIT,
				value: search.limit
			});
			const holder = el('div', {}, nameResults(target));
			function run() {
				search.query = query.value;
				search.limit = Math.min(
					Math.max(1, Math.floor(Number(limit.value) || UnicodeNames.DEFAULT_LIMIT)),
					UnicodeNames.MAX_LIMIT
				);
				limit.value = search.limit;
				holder.replaceChildren(el('p', { class: 'le-note', text: tl('names.loading') }));
				withNames(() => {
					if (!search.failed) search.answer = UnicodeNames.search(search.query, search.limit);
					holder.replaceChildren(nameResults(target));
				});
			}
			return el('div', { class: 'le-name-search' }, [
				el('label', { class: 'le-inline' }, [tl('names.label'), query]),
				el('label', { class: 'le-inline' }, [tl('names.limit'), limit]),
				el('button', {
					type: 'button',
					id: 'le-name-search-run',
					text: tl('names.search'),
					onclick: run
				}),
				el('p', { class: 'le-note', text: tl('names.help') }),
				holder
			]);
		}

		function keyProperties(code) {
			const entry = (doc().keys || {})[code] || {};
			const layerOptions = LayoutEditorModel.layers(doc()).map((l) => [l.id, l.id]);
			const mode = entry.caps_lock || 'unaffected';
			const capsLayer = select(layerOptions, entry.caps_layer, () => {}, { id: 'le-caps-layer' });
			const capsShift = select(layerOptions, entry.caps_shift_layer, () => {}, {
				id: 'le-caps-shift-layer'
			});
			const capsSelect = select(
				LayoutEditorModel.CAPS_MODES.map((m) => [m, tl(`caps.${m}`)]),
				mode,
				() => {},
				{ id: 'le-caps' }
			);
			const nameInput = el('input', { type: 'text', id: 'le-key-name', value: entry.name || '' });
			const virtualKeyBounds = declared('LAYOUT_SOURCE_KEYS_VIRTUAL_KEY');
			const virtualKey = el('input', {
				type: 'number',
				id: 'le-virtual-key',
				min: virtualKeyBounds.min,
				max: virtualKeyBounds.max,
				value: entry.virtual_key === undefined ? '' : entry.virtual_key
			});
			const capsAltgr = el('input', {
				type: 'checkbox',
				id: 'le-caps-altgr',
				checked: entry.caps_altgr === true
			});
			return inspectorGroup('key', [
				el('label', { class: 'le-field' }, [tl('caps.label'), capsSelect]),
				el('label', { class: 'le-field' }, [tl('caps.layer'), capsLayer]),
				el('label', { class: 'le-field' }, [tl('caps.shift_layer'), capsShift]),
				el('label', { class: 'le-field' }, [tl('key.name'), nameInput]),
				el('label', { class: 'le-check' }, [capsAltgr, tl('key.caps_altgr')]),
				el('label', { class: 'le-field' }, [tl('key.virtual_key'), virtualKey]),
				el('button', {
					type: 'button',
					id: 'le-key-apply',
					text: tl('btn.apply'),
					onclick: () => {
						const properties = Object.assign({}, entry);
						delete properties.caps_layer;
						delete properties.caps_shift_layer;
						if (capsSelect.value === 'unaffected') delete properties.caps_lock;
						else properties.caps_lock = capsSelect.value;
						if (capsSelect.value === 'separate') {
							properties.caps_layer = capsLayer.value;
							properties.caps_shift_layer = capsShift.value;
						}
						if (nameInput.value) properties.name = nameInput.value;
						else delete properties.name;
						if (capsAltgr.checked) properties.caps_altgr = true;
						else delete properties.caps_altgr;
						if (virtualKey.value === '') delete properties.virtual_key;
						else {
							const typed = checkedNumber(
								virtualKey,
								window.ErgoptiValueCheck.KEY.LAYOUT_SOURCE_KEYS_VIRTUAL_KEY,
								notify
							);
							if (typed === undefined) return;
							properties.virtual_key = typed;
						}
						apply((d) => LayoutEditorModel.setKeyProperties(d, code, properties));
					}
				})
			]);
		}

		function remapEditor(code) {
			const remap = doc().remap || {};
			const current = Object.prototype.hasOwnProperty.call(remap, code) ? remap[code] : null;
			const options = [
				['__none', tl('remap.none')],
				['', tl('remap.disabled')]
			].concat(
				data.keys
					.filter((k) => k.kind === 'key' && k.code !== code)
					.map((k) => [k.code, keyName(k.code)])
			);
			return inspectorGroup('remap', [
				select(
					options,
					current === null ? '__none' : current,
					(value) =>
						apply((d) => LayoutEditorModel.setRemap(d, code, value === '__none' ? null : value)),
					{ id: 'le-remap' }
				)
			]);
		}

		/**
		 * The shortcut overrides of a key: every one listed with Edit and Remove,
		 * and a form for any combination of modifiers sending any chord. A
		 * combination with no override acts as on the base key.
		 */
		function shortcutEditor(code) {
			const shortcuts = keyShortcuts(code);
			const draft =
				state.shortcutDraft && state.shortcutDraft.key === code ? state.shortcutDraft : null;
			// The form's choices live in the state, not only in its inputs: any render
			// before « Add » (another key, a late analysis) rebuilt the form empty and
			// « Add » then refused the combination for want of a modifier.
			if (!state.shortcutForm || state.shortcutForm.key !== code)
				state.shortcutForm = {
					key: code,
					modifiers: draft ? draft.modifiers.slice() : [],
					send_key: draft ? draft.send_key : code,
					send_modifiers: draft ? draft.send_modifiers.slice() : []
				};
			const form = state.shortcutForm;
			const modifierChecks = (prefix, field) =>
				modifierOptions().map((id) =>
					el('label', { class: 'le-check', title: id }, [
						el('input', {
							type: 'checkbox',
							value: id,
							'data-group': prefix,
							checked: form[field].includes(id),
							onchange: (event) => {
								const others = form[field].filter((chosen) => chosen !== id);
								form[field] = event.target.checked ? others.concat(id) : others;
							}
						}),
						modifierLabel(id)
					])
				);
			const from = modifierChecks('from', 'modifiers');
			const to = modifierChecks('to', 'send_modifiers');
			const sendKey = select(
				data.keys.filter((k) => k.kind === 'key').map((k) => [k.code, keyName(k.code)]),
				form.send_key,
				(value) => {
					form.send_key = value;
				},
				{ id: 'le-shortcut-send' }
			);
			const group = state.shortcutView
				? (id, children) =>
						el(
							'div',
							{ class: 'le-group', id: `le-group-${id}` },
							[el('h3', { text: tl(`inspector.${id}`) })].concat(children)
						)
				: inspectorGroup;
			// The simple case first, in one action: every other combination acts as one key.
			const actsAs = shortcutKeyOf(code);
			const actAsSelect = select(
				[['', tl('shortcut.same')]].concat(
					data.keys
						.filter((k) => k.kind === 'key' && k.code !== code)
						.map((k) => [k.code, capLabel(k.code)])
				),
				actsAs || '',
				(value) =>
					apply((d) => LayoutEditorModel.setShortcutKey(d, code, value === '' ? null : value)),
				{ id: 'le-shortcut-key' }
			);
			const picking = state.pickingShortcutKey === code;
			return group('shortcuts', [
				el('div', { class: 'le-act-as', id: 'le-act-as' }, [
					el('label', { class: 'le-field' }, [tl('shortcut.act_as'), actAsSelect]),
					el('button', {
						type: 'button',
						id: 'le-shortcut-key-pick',
						class: picking ? 'primary' : null,
						'aria-pressed': String(picking),
						text: tl(picking ? 'shortcut.picking' : 'shortcut.pick'),
						onclick: () => {
							state.pickingShortcutKey = picking ? null : code;
							render();
						}
					}),
					el('p', { class: 'le-note', text: tl('shortcut.act_as_note') })
				]),
				el('h4', { class: 'le-advanced', text: tl('shortcut.advanced') }),
				shortcuts.length
					? null
					: el('p', { class: 'le-note', id: 'le-shortcut-none', text: tl('shortcut.none') }),
				el(
					'ul',
					{ class: 'le-list le-shortcut-list', id: 'le-shortcuts' },
					shortcuts.map((s) =>
						el('li', { 'data-chord': s.modifiers.slice().sort().join('+') }, [
							el('span', {
								text: `${chordLabel(s.modifiers, s.key)} → ${chordLabel(s.send_modifiers, s.send_key)} `
							}),
							el('button', {
								type: 'button',
								class: 'le-shortcut-edit',
								text: tl('btn.edit'),
								onclick: () => {
									state.shortcutDraft = JSON.parse(JSON.stringify(s));
									state.shortcutForm = null;
									render();
								}
							}),
							el('button', {
								type: 'button',
								class: 'danger le-shortcut-remove',
								text: tl('btn.remove'),
								onclick: () => apply((d) => LayoutEditorModel.removeShortcut(d, s.key, s.modifiers))
							})
						])
					)
				),
				el('p', { class: 'le-note', text: tl('shortcut.when') }),
				el('div', { class: 'le-checks', id: 'le-shortcut-from' }, from),
				el('p', { class: 'le-note', text: tl('shortcut.sends') }),
				sendKey,
				el('div', { class: 'le-checks', id: 'le-shortcut-to' }, to),
				el('button', {
					type: 'button',
					id: 'le-shortcut-add',
					class: 'primary',
					text: tl(draft ? 'btn.apply' : 'btn.add'),
					onclick: () => {
						const modifiers = form.modifiers.slice();
						if (!modifiers.length) return notify('error', tl('shortcut.need_modifier'));
						// An edited override whose combination changed replaces the old one.
						const replaced =
							draft &&
							draft.modifiers.slice().sort().join('+') !== modifiers.slice().sort().join('+')
								? draft
								: null;
						const chord = { send_key: form.send_key, send_modifiers: form.send_modifiers.slice() };
						state.shortcutDraft = null;
						state.shortcutForm = null;
						apply((d) => {
							const base = replaced
								? LayoutEditorModel.removeShortcut(d, code, replaced.modifiers)
								: d;
							return LayoutEditorModel.setShortcut(base, {
								key: code,
								modifiers,
								send_key: chord.send_key,
								send_modifiers: chord.send_modifiers
							});
						});
					}
				}),
				draft
					? el('button', {
							type: 'button',
							id: 'le-shortcut-cancel',
							text: tl('btn.cancel'),
							onclick: () => {
								state.shortcutDraft = null;
								state.shortcutForm = null;
								render();
							}
						})
					: null
			]);
		}

		function tapHoldEditor(code) {
			const entry = (doc().tap_holds || []).find((e) => e.key === code);
			const holdOptions = LayoutEditorModel.layers(doc())
				.map((l) => [`layer:${l.id}`, tl('tap_hold.layer', { id: l.id })])
				.concat(
					modifierOptions().map((m) => [`modifier:${m}`, tl('tap_hold.modifier', { id: m })])
				);
			const hold = select(
				holdOptions,
				entry
					? entry.hold_layer
						? `layer:${entry.hold_layer}`
						: `modifier:${entry.hold_modifier}`
					: null,
				() => {},
				{ id: 'le-hold' }
			);
			const tapText = el('input', {
				type: 'text',
				id: 'le-tap-text',
				value: entry && entry.tap.text !== undefined ? entry.tap.text : ''
			});
			const thresholdBounds = declared('LAYOUT_SOURCE_TAP_HOLDS_THRESHOLD_MS');
			const threshold = el('input', {
				type: 'number',
				id: 'le-threshold',
				min: thresholdBounds.min,
				max: thresholdBounds.max,
				step: TAP_HOLD_THRESHOLD_STEP,
				value: entry ? entry.threshold_ms : ''
			});
			return inspectorGroup('tap_hold', [
				el('label', { class: 'le-field' }, [tl('tap_hold.tap_text'), tapText]),
				el('label', { class: 'le-field' }, [tl('tap_hold.hold'), hold]),
				el('label', { class: 'le-field' }, [tl('tap_hold.threshold'), threshold]),
				el('button', {
					type: 'button',
					id: 'le-tap-hold-apply',
					text: tl('btn.apply'),
					onclick: () => {
						const [kind, id] = hold.value.split(':');
						const thresholdMs = checkedNumber(
							threshold,
							window.ErgoptiValueCheck.KEY.LAYOUT_SOURCE_TAP_HOLDS_THRESHOLD_MS,
							notify
						);
						if (thresholdMs === undefined) return;
						const next = {
							key: code,
							tap: tapText.value === '' ? { key: code } : { text: tapText.value },
							threshold_ms: thresholdMs
						};
						next[kind === 'layer' ? 'hold_layer' : 'hold_modifier'] = id;
						apply((d) => LayoutEditorModel.setTapHold(d, next));
					}
				}),
				entry
					? el('button', {
							type: 'button',
							class: 'danger',
							id: 'le-tap-hold-remove',
							text: tl('btn.remove'),
							onclick: () => apply((d) => LayoutEditorModel.removeTapHold(d, code))
						})
					: null
			]);
		}

		/**
		 * A folded group of the key inspector; it stays open across renders once
		 * opened, so editing a key does not fold it again.
		 */
		function inspectorGroup(id, children) {
			return el(
				'details',
				{
					class: 'le-group',
					id: `le-group-${id}`,
					open: state.openGroups.has(id),
					ontoggle: (event) => {
						if (event.target.open) state.openGroups.add(id);
						else state.openGroups.delete(id);
					}
				},
				[el('summary', { text: tl(`inspector.${id}`) })].concat(children)
			);
		}

		function inspector() {
			const code = state.selected;
			if (!code)
				return el(
					'section',
					{ class: 'le-inspector' },
					el('p', { class: 'le-note', text: tl('inspector.pick') })
				);
			if (LayoutSourceIO.isPreserved(doc()))
				return el(
					'section',
					{ class: 'le-inspector' },
					el('p', { class: 'le-note', text: tl('preserved_note') })
				);
			return el('section', { class: 'le-inspector', id: 'le-inspector' }, [
				el('h2', { text: keyName(code) }),
				state.shortcutView ? shortcutEditor(code) : null,
				state.layer && !state.shortcutView ? mappingEditor(code) : null,
				keyProperties(code),
				remapEditor(code),
				state.shortcutView ? null : shortcutEditor(code),
				tapHoldEditor(code)
			]);
		}

		// ==================================
		// ======= 10/ Modifiers, dead keys ==
		// ==================================

		// The one load of the fill sources: the opening start and the panels share it,
		// so the host is asked once (a second request while one is pending is refused).
		let fillLoad = null;

		/**
		 * Lists the fill sources once: the built-in references, then the host's registry layouts.
		 * @returns {Promise<void>} Settled once state.fillSources is set.
		 */
		function loadFillSources() {
			if (fillLoad) return fillLoad;
			const loaded = host.loadSources
				? Promise.resolve().then(() => host.loadSources())
				: Promise.resolve([]);
			fillLoad = loaded.then(
				(supplied) => {
					state.fillSources = LayoutSourceIO.fillSources(supplied);
					render();
				},
				(error) => {
					// The references still work; the panel says the registry list failed.
					state.fillSources = LayoutSourceIO.fillSources([]);
					// Kept as the error: its text is made at render, in the locale loaded by then.
					state.fillUnavailable = error;
					render();
				}
			);
			return fillLoad;
		}

		/** « Start from »: a blank layout, or a copy of a built-in or registry layout. */
		function startPanel() {
			if (!state.starting) return null;
			const begin = (make) => {
				const run = () => {
					let started;
					try {
						started = make();
					} catch (error) {
						notify('error', problemText(error));
						return;
					}
					state.starting = false;
					replace(started.doc, started.lost.length ? started.lost : null);
					render();
				};
				if (state.dirty) ask(tl('discard_confirm'), run);
				else run();
			};
			const choices = [
				el('button', {
					type: 'button',
					'data-start': 'file',
					text: tl('start.file'),
					onclick: () => {
						state.starting = false;
						render();
						if (host.pickFile) pickWithHost();
						else root.querySelector('#le-open-file').click();
					}
				}),
				el('button', {
					type: 'button',
					'data-start': 'blank',
					text: tl('start.blank'),
					onclick: () =>
						begin(() => ({
							doc: LayoutSourceIO.create('my_layout', tl('default_name')),
							lost: []
						}))
				})
			];
			for (const entry of state.fillSources || [])
				choices.push(
					el('button', {
						type: 'button',
						'data-start': entry.id,
						text: entry.name,
						onclick: () =>
							begin(() =>
								LayoutSourceIO.startFrom(
									entry,
									`${LayoutSourceIO.identifierFrom(entry.id, 'layout')}_custom`,
									tl('start.copy_name', { name: entry.name })
								)
							)
					})
				);
			return el('section', { class: 'le-panel le-start', id: 'le-start' }, [
				el('h2', { text: tl('start.title') }),
				el('p', { class: 'le-note', text: tl('start.note') }),
				state.fillSources === null
					? el('p', { class: 'le-note', text: tl('start.loading') })
					: null,
				state.fillUnavailable
					? el('p', { class: 'le-message error', text: problemText(state.fillUnavailable) })
					: null,
				el('div', { class: 'le-buttons' }, choices),
				libraryStart(begin)
			]);
		}

		/**
		 * Every layout of the library, by display name (maintainer, 2026-11-15):
		 * the analysis data's one list (LAYOUT_ANALYSIS.libraryLayouts), with a
		 * search field. A layout the host also lists as a fill source starts
		 * through its exact importer, any other from its library entry
		 * (LAYOUT_FORMATS.toSource: its base, Shift, AltGr levels and dead keys).
		 * @param {function(function(): {doc: object, lost: string[]}): void} begin
		 * @returns {HTMLElement}
		 */
		function libraryStart(begin) {
			const layouts = LAYOUT_ANALYSIS.libraryLayouts().sort((a, b) =>
				a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })
			);
			const list = el('select', { id: 'le-start-layout', size: '8' });
			const go = el('button', {
				type: 'button',
				id: 'le-start-library-go',
				text: tl('start.from_library'),
				onclick: () => {
					const layout = layouts.find((entry) => entry.id === list.value);
					if (!layout) return;
					const id = `${LayoutSourceIO.identifierFrom(layout.id, 'layout')}_custom`;
					const name = tl('start.copy_name', { name: layout.name });
					const source = (state.fillSources || []).find((entry) => entry.id === layout.id);
					begin(() =>
						source
							? LayoutSourceIO.startFrom(source, id, name)
							: LayoutSourceIO.startFromDocument(LAYOUT_FORMATS.toSource(layout), id, name)
					);
				}
			});
			const fill = (query) => {
				const wanted = query.trim().toLocaleLowerCase();
				const shown = layouts.filter(
					(layout) => !wanted || layout.name.toLocaleLowerCase().includes(wanted)
				);
				list.replaceChildren(
					...shown.map((layout) => el('option', { value: layout.id }, layout.name))
				);
				if (shown.length) list.value = shown[0].id;
				go.disabled = shown.length === 0;
			};
			list.addEventListener('dblclick', () => go.click());
			const search = el('input', {
				type: 'search',
				id: 'le-start-search',
				placeholder: tl('start.search'),
				'aria-label': tl('start.search'),
				oninput: (event) => fill(event.target.value)
			});
			fill('');
			return el('div', { class: 'le-start-library' }, [
				el('h3', { text: tl('start.library') }),
				search,
				list,
				go
			]);
		}

		/** The composer's job: fill the current layer from one level of another layout. */
		function fillPanel() {
			const parts = [
				el('h2', { text: tl('fill.title') }),
				el('p', { class: 'le-note', text: tl('fill.note') })
			];
			if (state.fillSources === null) {
				parts.push(
					el('button', {
						type: 'button',
						id: 'le-fill-load',
						text: tl('fill.load'),
						onclick: loadFillSources
					})
				);
				return el('section', { class: 'le-panel', id: 'le-fill' }, parts);
			}
			const source = select(
				state.fillSources.map((entry) => [entry.id, entry.name]),
				null,
				() => {},
				{ id: 'le-fill-source' }
			);
			const level = select(
				FILL_LEVELS.map((id) => [id, tl(`fill.level.${id}`)]),
				FILL_LEVELS[0],
				() => {},
				{ id: 'le-fill-level' }
			);
			if (state.fillUnavailable)
				parts.push(
					el('p', { class: 'le-message error', text: problemText(state.fillUnavailable) })
				);
			parts.push(
				el('label', { class: 'le-field' }, [tl('fill.source'), source]),
				el('label', { class: 'le-field' }, [tl('fill.level'), level]),
				el('button', {
					type: 'button',
					id: 'le-fill-apply',
					text: tl('fill.apply', { layer: state.layer }),
					disabled: !state.layer,
					onclick: () => {
						const chosen = state.fillSources.find((entry) => entry.id === source.value);
						const layerId = state.layer;
						ask(tl('fill.confirm', { layer: layerId }), () =>
							apply((d) => LayoutSourceIO.fillLayer(d, chosen, level.value, layerId))
						);
					}
				})
			);
			return el('section', { class: 'le-panel', id: 'le-fill' }, parts);
		}

		/** Windows-only records: the .klc metadata, layout flags and NLS special functions. */
		function windowsPanel() {
			const windows = doc().windows || {};
			const flags = el('input', {
				type: 'text',
				id: 'le-win-flags',
				value: (windows.flags || []).join(', '),
				placeholder: 'kllf_altgr'
			});
			const key = select(
				data.keys.filter((k) => k.kind === 'key').map((k) => [k.code, keyName(k.code)]),
				null,
				() => {},
				{ id: 'le-nls-key' }
			);
			const modifiers = modifierOptions().map((id) =>
				el('label', { class: 'le-check' }, [el('input', { type: 'checkbox', value: id }), id])
			);
			const fn = el('input', { type: 'text', id: 'le-nls-function', placeholder: 'kana_toggle' });
			const parameter = select(
				[['', tl('windows.no_parameter')]].concat(
					data.keys.filter((k) => k.kind === 'key').map((k) => [k.code, keyName(k.code)])
				),
				'',
				() => {},
				{ id: 'le-nls-parameter' }
			);
			// The .klc metadata (exports.windows): all three, or none.
			const klc = (doc().exports || {}).windows || {};
			const klcFields = [
				['locale', 'fr-FR'],
				['layout_id', '0000040c'],
				['dll_name', 'kbdmine']
			].map(([field, placeholder]) => [
				field,
				el('input', {
					type: 'text',
					id: `le-win-${field.replace('_', '-')}`,
					value: klc[field] || '',
					placeholder
				})
			]);
			return el('section', { class: 'le-panel', id: 'le-windows' }, [
				el('h2', { text: tl('windows.title') }),
				el('p', { class: 'le-note', text: tl('windows.klc_note') }),
				...klcFields.map(([field, input]) =>
					el('label', { class: 'le-field' }, [tl(`windows.${field}`), input])
				),
				el('button', {
					type: 'button',
					id: 'le-win-klc-apply',
					text: tl('btn.apply'),
					onclick: () => {
						const values = Object.fromEntries(
							klcFields.map(([field, input]) => [field, input.value.trim()])
						);
						const empty = Object.values(values).every((value) => value === '');
						apply((d) => LayoutEditorModel.setExport(d, 'windows', empty ? null : values));
					}
				}),
				el('p', { class: 'le-note', text: tl('windows.note') }),
				el('label', { class: 'le-field' }, [tl('windows.flags'), flags]),
				el('button', {
					type: 'button',
					id: 'le-win-flags-apply',
					text: tl('btn.apply'),
					onclick: () =>
						apply((d) =>
							LayoutEditorModel.setWindowsFlags(d, flags.value.split(/[\s,]+/).filter(Boolean))
						)
				}),
				el(
					'ul',
					{ class: 'le-list', id: 'le-nls-list' },
					(windows.nls || []).map((entry) =>
						el('li', {}, [
							`${entry.modifiers.concat([keyName(entry.key)]).join('+')} → ${entry.function} `,
							el('button', {
								type: 'button',
								class: 'danger',
								text: tl('btn.remove'),
								onclick: () =>
									apply((d) => LayoutEditorModel.removeNls(d, entry.key, entry.modifiers))
							})
						])
					)
				),
				key,
				el('div', { class: 'le-checks' }, modifiers),
				el('label', { class: 'le-field' }, [tl('windows.nls_function'), fn]),
				el('label', { class: 'le-field' }, [tl('windows.nls_parameter'), parameter]),
				el('button', {
					type: 'button',
					id: 'le-nls-add',
					text: tl('btn.add'),
					onclick: () => {
						const entry = {
							key: key.value,
							modifiers: modifiers
								.map((c) => c.firstChild)
								.filter((c) => c.checked)
								.map((c) => c.value),
							function: fn.value.trim()
						};
						if (parameter.value) entry.parameter_key = parameter.value;
						apply((d) => LayoutEditorModel.setNls(d, entry));
					}
				})
			]);
		}

		function modifiersPanel() {
			const id = el('input', {
				type: 'text',
				id: 'le-mod-id',
				placeholder: tl('modifier.id_placeholder')
			});
			const mode = select(
				[
					['held', tl('modifier.held')],
					['locked', tl('modifier.locked')]
				],
				'held',
				() => {},
				{ id: 'le-mod-mode' }
			);
			const keys = el('input', { type: 'text', id: 'le-mod-keys', placeholder: 'ScrollLock' });
			return el('section', { class: 'le-panel', id: 'le-modifiers' }, [
				el('h2', { text: tl('modifier.title') }),
				el('p', { class: 'le-note', text: tl('modifier.note') }),
				el(
					'ul',
					{ class: 'le-list' },
					(doc().modifiers || []).map((m) =>
						el('li', {}, [
							`${m.id} (${tl(`modifier.${m.mode}`)}): ${m.keys.map(keyName).join(', ')} `,
							el('button', {
								type: 'button',
								class: 'danger',
								text: tl('btn.remove'),
								onclick: () => apply((d) => LayoutEditorModel.removeModifier(d, m.id))
							})
						])
					)
				),
				id,
				mode,
				keys,
				el('button', {
					type: 'button',
					id: 'le-mod-add',
					text: tl('btn.add'),
					onclick: () =>
						apply((d) =>
							LayoutEditorModel.setModifier(
								d,
								id.value.trim(),
								mode.value,
								keys.value.split(/[\s,]+/).filter(Boolean)
							)
						)
				})
			]);
		}

		function deadKeysPanel() {
			const deadKeys = doc().dead_keys || [];
			const current = deadKeys.find((d) => d.id === state.deadKey) || null;
			const id = el('input', {
				type: 'text',
				id: 'le-dead-id',
				placeholder: tl('dead.id_placeholder')
			});
			const terminator = el('input', {
				type: 'text',
				id: 'le-dead-terminator',
				placeholder: '^',
				size: 4
			});
			const parts = [
				el('h2', { text: tl('dead.title') }),
				el('p', { class: 'le-note', text: tl('dead.note') }),
				el(
					'div',
					{ class: 'le-tabs' },
					deadKeys.map((d) =>
						el('button', {
							type: 'button',
							class: `le-tab${current && current.id === d.id ? ' active' : ''}`,
							'data-dead': d.id,
							text: `${d.name || d.id} ${visible(d.terminator)}`,
							onclick: () => {
								state.deadKey = d.id;
								render();
							}
						})
					)
				),
				id,
				terminator,
				el('button', {
					type: 'button',
					id: 'le-dead-add',
					text: tl('btn.add'),
					onclick: () => {
						const newId = id.value.trim();
						apply((d) => LayoutEditorModel.setDeadKey(d, newId, '', terminator.value));
						if ((doc().dead_keys || []).some((d) => d.id === newId)) {
							state.deadKey = newId;
							render();
						}
					}
				})
			];
			if (current) {
				const input = el('input', { type: 'text', id: 'le-rule-input', size: 4 });
				const output = el('input', { type: 'text', id: 'le-rule-output', size: 6 });
				const chain = select(
					[['', tl('dead.no_chain')]].concat(deadKeys.map((d) => [d.id, d.name || d.id])),
					'',
					() => {},
					{ id: 'le-rule-next' }
				);
				parts.push(
					el(
						'table',
						{ class: 'le-rules', id: 'le-rules' },
						current.rules.map((rule) =>
							el('tr', {}, [
								el('td', { text: visible(rule.input) }),
								el('td', { text: rule.next ? `→ ${rule.next}` : visible(rule.text) }),
								el(
									'td',
									{},
									el('button', {
										type: 'button',
										class: 'danger',
										text: tl('btn.remove'),
										onclick: () =>
											apply((d) => LayoutEditorModel.setDeadRule(d, current.id, rule.input, null))
									})
								)
							])
						)
					),
					input,
					output,
					chain,
					el('button', {
						type: 'button',
						id: 'le-rule-add',
						text: tl('dead.add_rule'),
						onclick: () =>
							apply((d) =>
								LayoutEditorModel.setDeadRule(
									d,
									current.id,
									input.value,
									chain.value ? { next: chain.value } : { text: output.value }
								)
							)
					}),
					el('button', {
						type: 'button',
						class: 'danger',
						id: 'le-dead-remove',
						text: tl('dead.remove', { id: current.id }),
						onclick: () => {
							apply((d) => LayoutEditorModel.removeDeadKey(d, current.id));
							if (!(doc().dead_keys || []).some((d) => d.id === current.id)) {
								state.deadKey = null;
								render();
							}
						}
					})
				);
			}
			return el('section', { class: 'le-panel', id: 'le-dead-keys' }, parts);
		}

		// ============================
		// ======= 11/ Preview ========
		// ============================

		function heldModifiers(event) {
			const held = [...state.heldSides];
			// A modifier held before the field had focus has no known side.
			for (const [flag, id] of [
				['shiftKey', 'shift'],
				['altKey', 'alt'],
				['ctrlKey', 'control'],
				['metaKey', 'meta']
			])
				if (event[flag] && !held.some((h) => h.startsWith(id + '_'))) held.push(id);
			for (const id of state.heldCustom) held.push(id);
			for (const id of state.locked) held.push(id);
			return kanaHeld(held);
		}

		/**
		 * The Kana level is typed with Alt in the preview, as the targets compile it
		 * to the Option/AltGr level, when no layer of the source selects Alt itself.
		 */
		function kanaHeld(held) {
			const selects = (ids) =>
				(doc().layers || []).some((layer) =>
					[layer, ...(layer.alternatives || [])].some((selector) =>
						[...selector.required, ...selector.optional].some((id) => ids.includes(id))
					)
				);
			const alt = ['alt', 'alt_left', 'alt_right'];
			if (!selects(['kana']) || selects(alt) || !held.some((id) => alt.includes(id))) return held;
			return held.filter((id) => !alt.includes(id)).concat('kana');
		}

		function customModifier(code) {
			return (doc().modifiers || []).find((m) => m.keys.includes(code));
		}

		/**
		 * The web emulation the preview types through, rebuilt when the source or
		 * the OS changes; null for a preserved import or a refused table (the
		 * preview then types the source's layers directly).
		 */
		function typist() {
			const platform = state.platform || host.platform || PREVIEW_PLATFORM;
			if (state.typist && state.typist.doc === doc() && state.typist.platform === platform)
				return state.typist.engine;
			let engine = null;
			if (!LayoutSourceIO.isPreserved(doc()))
				try {
					engine = LayoutEditorModel.previewTypist(doc(), platform);
				} catch (error) {
					// The report row of this OS says why its emulation is refused.
				}
			state.typist = { doc: doc(), platform, engine };
			return engine;
		}

		/** The held modifiers of a press, Caps Lock included when it is on. */
		function pressHeld(event) {
			const held = heldModifiers(event);
			if (event.getModifierState && event.getModifierState('CapsLock')) held.push('caps_lock');
			return held;
		}

		function preview() {
			const result = LayoutSourceIO.isPreserved(doc())
				? { text: '', pending: null }
				: LayoutEditorModel.simulate(doc(), state.presses, state.platform || null);
			// What the layout types, shown inside the bar; the placeholder while empty.
			const output = el('output', {
				class: 'le-preview-output',
				id: 'le-preview-output',
				'data-placeholder': tl('preview.placeholder'),
				'aria-live': 'polite',
				text: result.text
			});
			const typed = (entries) => {
				if (!entries.length) return;
				state.presses.push(...entries);
				renderPreviewOnly();
			};
			const pad = el('input', {
				type: 'text',
				id: 'le-preview-input',
				class: 'le-try-keys',
				'aria-label': tl('preview.placeholder'),
				autocomplete: 'off',
				onkeydown: (event) => {
					event.preventDefault();
					const engine = typist();
					if (engine && engine.owns(event.code)) {
						typed(engine.down(event.code, pressHeld(event), event.timeStamp));
						const threshold = engine.pendingThreshold();
						// The hold starts at its threshold even when no other key comes.
						if (threshold !== null)
							setTimeout(() => typed(engine.tick(performance.now())), threshold);
						return;
					}
					const modifier = engine ? null : customModifier(event.code);
					if (modifier) {
						if (modifier.mode === 'locked') {
							if (state.locked.has(modifier.id)) state.locked.delete(modifier.id);
							else state.locked.add(modifier.id);
						} else state.heldCustom.add(modifier.id);
						return;
					}
					if (Object.prototype.hasOwnProperty.call(SIDED_MODIFIERS, event.code)) {
						state.heldSides.add(SIDED_MODIFIERS[event.code]);
						return;
					}
					if (engine) typed(engine.down(event.code, pressHeld(event), event.timeStamp));
					else typed([{ code: event.code, held: heldModifiers(event) }]);
				},
				onkeyup: (event) => {
					state.heldSides.delete(SIDED_MODIFIERS[event.code]);
					const engine = typist();
					if (engine) {
						typed(engine.up(event.code, event.timeStamp));
						return;
					}
					const modifier = customModifier(event.code);
					if (modifier && modifier.mode === 'held') state.heldCustom.delete(modifier.id);
				}
			});
			// « Essayer »: one input bar (maintainer, 2026-11-15), the same on the site and
			// in the app windows. The transparent field over it takes the key presses
			// (each one is simulated, never typed); the result shows in the bar, and the
			// clear button sits inside it, at the end.
			const bar = el('div', { class: 'le-try', id: 'le-try' }, [
				output,
				pad,
				el('button', {
					type: 'button',
					class: 'le-try-clear',
					id: 'le-preview-clear',
					text: '×',
					title: tl('btn.clear'),
					'aria-label': tl('btn.clear'),
					onclick: () => {
						state.presses = [];
						state.typist = null;
						render();
						const field = root.querySelector('#le-preview-input');
						if (field) field.focus();
					}
				})
			]);
			return el('section', { class: 'le-preview' }, [
				el('h2', { text: tl('preview.title') }),
				bar,
				result.pending
					? el('p', { class: 'le-note', text: tl('preview.pending', { id: result.pending }) })
					: null
			]);
		}

		function renderPreviewOnly() {
			const output = root.querySelector('#le-preview-output');
			const result = LayoutEditorModel.simulate(doc(), state.presses, state.platform || null);
			if (output) output.textContent = result.text;
		}

		// ============================
		// ======= 12/ Export =========
		// ============================

		/** A report reason: its own text, else the refusal it names. */
		function reasonText(code) {
			const strings = window._i18n_strings || {};
			return typeof strings[`${PREFIX}reason.${code}`] === 'string'
				? tl(`reason.${code}`)
				: problemText({ code });
		}

		/** Installs the source through the ErgoptiPlus composer host and switches to it. */
		function installButton(report) {
			const row = report.find((entry) => entry.target === `driver_${host.platform}`);
			return el('button', {
				type: 'button',
				id: 'le-install',
				class: 'primary',
				text: tl('btn.install'),
				disabled: !row || row.status === 'unavailable',
				onclick: () =>
					ask(tl('install_confirm'), () => {
						let payload;
						try {
							payload = LayoutSourceIO.installPayload(doc(), host.platform);
						} catch (error) {
							notify('error', problemText(error));
							return;
						}
						fromHost(() => host.install(payload)).then(
							(result) =>
								notify(
									'ok',
									tl(result && result.pending ? 'status.installed_pending' : 'status.installed')
								),
							(error) => notify('error', problemText(error))
						);
					})
			});
		}

		/** « Emulate without installing »: the driver's emulation types the source over the system layout. */
		function emulateButton(report) {
			const row = report.find((entry) => entry.target === `driver_${host.platform}`);
			return el('button', {
				type: 'button',
				id: 'le-emulate',
				text: tl('btn.emulate'),
				disabled: !row || row.status === 'unavailable',
				onclick: () =>
					ask(tl('emulate_confirm'), () => {
						let payload;
						try {
							payload = LayoutSourceIO.installPayload(doc(), host.platform);
						} catch (error) {
							notify('error', problemText(error));
							return;
						}
						fromHost(() => host.emulate(payload)).then(
							() => notify('ok', tl('status.emulated')),
							(error) => notify('error', problemText(error))
						);
					})
			});
		}

		/**
		 * The targets that cannot hold the shortcut overrides, named in one line: the
		 * format owner reports them as omitted (shortcut_output_not_in_*), and only
		 * ErgoptiPlus's emulation performs them.
		 */
		function shortcutExportNote(report) {
			const actsAs = Object.values(doc().keys || {}).filter((entry) => entry.shortcut_key);
			const count = (doc().shortcuts || []).length + actsAs.length;
			if (!count) return null;
			const shortcutPath = /^shortcuts\.|^keys\.[^.]+\.shortcut_key$/;
			const without = report
				.filter((row) => (row.omitted || []).some((entry) => shortcutPath.test(entry.path)))
				.map((row) => tl(`target.${row.target}`));
			return el('p', {
				class: 'le-message ok le-export-shortcuts',
				id: 'le-export-shortcuts',
				text: without.length
					? tl('shortcut.export_partial', { count, targets: without.join(', ') })
					: tl('shortcut.export_all', { count })
			});
		}

		function exportPanel() {
			let report = [];
			try {
				report = LayoutSourceIO.capabilities(doc());
			} catch (error) {
				return el(
					'section',
					{ class: 'le-export' },
					el('p', { class: 'le-message error', text: problemText(error) })
				);
			}
			const rows = report.map((row) => {
				const omitted = row.omitted || [];
				return el('tr', { 'data-target': row.target }, [
					el('td', { text: tl(`target.${row.target}`) }),
					el('td', { class: `le-status ${row.status}`, text: tl(`status_kind.${row.status}`) }),
					el('td', {}, [
						row.reason ? reasonText(row.reason) : '',
						omitted.length
							? el('details', {}, [
									el('summary', { text: tl('export.omitted', { count: omitted.length }) }),
									el(
										'ul',
										{},
										omitted.map((entry) => el('li', { text: `${entry.path}: ${entry.reason}` }))
									)
								])
							: null
					])
				]);
			});
			const buttons = [
				el('button', {
					type: 'button',
					id: 'le-export-toml',
					text: tl('export.toml'),
					onclick: saveSource
				})
			];
			const preserved = LayoutSourceIO.isPreserved(doc());
			const macFormat = preserved
				? doc().imported_keylayout.convention
				: ((doc().exports || {}).macos || {}).format || 'bundle';
			let macos = null;
			try {
				macos = LayoutSourceIO.macosDownload(doc(), macFormat);
			} catch (error) {
				// Not producible here; the macOS report row says why.
			}
			// A ZIP needs a host that saves bytes; the webview hosts install the layout instead.
			if (macos && (macos.text !== undefined || host.saveBinary))
				buttons.push(
					el('button', {
						type: 'button',
						id: 'le-export-macos',
						'data-format': macFormat,
						text: tl(macFormat === 'bundle' ? 'export.bundle' : `export.keylayout_${macFormat}`),
						onclick: () => {
							if (macos.text !== undefined) return save(macos.filename, macos.text, macos.mime);
							fromHost(() => host.saveBinary(macos.filename, macos.bytes, macos.mime)).then(
								() => notify('ok', tl('status.saved', { name: macos.filename })),
								(error) => notify('error', problemText(error))
							);
						}
					})
				);
			if (host.exportAssets && host.saveBinary)
				for (const [target, build, mime] of [
					['xkb', LayoutSourceIO.xkbArchive, 'application/zip'],
					['klc', LayoutSourceIO.klcFile, 'application/octet-stream']
				])
					buttons.push(
						el('button', {
							type: 'button',
							id: `le-export-${target}`,
							text: tl(`export.${target}`),
							onclick: () => {
								// The host loads the converters on the first click; the build runs on the current source.
								const source = doc();
								fromHost(() => host.exportAssets())
									// The build may wait for the host's converters (lua_export).
									.then((assets) => build(source, assets))
									.then((file) =>
										fromHost(() => host.saveBinary(file.filename, file.bytes, mime)).then(
											() => file.filename
										)
									)
									.then(
										(name) => notify('ok', tl('status.saved', { name })),
										(error) => notify('error', problemText(error))
									);
							}
						})
					);
			// The four Windows DLL images, written in the page (no compiler).
			if (host.saveBinary && !LayoutSourceIO.isPreserved(doc()))
				buttons.push(
					el('button', {
						type: 'button',
						id: 'le-export-dll',
						text: tl('export.dll'),
						onclick: () => {
							let file;
							try {
								file = LayoutSourceIO.windowsDllArchive(doc());
							} catch (error) {
								notify('error', problemText(error));
								return;
							}
							fromHost(() => host.saveBinary(file.filename, file.bytes, 'application/zip')).then(
								() => notify('ok', tl('status.saved', { name: file.filename })),
								(error) => notify('error', problemText(error))
							);
						}
					})
				);
			// The two ways ErgoptiPlus uses a layout, each said in one line.
			if (host.install) buttons.push(installButton(report));
			if (host.emulate) buttons.push(emulateButton(report));
			// The driver applies the navigation layer through its navigation layer editor's save.
			if (host.applyNav && (doc().layers || []).some((l) => l.id === LayoutSourceIO.NAV_LAYER))
				buttons.push(
					el('button', {
						type: 'button',
						id: 'le-apply-nav',
						text: tl('btn.apply_nav'),
						onclick: () => {
							let text;
							try {
								text = LayoutSourceIO.navLayerFile(doc(), data);
							} catch (error) {
								notify('error', problemText(error));
								return;
							}
							fromHost(() => host.applyNav(text)).then(
								(result) =>
									notify(
										result && result.applied ? 'ok' : 'error',
										tl(result && result.applied ? 'status.nav_applied' : 'status.nav_not_applied')
									),
								(error) => notify('error', problemText(error))
							);
						}
					})
				);
			if ((doc().layers || []).some((l) => l.id === LayoutSourceIO.NAV_LAYER))
				buttons.push(
					el('button', {
						type: 'button',
						id: 'le-export-nav',
						text: tl('export.nav'),
						onclick: () => {
							try {
								save('layers.toml', LayoutSourceIO.navLayerFile(doc(), data), 'application/toml');
							} catch (error) {
								notify('error', problemText(error));
							}
						}
					})
				);
			return el('section', { class: 'le-export', id: 'le-export' }, [
				el('h2', { text: tl('export.title') }),
				preserved
					? null
					: el('label', { class: 'le-inline' }, [
							tl('export.macos_format'),
							select(
								['bundle', 'iso', 'ansi'].map((f) => [f, tl(`export.macos.${f}`)]),
								macFormat,
								(value) =>
									apply((d) =>
										LayoutEditorModel.setExport(
											d,
											'macos',
											Object.assign({}, (d.exports || {}).macos, { format: value })
										)
									),
								{ id: 'le-macos-format' }
							)
						]),
				el('table', { class: 'le-report', id: 'le-report' }, rows),
				shortcutExportNote(report),
				el('p', { class: 'le-note', text: tl('export.bundle_note') }),
				el('p', { class: 'le-note', id: 'le-dll-note', text: tl('export.windows_dll_note') }),
				host.exportAssets ? null : el('p', { class: 'le-note', text: tl('export.targets_note') }),
				el('div', { class: 'le-buttons' }, buttons),
				host.install
					? el('p', { class: 'le-note', id: 'le-install-hint', text: tl('install_hint') })
					: null,
				host.emulate
					? el('p', { class: 'le-note', id: 'le-emulate-hint', text: tl('emulate_hint') })
					: null
			]);
		}

		// ============================
		// ======= 13/ Stickers =======
		// ============================

		/** The layers each sticker prints, in source order. */
		function stickerLevels() {
			const ids = (doc().layers || []).map((layer) => layer.id);
			return state.stickerLayers === null
				? STICKER_LAYERS.filter((id) => ids.includes(id))
				: ids.filter((id) => state.stickerLayers.includes(id));
		}

		/** A legend the sticker leaves out: a Shift level that is only the capital of the base. */
		function caseDuplicate(layerId, code) {
			if (!state.stickerHideCase) return false;
			const partner = LayoutEditorModel.caseLayer(doc(), layerId);
			if (!partner || partner.upper) return false;
			const own = LayoutEditorModel.mappingAt(doc(), layerId, code, null);
			const base = LayoutEditorModel.mappingAt(doc(), partner.id, code, null);
			const text = (found) =>
				found && typeof found.mapping.text === 'string' ? found.mapping.text : null;
			return text(own) !== null && text(base) !== null && text(own) === text(base).toUpperCase();
		}

		/** Which layers the stickers print, and whether capitals are hidden. */
		function stickerOptions() {
			const chosen = stickerLevels();
			return el('div', { class: 'le-subpanel', id: 'le-sticker-levels' }, [
				el('h3', { text: tl('sticker.levels') }),
				el(
					'div',
					{ class: 'le-checks' },
					(doc().layers || []).map((layer) =>
						checkbox(`le-sticker-layer-${layer.id}`, layer.id, chosen.includes(layer.id), (on) => {
							const next = new Set(stickerLevels());
							if (on) next.add(layer.id);
							else next.delete(layer.id);
							state.stickerLayers = [...next];
							render();
						})
					)
				),
				checkbox('le-sticker-hide-case', tl('sticker.hide_case'), state.stickerHideCase, (on) => {
					state.stickerHideCase = on;
					render();
				})
			]);
		}

		/** Printable key caps: one sticker per key with its chosen character levels. */
		function stickers() {
			const levels = stickerLevels();
			const keys = data.keys.filter((k) => k.kind === 'key' && k.character);
			return el(
				'section',
				{
					class: `le-stickers${state.stickerMm === null ? '' : ' exact'}`,
					id: 'le-stickers',
					'aria-hidden': 'true',
					style: state.stickerMm === null ? null : `--le-sticker-size:${state.stickerMm}mm`
				},
				LayoutSourceIO.isPreserved(doc())
					? []
					: keys.map((key) =>
							el(
								'div',
								{ class: 'le-sticker' },
								levels.map((layerId) => {
									const found = LayoutEditorModel.mappingAt(doc(), layerId, key.code, null);
									return el('span', {
										class: `le-sticker-${layerId}`,
										text:
											found && !caseDuplicate(layerId, key.code) ? legend(found.mapping, doc()) : ''
									});
								})
							)
						)
			);
		}

		// ============================
		// ======= 14/ Render =========
		// ============================

		// A render inside a render (see below) only asks for one more pass.
		let rendering = false;
		let renderAgain = false;

		function render() {
			if (rendering) {
				renderAgain = true;
				return;
			}
			rendering = true;
			try {
				// Commit a focused field's edit before its node leaves the page, so its change
				// renders (as the pass below) before the tree is replaced, instead of being lost
				// or firing inside replaceChildren, where a nested render once made the outer
				// replacement throw.
				commitFocused();
				do {
					renderAgain = false;
					renderTree();
				} while (renderAgain);
			} finally {
				rendering = false;
			}
		}

		function renderTree() {
			keyView = makeKeyView(doc(), state.platform || host.platform || null);
			// Undo or redo can remove the layer shown: show the base layer then.
			const ids = (doc().layers || []).map((layer) => layer.id);
			if (state.layer && !ids.includes(state.layer))
				state.layer = ids.includes('base') ? 'base' : null;
			const parts = [
				tabBar(),
				toolbar(),
				startPanel(),
				messageBar(),
				layerBar(),
				el('div', { class: 'le-workspace' }, [
					el('div', { class: 'le-board-col' }, [board(), preview()]),
					el('aside', { class: 'le-inspector-col' }, [inspector(), magnifier()]),
					sideSlot
				]),
				tools(),
				stickers()
			];
			// A section a state hides is null: it must not reach the page as text.
			root.replaceChildren(...parts.filter(Boolean));
			fitLegends();
			applyHeat();
			root.dispatchEvent(new CustomEvent('layout-editor:rendered', { detail: { doc: doc() } }));
			if (analysisPanel) analysisPanel.update(doc());
			scheduleAutosave();
		}

		/**
		 * Fits every key label inside its key: the font shrinks in proportion to the
		 * overflow down to LEGEND_MIN_PX, then a label still too long is cut with an
		 * ellipsis (the key's title holds it whole). A board not laid out yet (a
		 * hidden frame) is measured at the next resize.
		 */
		function fitLegends() {
			const legends = [...root.querySelectorAll('#le-board .le-legend')];
			legends.forEach((node) => {
				node.style.fontSize = '';
				node.classList.remove('cut');
			});
			const widths = legends.map((node) => [node.clientWidth, node.scrollWidth]);
			legends.forEach((node, index) => {
				const [room, needed] = widths[index];
				if (room === 0 || needed <= room) return;
				const size = parseFloat(getComputedStyle(node).fontSize);
				node.style.fontSize = `${Math.max(LEGEND_MIN_PX, Math.floor((size * room) / needed))}px`;
			});
			legends.forEach((node) => {
				if (node.scrollWidth > node.clientWidth) node.classList.add('cut');
			});
		}

		/**
		 * Colours each key of the board from green (costs nothing) to red (costs
		 * the most of this layout) and adds what it costs to its tooltip; the
		 * shortcut view shows no colours. Runs after each render and each analysis.
		 */
		function applyHeat() {
			const heat = state.shortcutView ? null : state.heat;
			for (const node of root.querySelectorAll('#le-board .le-key[data-code]')) {
				if (node.dataset.title === undefined) node.dataset.title = node.title;
				const value = heat ? heat.values[node.dataset.code] : undefined;
				node.classList.toggle('le-heat', value !== undefined);
				if (value === undefined) {
					node.style.removeProperty('--le-heat');
					node.title = node.dataset.title;
					continue;
				}
				node.style.setProperty('--le-heat', String(heat.max > 0 ? value / heat.max : 0));
				node.title = `${node.dataset.title}\n${heat.titles[node.dataset.code]}`;
			}
		}

		// The board's key unit follows the editor's width: refit the labels when it changes.
		if (typeof ResizeObserver === 'function') {
			let lastWidth = -1;
			new ResizeObserver((entries) => {
				const width = Math.round(entries[0].contentRect.width);
				if (width === lastWidth) return;
				lastWidth = width;
				fitLegends();
			}).observe(root);
		}

		// One persistent element for a host's side panel (the analysis of the Studio):
		// re-inserted by every render, so what the host appends there survives.
		const sideSlot = el('div', { class: 'le-side-slot', id: 'le-side-slot' });
		// The live analysis (layout_analysis/analysis_panel.js), when the page loads it.
		if (analysisPanel) {
			sideSlot.append(analysisPanel.node);
			analysisPanel.onHeat((heat) => {
				state.heat = heat;
				applyHeat();
			});
		}

		/**
		 * Opens the first document: the host's initial text, else (with nothing to
		 * open) a copy of the host's start source, the app's and site's Studio
		 * starting on Ergopti (maintainer, 2026-11-15). The one place that decides
		 * the initial document, so a host's restored draft can come first.
		 */
		// The start the page opened on, renamed when the locale arrives after it.
		let openedStart = null;

		/**
		 * The first document: the host's workspace restored when it holds tabs, else
		 * the host's initial text, else a copy of its start source.
		 */
		function openInitial() {
			if (!host.workspace) {
				openStart();
				return;
			}
			fromHost(() => host.workspace.load()).then(
				(text) => {
					if (!restoreWorkspace(text)) openStart();
					render();
				},
				(error) => {
					// The tabs could not be read: the page says so, saves nothing over them,
					// and still opens the start document.
					refuseWorkspace(error);
					openStart();
					render();
				}
			);
		}

		function openStart() {
			if (typeof host.initial === 'string') {
				const parsed = LayoutSourceIO.parse(host.initial);
				if (parsed.ok) replace(parsed.doc);
				else state.message = { kind: 'error', text: problemText(parsed.error) };
			} else if (typeof host.startFrom === 'string') {
				// With nothing to open, a host may start on a copy of a start source (the
				// app's Studio: Ergopti, maintainer 2026-11-15) instead of an empty
				// keyboard, as « Start from » does, once the sources are known. Only the
				// untouched first document is replaced; without that source it stays. The
				// locale's arrival renames that document without touching it (i18n:applied).
				const opened = replacements;
				loadFillSources().then(() => {
					const entry = (state.fillSources || []).find((source) => source.id === host.startFrom);
					const touched = replacements !== opened || state.dirty || state.history.canUndo();
					if (!entry || touched) return;
					try {
						const started = LayoutSourceIO.startFrom(
							entry,
							`${LayoutSourceIO.identifierFrom(entry.id, 'layout')}_custom`,
							tl('start.copy_name', { name: entry.name })
						);
						replace(started.doc, started.lost.length ? started.lost : null);
						openedStart = { doc: doc(), name: entry.name };
					} catch (error) {
						state.message = { kind: 'error', text: problemText(error) };
					}
					render();
				});
			}
		}

		openInitial();
		render();
		if (host.workspace) {
			if (typeof host.workspace.persist === 'function')
				fromHost(() => host.workspace.persist()).then(
					(granted) => {
						state.persisted = granted === true;
						showAutosave();
					},
					() => {
						state.persisted = false;
						showAutosave();
					}
				);
			// A reload or a closed tab saves the last edits at once instead of after the delay.
			window.addEventListener('pagehide', () => {
				if (autosaveTimer !== null) flushAutosave();
			});
		}
		document.addEventListener('i18n:applied', () => {
			// The first document is made before the locale arrives: give an untouched one its translated name.
			const untouched =
				!state.dirty && !state.history.canUndo() && !LayoutSourceIO.isPreserved(doc());
			if (untouched && doc().layout.name === PREFIX + 'default_name')
				state.history.reset(LayoutEditorModel.setLayout(doc(), { name: tl('default_name') }));
			// The opening start's copy name, made before its locale arrived.
			if (openedStart && doc() === openedStart.doc && !state.dirty && !state.history.canUndo()) {
				const name = tl('start.copy_name', { name: openedStart.name });
				state.history.reset(LayoutEditorModel.setLayout(doc(), { name }));
				openedStart.doc = doc();
			}
			if (state.message && state.message.translate) state.message.text = state.message.translate();
			render();
		});
		return {
			open: (name, text) => openText(name, text),
			current: () => doc(),
			// Saves the tabs now instead of after the delay.
			flushAutosave,
			// The keyboard format shown, which the Studio passes on to its Comparer.
			format: () => state.format,
			sideSlot,
			render
		};
	}

	return { mount, t };
})();
