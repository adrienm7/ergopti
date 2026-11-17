// _shared/ui/layout_optimizer/optimizer_page.js

/**
 * ==============================================================================
 * MODULE: Layout Optimizer Page
 * DESCRIPTION:
 * The « Optimiser » tab of Ergopti Studio: pick a corpus, a start layout
 * (or a random arrangement of its keys), the constraints, the weights of the
 * Comparer's score and a budget; watch the best layout found so far, its
 * score and its metrics against the start; stop at any time; open the result
 * in « Éditer » or compare it in « Comparer ». Everything runs in the page.
 *
 * FEATURES & RATIONALE:
 * 1. Responsive: the search runs in Web Workers (optimizer_worker.js), one
 *    share of the restarts each; where a worker cannot start (a page a host
 *    inlines), the same runner runs on the page in short slices.
 * 2. Deterministic: the seed and the budget in swaps give the same layout on
 *    every machine, whatever the number of workers (LAYOUT_OPTIMIZER.bestOf).
 * 3. Honest: the score shown at the end is the engine's score of the layout
 *    on the whole corpus, the one the Comparer shows.
 * 4. Mountable: LAYOUT_OPTIMIZER_PAGE.mount(root, {host?}) fills any element;
 *    the site's page mounts its <main>. Every visible string is a locale key.
 * 5. Pins: a click on a key of the start layout keeps it in place; the QWERTY
 *    board keeps chosen letters at their QWERTY place (presets for the Ctrl
 *    shortcuts Z X C V and A S), whatever the start.
 * 6. Corpora: the built-in ones, or the reader's own text, pasted or opened
 *    from a file (the Comparer's reader), counted on the device, with its
 *    size limits said in words.
 * 7. Zones: a click on the zone board keeps a character on the keys chosen.
 * 8. Remembered: the choices and the last text are kept in this browser's
 *    storage; a browser that refuses storage gets the same page, unsaved.
 * ==============================================================================
 */

