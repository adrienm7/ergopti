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
 * 8. Score chip: above the board, sticky under the toolbar, the panel's score,
 *    rank and the change of the last edit (onResult), announced politely; a
 *    click unfolds the analysis and brings it into view.
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
	// The boards the editor draws: the registry's ANSI and ISO, and the JIS and
	// ABNT ones of keyboard_forms.json (LayoutSource.KEYBOARDS).
	const BOARD_FORMS = ['iso', 'ansi'].concat(LayoutSource.KEYBOARDS);
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
	// « Versions » (saved snapshots) and « Help » (the tasks, in words) are ideas
	// seen in the Layouts Wiki playground; « Help » stays last.
	const TOOLS = [
		'details',
		'versions',
		'layers',
		'modifiers',
		'dead_keys',
		'fill',
		'navigation',
		'windows',
		'export',
		'stickers',
		'help'
	];
	// The tasks « Help » explains, one titled section each (layout_editor.help.<id>_title, _text).
	const HELP_TOPICS = ['start', 'keys', 'layers', 'undo', 'versions', 'analyse', 'save', 'export'];
	// The drag data type of a character from the palette or the name search.
	const CHAR_DRAG_TYPE = 'application/x-ergopti-character';
	// The export « Format » drop-down (maintainer decision, 2026-11-15): the
	// viewer's last choice, kept in this browser only, and the first one shown.
	const EXPORT_FORMAT_KEY = 'ergopti.studio.export_format';
	const DEFAULT_EXPORT_FORMAT = 'toml';
	// The macOS downloads, in drop-down order: the ISO + ANSI bundle, then one .keylayout per board.
	const MACOS_EXPORTS = ['bundle', 'iso', 'ansi'];
	// The one list of files the editor reads: « Open… » takes these, « Import… »
	// takes them and the .zip backups of « Export all » (LAYOUT_FORMATS.EXTENSIONS,
	// which the app's native panel reads too).
	const OPENED_EXTENSIONS = LAYOUT_FORMATS.EXTENSIONS.map((ext) => `.${ext}`);
	const BACKUP_EXTENSION = '.zip';
	const IMPORTED_EXTENSIONS = OPENED_EXTENSIONS.concat([BACKUP_EXTENSION]);
	/** Whether a file name ends with one of these extensions. */
	const hasExtension = (name, extensions) =>
		extensions.some((ext) => name.toLowerCase().endsWith(ext));
	// The history shortcuts (every editor's): the chords LayerModel.chordText writes in
	// the buttons' names, and the keys each OS's users press for them. Ctrl and Cmd
	// both work on every OS (a Mac keyboard on Windows, a PC keyboard on a Mac).
	const HISTORY_SHORTCUTS = {
		undo: {
			chords: [{ mods: ['primary'], key: 'KeyZ' }],
			aria: ERGOPTI_EDIT_HISTORY.SHORTCUTS.undo
		},
		redo: {
			chords: [
				{ mods: ['primary'], key: 'KeyY' },
				{ mods: ['primary', 'shift'], key: 'KeyZ' }
			],
			aria: ERGOPTI_EDIT_HISTORY.SHORTCUTS.redo
		}
	};
	// The spellings a page without a host OS names those shortcuts in: the Ctrl
	// one (Windows and Linux) and the Cmd one (macOS).
	const NEUTRAL_SHORTCUT_OSES = Object.freeze(['windows', 'macos']);

	// ============================
	// ======= 2/ Helpers =========
	// ============================

	/** Translates a locale key (info_popover.js t(): numbers as every number shown). */
	const t = (key, values) => window.LAYOUT_ANALYSIS_INFO.t(key, values);
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

	// The board's gap between keys and corner radius in key units: style.css
	// draws a key 4px short of its units and rounds it by 6px, on a unit of
	// about 50px (40 to 58px, .le-board).
	const BOARD_DRAWING = Object.freeze({ gap: 0.08, radius: 0.12 });
	const SVG_NS = 'http://www.w3.org/2000/svg';

	/**
	 * The outline of an L-shaped key (the ISO Enter): one SVG path over the
	 * whole button, which style.css fills and strokes as the key's state says.
	 * @param {{d: string, width: number, height: number}} shape - From KEY_SHAPE.lPath.
	 * @returns {SVGSVGElement}
	 */
	function keyOutline(shape) {
		const svg = document.createElementNS(SVG_NS, 'svg');
		svg.setAttribute('class', 'le-key-shape');
		svg.setAttribute('viewBox', `0 0 ${shape.width} ${shape.height}`);
		svg.setAttribute('preserveAspectRatio', 'none');
		svg.setAttribute('aria-hidden', 'true');
		svg.setAttribute('focusable', 'false');
		const path = document.createElementNS(SVG_NS, 'path');
		path.setAttribute('class', 'le-key-body');
		path.setAttribute('d', shape.d);
		svg.append(path);
		return svg;
	}

	// The tab strip's icons (style.css .le-tab-icon), stroked on a 16 px grid:
	// two stacked sheets for « Duplicate », a cross for « Close », a plus for « + ».
	const TAB_ICONS = Object.freeze({
		duplicate:
			'M6 2.5h6.5a1 1 0 0 1 1 1V10M3.5 5.5h6a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-6a1 1 0 0 1-1-1v-6a1 1 0 0 1 1-1z',
		close: 'M4.5 4.5l7 7M11.5 4.5l-7 7',
		add: 'M8 3v10M3 8h10'
	});

	/**
	 * A decorative icon of the tab strip; its button is named by its aria-label.
	 * @param {string} name - A TAB_ICONS key.
	 * @returns {SVGSVGElement}
	 */
	function tabIcon(name) {
		const svg = document.createElementNS(SVG_NS, 'svg');
		svg.setAttribute('class', 'le-tab-icon');
		svg.setAttribute('viewBox', '0 0 16 16');
		svg.setAttribute('aria-hidden', 'true');
		svg.setAttribute('focusable', 'false');
		const path = document.createElementNS(SVG_NS, 'path');
		path.setAttribute('d', TAB_ICONS[name]);
		svg.append(path);
		return svg;
	}

	/**
	 * The export format this viewer chose last (a per-viewer convenience: a
	 * private window or blocked storage just starts on the default).
	 * @returns {string} A download id of exportPanel, or DEFAULT_EXPORT_FORMAT.
	 */
	function savedExportFormat() {
		try {
			return window.localStorage.getItem(EXPORT_FORMAT_KEY) || DEFAULT_EXPORT_FORMAT;
		} catch (error) {
			return DEFAULT_EXPORT_FORMAT;
		}
	}

	/** Remembers the viewer's export format; storage that refuses keeps nothing. */
	function rememberExportFormat(id) {
		try {
			window.localStorage.setItem(EXPORT_FORMAT_KEY, id);
		} catch (error) {
			// Blocked or full storage: the choice holds for this page only.
		}
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

	/**
	 * The OSes whose spelling names a shortcut the page offers: the host's
	 * alone, else both the Ctrl and the Cmd spellings, since the website states
	 * no OS and its shortcuts answer to either modifier.
	 * @param {string|undefined} hostPlatform - The host's platform, when it has one.
	 * @returns {string[]}
	 */
	function shortcutOses(hostPlatform) {
		if (LayoutEditorModel.PLATFORMS.includes(hostPlatform)) return [hostPlatform];
		return NEUTRAL_SHORTCUT_OSES;
	}

	/**
	 * The name of a history step: a locale key of edit_history.step.* and its
	 * values, translated when the Undo and Redo buttons are drawn.
	 * @param {string} key
	 * @param {object} [values]
	 * @returns {{key: string, values?: object}}
	 */
	function step(key, values) {
		return values ? { key, values } : { key };
	}

	/** The translated refusal of an edit or a file. */
	function problemText(error) {
		const code = error && error.code ? error.code : 'unexpected';
		const message = tl(`error.${code}`, error && error.values);
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
	 *   optimize(layout) receives it, under the editor_… id the Optimiser lists
	 *   it by, from « Optimize this layout »;
	 *   workspace {load(): Promise<string|null>, save(text): Promise,
	 *   persist?(): Promise<boolean>} keeps the tabs (LayoutEditorWorkspace);
	 *   startNav {text, hold} opens the editor on its navigation layer, as
	 *   showNav does (the drivers' « Navigation layer » entries).
	 * @returns {{open: function(string, string): void, openLayout: function(object): Promise<void>,
	 *   current: function(): object,
	 *   showNav: function(object): void}}
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
			// The board key the Tab key enters the board on (the last one focused).
			boardFocus: null,
			// The keyboard format shown (analysis_model.json keyboard_formats, the
			// Comparer's too): each hides the blocks it lacks.
			format: LAYOUT_ANALYSIS.keyboardFormats().some(
				(f) => f.id === window.LAYOUT_ANALYSIS_FILES.savedFormat()
			)
				? window.LAYOUT_ANALYSIS_FILES.savedFormat()
				: LAYOUT_ANALYSIS.defaultKeyboardFormat(),
			deadKey: null,
			paletteBlock: PALETTE_BLOCKS[0].id,
			// Whether the palette is unfolded, so a render keeps it open.
			paletteOpen: false,
			// Whether the layout's table view (the board's text alternative) is unfolded.
			boardTableOpen: false,
			// The name search: query, result cap and the last answer (null before a search).
			nameSearch: { query: '', limit: UnicodeNames.DEFAULT_LIMIT, answer: null, failed: false },
			// The text the character magnifier shows ('' shows its hint).
			magnified: '',
			// The index of the tab whose name is being edited in place, if any.
			tabRenaming: null,
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
			// The board drawn: ISO, ANSI, JIS or ABNT geometry (the source itself is
			// described on ISO); null follows the source's physical.keyboard.
			board: null,
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
			// The download the export « Format » drop-down shows: this viewer's last choice.
			exportFormat: savedExportFormat(),
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
			heat: null,
			// The last edit's name and the document it made ({doc, text}), for the score chip.
			lastEdit: null,
			// « Versions »: the name typed for the next snapshot, and the saved
			// version whose differences with the layout are listed (its index, or null).
			versionName: '',
			versionShown: null
		};
		state.tabs.push({ history: state.history, dirty: false, versions: [] });
		const doc = () => state.history.current();
		// The live analysis beside the board, on the pages that load its scripts.
		const analysisPanel =
			typeof window.LAYOUT_ANALYSIS_PANEL === 'object'
				? window.LAYOUT_ANALYSIS_PANEL.create({
						onCompare:
							typeof host.compare === 'function' ? (layout) => compareActive(layout) : null,
						onOptimize:
							typeof host.optimize === 'function' ? (layout) => optimizeActive(layout) : null,
						format: () => state.format,
						onSwap: (codes) => applyMove(codes)
					})
				: null;

		/**
		 * Applies an edit as one step of the history.
		 * @param {function(object): object} edit - The next document from the current one.
		 * @param {{key: string, values?: object}|function(object): {key: string, values?: object}} label -
		 *   What the step does (« change key A »), the name the Undo and Redo
		 *   buttons say, or a function reading it on the document before the edit.
		 * @param {function(object): string} [name] - The edit in a few characters
		 *   (« é ↔ a »), read on the document before it; the score chip names the
		 *   change of score after it.
		 */
		function apply(edit, label, name) {
			try {
				const before = doc();
				const text = name ? name(before) : null;
				const named = typeof label === 'function' ? label(before) : label;
				state.history.push(edit(before), named);
				// Kept with the document it made: an undo, a redo or another edit drops it.
				state.lastEdit = text ? { doc: doc(), text } : null;
				state.dirty = true;
				state.message = null;
				state.historySaid = null;
			} catch (error) {
				state.message = { kind: 'error', text: problemText(error) };
			}
			render();
		}

		/**
		 * Applies one of the analysis panel's best moves as one edit: a swap of two
		 * keys, or a cycle of three (codes[0]'s characters to codes[1], codes[1]'s
		 * to codes[2], codes[2]'s to codes[0]), each key moving its base character
		 * and, on the Shift layer, its capital (the pair the optimiser moves
		 * together), at the scope shown. A cycle is two swaps with the first key.
		 * @param {string[]} codes - Two or three KeyboardEvent codes.
		 * @throws {Error} On another count of keys.
		 */
		function applyMove(codes) {
			if (codes.length !== 2 && codes.length !== 3)
				throw new Error(`layout editor: a best move has 2 or 3 keys, not ${codes.length}`);
			const platform = state.platform || null;
			apply(
				(d) => {
					const partner = LayoutEditorModel.caseLayer(d, 'base');
					let next = d;
					for (const other of codes.slice(1)) {
						next = LayoutEditorModel.transferMapping(
							next,
							'base',
							codes[0],
							other,
							platform,
							false
						);
						if (partner)
							next = LayoutEditorModel.transferMapping(
								next,
								partner.id,
								codes[0],
								other,
								platform,
								false
							);
					}
					return next;
				},
				(d) => step('edit_history.step.move_keys', { keys: moveName('base', codes, false)(d) }),
				moveName('base', codes, false)
			);
		}

		/**
		 * What a key types on a layer, as the board shows it; its name when it
		 * types nothing there.
		 */
		function keyChar(d, layer, code) {
			const found = layer
				? LayoutEditorModel.mappingAt(d, layer, code, state.platform || null)
				: null;
			const text = found ? legend(found.mapping, d) : '';
			return text || keyName(code);
		}

		/**
		 * The name of a move of keys' characters: « é ↔ a » for a swap, « é → a »
		 * for a copy, « é → a → s » for a cycle.
		 * @returns {function(object): string} Read on the document before the move.
		 */
		function moveName(layer, codes, copy) {
			return (d) => {
				const chars = codes.map((code) => keyChar(d, layer, code));
				return chars.join(codes.length === 2 && !copy ? ' ↔ ' : ' → ');
			};
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

		// Which layout each history holds, for the analysis panel's change column: a
		// tab keeps its lineage through its edits, an opened document starts a new one.
		const lineages = new WeakMap();
		let lineageCount = 0;
		function lineage() {
			if (!lineages.has(state.history)) lineages.set(state.history, ++lineageCount);
			return lineages.get(state.history);
		}

		/**
		 * Shows another document in this tab. A layout the user opens is a step
		 * that Undo takes back (maintainer, 2026-11-21); the one the editor opens
		 * on (opening: true) starts the history.
		 */
		function replace(next, lost, opening) {
			// The edit belongs to the document being replaced: commit it there first.
			commitFocused();
			replacements += 1;
			if (opening) state.history.reset(next);
			else state.history.push(next, step('edit_history.step.open', { name: next.layout.name }));
			// Another layout: its first analysis shows no change against the one replaced.
			lineages.set(state.history, ++lineageCount);
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
				? { history: state.history, dirty: state.dirty, versions: state.tabs[index].versions }
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
			state.historySaid = null;
			state.versionShown = null;
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

		/**
		 * A tab for a document, with a history of its own and its saved versions
		 * ({name, text, at}, oldest first; none for a new document).
		 */
		function newTab(document, dirty, versions) {
			return {
				history: LayoutEditorModel.createHistory(document),
				dirty,
				versions: versions || []
			};
		}

		/** A blank layout, as « New » makes it. */
		function blankDoc() {
			return LayoutSourceIO.create('my_layout', tl('default_name'));
		}

		/** Turns a tab into its name field (double-click or F2), focused with its text selected. */
		function startTabRename(index) {
			commitFocused();
			state.tabRenaming = index;
			render();
			const field = root.querySelector('#le-tab-rename');
			field.focus();
			field.select();
		}

		/**
		 * A tab's name field: Enter renames the layout (one edit, undone by
		 * Undo), Escape or leaving it keeps the name; an empty name is refused in
		 * words and the field stays.
		 */
		function tabRenameField(index, name) {
			let done = false;
			const finish = (rename, value) => {
				if (done) return;
				done = true;
				state.tabRenaming = null;
				const clean = String(value || '').trim();
				if (rename && clean !== '' && clean !== name) {
					if (index !== state.active) {
						keepActive();
						showTab(index);
					}
					apply(
						(d) => LayoutEditorModel.setLayout(d, { name: clean }),
						step('edit_history.step.rename')
					);
				} else render();
				const tab = root.querySelector(`.le-layout-tab[data-tab="${index}"]`);
				if (tab) tab.focus();
			};
			return el('input', {
				type: 'text',
				id: 'le-tab-rename',
				class: 'le-layout-tab-rename',
				value: name,
				'aria-label': t('layout_analysis.mine.name_label', { name }),
				onkeydown: (event) => {
					if (event.key === 'Escape') {
						event.preventDefault();
						finish(false);
					} else if (event.key === 'Enter') {
						event.preventDefault();
						if (event.target.value.trim() === '') {
							notify('error', t('layout_analysis.mine.name_empty'));
							// The message's render drew the field again: keep typing there.
							root.querySelector('#le-tab-rename').focus();
							return;
						}
						finish(true, event.target.value);
					}
				},
				onblur: (event) => {
					// A render (a message) replaces the field: only a real blur cancels.
					const field = event.target;
					setTimeout(() => {
						if (!done && field.isConnected && state.tabRenaming === index) finish(false);
					}, 0);
				}
			});
		}

		/** « ⧉ »: the layout in a new tab named as its copy, the original left as it is. */
		function duplicateTab(index) {
			commitFocused();
			keepActive();
			const current = tabAt(index).history.current();
			const copy = LayoutEditorModel.setLayout(current, {
				name: t('layout_analysis.mine.copy_name', { name: current.layout.name }),
				id: LayoutSourceIO.identifierFrom(`${current.layout.id}_copy`, 'layout')
			});
			state.tabs.splice(index + 1, 0, newTab(copy, true));
			showTab(index + 1);
			notify('ok', t('layout_analysis.mine.duplicated', { name: copy.layout.name }));
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

		/**
		 * « Import »: every layout of the chosen files (any file « Open… » reads, and
		 * backups) in new tabs, read as « Open… » reads them; a file that does not
		 * read is named, the others open.
		 */
		async function importTabs(input) {
			const files = [...(input.files || [])];
			input.value = '';
			await importFiles(files);
		}

		/**
		 * Opens each file in a new tab (« Import… », or files dropped on the
		 * editor); a file that does not read is named, the others open.
		 * @param {File[]} files
		 */
		async function importFiles(files) {
			if (files.length === 0) return;
			const entries = [];
			const refused = [];
			for (const file of files) {
				try {
					if (/\.zip$/i.test(file.name))
						entries.push(
							...(await LayoutEditorWorkspace.readArchive(new Uint8Array(await file.arrayBuffer())))
						);
					else if (hasExtension(file.name, OPENED_EXTENSIONS)) {
						// Bytes too, as « Open… » reads them: a UTF-16 KLC, a KbdEdit .kbe header.
						const bytes = new Uint8Array(await file.arrayBuffer());
						entries.push({ name: file.name, text: LAYOUT_FORMATS.decode(bytes), bytes });
					} else
						throw {
							code: 'import_unsupported',
							path: file.name,
							values: { open: tl('btn.open'), extensions: OPENED_EXTENSIONS.join(', ') }
						};
				} catch (error) {
					refused.push(`${file.name}: ${problemText(error)}`);
				}
			}
			commitFocused();
			keepActive();
			const first = state.tabs.length;
			for (const entry of entries) {
				try {
					state.tabs.push(newTab(readDocument(entry.name, entry.text, entry.bytes).doc, false));
				} catch (error) {
					refused.push(`${entry.name}: ${refusalText(error)}`);
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
					// A saved version is a new array (see saveVersion), so identity is enough.
					return [tab.history.current(), tab.dirty, tab.versions];
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
						return {
							text: sourceText(tab.history.current()),
							dirty: tab.dirty,
							versions: tab.versions
						};
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
					return newTab(parsed.doc, tab.dirty, tab.versions);
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
				return el('li', { class: `le-layout-tab-item${active ? ' active' : ''}` }, [
					state.tabRenaming === index
						? tabRenameField(index, name)
						: el('button', {
								type: 'button',
								class: 'le-layout-tab',
								'data-tab': String(index),
								'aria-current': active ? 'true' : 'false',
								// Double-click or F2 renames the layout in place (ux-study item 20).
								title: `${tl(tab.dirty ? 'toolbar.unsaved' : 'toolbar.saved')} ${tl('tabs.rename_hint')}`,
								'aria-keyshortcuts': 'F2',
								text: `${name}${tab.dirty ? ' •' : ''}`,
								onclick: () => switchTab(index),
								ondblclick: () => startTabRename(index),
								onkeydown: (event) => {
									if (event.key === 'F2') {
										event.preventDefault();
										startTabRename(index);
									} else layoutTabKeys(event);
								}
							}),
					el(
						'button',
						{
							type: 'button',
							class: 'le-tab-icon-button le-layout-tab-duplicate',
							'data-duplicate-tab': String(index),
							'aria-label': t('layout_analysis.mine.duplicate_named', { name }),
							title: t('layout_analysis.mine.duplicate_named', { name }),
							onclick: () => duplicateTab(index)
						},
						tabIcon('duplicate')
					),
					el(
						'button',
						{
							type: 'button',
							class: 'le-tab-icon-button le-layout-tab-close',
							'data-close-tab': String(index),
							'aria-label': tl('tabs.close', { name }),
							title: tl('tabs.close', { name }),
							onclick: () => closeTab(index)
						},
						tabIcon('close')
					)
				]);
			});
			const importInput = el('input', {
				type: 'file',
				id: 'le-tabs-import-file',
				accept: IMPORTED_EXTENSIONS.join(','),
				multiple: true,
				hidden: true,
				onchange: (event) => importTabs(event.target)
			});
			return el('header', { class: 'le-layout-tabs', id: 'le-layout-tabs' }, [
				el('div', { class: 'le-layout-tab-list' }, [
					// A named list of the open layouts, the current one marked: a
					// tablist may hold only tabs, and each layout has its duplicate
					// and close buttons (WCAG 4.1.2). The arrows move between the
					// layouts' buttons (layoutTabKeys). The add button stays in the
					// same row (display: contents, style.css).
					el('ul', { class: 'le-layout-tab-roles', 'aria-label': tl('tabs.label') }, tabs),
					el(
						'button',
						{
							type: 'button',
							id: 'le-tab-add',
							class: 'le-layout-tab-add',
							'aria-label': tl('tabs.add'),
							title: tl('tabs.add'),
							onclick: addTab
						},
						tabIcon('add')
					)
				]),
				el('output', {
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
				el('button', {
					type: 'button',
					id: 'le-tabs-paste',
					'aria-haspopup': 'dialog',
					text: tl('tabs.paste'),
					onclick: openPaste
				}),
				importInput
			]);
		}

		// ===================================
		// ======= 4b2/ Paste and drop =======
		// ===================================

		// The paste dialog lives outside the rendered tree, so a render (a
		// message, an autosave) never takes the text being typed away.
		let pasteDialog = null;

		/** The paste dialog, made once: a field, what it recognises, open and cancel. */
		function pasteBox() {
			if (pasteDialog) return pasteDialog;
			const field = el('textarea', {
				id: 'le-paste-text',
				class: 'le-paste-text',
				rows: '8',
				spellcheck: 'false',
				'aria-describedby': 'le-paste-detected le-paste-help'
			});
			const detected = el('p', {
				id: 'le-paste-detected',
				class: 'le-paste-detected',
				'aria-live': 'polite'
			});
			const submit = el('button', {
				type: 'button',
				id: 'le-paste-open',
				class: 'le-primary',
				text: tl('tabs.paste_open'),
				onclick: () => {
					if (openPasted(field.value)) pasteDialog.close();
				}
			});
			const refusal = el('p', {
				id: 'le-paste-refusal',
				class: 'le-paste-refusal',
				role: 'alert',
				hidden: true
			});
			field.addEventListener('input', () => showPasteFormat(field, detected, submit, refusal));
			pasteDialog = el(
				'dialog',
				{ id: 'le-paste-dialog', class: 'le-paste-dialog', 'aria-labelledby': 'le-paste-title' },
				[
					el('h2', { id: 'le-paste-title', text: tl('tabs.paste').replace(/…$/, '') }),
					el('p', {
						id: 'le-paste-help',
						class: 'le-paste-help',
						text: t('layout_analysis.add.help')
					}),
					el('label', { for: 'le-paste-text', text: t('layout_analysis.add.paste_label') }),
					field,
					detected,
					refusal,
					el('p', { class: 'le-paste-actions' }, [
						el('button', {
							type: 'button',
							id: 'le-paste-cancel',
							text: tl('btn.cancel'),
							onclick: () => pasteDialog.close()
						}),
						submit
					])
				]
			);
			document.body.append(pasteDialog);
			return pasteDialog;
		}

		/** « Paste a layout… »: the dialog, emptied, its field focused. */
		function openPaste() {
			const dialog = pasteBox();
			const field = dialog.querySelector('#le-paste-text');
			field.value = '';
			showPasteFormat(
				field,
				dialog.querySelector('#le-paste-detected'),
				dialog.querySelector('#le-paste-open'),
				dialog.querySelector('#le-paste-refusal')
			);
			dialog.showModal();
			field.focus();
		}

		/** Live under the field: the format recognised (an Ergopti source too), or none yet. */
		function showPasteFormat(field, detected, submit, refusal) {
			const text = field.value;
			const format = text.trim() === '' ? null : LAYOUT_FORMATS.detect(text);
			detected.className = `le-paste-detected ${format ? 'ok' : text.trim() ? 'none' : ''}`;
			detected.textContent =
				text.trim() === ''
					? ''
					: format
						? `✓ ${t('layout_analysis.formats.detected', { format: t(LAYOUT_FORMATS.formatNameKey(format)) })}`
						: t('layout_analysis.formats.not_detected');
			submit.disabled = !format;
			refusal.hidden = true;
		}

		/**
		 * Reads a pasted (or dropped) text into a new tab: an Ergopti source or a
		 * .keylayout through « Open… »'s own path, any other format through the
		 * Comparer's readers by its content. A refusal stays in the dialog, the
		 * text kept, so it can be fixed where the message points.
		 * @param {string} text
		 * @returns {boolean} Whether a tab opened.
		 */
		function openPasted(text) {
			const format = LAYOUT_FORMATS.detect(text);
			let read;
			try {
				if (format === 'ergopti') read = readDocument('pasted.toml', text);
				else if (format === 'keylayout') read = readDocument('pasted.keylayout', text);
				else read = readForeign('', text, null, true);
			} catch (error) {
				const refusal = pasteBox().querySelector('#le-paste-refusal');
				refusal.textContent = refusalText(error);
				refusal.hidden = false;
				if (!pasteDialog.open) notify('error', refusalText(error));
				return false;
			}
			commitFocused();
			keepActive();
			state.tabs.push(newTab(read.doc, false));
			showTab(state.tabs.length - 1);
			notify('ok', read.notice);
			return true;
		}

		/**
		 * Files dropped anywhere on the editor open in new tabs, as « Import… »
		 * opens them; a dropped text (a link, a selection) reads as a paste.
		 * Bound once on the root, which every render keeps.
		 */
		function wireDrop() {
			const carries = (event) =>
				event.dataTransfer &&
				Array.from(event.dataTransfer.types || []).some((type) =>
					['Files', 'text/plain', 'text/uri-list'].includes(type)
				);
			// A drag over a text field drops its text there, as the browser does.
			const intoField = (event) => event.target.closest && event.target.closest('textarea, input');
			root.addEventListener('dragover', (event) => {
				if (!carries(event) || intoField(event)) return;
				event.preventDefault();
				event.dataTransfer.dropEffect = 'copy';
				root.classList.add('le-drop-active');
				root.dataset.dropHint = tl('tabs.drop');
			});
			root.addEventListener('dragleave', (event) => {
				if (!root.contains(event.relatedTarget)) root.classList.remove('le-drop-active');
			});
			root.addEventListener('drop', (event) => {
				if (!carries(event) || intoField(event)) return;
				event.preventDefault();
				root.classList.remove('le-drop-active');
				const files = Array.from(event.dataTransfer.files || []);
				if (files.length > 0) {
					importFiles(files);
					return;
				}
				const text =
					event.dataTransfer.getData('text/plain') || event.dataTransfer.getData('text/uri-list');
				if (text) openPasted(text);
			});
		}

		// ============================
		// ======= 4/ Files ===========
		// ============================

		/** A refusal already worded for the reader (a foreign file's reader). */
		function worded(text) {
			return { worded: text };
		}

		/** The words of a readDocument refusal, or of any other error. */
		function refusalText(error) {
			return error && typeof error.worded === 'string' ? error.worded : problemText(error);
		}

		/**
		 * Reads one layout file into a document, as « Open… » and « Import… » both
		 * do: a .keylayout through its importer, an Ergopti source as it is, any
		 * other layout file (KLA or KLAnext JSON, Kalamine, XKB symbols, KLC, DOF,
		 * cmini, rows, KbdEdit .kbe) through the Comparer's readers into a new
		 * source. The file's bytes, when the page has them, let a .kbe header be
		 * checked.
		 * @param {string} name - The file name.
		 * @param {string} text - Its text.
		 * @param {Uint8Array} [bytes] - Its bytes.
		 * @returns {{doc: object, notice: string}} The document and the status that says what was read.
		 * @throws {object} A refusal (refusalText words it).
		 */
		function readDocument(name, text, bytes) {
			if (/\.keylayout$/i.test(name)) {
				const id = LayoutSourceIO.identifierFrom(name.replace(/\.keylayout$/i, ''), 'layout');
				return {
					doc: LayoutSourceIO.importKeylayout(text, id, state.importConvention),
					notice: tl('status.imported', { name })
				};
			}
			if (!/^\s*format\s*=\s*"ergopti-layout"/m.test(text)) return readForeign(name, text, bytes);
			const parsed = LayoutSourceIO.parse(text);
			if (!parsed.ok) throw parsed.error;
			return { doc: parsed.doc, notice: tl('status.opened', { name }) };
		}

		function openText(name, text, bytes) {
			let read;
			try {
				read = readDocument(name, text, bytes);
			} catch (error) {
				notify('error', refusalText(error));
				return;
			}
			replace(read.doc);
			notify('ok', read.notice);
		}

		/**
		 * Reads another tool's layout file into a new Ergopti source: the
		 * Comparer's readers (layout_formats.js) give each key's characters and
		 * dead keys, toSource the source; what they could not read is listed.
		 */
		function readForeign(name, text, bytes, pasted) {
			let result;
			let started;
			const tools = {
				parseToml: window.exports && window.exports.parse,
				scancodes: LAYOUT_ANALYSIS_DATA.scancodes,
				composer: LayoutComposer,
				table: LAYOUT_COMPOSER_DATA,
				analysis: LAYOUT_ANALYSIS,
				convention: state.importConvention
			};
			try {
				// A pasted text has no name: its content says its format.
				result = pasted
					? LAYOUT_FORMATS.readText(text, tools)
					: bytes
						? LAYOUT_FORMATS.readBytes(name, bytes, tools)
						: LAYOUT_FORMATS.read(name, text, tools);
				const base = name.replace(/\.[^.]+$/, '');
				started = LayoutSourceIO.startFromDocument(
					LAYOUT_FORMATS.toSource(result.layout),
					LayoutSourceIO.identifierFrom(result.layout.id || base, 'layout'),
					result.layout.name || base
				);
			} catch (error) {
				// The Comparer's words for a file its readers refuse.
				const refusal = LAYOUT_FORMATS.refusalMessage(error);
				throw worded(t(refusal.key, refusal.values));
			}
			// What the reader recognised, in the page's language; a paste is named by its layout.
			const format = t(LAYOUT_FORMATS.formatNameKey(result.format));
			const shown = name || result.layout.name;
			return {
				doc: started.doc,
				notice:
					result.unmapped.length === 0
						? tl('status.imported_format', { name: shown, format })
						: tl('status.imported_partial', {
								name: shown,
								format,
								count: result.unmapped.length,
								list: lossList(result.unmapped)
							})
			};
		}

		/** What a reader or writer could not carry, in a few words of the page's language. */
		function lossList(unmapped) {
			const words = unmapped.slice(0, 8).map((entry) => {
				const loss = LAYOUT_FORMATS.lossMessage(entry);
				return t(loss.key, loss.values);
			});
			return unmapped.length > 8 ? `${words.join(', ')}…` : words.join(', ');
		}

		/**
		 * The KLA JSON of the edited layout and what KLA cannot hold (dead keys,
		 * several characters on one key, a layout's own levels past its four).
		 */
		function klaExport(layout) {
			const unmapped = [];
			for (const row of Object.values(layout.rows))
				for (const cell of row.slice(0, LAYOUT_ANALYSIS.LAYER_IDS.length)) {
					if (cell && typeof cell === 'object')
						unmapped.push({ what: 'dead_key', detail: cell.dead });
					else if (typeof cell === 'string' && Array.from(cell).length > 1)
						unmapped.push({ what: 'multi_character', detail: cell });
				}
			LAYOUT_FORMATS.levelLosses(layout, unmapped);
			const json = LAYOUT_FORMATS.toKla(layout, LAYOUT_ANALYSIS_DATA.model.fingerings.standard);
			return { text: `${JSON.stringify(json, null, 2)}\n`, unmapped };
		}

		/**
		 * Opens a file through the host's native panel (macOS), where the webview
		 * shows none: its UTF-8 text, or the base64 bytes of another tool's file
		 * that is not UTF-8 (a UTF-16 KLC, a KbdEdit .kbe).
		 */
		function pickWithHost() {
			fromHost(() => host.pickFile()).then(
				(picked) => {
					if (picked && typeof picked.text === 'string') openText(picked.filename, picked.text);
					else if (picked && typeof picked.data === 'string') {
						const bytes = Uint8Array.from(atob(picked.data), (ch) => ch.charCodeAt(0));
						openText(picked.filename, LAYOUT_FORMATS.decode(bytes), bytes);
					}
				},
				(error) => notify('error', problemText(error))
			);
		}

		/**
		 * Reads a picked file: its text (a KLC's UTF-16 decoded by its byte-order
		 * mark) and its bytes (a KbdEdit .kbe is binary).
		 */
		function readFile(input, onText) {
			const file = input.files && input.files[0];
			if (!file) return;
			file.arrayBuffer().then(
				(buffer) => {
					const bytes = new Uint8Array(buffer);
					onText(file.name, LAYOUT_FORMATS.decode(bytes), bytes);
				},
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
				state.history.push(
					LayoutSourceIO.withNavLayer(doc(), text, [hold], data),
					step('edit_history.step.navigation', { name })
				);
				state.layer = LayoutSourceIO.NAV_LAYER;
				state.dirty = true;
				notify('ok', tl('status.nav_imported', { name }));
			} catch (error) {
				notify('error', problemText(error));
			}
		}

		/**
		 * Shows the navigation layer, once the first document is in place. A
		 * document without one takes the driver's layers.toml (nav.text) as its
		 * navigation layer, held by nav.hold, the key whose hold enters the layer
		 * today; without that key the « Navigation » tool opens and says to choose
		 * it. layers.toml stays the compiled form: « Apply the navigation layer »
		 * writes it back from this layer.
		 * @param {{text?: string|null, hold?: string|null}} nav
		 */
		function showNav(nav) {
			initialSettled.then(() => {
				if ((doc().layers || []).some((l) => l.id === LayoutSourceIO.NAV_LAYER)) {
					showLayer(LayoutSourceIO.NAV_LAYER);
					return;
				}
				if (nav && typeof nav.hold === 'string' && nav.hold) state.navHold = nav.hold;
				if (nav && typeof nav.text === 'string' && state.navHold) {
					importNav('layers.toml', nav.text);
					return;
				}
				state.tool = 'navigation';
				notify('error', tl('status.nav_missing'));
			});
		}

		/**
		 * Asks a question in the page (see messageBar): the focus moves to its
		 * « Cancel », and goes back to the control that asked once answered.
		 */
		function ask(text, onYes) {
			const opener = focusAnchor(document.activeElement);
			state.confirm = { text, onYes, opener };
			render();
			const cancel = root.querySelector('#le-confirm-no');
			if (cancel) cancel.focus();
		}

		function adoptConverted(converted) {
			state.history.push(converted.doc, step('edit_history.step.convert'));
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

		/**
		 * Undoes or redoes the shown tab's last edit; nothing to undo does
		 * nothing. The polite line says which step was taken back or replayed.
		 */
		function runHistory(action) {
			const history = state.history;
			if (action === 'undo' ? !history.canUndo() : !history.canRedo()) return;
			commitFocused();
			const label = action === 'undo' ? history.undoLabel() : history.redoLabel();
			if (action === 'undo') history.undo();
			else history.redo();
			state.dirty = true;
			state.historySaid = { action, label };
			render();
		}

		/**
		 * An Undo or Redo button's state and its shortcut, in its accessible name
		 * and tooltip (« Undo (Ctrl+Z) », « Redo (⌘Y, ⇧⌘Z) ») and for assistive
		 * technologies (aria-keyshortcuts).
		 */
		function historyButton(action) {
			const shortcut = HISTORY_SHORTCUTS[action];
			const keys = shortcutOses(host.platform)
				.map((os) =>
					LayerModel.chordText(shortcut.chords, {
						os,
						data: LAYER_EDITOR_DATA,
						t,
						// The letters as printed, whatever the edited layout puts on those keys.
						legends: { KeyZ: 'Z', KeyY: 'Y' }
					})
				)
				.join(', ');
			// « Undo: change key A (Ctrl+Z) »: the step it would take back (maintainer, 2026-11-21).
			const label = action === 'undo' ? state.history.undoLabel() : state.history.redoLabel();
			const name = tl('btn.with_shortcut', {
				action: ERGOPTI_EDIT_HISTORY.buttonName(t, action, label),
				keys
			});
			return {
				disabled: action === 'undo' ? !state.history.canUndo() : !state.history.canRedo(),
				title: name,
				'aria-label': name,
				'aria-keyshortcuts': shortcut.aria
			};
		}

		/** The primary actions: the file, the history and, in a window, Close. */
		function toolbar() {
			const fileInput = el('input', {
				type: 'file',
				id: 'le-open-file',
				accept: OPENED_EXTENSIONS.join(','),
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
			// A menu element: the HTML toolbar, a list of commands each reached with Tab.
			return el('menu', { class: 'le-toolbar', 'aria-label': tl('toolbar.label') }, [
				el('li', { class: 'le-toolbar-group' }, [
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
				el('li', { class: 'le-toolbar-group' }, [
					button('le-undo', tl('btn.undo'), () => runHistory('undo'), historyButton('undo')),
					button('le-redo', tl('btn.redo'), () => runHistory('redo'), historyButton('redo')),
					el('p', {
						class: 'le-history-status theme-sr-only',
						id: 'le-history-status',
						role: 'status',
						text: state.historySaid
							? t(
									state.historySaid.action === 'undo'
										? 'edit_history.undone'
										: 'edit_history.redone',
									{ step: t(state.historySaid.label.key, state.historySaid.label.values) }
								)
							: ''
					})
				]),
				el('li', {
					class: `le-doc-state${state.dirty ? ' dirty' : ''}`,
					id: 'le-doc-state',
					text: `${doc().layout.name}${state.dirty ? ' •' : ''}`,
					title: tl(state.dirty ? 'toolbar.unsaved' : 'toolbar.saved')
				}),
				host.onClose
					? el(
							'li',
							{ class: 'le-toolbar-close' },
							button('le-close', tl('btn.close'), host.onClose)
						)
					: null
			]);
		}

		function messageBar() {
			const parts = [];
			if (state.confirm) {
				const question = state.confirm;
				const answer = (yes) => {
					state.confirm = null;
					if (yes) question.onYes();
					else render();
					// Back to the control that asked, or its counterpart after the render.
					const opener = question.opener;
					if (!opener || document.activeElement !== document.body) return;
					const back = opener.node.isConnected
						? opener.node
						: opener.selector && root.querySelector(opener.selector);
					if (back) back.focus({ preventScroll: true });
				};
				// Not modal: the question sits where the page's messages show. The
				// focus moves in on « Cancel », Escape cancels, and the focus goes
				// back to the control that asked (ask, answerConfirm).
				parts.push(
					el(
						'dialog',
						{
							class: 'le-confirm',
							id: 'le-confirm',
							role: 'alertdialog',
							open: true,
							'aria-describedby': 'le-confirm-text',
							'aria-label': tl('btn.confirm'),
							onkeydown: (event) => {
								if (event.key !== 'Escape') return;
								event.preventDefault();
								answer(false);
							}
						},
						[
							el('p', { id: 'le-confirm-text', text: question.text }),
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
						]
					)
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
					el('div', { class: 'le-preserved', id: 'le-preserved', role: 'note' }, [
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
							apply(
								(d) => LayoutEditorModel.setLayout(d, { [name]: event.target.value }),
								name === 'name'
									? step('edit_history.step.rename')
									: step('edit_history.step.details')
							)
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
								apply(
									(d) => LayoutEditorModel.setLayout(d, { description: event.target.value }),
									step('edit_history.step.details')
								)
						})
					]),
					el('label', { class: 'le-field' }, [
						tl('meta.keyboard'),
						select(
							[['', tl('physical.iso')]].concat(
								LayoutSource.KEYBOARDS.map((id) => [id, tl(`physical.${id}`)])
							),
							doc().physical.keyboard || '',
							(value) => {
								// The board follows the keyboard the layout is now for.
								state.board = null;
								apply(
									(d) => LayoutEditorModel.setKeyboard(d, value),
									step('edit_history.step.keyboard')
								);
							},
							{ id: 'le-keyboard', disabled: LayoutSourceIO.isPreserved(doc()) }
						)
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

		/** A layer's name as its tab shows it: a usual level by its name, another by its modifiers. */
		function layerName(layer) {
			const level = LayoutSourceIO.LEVEL_LAYERS.find((each) => levelLayer(each) === layer);
			return level ? tl(`fill.level.${level.id}`) : layerLabel(layer);
		}

		/**
		 * What a mapping does, in words a screen reader can say: the text it
		 * types, a dead key by its name (its bare accent alone is easy to miss),
		 * an action, a chord, or « disabled ».
		 */
		function spokenMapping(mapping) {
			const kind = LayoutEditorModel.kindOf(mapping);
			if (kind === 'dead_key') {
				const dead = (doc().dead_keys || []).find((entry) => entry.id === mapping.dead_key);
				return tl('board.dead_key', { name: (dead && dead.name) || mapping.dead_key });
			}
			if (kind === 'text' || kind === 'action' || kind === 'key') return legend(mapping, doc());
			return tl('board.disabled');
		}

		/**
		 * Each layer's mapping of a key, in the order of the layers, as
		 * « layer: what it does » (an unmapped layer is left out).
		 * @returns {string[]}
		 */
		function keyLevels(code) {
			if (LayoutSourceIO.isPreserved(doc())) return [];
			return LayoutEditorModel.layers(doc())
				.map((layer) => {
					const found = LayoutEditorModel.mappingAt(doc(), layer.id, code, state.platform || null);
					return found ? `${layerName(layer)} ${spokenMapping(found.mapping)}` : null;
				})
				.filter(Boolean);
		}

		/**
		 * Rows and ranks of the drawn keys: a key's row from the top and its
		 * rank from the left in that row, which the drawing shows by place.
		 * @returns {Map<string, string>} code → « row 2, key 5 ».
		 */
		function boardPositions(keys, form) {
			const rows = Array.from(new Set(keys.map((k) => k.geometry[form].row))).sort((a, b) => a - b);
			const out = new Map();
			rows.forEach((row, r) =>
				keys
					.filter((k) => k.geometry[form].row === row)
					.sort((a, b) => a.geometry[form].col - b.geometry[form].col)
					.forEach((k, c) => out.set(k.code, tl('board.position', { row: r + 1, column: c + 1 })))
			);
			return out;
		}

		/**
		 * A drawn key's accessible name: its visible text first (WCAG 2.5.3),
		 * then its printed name for a named key (Tab), its place, and what it
		 * does on every layer, or its shortcut overrides in the shortcut view.
		 */
		function keyAccessibleName(key, shown, where, shortcutText) {
			const named = key.character || keyName(key.code) === key.code ? '' : keyName(key.code);
			const parts = [named && !shown.includes(named) ? named : '', where]
				.filter(Boolean)
				.join(', ');
			const levels = shortcutText ? [shortcutText] : keyLevels(key.code);
			const head = shown ? `${shown}: ${parts}` : parts;
			return levels.length ? `${head}. ${levels.join(', ')}` : head;
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
		 * One Tab stop per tab list (the ARIA tabs pattern): the chosen tab, else
		 * the first; the arrows reach the others (tabListKeys).
		 * @param {HTMLElement[]} tabs - The list's tabs, in order.
		 */
		function rove(tabs) {
			const chosen = tabs.find((tab) => tab.getAttribute('aria-selected') === 'true') || tabs[0];
			for (const tab of tabs) tab.tabIndex = tab === chosen ? 0 : -1;
		}

		/**
		 * The arrow keys, Home and End on a tab: the focus moves to the next,
		 * previous, first or last tab of its list, round from end to start, and
		 * chooses it (automatic activation: a tab only shows its panel). The
		 * render that follows gives the focus back to the chosen tab.
		 * @param {KeyboardEvent} event - A keydown on a tab.
		 */
		function tabListKeys(event) {
			if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
			const list = event.currentTarget.closest('[role="tablist"]');
			const tabs = [...list.querySelectorAll('[role="tab"]')].filter((tab) => !tab.disabled);
			const at = tabs.indexOf(event.currentTarget);
			const steps = { ArrowRight: at + 1, ArrowLeft: at - 1, Home: 0, End: tabs.length - 1 };
			if (!(event.key in steps) || at < 0) return;
			event.preventDefault();
			const next = tabs[(steps[event.key] + tabs.length) % tabs.length];
			next.focus();
			if (next.getAttribute('aria-selected') !== 'true') next.click();
		}

		/**
		 * The arrow keys, Home and End on an open layout's button: the focus
		 * moves between the layouts (round from end to start); Enter or Space
		 * shows the one focused. Its duplicate and close buttons stay on Tab.
		 * @param {KeyboardEvent} event - A keydown on a .le-layout-tab button.
		 */
		function layoutTabKeys(event) {
			if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
			const tabs = [...root.querySelectorAll('#le-layout-tabs .le-layout-tab')];
			const at = tabs.indexOf(event.currentTarget);
			const steps = { ArrowRight: at + 1, ArrowLeft: at - 1, Home: 0, End: tabs.length - 1 };
			if (!(event.key in steps) || at < 0) return;
			event.preventDefault();
			tabs[(steps[event.key] + tabs.length) % tabs.length].focus();
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
						'aria-controls': 'le-board',
						title: layer.required.join('+') || tl('layer.no_modifier'),
						text: label,
						onclick: () => showLayer(layer.id),
						onkeydown: tabListKeys
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
						apply(
							(d) => LayoutEditorModel.addLayer(d, level.id, level.required, []),
							step('edit_history.step.add_level', { level: label })
						);
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
						'aria-controls': 'le-board',
						title: `${layer.id} (${layer.required.join('+') || tl('layer.no_modifier')})`,
						text: layerLabel(layer),
						onclick: () => showLayer(layer.id),
						onkeydown: tabListKeys
					})
				);
			rove(levels.filter((tab) => tab.getAttribute('role') === 'tab'));
			rove(others);
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
					// The layer bar's heading, which also names the levels' tab list.
					el('h2', { class: 'le-label', id: 'le-layers-label', text: tl('layer.selector') }),
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
						? el(
								'div',
								{
									class: 'le-tabs le-other-layers',
									role: 'tablist',
									'aria-labelledby': 'le-layers-label'
								},
								others
							)
						: null,
					preserved
						? null
						: // A toggle beside the layer tabs, not a tab: a tab must sit in
							// a tablist (WCAG 4.1.2).
							el('button', {
								type: 'button',
								id: 'le-shortcut-view',
								class: `le-tab le-shortcut-tab${state.shortcutView ? ' active' : ''}`,
								'aria-pressed': String(state.shortcutView),
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
				el('p', { class: 'le-view' }, [
					el('label', { class: 'le-inline' }, [tl('scope.label'), scope]),
					el('label', { class: 'le-inline' }, [
						tl('board.label'),
						select(
							BOARD_FORMS.map((form) => [form, tl(`physical.${form}`)]),
							boardForm(),
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
								window.LAYOUT_ANALYSIS_FILES.saveFormat(value);
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
			const addForm = el('section', { class: 'le-subpanel le-add', id: 'le-layer-add-form' }, [
				el('h3', { text: tl('layer.add') }),
				idInput,
				el('p', { class: 'le-checks', id: 'le-layer-required' }, checks),
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
						apply(
							(d) => LayoutEditorModel.addLayer(d, id, required, []),
							step('edit_history.step.add_level', { level: id })
						);
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
				apply(
					(d) => LayoutEditorModel.transferLayer(d, from, moveTarget.value, keep),
					step('edit_history.step.move_level', { level: from })
				);
			};
			const current =
				state.layer && others.length
					? el('section', { class: 'le-subpanel le-add', id: 'le-move-all' }, [
							el('h3', { text: tl('layer.move_all') }),
							el('label', { class: 'le-inline' }, [tl('layer.move_target'), moveTarget]),
							el('p', { class: 'le-buttons' }, [
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
											apply(
												(d) => LayoutEditorModel.removeLayer(d, removed),
												step('edit_history.step.remove_level', { level: removed })
											);
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
				el('p', { class: 'le-buttons' }, [
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
				el('p', { class: 'le-buttons' }, [
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

		// ============================
		// ======= 7b/ Versions =======
		// ============================

		/** The shown tab's saved versions, oldest first. */
		function versions() {
			return state.tabs[state.active].versions;
		}

		/** A version's time in the page's language (« 25 Nov 2026, 14:05 »). */
		function versionTime(at) {
			return new Intl.DateTimeFormat(document.documentElement.lang || undefined, {
				dateStyle: 'medium',
				timeStyle: 'short'
			}).format(new Date(at));
		}

		/**
		 * « Save this version »: a named snapshot of the layout shown, beside the
		 * undo history; the workspace keeps it with the tab. A full list or a
		 * name too long is refused, naming why; nothing is dropped in silence.
		 */
		function saveVersion() {
			commitFocused();
			const list = versions();
			const typed = state.versionName.trim();
			const name = typed || tl('versions.default_name', { n: list.length + 1 });
			if (list.length >= LayoutEditorWorkspace.MAX_VERSIONS) {
				notify('error', tl('versions.full', { max: LayoutEditorWorkspace.MAX_VERSIONS }));
				return;
			}
			if ([...name].length > LayoutEditorWorkspace.MAX_VERSION_NAME) {
				notify(
					'error',
					tl('versions.name_too_long', { max: LayoutEditorWorkspace.MAX_VERSION_NAME })
				);
				return;
			}
			// Its id is its time, kept distinct from the last one's; it branches
			// from the version the layout came from (the base), and becomes it.
			const at = Math.max(Date.now(), list.length ? list[list.length - 1].at + 1 : 0);
			const base = list.find((version) => version.base);
			const saved = { name, text: sourceText(doc()), at, base: true };
			if (base) saved.from = base.at;
			// A new array, so the workspace sees the change (workspaceShape).
			state.tabs[state.active].versions = list.map(withoutBase).concat([saved]);
			state.versionName = '';
			notify('ok', tl('versions.saved', { name }));
		}

		/** A version without the base mark (a copy when it had one). */
		function withoutBase(version) {
			if (!version.base) return version;
			const copy = Object.assign({}, version);
			delete copy.base;
			return copy;
		}

		/**
		 * The versions as their branch graph (an idea seen in the Layouts Wiki
		 * playground's Versions pane, which draws one): each version under the
		 * one it came from, siblings oldest first, with its depth.
		 * @returns {{version: object, index: number, depth: number, parent: object|null}[]}
		 */
		function versionTree(list) {
			const byAt = new Map(list.map((version) => [version.at, version]));
			const children = new Map();
			const roots = [];
			list.forEach((version, index) => {
				const parent = version.from !== undefined ? byAt.get(version.from) : undefined;
				const entry = { version, index };
				if (parent) {
					if (!children.has(parent.at)) children.set(parent.at, []);
					children.get(parent.at).push(entry);
				} else roots.push(entry);
			});
			const out = [];
			const walk = (entry, depth, parent) => {
				out.push({ version: entry.version, index: entry.index, depth, parent });
				for (const child of children.get(entry.version.at) || [])
					walk(child, depth + 1, entry.version);
			};
			for (const root of roots) walk(root, 0, null);
			return out;
		}

		/** The document a saved version holds; a version that no longer reads is refused. */
		function versionDoc(version) {
			const parsed = LayoutSourceIO.parse(version.text);
			if (!parsed.ok) throw { code: parsed.error.code, path: parsed.error.path };
			return parsed.doc;
		}

		/** « Restore »: the version becomes the layout, one step Undo takes back. */
		function restoreVersion(index) {
			const version = versions()[index];
			let next;
			try {
				next = versionDoc(version);
			} catch (error) {
				notify('error', problemText(error));
				return;
			}
			commitFocused();
			state.history.push(next, step('edit_history.step.restore', { name: version.name }));
			state.lastEdit = null;
			state.dirty = true;
			state.historySaid = null;
			resetView(next, null);
			// The layout now comes from this version: the next one saved branches from it.
			const tab = state.tabs[state.active];
			tab.versions = tab.versions.map((other) =>
				other === version ? Object.assign({}, other, { base: true }) : withoutBase(other)
			);
			notify('ok', tl('versions.restored', { name: version.name }));
		}

		/** « Delete »: asked first, the version cannot come back. */
		function deleteVersion(index) {
			const version = versions()[index];
			ask(tl('versions.confirm_delete', { name: version.name }), () => {
				const tab = state.tabs[state.active];
				// Its branches hang from its own parent; its base role goes there too.
				tab.versions = tab.versions
					.filter((_, at) => at !== index)
					.map((other) => {
						if (other.from !== version.at) return other;
						const moved = Object.assign({}, other);
						if (version.from === undefined) delete moved.from;
						else moved.from = version.from;
						return moved;
					})
					.map((other) =>
						version.base && other.at === version.from
							? Object.assign({}, other, { base: true })
							: other
					);
				state.versionShown = null;
				notify('ok', tl('versions.deleted', { name: version.name }));
			});
		}

		/** What a mapping types, in words, for the differences table. */
		function differenceCell(d, mapping) {
			return mapping ? spokenMapping(mapping) || legend(mapping, d) : tl('versions.unmapped');
		}

		/**
		 * The differences of a saved version with the layout shown: one row per
		 * key mapped differently (its layer, its OS when an override differs,
		 * what it typed then and what it types now).
		 */
		function versionDifferences(version) {
			let before;
			try {
				before = versionDoc(version);
			} catch (error) {
				return el('p', { class: 'le-note', role: 'alert', text: problemText(error) });
			}
			const now = doc();
			const heading = el('h3', {
				id: 'le-version-diff-title',
				text: tl('versions.diff_title', { name: version.name })
			});
			if (sourceText(before) === sourceText(now))
				return el('section', { class: 'le-version-diff', id: 'le-version-diff' }, [
					heading,
					el('p', { class: 'le-note', text: tl('versions.same') })
				]);
			// An imported .keylayout keeps its mappings in its XML: only « differs » is known.
			if (LayoutSourceIO.isPreserved(before) || LayoutSourceIO.isPreserved(now))
				return el('section', { class: 'le-version-diff', id: 'le-version-diff' }, [
					heading,
					el('p', { class: 'le-note', text: tl('versions.differs_preserved') })
				]);
			const found = LayoutEditorModel.differences(before, now);
			// A layer by its level's name when the layout shown has it, else by its modifiers.
			const layerTitle = (d, id) => {
				const level = LayoutSourceIO.LEVEL_LAYERS.find((each) => {
					const layer = levelLayer(each);
					return layer !== null && layer.id === id;
				});
				if (level && d === now) return tl(`fill.level.${level.id}`);
				const layer = (d.layers || []).find((entry) => entry.id === id);
				return layer ? layerLabel(layer) : id;
			};
			const rows = found.map((change) => {
				// A layer the version had and the layout lost is named as the version named it.
				const owner = now.layers.some((layer) => layer.id === change.layer) ? now : before;
				const layer = layerTitle(owner, change.layer);
				return el('tr', {}, [
					el('th', { scope: 'row', text: keyName(change.code) }),
					el('td', {
						text: change.scope === 'all' ? layer : `${layer} (${tl(`scope.${change.scope}`)})`
					}),
					el('td', { text: differenceCell(before, change.before) }),
					el('td', { text: differenceCell(now, change.after) })
				]);
			});
			return el('section', { class: 'le-version-diff', id: 'le-version-diff' }, [
				heading,
				el('p', {
					class: 'le-note',
					text: found.length
						? tl('versions.diff_count', { count: found.length })
						: tl('versions.differs_outside_keys')
				}),
				found.length
					? el(
							'section',
							{
								class: 'le-board-table-wrap',
								tabindex: '0',
								'aria-labelledby': 'le-version-diff-title'
							},
							[
								el('table', { id: 'le-version-diff-table' }, [
									el('thead', {}, [
										el('tr', {}, [
											el('th', { scope: 'col', text: tl('board.table_key') }),
											el('th', { scope: 'col', text: tl('versions.col_layer') }),
											el('th', { scope: 'col', text: tl('versions.col_before') }),
											el('th', { scope: 'col', text: tl('versions.col_after') })
										])
									]),
									el('tbody', {}, rows)
								])
							]
						)
					: null
			]);
		}

		/**
		 * « Versions » (an idea seen in the Layouts Wiki playground's Versions
		 * pane): named snapshots of the tab's layout, kept with the tab beside
		 * the undo history, each compared with the layout key by key, restored
		 * as one step Undo takes back, or deleted.
		 */
		function versionsTool() {
			const list = versions();
			const full = list.length >= LayoutEditorWorkspace.MAX_VERSIONS;
			const kept = host.workspace ? 'versions.kept' : 'versions.kept_session';
			const rows = versionTree(list).map(({ version, index, depth, parent }) =>
				el(
					'tr',
					{
						class:
							[
								index === state.versionShown ? 'le-version-shown' : '',
								version.base ? 'le-version-base' : ''
							]
								.filter(Boolean)
								.join(' ') || null
					},
					[
						// Its depth drawn as an indent and a branch mark; its parent said in words.
						el(
							'th',
							{
								scope: 'row',
								class: 'le-version-node',
								style: `--le-version-depth: ${depth}`
							},
							[
								depth > 0
									? el('span', { class: 'le-version-branch', 'aria-hidden': 'true', text: '└ ' })
									: null,
								version.name,
								version.base
									? el('small', { class: 'le-version-current', text: ` ${tl('versions.base')}` })
									: null
							]
						),
						el('td', { text: parent ? parent.name : tl('versions.from_none') }),
						el('td', {}, [
							el('time', {
								datetime: new Date(version.at).toISOString(),
								text: versionTime(version.at)
							})
						]),
						el('td', { class: 'le-version-actions' }, [
							el('button', {
								type: 'button',
								id: `le-version-diff-${index}`,
								text: tl('versions.compare'),
								'aria-label': tl('versions.compare_named', { name: version.name }),
								'aria-pressed': String(index === state.versionShown),
								onclick: () => {
									state.versionShown = state.versionShown === index ? null : index;
									render();
								}
							}),
							el('button', {
								type: 'button',
								id: `le-version-restore-${index}`,
								text: tl('versions.restore'),
								'aria-label': tl('versions.restore_named', { name: version.name }),
								onclick: () => restoreVersion(index)
							}),
							el('button', {
								type: 'button',
								id: `le-version-delete-${index}`,
								text: tl('versions.delete'),
								'aria-label': tl('versions.delete_named', { name: version.name }),
								onclick: () => deleteVersion(index)
							})
						])
					]
				)
			);
			return el('section', { class: 'le-panel le-versions', id: 'le-versions' }, [
				el('h2', { text: tl('tools.versions') }),
				el('p', { class: 'le-note', text: tl('versions.note') }),
				el('p', { class: 'le-note', text: tl(kept, { max: LayoutEditorWorkspace.MAX_VERSIONS }) }),
				el('p', { class: 'le-buttons' }, [
					el('label', { class: 'le-inline' }, [
						tl('versions.name'),
						el('input', {
							type: 'text',
							id: 'le-version-name',
							maxlength: String(LayoutEditorWorkspace.MAX_VERSION_NAME),
							placeholder: tl('versions.default_name', { n: list.length + 1 }),
							value: state.versionName,
							oninput: (event) => {
								state.versionName = event.target.value;
							},
							onkeydown: (event) => {
								if (event.key !== 'Enter') return;
								event.preventDefault();
								saveVersion();
							}
						})
					]),
					el('button', {
						type: 'button',
						id: 'le-version-save',
						class: 'primary',
						text: tl('versions.save'),
						disabled: full,
						onclick: saveVersion
					})
				]),
				list.length
					? el(
							'section',
							{ class: 'le-board-table-wrap', tabindex: '0', 'aria-label': tl('versions.list') },
							[
								el('table', { id: 'le-versions-table' }, [
									el('caption', { class: 'theme-sr-only', text: tl('versions.list') }),
									el('thead', {}, [
										el('tr', {}, [
											el('th', { scope: 'col', text: tl('versions.col_name') }),
											el('th', { scope: 'col', text: tl('versions.col_from') }),
											el('th', { scope: 'col', text: tl('versions.col_time') }),
											el('th', { scope: 'col', text: tl('versions.col_actions') })
										])
									]),
									el('tbody', {}, rows)
								])
							]
						)
					: el('p', { class: 'le-note', id: 'le-versions-empty', text: tl('versions.empty') }),
				state.versionShown !== null && list[state.versionShown]
					? versionDifferences(list[state.versionShown])
					: null
			]);
		}

		/**
		 * « Help » (an idea seen in the Layouts Wiki playground's Docs pane): the
		 * editor's common tasks in a few lines each, one titled section per task.
		 */
		function helpTool() {
			return el('section', { class: 'le-panel le-help', id: 'le-help' }, [
				el('h2', { text: tl('tools.help') }),
				el('p', { class: 'le-note', text: tl('help.intro') }),
				...HELP_TOPICS.map((id) =>
					el('section', { class: 'le-help-topic', 'aria-labelledby': `le-help-${id}` }, [
						el('h3', { id: `le-help-${id}`, text: tl(`help.${id}_title`) }),
						el('p', { text: tl(`help.${id}_text`) })
					])
				),
				el('p', { class: 'le-note', text: tl('help.credit') })
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
				versions: versionsTool,
				layers: preserved ? null : layersTool,
				modifiers: preserved ? null : modifiersPanel,
				dead_keys: preserved ? null : deadKeysPanel,
				fill: preserved ? null : fillPanel,
				navigation: navigationTool,
				windows: preserved ? null : windowsPanel,
				export: exportPanel,
				stickers: stickersTool,
				help: helpTool
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
					tabindex: id === active ? '0' : '-1',
					text: tl(`tools.${id}`),
					onclick: () => showTool(id),
					onkeydown: tabListKeys
				})
			);
			return el('section', { class: 'le-tools', id: 'le-tools' }, [
				el(
					'div',
					{ class: 'le-tool-tabs', role: 'tablist', 'aria-label': tl('tools.label') },
					tabs
				),
				el(
					'section',
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
			apply(
				(d) =>
					LayoutEditorModel.setMapping(
						d,
						state.layer,
						code,
						state.clipboard,
						state.platform || null
					),
				step('edit_history.step.change_key', { key: keyName(code) })
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

		/**
		 * The arrow keys, Home and End on a focused key move the focus over the
		 * board as it is drawn (Enter or Space then chooses the key): left and
		 * right along the key's row, up and down to the nearest row above or
		 * below, to the key closest under the key's centre; Home and End to the
		 * ends of the row. The board is one Tab stop, so this is how a keyboard
		 * reaches every key.
		 * @param {KeyboardEvent} event - A keydown on a board key.
		 * @param {string} code - The focused key.
		 * @param {Map<string, {x: number, y: number, w: number, h: number}>} places - Each drawn key's box, in key units.
		 */
		function boardKeys(event, code, places) {
			if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
			const from = places.get(code);
			if (!from) return;
			// The row a key is in: the middle of its top unit (a two-row key is in its top row).
			const row = from.y + 0.5;
			const centre = from.x + from.w / 2;
			const inRow = [...places].filter(([, p]) => p.y <= row && row < p.y + p.h);
			const middle = (p) => p.x + p.w / 2;
			let candidates = [];
			if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
				const sign = event.key === 'ArrowRight' ? 1 : -1;
				candidates = inRow
					.filter(([, p]) => sign * (middle(p) - centre) > 0)
					.sort(([, a], [, b]) => sign * (middle(a) - middle(b)));
			} else if (event.key === 'Home' || event.key === 'End') {
				candidates = inRow.sort(([, a], [, b]) => (event.key === 'Home' ? a.x - b.x : b.x - a.x));
			} else if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
				const up = event.key === 'ArrowUp';
				const gap = (p) => (up ? from.y - (p.y + p.h) : p.y - (from.y + from.h));
				// How far the centre is from a key's span, 0 when the key is under it.
				const aside = (p) => Math.max(0, p.x - centre, centre - (p.x + p.w));
				candidates = [...places]
					.filter(([, p]) => gap(p) > -0.01)
					.sort(([, a], [, b]) => gap(a) - gap(b) || aside(a) - aside(b));
				if (candidates.length) {
					const nearest = gap(candidates[0][1]);
					candidates = candidates
						.filter(([, p]) => gap(p) - nearest < 0.01)
						.sort(([, a], [, b]) => aside(a) - aside(b) || middle(a) - middle(b));
				}
			} else return;
			event.preventDefault();
			const next = candidates.find(([other]) => other !== code);
			if (!next) return;
			const button = root.querySelector(`#le-board .le-key[data-code="${CSS.escape(next[0])}"]`);
			if (button) button.focus();
		}

		/** The board drawn: the one chosen, else the keyboard the source is for. */
		function boardForm() {
			return state.board || doc().physical.keyboard || 'iso';
		}

		function board() {
			const form = boardForm();
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
				style: `--le-cols:${width};--le-rows:${height}`,
				// The keys as one toolbar named by the layout; one Tab stop, the
				// arrows walk it (boardKeys).
				role: 'toolbar',
				'aria-label': doc().layout.name
			});
			const remap = doc().remap || {};
			const places = new Map(
				keys.map((k) => {
					const g = k.geometry[form];
					return [k.code, { x: g.col, y: g.row, w: g.width, h: g.height || 1 }];
				})
			);
			// The key the Tab key enters the board on: the last one focused, else
			// the selected one, else the first.
			const entry = [state.boardFocus, state.selected].find((code) => places.has(code));
			const roving = entry || keys[0].code;
			const positions = boardPositions(keys, form);
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
				// The ISO Enter is drawn as its L (key_shape.js), not as a tall rectangle.
				const shape = KEY_SHAPE.isTwoRowL(g) ? KEY_SHAPE.lPath(g, BOARD_DRAWING) : null;
				if (shape) classes.push('le-key-l');
				const codeText = key.character || keyName(key.code) === key.code ? '' : keyName(key.code);
				const accessibleName = keyAccessibleName(
					key,
					[label, codeText].filter(Boolean).join(' '),
					positions.get(key.code),
					state.shortcutView ? shortcutTitle(key.code, actsAs, overrides).replace(/\n/g, ', ') : ''
				);
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
							'aria-label': accessibleName,
							'data-label': accessibleName,
							style:
								`--x:${g.col};--y:${g.row - top};--w:${g.width};--h:${g.height || 1}` +
								(shape
									? `;--notch-x:${shape.notchX / shape.width};--notch-y:${shape.notchY / shape.height}`
									: ''),
							draggable: editableLayer() ? 'true' : null,
							onclick: () => {
								// « Pick on the board »: this click chooses the key to act as.
								const picking = state.pickingShortcutKey;
								if (picking) {
									state.pickingShortcutKey = null;
									if (key.code !== picking)
										return apply(
											(d) => LayoutEditorModel.setShortcutKey(d, picking, key.code),
											step('edit_history.step.shortcut', { key: keyName(picking) })
										);
									return render();
								}
								state.selected = key.code;
								render();
							},
							tabindex: key.code === roving ? '0' : '-1',
							onkeydown: (event) => {
								clipboardKey(event, key.code);
								if (!event.defaultPrevented) boardKeys(event, key.code, places);
							},
							onfocusin: () => {
								state.boardFocus = key.code;
								for (const other of container.querySelectorAll('.le-key[data-code]'))
									other.tabIndex = other.dataset.code === key.code ? 0 : -1;
							},
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
									return apply(
										(d) =>
											LayoutEditorModel.setMapping(
												d,
												state.layer,
												key.code,
												{ text: char },
												state.platform || null
											),
										step('edit_history.step.change_key', { key: keyName(key.code) })
									);
								const from = event.dataTransfer.getData('text/plain');
								if (!from) return;
								const keep = event.ctrlKey || event.altKey;
								apply(
									(d) =>
										LayoutEditorModel.transferMapping(
											d,
											state.layer,
											from,
											key.code,
											state.platform || null,
											keep
										),
									(d) =>
										step('edit_history.step.move_keys', {
											keys: moveName(state.layer, [from, key.code], keep)(d)
										}),
									moveName(state.layer, [from, key.code], keep)
								);
							}
						},
						[
							shape ? keyOutline(shape) : null,
							el('span', {
								class:
									!state.shortcutView && isDeadKey(found && found.mapping)
										? `le-legend ${KEY_LEGEND.DEAD_KEY_CLASS}`
										: 'le-legend',
								text: label
							}),
							// Unrendered between flex items, the space keeps the two texts two
							// words in the visible text the accessible name starts with.
							' ',
							// Only a key with a printed name (Tab, Shift, Esc) shows it: a character
							// key shows the selected layer's value alone, never the base character
							// or its raw code; the tooltip still names it.
							el('span', { class: 'le-code', text: codeText })
						]
					)
				);
			}
			const media = data.keys.filter((k) => k.kind === 'key' && !k.geometry);
			const mediaRow = el(
				'p',
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
				mediaRow,
				// The drawing as a PNG or SVG image (board_image.js), heat colours included.
				typeof window.LAYOUT_BOARD_IMAGE === 'object'
					? window.LAYOUT_BOARD_IMAGE.buttons({
							id: 'le-board-image',
							board: () => root.querySelector('#le-board'),
							options: () => ({
								title: doc().layout.name,
								legend: '.le-legend, .le-code',
								words: [doc().layout.name]
							})
						})
					: null,
				boardTable(keys, form, positions)
			]);
		}

		/**
		 * The layout as a table, the drawing's text alternative: one row per
		 * drawn key in reading order (its name and place), one column per
		 * layer, each cell what the key does there in words. Built only while
		 * unfolded, so a closed table costs no render time.
		 */
		function boardTable(keys, form, positions) {
			const box = el('details', {
				class: 'le-board-table',
				id: 'le-board-table',
				open: state.boardTableOpen,
				ontoggle: (event) => {
					if (state.boardTableOpen === event.target.open) return;
					state.boardTableOpen = event.target.open;
					render();
				}
			});
			box.append(el('summary', { text: tl('board.table') }));
			if (!state.boardTableOpen) return box;
			const layers = LayoutSourceIO.isPreserved(doc()) ? [] : LayoutEditorModel.layers(doc());
			const head = el('tr', {}, [
				el('th', { scope: 'col', text: tl('board.table_key') }),
				...layers.map((layer) => el('th', { scope: 'col', text: layerName(layer) }))
			]);
			const ordered = keys.slice().sort((a, b) => {
				const ga = a.geometry[form];
				const gb = b.geometry[form];
				return ga.row - gb.row || ga.col - gb.col;
			});
			const body = ordered.map((key) =>
				el('tr', {}, [
					el('th', { scope: 'row', text: `${keyName(key.code)} (${positions.get(key.code)})` }),
					...layers.map((layer) => {
						const found = LayoutEditorModel.mappingAt(
							doc(),
							layer.id,
							key.code,
							state.platform || null
						);
						return el('td', { text: found ? spokenMapping(found.mapping) : '' });
					})
				])
			);
			box.append(
				el(
					'section',
					{
						class: 'le-board-table-wrap',
						tabindex: '0',
						'aria-label': tl('board.table')
					},
					[el('table', {}, [el('thead', {}, head), el('tbody', {}, body)])]
				)
			);
			return box;
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
				if (kind === 'key') area.append(fields.key, el('p', { class: 'le-checks' }, sendModifiers));
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
			return el('section', { class: 'le-group' }, [
				el('h3', {
					text: tl('inspector.mapping', {
						layer: state.layer,
						scope: state.platform ? tl(`scope.${state.platform}`) : tl('scope.all')
					})
				}),
				kindSelect,
				area,
				el('p', { class: 'le-checks' }, [
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
						apply(
							(d) =>
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
										),
							step('edit_history.step.change_key', { key: keyName(code) }),
							(d) => `${keyChar(d, state.layer, code)} → ${legend(built(), d) || keyName(code)}`
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
				swapControl(code, keyOptions),
				el('p', { class: 'le-note', text: tl('drag_hint') })
			]);
		}

		/**
		 * The click and keyboard way to do what dropping a key on another does
		 * (WCAG 2.5.7, dragging movements): choose the other key, then swap the
		 * two on this layer. Copying is Copy then Paste.
		 */
		function swapControl(code, keyOptions) {
			const target = select(
				keyOptions.filter(([other]) => other !== code),
				null,
				() => {},
				{ id: 'le-swap-target' }
			);
			return el('p', { class: 'le-inline le-swap' }, [
				el('label', { for: 'le-swap-target', text: tl('swap.label') }),
				target,
				el('button', {
					type: 'button',
					id: 'le-swap',
					text: tl('swap.button'),
					onclick: () =>
						apply(
							(d) =>
								LayoutEditorModel.transferMapping(
									d,
									state.layer,
									code,
									target.value,
									state.platform || null,
									false
								),
							(d) =>
								step('edit_history.step.move_keys', {
									keys: moveName(state.layer, [code, target.value], false)(d)
								}),
							moveName(state.layer, [code, target.value], false)
						)
				})
			]);
		}

		/** Where a character is typed in the source: every layer and key whose text holds it. */
		function locate() {
			const input = el('input', {
				type: 'text',
				id: 'le-locate',
				size: 8,
				placeholder: tl('palette.locate_placeholder'),
				'aria-label': tl('palette.locate_placeholder')
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
			return el('search', { class: 'le-inline le-locate', 'aria-label': tl('palette.locate') }, [
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
			const grid = el('ul', { class: 'le-palette-grid', id: 'le-palette' });
			for (let point = block.from; point <= block.to; point++) {
				const char = String.fromCodePoint(point);
				grid.append(
					el(
						'li',
						{},
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
					)
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
				return el(
					'section',
					{ class: 'le-magnifier', id: 'le-magnifier', 'aria-labelledby': 'le-magnifier-title' },
					[
						el('h3', { id: 'le-magnifier-title', text: tl('magnifier.title') }),
						el('p', { class: 'le-note', text: tl('magnifier.hint') })
					]
				);
			const named = UnicodeNames.available();
			const rows = Array.from(text).map((char) => {
				const point = char.codePointAt(0);
				const name = named ? UnicodeNames.nameOf(point) : null;
				const block = named ? UnicodeNames.blockOf(point) : null;
				return el('li', { class: 'le-magnifier-row' }, [
					el('code', { text: UnicodeNames.codeLabel(point) }),
					' ',
					el('small', {
						class: 'le-magnifier-name',
						text: named
							? name || tl('magnifier.unnamed')
							: tl(state.nameSearch.failed ? 'names.unavailable' : 'names.loading')
					}),
					block ? el('small', { class: 'le-magnifier-block', text: ` · ${block}` }) : null
				]);
			});
			return el(
				'section',
				{ class: 'le-magnifier', id: 'le-magnifier', 'aria-labelledby': 'le-magnifier-title' },
				[
					el('h3', { id: 'le-magnifier-title', text: tl('magnifier.title') }),
					el('p', {
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
				]
			);
		}

		/** The search's answer as clickable cells, or its state. */
		function nameResults(box, target) {
			const search = state.nameSearch;
			box.replaceChildren();
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
					'ul',
					{ class: 'le-palette-grid' },
					results.map((result) =>
						el(
							'li',
							{},
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
			const box = nameResults(
				el('div', { class: 'le-name-results', id: 'le-name-results' }),
				target
			);
			function run() {
				search.query = query.value;
				search.limit = Math.min(
					Math.max(1, Math.floor(Number(limit.value) || UnicodeNames.DEFAULT_LIMIT)),
					UnicodeNames.MAX_LIMIT
				);
				limit.value = search.limit;
				box.replaceChildren(el('p', { class: 'le-note', text: tl('names.loading') }));
				withNames(() => {
					if (!search.failed) search.answer = UnicodeNames.search(search.query, search.limit);
					nameResults(box, target);
				});
			}
			return el('search', { class: 'le-name-search', 'aria-label': tl('names.search') }, [
				el('label', { class: 'le-inline' }, [tl('names.label'), query]),
				el('label', { class: 'le-inline' }, [tl('names.limit'), limit]),
				el('button', {
					type: 'button',
					id: 'le-name-search-run',
					text: tl('names.search'),
					onclick: run
				}),
				el('p', { class: 'le-note', text: tl('names.help') }),
				box
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
						apply(
							(d) => LayoutEditorModel.setKeyProperties(d, code, properties),
							step('edit_history.step.key_properties', { key: keyName(code) })
						);
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
						apply(
							(d) => LayoutEditorModel.setRemap(d, code, value === '__none' ? null : value),
							step('edit_history.step.remap', { key: keyName(code) })
						),
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
							'section',
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
					apply(
						(d) => LayoutEditorModel.setShortcutKey(d, code, value === '' ? null : value),
						step('edit_history.step.shortcut', { key: keyName(code) })
					),
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
							`${chordLabel(s.modifiers, s.key)} → ${chordLabel(s.send_modifiers, s.send_key)} `,
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
								onclick: () =>
									apply(
										(d) => LayoutEditorModel.removeShortcut(d, s.key, s.modifiers),
										step('edit_history.step.shortcut', { key: keyName(s.key) })
									)
							})
						])
					)
				),
				el('p', { class: 'le-note', id: 'le-shortcut-from-label', text: tl('shortcut.when') }),
				el(
					'p',
					{
						class: 'le-checks',
						id: 'le-shortcut-from',
						role: 'group',
						'aria-labelledby': 'le-shortcut-from-label'
					},
					from
				),
				el('p', { class: 'le-note', id: 'le-shortcut-to-label', text: tl('shortcut.sends') }),
				sendKey,
				el(
					'p',
					{
						class: 'le-checks',
						id: 'le-shortcut-to',
						role: 'group',
						'aria-labelledby': 'le-shortcut-to-label'
					},
					to
				),
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
						apply(
							(d) => {
								const base = replaced
									? LayoutEditorModel.removeShortcut(d, code, replaced.modifiers)
									: d;
								return LayoutEditorModel.setShortcut(base, {
									key: code,
									modifiers,
									send_key: chord.send_key,
									send_modifiers: chord.send_modifiers
								});
							},
							step('edit_history.step.shortcut', { key: keyName(code) })
						);
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
						apply(
							(d) => LayoutEditorModel.setTapHold(d, next),
							step('edit_history.step.tap_hold', { key: keyName(code) })
						);
					}
				}),
				entry
					? el('button', {
							type: 'button',
							class: 'danger',
							id: 'le-tap-hold-remove',
							text: tl('btn.remove'),
							onclick: () =>
								apply(
									(d) => LayoutEditorModel.removeTapHold(d, code),
									step('edit_history.step.tap_hold', { key: keyName(code) })
								)
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
				el('p', { class: 'le-buttons' }, choices),
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
			return el('section', { class: 'le-start-library' }, [
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
							apply(
								(d) => LayoutSourceIO.fillLayer(d, chosen, level.value, layerId),
								step('edit_history.step.fill_level', { level: layerId })
							)
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
						apply(
							(d) => LayoutEditorModel.setExport(d, 'windows', empty ? null : values),
							step('edit_history.step.export')
						);
					}
				}),
				el('p', { class: 'le-note', text: tl('windows.note') }),
				el('label', { class: 'le-field' }, [tl('windows.flags'), flags]),
				el('button', {
					type: 'button',
					id: 'le-win-flags-apply',
					text: tl('btn.apply'),
					onclick: () =>
						apply(
							(d) =>
								LayoutEditorModel.setWindowsFlags(d, flags.value.split(/[\s,]+/).filter(Boolean)),
							step('edit_history.step.export')
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
									apply(
										(d) => LayoutEditorModel.removeNls(d, entry.key, entry.modifiers),
										step('edit_history.step.export')
									)
							})
						])
					)
				),
				key,
				el('p', { class: 'le-checks' }, modifiers),
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
						apply((d) => LayoutEditorModel.setNls(d, entry), step('edit_history.step.export'));
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
								onclick: () =>
									apply(
										(d) => LayoutEditorModel.removeModifier(d, m.id),
										step('edit_history.step.modifier', { name: m.id })
									)
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
						apply(
							(d) =>
								LayoutEditorModel.setModifier(
									d,
									id.value.trim(),
									mode.value,
									keys.value.split(/[\s,]+/).filter(Boolean)
								),
							step('edit_history.step.modifier', { name: id.value.trim() })
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
					'p',
					{ class: 'le-tabs' },
					deadKeys.map((d) =>
						el('button', {
							type: 'button',
							class: `le-tab${current && current.id === d.id ? ' active' : ''}`,
							// The dead key edited below, said in words as well as drawn.
							'aria-current': current && current.id === d.id ? 'true' : null,
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
						apply(
							(d) => LayoutEditorModel.setDeadKey(d, newId, '', terminator.value),
							step('edit_history.step.dead_key', { name: newId })
						);
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
											apply(
												(d) => LayoutEditorModel.setDeadRule(d, current.id, rule.input, null),
												step('edit_history.step.dead_key', { name: current.id })
											)
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
							apply(
								(d) =>
									LayoutEditorModel.setDeadRule(
										d,
										current.id,
										input.value,
										chain.value ? { next: chain.value } : { text: output.value }
									),
								step('edit_history.step.dead_key', { name: current.id })
							)
					}),
					el('button', {
						type: 'button',
						class: 'danger',
						id: 'le-dead-remove',
						text: tl('dead.remove', { id: current.id }),
						onclick: () => {
							apply(
								(d) => LayoutEditorModel.removeDeadKey(d, current.id),
								step('edit_history.step.dead_key', { name: current.id })
							);
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
					// Tab and Shift+Tab move the focus on, as from any field: the
					// field simulated them too, so the keyboard could enter it but
					// never leave (WCAG 2.1.2, found by the Studio keyboard walk).
					if (event.key === 'Tab' && !event.ctrlKey && !event.altKey && !event.metaKey) return;
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

		/** The export report's row of this host's driver, which says whether it can take the source. */
		const driverRow = (report) =>
			report.find((entry) => entry.target === `driver_${host.platform}`);

		/**
		 * Installs the source through the ErgoptiPlus composer host and switches
		 * to it, once the user agrees; a driver that cannot take it says why.
		 */
		function install(report) {
			const row = driverRow(report);
			if (!row || row.status === 'unavailable') {
				notify(
					'error',
					row && row.reason ? reasonText(row.reason) : tl('export.driver_unavailable')
				);
				return;
			}
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
			});
		}

		/**
		 * « Emulate without installing »: the driver's emulation types the source
		 * over the system layout, once the user agrees.
		 */
		function emulate(report) {
			const row = driverRow(report);
			if (!row || row.status === 'unavailable') {
				notify(
					'error',
					row && row.reason ? reasonText(row.reason) : tl('export.driver_unavailable')
				);
				return;
			}
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
			});
		}

		function installButton(report) {
			const row = driverRow(report);
			return el('button', {
				type: 'button',
				id: 'le-install',
				class: 'primary',
				text: tl('btn.install'),
				disabled: !row || row.status === 'unavailable',
				onclick: () => install(report)
			});
		}

		function emulateButton(report) {
			const row = driverRow(report);
			return el('button', {
				type: 'button',
				id: 'le-emulate',
				text: tl('btn.emulate'),
				disabled: !row || row.status === 'unavailable',
				onclick: () => emulate(report)
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

		// The export tool's actions as last drawn: openLayout's intent runs them.
		let exportActions = null;

		function exportPanel() {
			exportActions = null;
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
			// Every download the layout has, in one « Format » drop-down with one
			// « Download » button (maintainer decision, 2026-11-15); each entry is
			// offered only when this host can produce it, and says why when it fails.
			const downloads = [];
			const offer = (id, run) => {
				// One list of downloads for the Studio (the optimizer's « get it » names them too).
				if (!window.LAYOUT_ANALYSIS_FILES.EDITOR_DOWNLOADS.includes(id))
					throw new Error(`layout_editor: the download ${id} is not in EDITOR_DOWNLOADS`);
				downloads.push({ id, run });
			};
			const saveBytes = (file, mime) =>
				fromHost(() => host.saveBinary(file.filename, file.bytes, mime)).then(
					() => notify('ok', tl('status.saved', { name: file.filename })),
					(error) => notify('error', problemText(error))
				);
			offer('toml', saveSource);
			const preserved = LayoutSourceIO.isPreserved(doc());
			// macOS: the bundle, or one .keylayout per board; an imported .keylayout
			// stays verbatim, so only its own variant is offered.
			for (const variant of preserved ? [doc().imported_keylayout.convention] : MACOS_EXPORTS) {
				let macos = null;
				try {
					macos = LayoutSourceIO.macosDownload(doc(), variant);
				} catch (error) {
					// Not producible here; the macOS report row says why.
				}
				// A ZIP needs a host that saves bytes; the webview hosts install the layout instead.
				if (macos && (macos.text !== undefined || host.saveBinary))
					offer(`macos_${variant}`, () =>
						macos.text !== undefined
							? save(macos.filename, macos.text, macos.mime)
							: saveBytes(macos, macos.mime)
					);
			}
			if (host.exportAssets && host.saveBinary)
				for (const [target, build, mime] of [
					['xkb', LayoutSourceIO.xkbArchive, 'application/zip'],
					['klc', LayoutSourceIO.klcFile, 'application/octet-stream']
				])
					offer(target, () => {
						// The host loads the converters on the first download; the build runs on the current source.
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
					});
			// The Windows installable package: the four DLL images, written in the page
			// (no compiler), with the generic installer and its layout.ini.
			if (host.saveBinary && !preserved)
				offer('dll', () => {
					let file;
					try {
						file = LayoutSourceIO.windowsPackage(doc());
					} catch (error) {
						notify('error', problemText(error));
						return;
					}
					saveBytes(file, 'application/zip');
				});
			// Interoperability (coordinator, 2026-11-14): the KLA / KLAnext JSON,
			// Kalamine TOML, Oxeylyzer DOF, genkey and cmini files of the layout,
			// each saying what it cannot hold. Every extension is one the app's
			// hosts write (source.export_extensions of the layout defaults).
			if (!preserved)
				for (const [target, write, extension, mime] of [
					['kla', klaExport, 'kla.json', 'application/json'],
					['kalamine', LAYOUT_FORMATS.toKalamineToml, 'kalamine.toml', 'application/toml'],
					['dof', LAYOUT_FORMATS.toDof, 'dof', 'application/json'],
					['genkey', LAYOUT_FORMATS.toGenkey, 'genkey.txt', 'text/plain'],
					['cmini', LAYOUT_FORMATS.toCmini, 'cmini.json', 'application/json']
				])
					offer(target, () => {
						let file;
						try {
							file = write(LAYOUT_ANALYSIS_PANEL.layoutFromEditorDoc(doc()));
						} catch (error) {
							notify('error', problemText(error));
							return;
						}
						const filename = `${doc().layout.id}.${extension}`;
						// A download, not a file of the app's layout store: the app's
						// store keeps only sources, so the app writes it to Downloads.
						fromHost(() =>
							host.saveBinary
								? host.saveBinary(filename, new TextEncoder().encode(file.text), mime)
								: host.saveFile(filename, file.text, mime)
						).then(
							() =>
								notify(
									'ok',
									file.unmapped.length === 0
										? tl('status.saved', { name: filename })
										: tl('status.saved_partial', {
												name: filename,
												count: file.unmapped.length,
												list: lossList(file.unmapped)
											})
								),
							(error) => notify('error', problemText(error))
						);
					});
			const hasNav = (doc().layers || []).some((l) => l.id === LayoutSourceIO.NAV_LAYER);
			if (hasNav)
				offer('nav', () => {
					try {
						save('layers.toml', LayoutSourceIO.navLayerFile(doc(), data), 'application/toml');
					} catch (error) {
						notify('error', problemText(error));
					}
				});
			// The viewer's last choice when this layout offers it, else the first download.
			const chosen = downloads.find((entry) => entry.id === state.exportFormat) || downloads[0];
			// What another Studio tool may ask of this layout (openLayout's intent).
			exportActions = {
				download(id) {
					const entry = downloads.find((candidate) => candidate.id === id);
					if (!entry) {
						notify('error', tl('export.unavailable', { format: tl(`export.option.${id}`) }));
						return;
					}
					entry.run();
				},
				install: host.install ? () => install(report) : null,
				emulate: host.emulate ? () => emulate(report) : null
			};
			const actions = [];
			// The two ways ErgoptiPlus uses a layout, each said in one line.
			if (host.install) actions.push(installButton(report));
			if (host.emulate) actions.push(emulateButton(report));
			// The driver applies the navigation layer through its navigation layer editor's save.
			if (host.applyNav && hasNav)
				actions.push(
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
			return el('section', { class: 'le-export', id: 'le-export' }, [
				el('h2', { text: tl('export.title') }),
				el('table', { class: 'le-report', id: 'le-report' }, rows),
				shortcutExportNote(report),
				el('p', { class: 'le-note', text: tl('export.bundle_note') }),
				el('p', { class: 'le-note', id: 'le-dll-note', text: tl('export.windows_dll_note') }),
				// KbdEdit encrypts its .kbe (layout_formats.js, KBE_SIGNATURE): say where to go instead.
				el('p', { class: 'le-note', id: 'le-kbe-note', text: tl('export.kbe_note') }),
				host.exportAssets ? null : el('p', { class: 'le-note', text: tl('export.targets_note') }),
				el('p', { class: 'le-buttons le-export-download' }, [
					el('label', { class: 'le-inline' }, [
						tl('export.format'),
						select(
							downloads.map((entry) => [entry.id, tl(`export.option.${entry.id}`)]),
							chosen.id,
							(value) => {
								// Kept without a redraw: the drop-down already shows it.
								state.exportFormat = value;
								rememberExportFormat(value);
							},
							{ id: 'le-export-format' }
						)
					]),
					el('button', {
						type: 'button',
						id: 'le-export-download',
						text: tl('export.download'),
						onclick: () => {
							const id = document.getElementById('le-export-format').value;
							const entry = downloads.find((candidate) => candidate.id === id);
							entry.run();
						}
					})
				]),
				actions.length ? el('p', { class: 'le-buttons' }, actions) : null,
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
			return el('section', { class: 'le-subpanel', id: 'le-sticker-levels' }, [
				el('h3', { text: tl('sticker.levels') }),
				el(
					'p',
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
			const anchor = focusAnchor(document.activeElement);
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
			restoreFocus(anchor);
		}

		// The attributes that name one control across renders, after its id.
		const FOCUS_HOOKS = Object.freeze([
			'data-code',
			'data-tab',
			'data-duplicate-tab',
			'data-close-tab',
			'data-tool',
			'data-layer',
			'data-level',
			'data-dead',
			'data-start'
		]);

		/**
		 * The focused control and its selector in the next tree, or null when
		 * the focus is outside the editor or in a text field (a field commits on
		 * blur and keeps its own undo: it is not focused again behind the user).
		 * @param {Element|null} node - The focused element before a render.
		 * @returns {{node: Element, selector: string|null}|null}
		 */
		function focusAnchor(node) {
			if (!node || node === root || !root.contains(node) || ERGOPTI_EDIT_HISTORY.inTextField(node))
				return null;
			if (node.id) return { node, selector: `#${CSS.escape(node.id)}` };
			const hook = FOCUS_HOOKS.find((name) => node.hasAttribute(name));
			return {
				node,
				selector: hook ? `[${hook}="${CSS.escape(node.getAttribute(hook))}"]` : null
			};
		}

		/**
		 * Gives the focus back after a render replaced the focused control (a
		 * key chosen with Enter, a tab chosen with an arrow, a drop-down that
		 * redraws the page): a keyboard user stays where they were instead of
		 * starting again from the top of the page. The same node when the render
		 * kept it (the host's side panel), else its counterpart in the new tree.
		 * A focus the render did not take (a field focused on purpose) is left alone.
		 * @param {{node: Element, selector: string|null}|null} anchor - From focusAnchor.
		 */
		function restoreFocus(anchor) {
			const now = document.activeElement;
			if (!anchor || (now && now !== document.body && now !== document.documentElement)) return;
			const target = anchor.node.isConnected
				? anchor.node
				: anchor.selector && root.querySelector(anchor.selector);
			if (target) target.focus({ preventScroll: true });
		}

		function renderTree() {
			keyView = makeKeyView(doc(), state.platform || host.platform || null);
			// Undo or redo can remove the layer shown: show the base layer then.
			const ids = (doc().layers || []).map((layer) => layer.id);
			if (state.layer && !ids.includes(state.layer))
				state.layer = ids.includes('base') ? 'base' : null;
			const parts = [
				// The page's one h1, for a screen reader's outline: the tabs show the documents.
				el('h1', { class: 'le-sr-only', text: tl('heading') }),
				tabBar(),
				toolbar(),
				startPanel(),
				messageBar(),
				layerBar(),
				analysisPanel ? scoreChip : null,
				el('div', { class: 'le-workspace' }, [
					el('div', { class: 'le-board-col' }, [board(), preview()]),
					el('aside', { class: 'le-inspector-col', 'aria-label': tl('inspector.key') }, [
						inspector(),
						magnifier()
					]),
					sideSlot
				]),
				tools(),
				stickers()
			];
			// A section a state hides is null: it must not reach the page as text.
			root.replaceChildren(...parts.filter(Boolean));
			fitLegends();
			observeKeyNames();
			applyHeat();
			placeScoreChip();
			root.dispatchEvent(new CustomEvent('layout-editor:rendered', { detail: { doc: doc() } }));
			if (analysisPanel) analysisPanel.update(doc(), lineage());
			scheduleAutosave();
			schedulePublish();
		}

		// The Comparer lists the layouts open here (its personal layouts): each
		// tab's analysis layout, sent after the same delay as the autosave.
		const comparerLayouts = new WeakMap();
		let publishTimer = null;
		let published = null;
		// The entry each tab was last published under (null: not analysed).
		let publishedEntries = [];
		function schedulePublish() {
			if (!analysisPanel || !window.LAYOUT_ANALYSIS_FILES) return;
			clearTimeout(publishTimer);
			publishTimer = setTimeout(publishLayouts, LayoutEditorWorkspace.AUTOSAVE_DELAY_MS);
		}

		/** Sends the open tabs to the Comparer; a tab the analysis cannot read is left out. */
		function publishLayouts() {
			keepActive();
			const ids = new Set();
			const layouts = [];
			publishedEntries = state.tabs.map(() => null);
			state.tabs.forEach((tab, index) => {
				const document = tabAt(index).history.current();
				if (!comparerLayouts.has(document)) {
					let layout = null;
					try {
						layout = window.LAYOUT_ANALYSIS_PANEL.layoutFromEditorDoc(document);
					} catch (error) {
						// Its own tab says why (the panel); the Comparer just lacks it.
						console.warn(
							`layout editor: tab ${index} is not analysed (${error.code || error.message})`
						);
					}
					comparerLayouts.set(document, layout);
				}
				const layout = comparerLayouts.get(document);
				if (!layout) return;
				let id = `editor_${document.layout.id}`;
				for (let n = 2; ids.has(id); n++) id = `editor_${document.layout.id}_${n}`;
				ids.add(id);
				publishedEntries[index] = Object.assign({}, layout, { id, name: document.layout.name });
				layouts.push(publishedEntries[index]);
			});
			const text = JSON.stringify(layouts);
			if (text === published) return;
			published = text;
			window.LAYOUT_ANALYSIS_FILES.publishEditorLayouts(layouts);
		}

		/**
		 * « Compare with other layouts »: the host receives the shown tab under the
		 * editor_… id the Comparer already lists it by, so it is ticked there and
		 * never listed twice. Only a tab that could not be published (no Comparer
		 * file helpers on the page) goes as the panel's own copy, and the console
		 * says why.
		 * @param {object} layout - The analysis panel's layout (library shape).
		 */
		function compareActive(layout) {
			clearTimeout(publishTimer);
			publishTimer = null;
			if (window.LAYOUT_ANALYSIS_FILES) publishLayouts();
			const entry = publishedEntries[state.active] || null;
			if (!entry)
				console.warn(
					'layout editor: the shown tab is not published to the Comparer, so it is compared as a copy'
				);
			host.compare(entry || layout);
		}

		/**
		 * « Optimize this layout »: the host receives the shown tab under the
		 * editor_… id the Optimiser lists it by, published first, so the
		 * Optimiser can choose it as its start.
		 * @param {object} layout - The analysis panel's layout (library shape).
		 * @throws {Error} When the tab could not be published: the Optimiser
		 *   would have nothing to start from.
		 */
		function optimizeActive(layout) {
			clearTimeout(publishTimer);
			publishTimer = null;
			publishLayouts();
			const entry = publishedEntries[state.active];
			if (!entry)
				throw new Error(
					`layout editor: the shown tab (${layout.id}) is not published to the Optimiser`
				);
			host.optimize(entry);
		}

		/**
		 * The height a legend may take in its key: the key's content box less the
		 * key-name label above it. A reader's wider line spacing (WCAG 1.4.12, the
		 * site's « wide » spacing) makes both lines taller than the key, whose
		 * bottom edge then cut the legend.
		 * @param {HTMLElement} legend
		 * @returns {number} Pixels, 0 when the key is not laid out.
		 */
		function legendRoom(legend) {
			const key = legend.parentElement;
			const style = getComputedStyle(key);
			const code = key.querySelector('.le-code');
			return Math.max(
				0,
				key.clientHeight -
					parseFloat(style.paddingTop) -
					parseFloat(style.paddingBottom) -
					(code ? code.offsetHeight : 0)
			);
		}

		/**
		 * Fits every key label inside its key: the font shrinks in proportion to the
		 * overflow, in width and in height, down to LEGEND_MIN_PX, then a label
		 * still too long is cut with an ellipsis (the key's title holds it whole).
		 * A board not laid out yet (a hidden frame) is measured at the next resize,
		 * and keeps the sizes it was last fitted to: resetting them there left the
		 * legends unfitted once the frame showed again, a key name below its legend
		 * then crossing the key's bottom edge. One frame later, a key name that
		 * still crosses its key's edge refits the board once: under the site's
		 * 200 % text (a zoomed body) Chromium measured the size a legend had before
		 * its reset on every other fit, so that fit shrank nothing.
		 */
		function fitLegends() {
			if (!fitLegendsOnce()) return;
			requestAnimationFrame(() => {
				if (keyNameCrosses()) fitLegendsOnce();
			});
		}

		/**
		 * Whether a key name of the drawn board ends below its key's content box.
		 * @returns {boolean}
		 */
		function keyNameCrosses() {
			return [...root.querySelectorAll('#le-board .le-key > .le-code')].some((code) => {
				const key = code.parentElement;
				const bottom = key.clientHeight - parseFloat(getComputedStyle(key).paddingBottom);
				return code.offsetTop + code.offsetHeight > bottom + 1;
			});
		}

		/**
		 * One fit of every legend (fitLegends).
		 * @returns {boolean} False when the board is not laid out, so nothing was fitted.
		 */
		function fitLegendsOnce() {
			const drawn = root.querySelector('#le-board');
			if (!drawn || drawn.clientWidth === 0) return false;
			const legends = [...root.querySelectorAll('#le-board .le-legend')];
			legends.forEach((node) => {
				node.style.fontSize = '';
				node.classList.remove('cut');
			});
			const sizes = legends.map((node) => [
				node.clientWidth,
				node.scrollWidth,
				legendRoom(node),
				node.offsetHeight
			]);
			legends.forEach((node, index) => {
				const [room, needed, roomHeight, neededHeight] = sizes[index];
				if (room === 0) return;
				const ratio = Math.min(
					1,
					room / needed,
					roomHeight > 0 && neededHeight > 0 ? roomHeight / neededHeight : 1
				);
				if (ratio >= 1) return;
				const size = parseFloat(getComputedStyle(node).fontSize);
				node.style.fontSize = `${Math.max(LEGEND_MIN_PX, Math.floor(size * ratio))}px`;
			});
			legends.forEach((node) => {
				if (node.scrollWidth > node.clientWidth) node.classList.add('cut');
			});
			return true;
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
					node.setAttribute('aria-label', node.dataset.label);
					continue;
				}
				node.style.setProperty('--le-heat', String(heat.max > 0 ? value / heat.max : 0));
				node.title = `${node.dataset.title}\n${heat.titles[node.dataset.code]}`;
				// The colour's value in words too, never by colour alone.
				node.setAttribute('aria-label', `${node.dataset.label}. ${heat.titles[node.dataset.code]}`);
			}
		}

		// The board's key unit follows the editor's width: refit the labels when it
		// changes. The refit runs on the next frame, never inside the observer: it
		// writes layout, which raised « ResizeObserver loop completed with
		// undelivered notifications ».
		if (typeof ResizeObserver === 'function') {
			let lastWidth = -1;
			let frame = 0;
			new ResizeObserver((entries) => {
				const width = Math.round(entries[0].contentRect.width);
				cancelAnimationFrame(frame);
				frame = requestAnimationFrame(() => {
					if (width === lastWidth) return;
					lastWidth = width;
					fitLegends();
					placeScoreChip();
				});
			}).observe(root);
		}

		// A reader's text spacing (WCAG 1.4.12: a user style sheet, or the site's
		// « wide » spacing chosen while the editor is open), a reading choice
		// written on the root element and a web font that finishes loading all
		// resize the legends and key names without changing the editor's width,
		// so the observer above never fires and a legend fitted to the old layout
		// pushed the key name below it past the key's bottom edge. Each of them
		// refits on the next frame; the key names are watched by size, which
		// fitLegends never writes, so the refit cannot loop.
		let refitFrame = 0;
		const refitSoon = () => {
			cancelAnimationFrame(refitFrame);
			refitFrame = requestAnimationFrame(fitLegends);
		};
		const keyNameObserver =
			typeof ResizeObserver === 'function' ? new ResizeObserver(refitSoon) : null;
		if (typeof MutationObserver === 'function')
			new MutationObserver(refitSoon).observe(document.documentElement, {
				attributes: true,
				attributeFilter: ['data-a11y-font', 'data-a11y-text', 'data-a11y-spacing']
			});
		if (document.fonts && typeof document.fonts.addEventListener === 'function')
			document.fonts.addEventListener('loadingdone', refitSoon);

		/** Watch the key names of the board just drawn (keyNameObserver). */
		function observeKeyNames() {
			if (!keyNameObserver) return;
			keyNameObserver.disconnect();
			for (const code of root.querySelectorAll('#le-board .le-key > .le-code'))
				keyNameObserver.observe(code);
		}

		// One persistent element for a host's side panel (the analysis of the Studio):
		// re-inserted by every render, so what the host appends there survives.
		const sideSlot = el('div', { class: 'le-side-slot', id: 'le-side-slot' });
		// The score chip: persistent too, so its live region announces each new score.
		const chipLabel = el('small', { class: 'le-score-label' });
		const chipScore = el('strong', { class: 'le-score-value' });
		const chipRank = el('small', { class: 'le-score-rank' });
		const chipChange = el('em', { class: 'le-score-change' });
		const chipLive = el('output', {
			class: 'le-sr-only',
			id: 'le-score-live',
			role: 'status',
			'aria-live': 'polite'
		});
		const chipButton = el(
			'button',
			{
				type: 'button',
				class: 'le-score-open',
				id: 'le-score-open',
				'aria-controls': 'la-live-panel',
				onclick: () => analysisPanel.reveal()
			},
			// The spaces are not drawn (flex items) but part the visible words, which
			// the button's name then contains (WCAG 2.5.3), not « Score27,4rang ».
			[chipLabel, ' ', chipScore, ' ', chipRank, ' ', chipChange]
		);
		const scoreChip = el('p', { class: 'le-score-chip', id: 'le-score-chip' }, [
			chipButton,
			chipLive
		]);
		// The last result shown, redrawn when the locale arrives.
		let chipResult = null;

		/**
		 * Draws the chip for one analysis result (analysis_panel.js onResult), or
		 * says that the analysis is folded or unavailable; the live region
		 * announces the text when it changes.
		 */
		function drawScoreChip(result) {
			chipResult = result;
			chipLabel.textContent = t('layout_analysis.table.score');
			const format = window.LAYOUT_ANALYSIS_INFO.format;
			// What the live region says, and the button's name: the visible text in
			// the same order, so a voice command saying it reaches the button, its
			// parts joined by « · » so that no breaking space follows a number.
			const words = [];
			const named = [];
			chipChange.className = 'le-score-change';
			chipChange.replaceChildren();
			if (!result) {
				chipScore.textContent = '—';
				chipRank.textContent = tl('score_chip.none');
				words.push(tl('score_chip.none'));
				named.push(`${chipLabel.textContent} ${chipScore.textContent}`, chipRank.textContent);
			} else {
				chipScore.textContent = format(result.score, 1);
				chipRank.textContent = tl('score_chip.rank', { rank: result.rank, count: result.count });
				named.push(`${chipLabel.textContent} ${chipScore.textContent}`, chipRank.textContent);
				words.push(
					t('layout_analysis.panel.score', {
						score: format(result.score, 1),
						rank: result.rank,
						count: result.count
					})
				);
				if (result.change !== null) {
					const epsilon = window.LAYOUT_ANALYSIS_PANEL.DELTA_EPSILON;
					const moved = Math.abs(result.change) >= epsilon;
					// Better or worse with a mark and in words, never by its colour alone.
					const verdict = !moved ? 'same' : result.change > 0 ? 'better' : 'worse';
					const signed = `${result.change > 0 ? '+' : '−'}${format(Math.abs(result.change), 1)}`;
					// The edit named when the analysis is of the document it made.
					const edit = state.lastEdit && state.lastEdit.doc === doc() ? state.lastEdit.text : null;
					const text = edit
						? moved
							? tl('score_chip.change_named', { change: signed, edit })
							: tl('score_chip.unchanged_named', { edit })
						: moved
							? tl('score_chip.change', { change: signed })
							: tl('score_chip.unchanged');
					const mark = { better: '▲', worse: '▼', same: '=' }[verdict];
					const verdictWords = t(`layout_analysis.details.verdict_${verdict}`);
					const shown = moved ? `${text} · ${verdictWords}` : text;
					chipChange.classList.add(`le-score-${verdict}`);
					chipChange.append(
						el('b', { class: 'le-score-mark', 'aria-hidden': 'true', text: mark }),
						shown
					);
					words.push(moved ? `${text} (${verdictWords})` : text);
					named.push(shown);
				}
			}
			const label = tl('score_chip.open');
			chipButton.title = label;
			chipButton.setAttribute('aria-label', `${named.join(' · ')}. ${label}`);
			const spoken = words.join('. ');
			if (chipLive.textContent !== spoken) chipLive.textContent = spoken;
		}

		/** Keeps the chip just under the sticky toolbar, whose height follows its wrapping. */
		function placeScoreChip() {
			const bar = root.querySelector('.le-toolbar');
			if (bar) root.style.setProperty('--le-toolbar-height', `${bar.offsetHeight}px`);
		}

		// The live analysis (layout_analysis/analysis_panel.js), when the page loads it.
		if (analysisPanel) {
			drawScoreChip(null);
			analysisPanel.onResult(drawScoreChip);
			// The worst n-gram hovered or focused in the panel: its keys on the board.
			analysisPanel.onHighlight(
				window.LAYOUT_ANALYSIS_WORST.highlighter(() => root.querySelector('#le-board'))
			);
			document.addEventListener('i18n:applied', () => drawScoreChip(chipResult));
			sideSlot.append(analysisPanel.node);
			analysisPanel.onHeat((heat) => {
				state.heat = heat;
				applyHeat();
			});
			// A fingering change made in the panel is a step of the shown tab's
			// history: the document stays, Undo puts the fingering back. The app's
			// Studio window also holds the Comparer, whose own history keeps the
			// changes made there.
			window.LAYOUT_ANALYSIS_FINGERING.onEdit(({ before, after }) => {
				if (root.getClientRects().length === 0) return;
				state.history.push(doc(), step('edit_history.step.fingering'), {
					undo: () => window.LAYOUT_ANALYSIS_FINGERING.restore(before),
					redo: () => window.LAYOUT_ANALYSIS_FINGERING.restore(after)
				});
				state.historySaid = null;
				render();
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
		// Whether the tabs came from the host's workspace: their start copies are
		// renamed again when the locale arrives after them.
		let restoredTabs = false;

		/**
		 * The first document: the host's workspace restored when it holds tabs, else
		 * the host's initial text, else a copy of its start source.
		 */
		/**
		 * Opens the first document: the restored tabs, else the start one.
		 * @returns {Promise<void>} Settles once that document is in place.
		 */
		function openInitial() {
			if (!host.workspace) return Promise.resolve(openStart());
			return fromHost(() => host.workspace.load()).then(
				(text) => {
					restoredTabs = restoreWorkspace(text);
					const started = restoredTabs ? renameRestoredStarts() : openStart();
					render();
					return started;
				},
				(error) => {
					// The tabs could not be read: the page says so, saves nothing over them,
					// and still opens the start document.
					refuseWorkspace(error);
					const started = openStart();
					render();
					return started;
				}
			);
		}

		/**
		 * Names each restored tab that is still the host's start copy (the keys
		 * the start made, no unsaved edit) with this locale's copy name: that
		 * name was the page's, never the user's, so the former copy name of a
		 * workspace saved before the copy was renamed (maintainer, 2026-11-19),
		 * or another locale's name, gives way. Ids stay as stored; a tab whose
		 * keys differ from the start keeps its name.
		 * @returns {Promise<void>} Settles once the start source was compared.
		 */
		function renameRestoredStarts() {
			if (typeof host.startFrom !== 'string') return Promise.resolve();
			return loadFillSources().then(() => {
				const entry = (state.fillSources || []).find((source) => source.id === host.startFrom);
				if (!entry) return;
				const name = tl('start.copy_name', { name: entry.name });
				let renamed = false;
				try {
					state.tabs.forEach((stored, index) => {
						const tab = tabAt(index);
						const current = tab.history.current();
						if (tab.dirty || tab.history.canUndo() || current.layout.name === name) return;
						if (LayoutSourceIO.isPreserved(current)) return;
						const start = LayoutSourceIO.startFrom(entry, current.layout.id, current.layout.name);
						if (LayoutSourceIO.serialize(start.doc) !== LayoutSourceIO.serialize(current)) return;
						tab.history.reset(LayoutEditorModel.setLayout(current, { name }));
						renamed = true;
					});
				} catch (error) {
					state.message = { kind: 'error', text: problemText(error) };
					renamed = true;
				}
				if (renamed) render();
			});
		}

		function openStart() {
			if (typeof host.initial === 'string') {
				const parsed = LayoutSourceIO.parse(host.initial);
				if (parsed.ok) replace(parsed.doc, null, true);
				else state.message = { kind: 'error', text: problemText(parsed.error) };
			} else if (typeof host.startFrom === 'string') {
				// With nothing to open, a host may start on a copy of a start source (the
				// app's Studio: Ergopti, maintainer 2026-11-15) instead of an empty
				// keyboard, as « Start from » does, once the sources are known. Only the
				// untouched first document is replaced; without that source it stays. The
				// locale's arrival renames that document without touching it (i18n:applied).
				const opened = replacements;
				return loadFillSources().then(() => {
					const entry = (state.fillSources || []).find((source) => source.id === host.startFrom);
					const touched = replacements !== opened || state.dirty || state.history.canUndo();
					if (!entry || touched) return;
					try {
						const started = LayoutSourceIO.startFrom(
							entry,
							`${LayoutSourceIO.identifierFrom(entry.id, 'layout')}_custom`,
							tl('start.copy_name', { name: entry.name })
						);
						replace(started.doc, started.lost.length ? started.lost : null, true);
						openedStart = { doc: doc(), name: entry.name };
					} catch (error) {
						state.message = { kind: 'error', text: problemText(error) };
					}
					render();
				});
			}
		}

		// Ctrl/Cmd+Z and Ctrl/Cmd+Y (or Shift+Z) anywhere in the editor shown, but in a
		// text field, which keeps its own undo. The document listens, so a press with
		// nothing focused (after a click on the page) works too.
		ERGOPTI_EDIT_HISTORY.bindKeys(document, runHistory, () => {
			const target = document.activeElement;
			const inside = !target || target === document.body || target === document.documentElement;
			return (inside || root.contains(target)) && root.getClientRects().length > 0;
		});

		wireDrop();
		const initialSettled = openInitial();
		render();
		if (host.startNav) showNav(host.startNav);
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
			if (restoredTabs) renameRestoredStarts();
			if (state.message && state.message.translate) state.message.text = state.message.translate();
			render();
		});
		/**
		 * Opens a layout another Studio tool made (library shape: the optimizer's
		 * result) in a new tab, once the first document is in place, so the
		 * restored tabs are kept beside it. With an intent, the « Export » tool
		 * opens and does what was asked, as its own controls do: a download of
		 * that format (said when this host cannot make it), or an install or an
		 * emulation, each after the user agrees (said when this host has none).
		 * @param {object} layout - {id, name, rows, dead, command}.
		 * @param {{action: 'download'|'install'|'emulate', format?: string}} [intent]
		 * @returns {Promise<void>}
		 * @throws {Error} On an unknown intent (LAYOUT_ANALYSIS_FILES.checkedIntent).
		 */
		function openLayout(layout, intent) {
			const asked =
				intent === undefined ? null : window.LAYOUT_ANALYSIS_FILES.checkedIntent(intent);
			return initialSettled.then(() => {
				let started;
				try {
					const id = LayoutSourceIO.identifierFrom(layout.id, 'layout');
					started = LayoutSourceIO.startFromDocument(
						LAYOUT_FORMATS.toSource(layout),
						id,
						layout.name
					);
				} catch (error) {
					notify('error', problemText(error));
					return;
				}
				commitFocused();
				keepActive();
				state.tabs.push(newTab(started.doc, true));
				showTab(state.tabs.length - 1);
				state.message = null;
				if (asked) {
					state.tool = 'export';
					if (asked.action === 'download') state.exportFormat = asked.format;
				}
				render();
				if (!asked) return;
				const tab = root.querySelector('#le-tool-tab-export');
				if (tab) tab.scrollIntoView({ block: 'nearest' });
				if (!exportActions) return;
				if (asked.action === 'download') exportActions.download(asked.format);
				else if (exportActions[asked.action]) exportActions[asked.action]();
				else
					notify(
						'error',
						tl(asked.action === 'install' ? 'export.no_install' : 'export.no_emulate')
					);
			});
		}

		return {
			open: (name, text) => openText(name, text),
			openLayout,
			current: () => doc(),
			showNav,
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