(function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const O = window.LAYOUT_OPTIMIZER;
	const FILES = window.LAYOUT_ANALYSIS_FILES;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	const PREFIX = 'layout_optimizer.';
	// The constraint switches the page offers, in the core's order (DEFAULT_OPTIONS).
	const SWITCHES = [
		'moveDigits',
		'digitsOutsideNumberRow',
		'lettersOnNumberRow',
		'movePunctuation',
		'moveSymbols',
		'altgr',
		'deadKeyLayer'
	];
	// The metrics compared with the start, as the Comparer's table shows them.
	const DELTA_METRICS = [
		'sfb',
		'sfs',
		'lsb',
		'scissors',
		'redirect',
		'roll_in',
		'roll_out',
		'alternation',
		'home_row',
		'distance',
		'finger_imbalance',
		'hand_imbalance',
		'pinky_load',
		'simplicity'
	];
	const DEFAULT_START = 'azerty';
	const DEFAULT_CORPUS = 'fr_swann';
	const DEFAULT_SECONDS = 30;
	const DEFAULT_ITERATIONS = 4000;
	const DEFAULT_SEED = 1;
	// The search accuracies: the share of each n-gram table the search scores on.
	const ACCURACIES = { full: 1, fast: 0.99 };
	// Workers at most, and the threads left to the page.
	const MAX_WORKERS = 8;
	// Size of one key unit of a drawn board, in pixels, at most and at least.
	const KEY_UNIT_MAX = 44;
	const KEY_UNIT_MIN = 20;
	// The best layout's metrics are measured again at most this often (ms).
	const METRICS_MS = 500;
	const HEIGHT_MESSAGE = 'ergopti-layout-optimizer:height';
	// The corpus a pasted text or an opened file makes.
	const CUSTOM_ID = 'custom';
	// The app's keystats corpus (« My typing ») and the event its Studio window
	// dispatches with those n-grams (layout_editor_window/script.js).
	const MY_TYPING_ID = 'my_typing';
	const NGRAMS_EVENT = 'studio-ngrams';
	// A text shorter than this gives the search too few n-grams to measure; a
	// longer one would hold the page while it is counted and sent to the workers.
	const MIN_TEXT_CHARS = 200;
	const MAX_TEXT_CHARS = 5000000;
	// Files larger than this are refused before they are read (MB).
	const MAX_FILE_MB = 50;
	const TEXT_DEBOUNCE_MS = 400;
	// The reader's choices and last text, kept in this browser for the next visit.
	const STORAGE_KEY = 'ergopti.layout_optimizer.v1';
	const TEXT_KEY = 'ergopti.layout_optimizer.text.v1';
	const STANDALONE_ROOT_ID = 'layout-optimizer';

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	// The page's markup; data-i18n attributes are filled by applyStrings().
	const MARKUP = `<h1 data-i18n="layout_optimizer.title"></h1>
<p class="lo-muted" data-i18n="layout_optimizer.intro"></p>
<section class="lo-grid">
	<div class="lo-panel">
		<h2 data-i18n="layout_optimizer.setup.title"></h2>
		<label class="lo-field"><span data-i18n="layout_optimizer.corpus.language"></span>
			<select id="lo-language"></select></label>
		<label class="lo-field"><span data-i18n="layout_optimizer.corpus.label"></span>
			<select id="lo-corpus"></select></label>
		<div id="lo-custom" class="lo-field lo-custom" hidden>
			<textarea id="lo-text" rows="4" data-i18n-placeholder="layout_optimizer.corpus.paste_placeholder"></textarea>
			<label class="lo-file"><span data-i18n="layout_optimizer.corpus.file"></span>
				<input id="lo-file" type="file" accept=".txt,.md,.csv,.tsv,.html,.htm,.json,.tex,.docx,.odt,.pdf" /></label>
			<p id="lo-text-status" class="lo-muted" role="status" aria-live="polite"></p>
		</div>
		<label class="lo-field"><span data-i18n="layout_optimizer.start.label"></span>
			<select id="lo-start"></select></label>
		<fieldset class="lo-field lo-radios">
			<legend data-i18n="layout_optimizer.start.mode"></legend>
			<label><input type="radio" name="lo-start-mode" value="layout" checked />
				<span data-i18n="layout_optimizer.start.mode_layout"></span></label>
			<label><input type="radio" name="lo-start-mode" value="random" />
				<span data-i18n="layout_optimizer.start.mode_random"></span></label>
		</fieldset>
		<label class="lo-field"><span data-i18n="layout_optimizer.keyboard"></span>
			<select id="lo-keyboard"></select></label>
	</div>
	<div class="lo-panel">
		<h2 data-i18n="layout_optimizer.constraints.title"></h2>
		<p class="lo-muted" data-i18n="layout_optimizer.constraints.fixed"></p>
		<div id="lo-switches"></div>
	</div>
	<div class="lo-panel lo-wide">
		<h2 data-i18n="layout_optimizer.pins.title"></h2>
		<p class="lo-muted" data-i18n="layout_optimizer.pins.help"></p>
		<div class="lo-board-box"><div id="lo-pin-board" class="lo-board"></div></div>
		<h3 data-i18n="layout_optimizer.qwerty.title"></h3>
		<p class="lo-muted" data-i18n="layout_optimizer.qwerty.help"></p>
		<div class="lo-buttons" id="lo-qwerty-presets"></div>
		<div class="lo-board-box"><div id="lo-qwerty-board" class="lo-board"></div></div>
		<h3 data-i18n="layout_optimizer.zones.title"></h3>
		<p class="lo-muted" data-i18n="layout_optimizer.zones.help"></p>
		<div class="lo-buttons">
			<label class="lo-field lo-inline"><span data-i18n="layout_optimizer.zones.char"></span>
				<select id="lo-zone-char"></select></label>
			<button type="button" id="lo-zone-clear" data-i18n="layout_optimizer.zones.clear"></button>
			<button type="button" id="lo-zones-clear" data-i18n="layout_optimizer.zones.clear_all"></button>
		</div>
		<div class="lo-board-box"><div id="lo-zone-board" class="lo-board"></div></div>
		<p id="lo-zones-summary" class="lo-muted" role="status"></p>
	</div>
	<details class="lo-panel lo-wide">
		<summary data-i18n="layout_optimizer.weights.title"></summary>
		<p class="lo-muted" data-i18n="layout_optimizer.weights.help"></p>
		<div id="lo-weights" class="lo-weights"></div>
		<button type="button" id="lo-weights-restore" data-i18n="layout_optimizer.weights.restore"></button>
	</details>
	<div class="lo-panel lo-wide">
		<h2 data-i18n="layout_optimizer.budget.title"></h2>
		<div class="lo-row">
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.seconds"></span>
				<input id="lo-seconds" type="number" min="1" max="3600" step="1" /></label>
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.iterations"></span>
				<input id="lo-iterations" type="number" min="10" max="1000000" step="10" /></label>
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.restarts"></span>
				<input id="lo-restarts" type="number" min="1" max="64" step="1" /></label>
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.seed"></span>
				<input id="lo-seed" type="number" min="0" max="4294967295" step="1" /></label>
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.accuracy"></span>
				<select id="lo-accuracy" data-i18n-option-prefix="layout_optimizer.accuracy">
					<option value="full"></option>
					<option value="fast"></option>
				</select></label>
		</div>
		<p class="lo-muted" data-i18n="layout_optimizer.budget.help"></p>
		<div class="lo-buttons">
			<button type="button" id="lo-run" class="lo-primary" data-i18n="layout_optimizer.run"></button>
			<button type="button" id="lo-stop" data-i18n="layout_optimizer.stop" disabled></button>
		</div>
		<progress id="lo-progress" max="1" value="0" aria-labelledby="lo-status"></progress>
		<p id="lo-status" class="lo-muted" role="status" aria-live="polite"></p>
	</div>
</section>
<section id="lo-result" class="lo-panel" hidden>
	<h2 data-i18n="layout_optimizer.result.title"></h2>
	<p id="lo-score" class="lo-score"></p>
	<div class="lo-board-box"><div id="lo-result-board" class="lo-board"></div></div>
	<div class="lo-table-box"><table class="lo-table">
		<thead><tr>
			<th data-i18n="layout_optimizer.result.metric"></th>
			<th data-i18n="layout_optimizer.result.start"></th>
			<th data-i18n="layout_optimizer.result.best"></th>
			<th data-i18n="layout_optimizer.result.change"></th>
		</tr></thead>
		<tbody id="lo-metrics"></tbody>
	</table></div>
	<div class="lo-buttons">
		<button type="button" id="lo-open-editor" data-i18n="layout_optimizer.result.open_editor" disabled></button>
		<button type="button" id="lo-open-comparer" data-i18n="layout_optimizer.result.open_comparer" disabled></button>
	</div>
</section>`;

	let mounted = null;
	// The app's last keystats tables, kept when they arrive before the mount
	// (the Studio window mounts this tab the first time it opens).
	let lastNgrams = null;
	let onNgrams = null;
	document.addEventListener(NGRAMS_EVENT, (event) => {
		lastNgrams = event.detail;
		if (onNgrams) onNgrams(event.detail);
	});

	/**
	 * Fills an element with the optimizer.
	 * @param {HTMLElement} root - The element the page fills.
	 * @param {{reportHeight?: boolean, host?: {openEditor?: function(object): void,
	 *   openComparer?: function(object): void}}} [options] - reportHeight: post
	 *   the page height to a framing parent (the site); host: the app's Studio
	 *   window, which opens the result in its own « Éditer » and « Comparer »
	 *   tabs instead of the site's.
	 * @returns {{setCorpus: function(object): void}} The mounted page.
	 * @throws {Error} On a missing root or a second mount.
	 */
	function mount(root, options) {
		if (!root || typeof root.append !== 'function')
			throw new Error('layout_optimizer: mount needs an element');
		if (mounted) throw new Error('layout_optimizer: the page is already mounted');
		const opts = options || {};
		const HOST = opts.host || {};
		root.classList.add('layout-optimizer');
		// A constant of this script, no user data: safe as markup.
		root.innerHTML = MARKUP;
		const $ = (id) => root.querySelector(`#${id}`);

		// ============================
		// ======= 1/ Helpers =========
		// ============================

		/** Translates a locale key; an unknown key shows itself so the gap is visible. */
		function t(key, values) {
			const strings = window._i18n_strings || {};
			let text = typeof strings[key] === 'string' ? strings[key] : key;
			for (const [name, value] of Object.entries(values || {}))
				text = text.split(`{${name}}`).join(String(value));
			return text;
		}

		function el(tag, className, text) {
			const node = document.createElement(tag);
			if (className) node.className = className;
			if (text !== undefined) node.textContent = text;
			return node;
		}

		// The language of the page's strings (i18n.js loads _i18n_locale, else the
		// page's declared language), never the browser's own.
		const number = (value, digits) =>
			Number(value).toLocaleString(window._i18n_locale || document.documentElement.lang, {
				minimumFractionDigits: digits,
				maximumFractionDigits: digits
			});
		const signed = (value, digits) => (value > 0 ? '+' : '') + number(value, digits);
		const metricDigits = E.metricDigits;

		function applyStrings() {
			for (const node of root.querySelectorAll('[data-i18n]'))
				node.textContent = t(node.dataset.i18n);
			for (const node of root.querySelectorAll('[data-i18n-placeholder]'))
				node.placeholder = t(node.dataset.i18nPlaceholder);
			for (const select of root.querySelectorAll('select[data-i18n-option-prefix]'))
				for (const option of select.options)
					option.textContent = t(`${select.dataset.i18nOptionPrefix}.${option.value}`);
		}

		/** The message of a refusal in the reader's language. */
		function errorText(code, message, values) {
			const key = `${PREFIX}error.${code}`;
			const strings = window._i18n_strings || {};
			return typeof strings[key] === 'string'
				? t(key, values)
				: t(`${PREFIX}error.failed`, { message });
		}

		// ============================
		// ======= 2/ State ===========
		// ============================

		const library = E.libraryLayouts();
		const qwerty = library.find((layout) => layout.id === 'qwerty');
		const state = {
			editorLayouts: [],
			pinnedCodes: new Set(),
			qwertyPins: new Set(),
			// Character → the keys it may sit on (LAYOUT_OPTIMIZER zones).
			zones: new Map(),
			weights: E.defaultWeights(),
			tables: new Map(),
			// The pasted or opened text's tables: {hash, chars, tables}.
			custom: null,
			// The saved start layout, until the reader picks another.
			savedStart: null,
			// The host's corpora: {id, title, tables}, listed first.
			hostCorpora: [],
			running: null,
			startResult: null,
			best: null,
			bestLayout: null,
			lastMetrics: 0
		};

		function startLayouts() {
			return state.editorLayouts.map(E.layoutFromRows).concat(library);
		}

		function startLayout() {
			const id = $('lo-start').value;
			return startLayouts().find((layout) => layout.id === id) || null;
		}

		// ============================
		// ======= 3/ Controls ========
		// ============================

		function fillLanguages() {
			const languages = [...new Set(DATA.corpora.map((corpus) => corpus.language))];
			const select = $('lo-language');
			const kept = select.value;
			select.replaceChildren(
				...languages.map((code) => {
					const option = el('option', '', t(`${PREFIX}language.${code}`));
					option.value = code;
					return option;
				})
			);
			select.value = kept || DATA.corpora.find((c) => c.id === DEFAULT_CORPUS).language;
		}

		function fillCorpora() {
			const select = $('lo-corpus');
			const kept = select.value;
			const shown = DATA.corpora.filter((corpus) => corpus.language === $('lo-language').value);
			const custom = el('option', '', t(`${PREFIX}corpus.custom`));
			custom.value = CUSTOM_ID;
			// The host's corpora (« My typing ») first, whatever the language.
			select.replaceChildren(
				...state.hostCorpora.concat(shown).map((corpus) => {
					const option = el('option', '', corpus.title);
					option.value = corpus.id;
					return option;
				}),
				custom
			);
			const values = Array.from(select.options, (option) => option.value);
			if (values.includes(kept)) select.value = kept;
			else if (values.includes(DEFAULT_CORPUS)) select.value = DEFAULT_CORPUS;
			syncCorpus();
		}

		/** Shows the text box under « Your own text » only. */
		function syncCorpus() {
			$('lo-custom').hidden = $('lo-corpus').value !== CUSTOM_ID;
		}

		/**
		 * Reduces the user's text to tables, once per distinct text, and says
		 * whether the optimizer can use it.
		 * @param {string} text - The pasted or opened text.
		 */
		function useText(text) {
			const trimmed = text.trim();
			const chars = Array.from(trimmed).length;
			const status = $('lo-text-status');
			let problem = null;
			if (chars > 0 && chars < MIN_TEXT_CHARS)
				problem = t(`${PREFIX}corpus.text_short`, {
					chars: number(chars, 0),
					min: number(MIN_TEXT_CHARS, 0)
				});
			else if (chars > MAX_TEXT_CHARS)
				problem = t(`${PREFIX}corpus.text_long`, {
					chars: number(chars, 0),
					max: number(MAX_TEXT_CHARS, 0)
				});
			if (chars === 0 || problem) {
				if (restored && chars === 0) writeStored(TEXT_KEY, null);
				state.custom = null;
				status.textContent = problem || '';
				status.classList.toggle('lo-error', Boolean(problem));
				return;
			}
			const hash = E.hashText(trimmed);
			if (!state.custom || state.custom.hash !== hash) {
				state.custom = { hash, chars, tables: E.ngramsFromText(trimmed) };
				// Too long for the storage quota: the text is simply not kept.
				if (restored) writeStored(TEXT_KEY, { text: trimmed });
			}
			status.textContent = t(`${PREFIX}corpus.text_ready`, { chars: number(chars, 0) });
			status.classList.remove('lo-error');
		}

		/** Reads an opened file into the text box, or says why it cannot. */
		async function useFile(file) {
			const status = $('lo-text-status');
			const fail = (text) => {
				state.custom = null;
				status.textContent = text;
				status.classList.add('lo-error');
			};
			const megabytes = file.size / (1024 * 1024);
			if (megabytes > MAX_FILE_MB) {
				fail(
					t(`${PREFIX}corpus.file_large`, {
						size: number(megabytes, 1),
						max: number(MAX_FILE_MB, 0)
					})
				);
				return;
			}
			let text;
			try {
				text = await FILES.readText(file);
			} catch (failure) {
				// The Comparer's words for each refusal: an unknown type, a PDF that is
				// locked or holds no text (a scan), or a file that could not be read.
				const known = {
					file_unsupported: 'layout_analysis.corpus.file_unsupported',
					pdf_encrypted: 'layout_analysis.corpus.pdf_encrypted',
					pdf_no_text: 'layout_analysis.corpus.pdf_no_text'
				};
				fail(t(known[failure.code] || 'layout_analysis.corpus.file_unreadable'));
				return;
			}
			// A text over the limit is not put in the box, where it would hold the page.
			if (text.length <= MAX_TEXT_CHARS * 2) $('lo-text').value = text;
			useText(text);
		}

		function fillStarts() {
			const select = $('lo-start');
			// A saved layout of « Éditer » is chosen once its tab is listed.
			const kept = state.savedStart || select.value || DEFAULT_START;
			const group = (label, layouts) => {
				const node = el('optgroup');
				node.label = label;
				for (const layout of layouts) {
					const option = el('option', '', layout.name);
					option.value = layout.id;
					node.append(option);
				}
				return node;
			};
			const sorted = library
				.slice()
				.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
			const groups = [];
			if (state.editorLayouts.length)
				groups.push(
					group(t(`${PREFIX}start.editor_group`), state.editorLayouts.map(E.layoutFromRows))
				);
			groups.push(group(t(`${PREFIX}start.library_group`), sorted));
			select.replaceChildren(...groups);
			select.value = startLayouts().some((layout) => layout.id === kept) ? kept : DEFAULT_START;
		}

		function fillKeyboards() {
			const select = $('lo-keyboard');
			const kept = select.value || 'iso';
			select.replaceChildren(
				...Object.keys(DATA.model.keyboards).map((id) => {
					const option = el('option', '', t(`layout_analysis.keyboard.${id}`));
					option.value = id;
					return option;
				})
			);
			select.value = kept;
		}

		function fillSwitches() {
			const box = $('lo-switches');
			const checked = {};
			for (const input of box.querySelectorAll('input')) checked[input.value] = input.checked;
			box.replaceChildren(
				...SWITCHES.map((id) => {
					const input = el('input');
					input.type = 'checkbox';
					input.value = id;
					input.id = `lo-switch-${id}`;
					input.checked = id in checked ? checked[id] : O.DEFAULT_OPTIONS[id];
					const label = el('label', 'lo-switch');
					label.append(input, el('span', '', t(`${PREFIX}option.${id}.label`)));
					const help = el('p', 'lo-muted lo-help', t(`${PREFIX}option.${id}.help`));
					const item = el('div', 'lo-switch-item');
					item.append(label, help);
					return item;
				})
			);
			syncSwitches();
		}

		/** A switch that only means something with another one follows it. */
		function syncSwitches() {
			const digits = $('lo-switch-moveDigits');
			const outside = $('lo-switch-digitsOutsideNumberRow');
			outside.disabled = !digits.checked;
			if (!digits.checked) outside.checked = false;
		}

		function fillWeights() {
			const box = $('lo-weights');
			box.replaceChildren(
				...Object.keys(E.defaultWeights()).map((id) => {
					const input = el('input');
					input.type = 'number';
					input.min = '0';
					input.step = '0.05';
					input.value = String(state.weights[id]);
					input.dataset.metric = id;
					input.addEventListener('change', () => {
						const value = Number(input.value);
						if (Number.isFinite(value) && value >= 0) state.weights[id] = value;
						else input.value = String(state.weights[id]);
					});
					const label = el('label', 'lo-field lo-weight');
					label.append(el('span', '', t(`layout_analysis.metric.${id}`)), input);
					return label;
				})
			);
		}

		function fillPresets() {
			const box = $('lo-qwerty-presets');
			const buttons = Object.entries(O.QWERTY_PIN_PRESETS).map(([id, letters]) => {
				const button = el('button', '', t(`${PREFIX}qwerty.preset.${id}`));
				button.type = 'button';
				button.addEventListener('click', () => {
					for (const letter of letters) state.qwertyPins.add(letter);
					drawPinBoards();
				});
				return button;
			});
			const clear = el('button', '', t(`${PREFIX}qwerty.clear`));
			clear.type = 'button';
			clear.addEventListener('click', () => {
				state.qwertyPins.clear();
				drawPinBoards();
			});
			box.replaceChildren(...buttons, clear);
		}

		// ============================
		// ======= 4/ Boards ==========
		// ============================

		/** The legend of a key's base level: a dead key shows its bare accent. */
		function legend(layout, code) {
			const row = layout.rows[code];
			if (!row) return '';
			const cell = row[0];
			if (cell && typeof cell === 'object')
				return KEY_LEGEND.deadKeyText(((layout.dead || {})[cell.dead] || {})[' '] || '') || '★';
			if (code === 'Space') return '␣';
			return typeof cell === 'string' ? cell : '';
		}

		/**
		 * Draws a layout's base level on the chosen keyboard.
		 * @param {HTMLElement} box - The board element.
		 * @param {object} layout - Library shape.
		 * @param {{marked?: function(string): boolean, onKey?: function(string): void,
		 *   changed?: function(string): boolean, label?: function(string): string}} [how]
		 */
		function drawBoard(box, layout, how) {
			const opts = how || {};
			box.replaceChildren();
			const board = E.keyboard($('lo-keyboard').value);
			const modifiers = new Set(Object.values(DATA.model.modifier_keys));
			const minX = Math.min(...board.x) - 0.5;
			const maxX = Math.max(...board.x) + 0.5;
			const maxY = Math.max(...board.y);
			const width = box.parentElement.clientWidth || KEY_UNIT_MAX * (maxX - minX);
			const unit = Math.max(
				KEY_UNIT_MIN,
				Math.min(KEY_UNIT_MAX, Math.floor(width / (maxX - minX)))
			);
			box.style.width = `${(maxX - minX) * unit}px`;
			box.style.height = `${maxY * unit}px`;
			box.style.fontSize = `${Math.round(unit * 0.38)}px`;
			board.codes.forEach((code, k) => {
				if (modifiers.has(code)) return;
				const text = opts.label ? opts.label(code) : legend(layout, code);
				const key = el(opts.onKey ? 'button' : 'span', 'lo-key', text);
				key.dataset.code = code;
				const row = layout.rows[code];
				if (row && row[0] && typeof row[0] === 'object')
					key.classList.add(KEY_LEGEND.DEAD_KEY_CLASS);
				const wide = code === 'Space' ? 6 : 1;
				key.style.left = `${(board.x[k] - wide / 2 - minX) * unit}px`;
				key.style.top = `${(board.y[k] - 1) * unit}px`;
				key.style.width = `${wide * unit - 3}px`;
				key.style.height = `${unit - 3}px`;
				if (opts.marked && opts.marked(code)) key.classList.add('lo-marked');
				if (opts.changed && opts.changed(code)) key.classList.add('lo-changed');
				if (opts.onKey) {
					key.type = 'button';
					key.setAttribute('aria-pressed', opts.marked && opts.marked(code) ? 'true' : 'false');
					key.setAttribute('aria-label', `${code} ${text}`);
					key.addEventListener('click', () => opts.onKey(code));
				}
				box.append(key);
			});
		}

		function drawPinBoards() {
			const start = startLayout();
			if (start)
				drawBoard($('lo-pin-board'), start, {
					marked: (code) => state.pinnedCodes.has(code),
					onKey: (code) => {
						if (code === 'Space') return;
						if (state.pinnedCodes.has(code)) state.pinnedCodes.delete(code);
						else state.pinnedCodes.add(code);
						drawPinBoards();
					}
				});
			// The QWERTY board: only its letters can be held at their place.
			const letterAt = (code) => {
				const cell = (qwerty.rows[code] || [])[0];
				return typeof cell === 'string' && /^[a-z]$/.test(cell) ? cell : '';
			};
			drawBoard($('lo-qwerty-board'), qwerty, {
				label: letterAt,
				marked: (code) => state.qwertyPins.has(letterAt(code)),
				onKey: (code) => {
					const letter = letterAt(code);
					if (!letter) return;
					if (state.qwertyPins.has(letter)) state.qwertyPins.delete(letter);
					else state.qwertyPins.add(letter);
					drawPinBoards();
				}
			});
			if (start) drawZones(start);
			save();
		}

		/** The characters a zone can hold: each one on a base level of the start layout's keys. */
		function zoneChars(layout) {
			const out = [];
			for (const code of E.typingCodes()) {
				const cell = (layout.rows[code] || [])[0];
				if (typeof cell === 'string' && cell.trim() && Array.from(cell).length === 1)
					out.push(cell);
			}
			return out.sort((a, b) => a.localeCompare(b));
		}

		/** The zone board: the chosen character's keys marked; a click adds or removes a key. */
		function drawZones(start) {
			const select = $('lo-zone-char');
			const chars = zoneChars(start);
			// A zone of a character the start lacks would be refused: it goes.
			for (const char of [...state.zones.keys()])
				if (!chars.includes(char)) state.zones.delete(char);
			const kept = select.value;
			select.replaceChildren(
				...chars.map((char) => {
					const option = el('option', '', state.zones.has(char) ? `${char} ●` : char);
					option.value = char;
					return option;
				})
			);
			if (chars.includes(kept)) select.value = kept;
			const char = select.value;
			const zone = state.zones.get(char) || new Set();
			drawBoard($('lo-zone-board'), start, {
				marked: (code) => zone.has(code),
				changed: (code) => legend(start, code) === char,
				onKey: (code) => {
					if (code === 'Space' || !char) return;
					if (zone.has(code)) zone.delete(code);
					else zone.add(code);
					if (zone.size) state.zones.set(char, zone);
					else state.zones.delete(char);
					drawPinBoards();
				}
			});
			const summary = [...state.zones.entries()]
				.sort(([a], [b]) => a.localeCompare(b))
				.map(([key, codes]) => t(`${PREFIX}zones.summary`, { char: key, count: codes.size }));
			$('lo-zones-summary').textContent = summary.length
				? summary.join(' · ')
				: t(`${PREFIX}zones.none`);
		}

		// ============================
		// ======= 5/ Run =============
		// ============================

		/** The constraints of the run (LAYOUT_OPTIMIZER.problem options). */
		function problemOptions() {
			const out = {
				pinnedCodes: [...state.pinnedCodes].sort(),
				qwertyPins: [...state.qwertyPins].sort(),
				zones: Object.fromEntries(
					[...state.zones.entries()]
						.sort(([a], [b]) => (a < b ? -1 : 1))
						.map(([char, codes]) => [char, [...codes].sort()])
				)
			};
			for (const id of SWITCHES) out[id] = $(`lo-switch-${id}`).checked;
			return out;
		}

		function analysisOptions() {
			const format = FILES.savedFormat();
			return {
				keyboard: $('lo-keyboard').value,
				weights: Object.assign({}, state.weights),
				format: E.keyboardFormats().some((f) => f.id === format)
					? format
					: E.defaultKeyboardFormat()
			};
		}

		function readInteger(id, min, max, fallback) {
			const value = Math.floor(Number($(id).value));
			if (!Number.isFinite(value) || value < min || value > max) {
				$(id).value = String(fallback);
				return fallback;
			}
			return value;
		}

		function setStatus(text, error) {
			$('lo-status').textContent = text;
			$('lo-status').classList.toggle('lo-error', Boolean(error));
		}

		async function loadTables(id) {
			if (id === CUSTOM_ID) {
				if (!state.custom) throw Object.assign(new Error('no text'), { code: 'text_missing' });
				return state.custom.tables;
			}
			const hosted = state.hostCorpora.find((corpus) => corpus.id === id);
			if (hosted) return hosted.tables;
			if (state.tables.has(id)) return state.tables.get(id);
			const corpus = DATA.corpora.find((entry) => entry.id === id);
			const tables = await FILES.builtinTables(corpus);
			state.tables.set(id, tables);
			return tables;
		}

		/** A worker, or the page's own runner when workers cannot start here. */
		function makeRunner(onMessage) {
			try {
				if (!SCRIPT_BASE || typeof Worker !== 'function') throw new Error('no worker');
				const worker = new Worker(new URL('optimizer_worker.js', SCRIPT_BASE).href);
				worker.onmessage = (event) => onMessage(event.data);
				worker.onerror = (event) => {
					event.preventDefault();
					onMessage({ type: 'error', code: 'worker', message: event.message || '' });
				};
				return {
					start: (request) => worker.postMessage({ type: 'start', request }),
					stop: () => worker.postMessage({ type: 'stop' }),
					end: () => worker.terminate()
				};
			} catch {
				// A page the host inlines has no URL to load a worker from: run here.
				let local = null;
				return {
					start: (request) => {
						local = window.LAYOUT_OPTIMIZER_RUNNER.start(request, onMessage);
					},
					stop: () => local && local.stop(),
					end: () => {}
				};
			}
		}

		async function run() {
			if (state.running) return;
			const start = startLayout();
			if (!start) return;
			const opts = problemOptions();
			const analysis = analysisOptions();
			const seconds = readInteger('lo-seconds', 1, 3600, DEFAULT_SECONDS);
			const iterations = readInteger('lo-iterations', 10, 1000000, DEFAULT_ITERATIONS);
			const restarts = readInteger('lo-restarts', 1, 64, defaultRestarts());
			const seed = readInteger('lo-seed', 0, 4294967295, DEFAULT_SEED);
			const share = ACCURACIES[$('lo-accuracy').value];
			// Refused constraints are said before anything starts.
			try {
				O.problem(E, start, opts);
			} catch (error) {
				setStatus(errorText(error.code, error.message, error.values), true);
				return;
			}
			setStatus(t(`${PREFIX}status.loading`));
			// A text typed just now is read before the run, not after its pause.
			if ($('lo-corpus').value === CUSTOM_ID) useText($('lo-text').value);
			let tables;
			try {
				tables = await loadTables($('lo-corpus').value);
			} catch (error) {
				setStatus(errorText(error.code || 'corpus', error.message), true);
				return;
			}
			const identity = {
				id: `${start.id}_optimized`,
				name: t(`${PREFIX}result.name`, { name: start.name })
			};
			state.startResult = E.analyse(start, tables, analysis);
			state.best = null;
			state.bestLayout = null;
			state.tablesInUse = tables;
			state.analysisInUse = analysis;
			state.startInUse = start;
			$('lo-result').hidden = false;
			$('lo-open-editor').disabled = true;
			$('lo-open-comparer').disabled = true;
			showBest(start, state.startResult.score.total, false);

			// One share of the restarts per worker, in order, so the split never changes the winner.
			const workers = Math.max(1, Math.min(restarts, MAX_WORKERS, threads()));
			const began = Date.now();
			const shares = [];
			let first = 0;
			for (let w = 0; w < workers; w++) {
				const count = Math.floor(restarts / workers) + (w < restarts % workers ? 1 : 0);
				shares.push({ firstRestart: first, restarts: count, progress: null, result: null });
				first += count;
			}
			const running = { shares, runners: [], finished: 0, stopped: false };
			state.running = running;
			$('lo-run').disabled = true;
			$('lo-stop').disabled = false;
			shares.forEach((part) => {
				const runner = makeRunner((message) => receive(running, part, message, began, iterations));
				running.runners.push(runner);
				runner.start({
					start,
					options: opts,
					tables,
					analysis,
					share,
					seed,
					restarts: part.restarts,
					firstRestart: part.firstRestart,
					iterations,
					startMode: root.querySelector('input[name="lo-start-mode"]:checked').value,
					timeBudgetMs: seconds * 1000,
					identity
				});
			});
		}

		function receive(running, part, message, began, iterations) {
			if (state.running !== running) return;
			if (message.type === 'error') {
				stop();
				finish(running, began, errorText(message.code, message.message, message.values));
				return;
			}
			if (message.type === 'progress') {
				part.progress = message.progress;
				if (message.layout && (!state.best || message.progress.best > state.best.searchScore)) {
					state.best = { searchScore: message.progress.best };
					showBest(message.layout, message.progress.best, true);
				}
				showProgress(running, began, iterations);
				return;
			}
			part.result = message.result;
			running.finished += 1;
			if (running.finished === running.shares.length) {
				const winner = O.bestOf(running.shares.map((entry) => entry.result));
				showBest(winner.layout, winner.score, true, true);
				finish(running, began, null);
			}
		}

		function showProgress(running, began, iterations) {
			const done = running.shares.reduce(
				(sum, part) =>
					sum +
					(part.progress
						? Math.min(
								1,
								(part.progress.restart -
									part.firstRestart +
									(part.progress.iteration || 0) / Math.max(1, iterations)) /
									part.restarts
							)
						: 0),
				0
			);
			const seconds = (Date.now() - began) / 1000;
			const budget = Number($('lo-seconds').value) || DEFAULT_SECONDS;
			$('lo-progress').value = Math.max(
				done / running.shares.length,
				Math.min(1, seconds / budget)
			);
			setStatus(
				t(`${PREFIX}status.running`, {
					evaluations: number(evaluations(running), 0),
					seconds: number(seconds, 0)
				})
			);
		}

		const evaluations = (running) =>
			running.shares.reduce(
				(sum, part) =>
					sum +
					(part.result ? part.result.evaluations : part.progress ? part.progress.evaluations : 0),
				0
			);

		function finish(running, began, error) {
			for (const runner of running.runners) runner.end();
			state.running = null;
			$('lo-run').disabled = false;
			$('lo-stop').disabled = true;
			$('lo-progress').value = 1;
			const values = {
				evaluations: number(evaluations(running), 0),
				seconds: number((Date.now() - began) / 1000, 1)
			};
			if (error) setStatus(error, true);
			else setStatus(t(`${PREFIX}status.${running.stopped ? 'stopped' : 'done'}`, values));
		}

		function stop() {
			const running = state.running;
			if (!running) return;
			running.stopped = true;
			for (const runner of running.runners) runner.stop();
		}

		/**
		 * Shows a layout as the best so far: its board, its score and, at most
		 * every METRICS_MS (always for the final one), its metrics against the start.
		 */
		function showBest(layout, score, better, final) {
			state.bestLayout = layout;
			const start = state.startInUse;
			drawBoard($('lo-result-board'), layout, {
				changed: (code) => legend(layout, code) !== legend(start, code)
			});
			const startScore = state.startResult.score.total;
			$('lo-score').textContent = t(`${PREFIX}result.score`, {
				best: number(score, 2),
				start: number(startScore, 2),
				change: signed(score - startScore, 2)
			});
			$('lo-score').classList.toggle('lo-good', score > startScore);
			if (!final && Date.now() - state.lastMetrics < METRICS_MS) return;
			state.lastMetrics = Date.now();
			const result = E.analyse(layout, state.tablesInUse, state.analysisInUse);
			drawMetrics(result);
			if (final) {
				$('lo-open-editor').disabled = false;
				$('lo-open-comparer').disabled = false;
			}
		}

		function drawMetrics(result) {
			const body = $('lo-metrics');
			body.replaceChildren(
				...DELTA_METRICS.map((id) => {
					const before = state.startResult.metrics[id];
					const after = result.metrics[id];
					const change = after - before;
					const tr = el('tr');
					const digits = metricDigits(id);
					const cell = el('td', 'lo-num', signed(change, digits));
					const better = E.METRICS[id].better;
					const good = better === 'lower' ? change < 0 : better === 'higher' ? change > 0 : false;
					const bad = better === 'lower' ? change > 0 : better === 'higher' ? change < 0 : false;
					if (Math.abs(change) >= Math.pow(10, -digits)) {
						if (good) cell.classList.add('lo-good');
						if (bad) cell.classList.add('lo-bad');
					}
					tr.append(
						el('th', '', t(`layout_analysis.metric.${id}`)),
						el('td', 'lo-num', number(before, digits)),
						el('td', 'lo-num', number(after, digits)),
						cell
					);
					return tr;
				})
			);
		}

		// ============================
		// ======= 6/ Hand-offs =======
		// ============================

		/** Opens another tab of the Studio: the framing site's, or the sibling page. */
		function openTab(message, page) {
			if (window.parent !== window) window.parent.postMessage({ type: message }, location.origin);
			else location.href = new URL(`${page}${location.search}`, BASE).href;
		}

		function openEditor() {
			if (!state.bestLayout) return;
			if (typeof HOST.openEditor === 'function') {
				HOST.openEditor(state.bestLayout);
				return;
			}
			try {
				FILES.handOffToEditor(state.bestLayout);
			} catch (error) {
				setStatus(errorText(error.code, error.message), true);
				return;
			}
			openTab(FILES.OPEN_EDITOR_MESSAGE, '../layout_editor/index.html');
		}

		function openComparer() {
			if (!state.bestLayout) return;
			if (typeof HOST.openComparer === 'function') {
				HOST.openComparer(state.bestLayout);
				return;
			}
			try {
				FILES.handOff(state.bestLayout);
			} catch (error) {
				setStatus(errorText(error.code, error.message), true);
				return;
			}
			openTab(FILES.OPEN_COMPARER_MESSAGE, '../layout_analysis/index.html');
		}

		// ============================
		// ======= 7/ Saved choices ===
		// ============================

		/** Reads a saved value; a browser that refuses storage gives none. */
		function readStored(key) {
			try {
				const raw = window.localStorage.getItem(key);
				return raw ? JSON.parse(raw) : null;
			} catch {
				return null;
			}
		}

		/** Writes a saved value; a refused or full storage keeps none, the page works the same. */
		function writeStored(key, value) {
			try {
				if (value === null) window.localStorage.removeItem(key);
				else window.localStorage.setItem(key, JSON.stringify(value));
			} catch {
				// A private window, blocked site data or a full quota: nothing is kept.
			}
		}

		/** The reader's choices, kept for their next visit (this browser only). */
		function save() {
			if (!restored) return;
			const switches = {};
			for (const id of SWITCHES) switches[id] = $(`lo-switch-${id}`).checked;
			writeStored(STORAGE_KEY, {
				language: $('lo-language').value,
				corpus: $('lo-corpus').value,
				start: $('lo-start').value,
				startMode: root.querySelector('input[name="lo-start-mode"]:checked').value,
				keyboard: $('lo-keyboard').value,
				switches,
				pinnedCodes: [...state.pinnedCodes],
				qwertyPins: [...state.qwertyPins],
				zones: problemOptions().zones,
				weights: state.weights,
				seconds: $('lo-seconds').value,
				iterations: $('lo-iterations').value,
				restarts: $('lo-restarts').value,
				seed: $('lo-seed').value,
				accuracy: $('lo-accuracy').value
			});
		}

		/** Puts back the saved choices; a value this page no longer knows is skipped. */
		function restore() {
			const saved = readStored(STORAGE_KEY);
			if (!saved || typeof saved !== 'object') return;
			const choose = (id, value) => {
				const select = $(id);
				if (Array.from(select.options).some((option) => option.value === value))
					select.value = value;
			};
			const strings = (list) =>
				Array.isArray(list) ? list.filter((item) => typeof item === 'string') : [];
			choose('lo-language', saved.language);
			fillCorpora();
			choose('lo-corpus', saved.corpus);
			syncCorpus();
			// A layout open in « Éditer » may arrive after the mount: it is chosen then.
			state.savedStart = typeof saved.start === 'string' ? saved.start : null;
			choose('lo-start', saved.start);
			if (saved.startMode === 'layout' || saved.startMode === 'random')
				root.querySelector(`input[name="lo-start-mode"][value="${saved.startMode}"]`).checked =
					true;
			choose('lo-keyboard', saved.keyboard);
			for (const id of SWITCHES)
				if (saved.switches && typeof saved.switches[id] === 'boolean')
					$(`lo-switch-${id}`).checked = saved.switches[id];
			syncSwitches();
			state.pinnedCodes = new Set(strings(saved.pinnedCodes));
			state.qwertyPins = new Set(strings(saved.qwertyPins));
			state.zones = new Map();
			for (const [char, codes] of Object.entries(saved.zones || {}))
				if (strings(codes).length) state.zones.set(char, new Set(strings(codes)));
			const defaults = E.defaultWeights();
			for (const [id, value] of Object.entries(saved.weights || {}))
				if (id in defaults && Number.isFinite(value) && value >= 0) state.weights[id] = value;
			fillWeights();
			for (const id of ['seconds', 'iterations', 'restarts', 'seed'])
				if (typeof saved[id] === 'string' && /^\d+$/.test(saved[id]))
					$(`lo-${id}`).value = saved[id];
			choose('lo-accuracy', saved.accuracy);
			const text = readStored(TEXT_KEY);
			if (text && typeof text.text === 'string') {
				$('lo-text').value = text.text;
				useText(text.text);
			}
		}

		// ============================
		// ======= 8/ Start ===========
		// ============================

		const threads = () => Math.max(1, (navigator.hardwareConcurrency || 2) - 1);
		const defaultRestarts = () => Math.min(MAX_WORKERS, threads());

		function bind() {
			$('lo-language').addEventListener('change', fillCorpora);
			$('lo-corpus').addEventListener('change', syncCorpus);
			let textTimer = null;
			$('lo-text').addEventListener('input', (event) => {
				clearTimeout(textTimer);
				textTimer = setTimeout(() => useText(event.target.value), TEXT_DEBOUNCE_MS);
			});
			$('lo-file').addEventListener('change', (event) => {
				const file = event.target.files && event.target.files[0];
				if (file) useFile(file);
				event.target.value = '';
			});
			$('lo-start').addEventListener('change', () => {
				state.savedStart = null;
				state.pinnedCodes.clear();
				drawPinBoards();
			});
			$('lo-keyboard').addEventListener('change', drawPinBoards);
			$('lo-zone-char').addEventListener('change', drawPinBoards);
			$('lo-zone-clear').addEventListener('click', () => {
				state.zones.delete($('lo-zone-char').value);
				drawPinBoards();
			});
			$('lo-zones-clear').addEventListener('click', () => {
				state.zones.clear();
				drawPinBoards();
			});
			$('lo-switches').addEventListener('change', syncSwitches);
			$('lo-weights-restore').addEventListener('click', () => {
				state.weights = E.defaultWeights();
				fillWeights();
			});
			$('lo-run').addEventListener('click', run);
			$('lo-stop').addEventListener('click', stop);
			$('lo-open-editor').addEventListener('click', openEditor);
			$('lo-open-comparer').addEventListener('click', openComparer);
			if (typeof ResizeObserver === 'function') {
				let width = root.clientWidth;
				new ResizeObserver(() => {
					if (root.clientWidth === width) return;
					width = root.clientWidth;
					drawPinBoards();
					if (state.bestLayout && state.startInUse)
						drawBoard($('lo-result-board'), state.bestLayout, {
							changed: (code) => legend(state.bestLayout, code) !== legend(state.startInUse, code)
						});
				}).observe(root);
			}
		}

		/** Every string again, once the locale has arrived. */
		function refreshStrings() {
			applyStrings();
			fillLanguages();
			fillCorpora();
			fillStarts();
			fillKeyboards();
			fillSwitches();
			fillWeights();
			fillPresets();
		}

		// Saving waits until the saved choices are back, or the defaults would replace them.
		let restored = false;
		refreshStrings();
		$('lo-seconds').value = String(DEFAULT_SECONDS);
		$('lo-iterations').value = String(DEFAULT_ITERATIONS);
		$('lo-restarts').value = String(defaultRestarts());
		$('lo-seed').value = String(DEFAULT_SEED);
		bind();
		restore();
		restored = true;
		// Every field and switch saves on change; the boards save as they redraw.
		root.addEventListener('change', save);
		drawPinBoards();
		FILES.onEditorLayouts((layouts) => {
			state.editorLayouts = Array.isArray(layouts) ? layouts : [];
			fillStarts();
		});
		document.addEventListener('i18n:applied', () => {
			refreshStrings();
			drawPinBoards();
		});
		if (opts.reportHeight && window.parent !== window) {
			const post = () =>
				window.parent.postMessage(
					{ type: HEIGHT_MESSAGE, height: document.documentElement.scrollHeight },
					location.origin
				);
			post();
			if (typeof ResizeObserver === 'function') new ResizeObserver(post).observe(document.body);
		}
		/**
		 * Adds or replaces a corpus the host provides (the app's keystats), listed
		 * first, and selects it when it is the default.
		 * @param {{id: string, title: string, tables: object, default?: boolean}} corpus
		 * @throws {Error} On tables the engine cannot read.
		 */
		function setCorpus(corpus) {
			E.prepareNgrams(corpus.tables);
			const entry = { id: corpus.id, title: corpus.title, tables: corpus.tables };
			const at = state.hostCorpora.findIndex((c) => c.id === corpus.id);
			if (at >= 0) state.hostCorpora.splice(at, 1, entry);
			else state.hostCorpora.unshift(entry);
			fillCorpora();
			if (corpus.default) $('lo-corpus').value = corpus.id;
			syncCorpus();
			save();
		}

		// « My typing »: the app's keystats n-grams, the default corpus in the app.
		onNgrams = (ngrams) =>
			setCorpus({
				id: MY_TYPING_ID,
				title: t('layout_analysis.corpus.my_typing'),
				tables: ngrams,
				default: true
			});
		if (lastNgrams) onNgrams(lastNgrams);
		mounted = { setCorpus };
		return mounted;
	}

	// This folder's URL, read while the script runs: the worker and the sibling
	// pages resolve against it. A script a host inlines has none: it runs the
	// search on the page and opens no sibling page.
	const SCRIPT_BASE =
		document.currentScript && document.currentScript.src
			? new URL('.', document.currentScript.src).href
			: null;
	const BASE = SCRIPT_BASE || location.href;

	window.LAYOUT_OPTIMIZER_PAGE = { mount };

	/** The site's page: mount into its <main>. */
	function autostart() {
		const root = document.getElementById(STANDALONE_ROOT_ID);
		if (root) mount(root, { reportHeight: true });
	}

	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', autostart);
	else autostart();
})();
