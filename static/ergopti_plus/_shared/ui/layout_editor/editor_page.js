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
 * 3. Every visible string is a locale key (21 locales, _shared/data/locales).
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
var LayoutEditorPage = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const PREFIX = 'layout_editor.';
	const KEY_UNIT_PX = 46;
	const MAPPING_CHOICES = ['none', 'text', 'dead_key', 'action', 'key', 'disabled'];
	const BUILTIN_MODIFIERS = ['shift', 'control', 'alt', 'meta', 'caps_lock'];
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
	const TAP_HOLD_THRESHOLD_STEP = 10;

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
	function visible(text) {
		if (text === '') return '∅';
		if (text === ' ') return '␣';
		return Array.from(text)
			.map((c) => {
				const code = c.codePointAt(0);
				if (code < 0x20) return String.fromCodePoint(0x2400 + code);
				if (code >= 0x300 && code <= 0x36f) return '◌' + c;
				return c;
			})
			.join('');
	}

	/** A short legend for a mapping on the board. */
	function legend(mapping, doc) {
		if (!mapping) return '';
		const kind = LayoutEditorModel.kindOf(mapping);
		if (kind === 'text') return visible(mapping.text);
		if (kind === 'dead_key') {
			const dead = (doc.dead_keys || []).find((entry) => entry.id === mapping.dead_key);
			return '◌' + (dead && dead.terminator ? visible(dead.terminator) : '');
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
	 *   savedStatus names the message shown after a save; onClose leaves the editor.
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
			numpad: false,
			deadKey: null,
			paletteBlock: PALETTE_BLOCKS[0].id,
			presses: [],
			locked: new Set(),
			heldCustom: new Set(),
			message: null,
			// A pending question: { text, onYes }. In-page, because a webview
			// host may not show window.confirm (WKWebView needs a UI delegate).
			confirm: null,
			// Whether the exact import refused the file, so the approximate one is offered.
			approximate: false,
			// Physical modifier keys held in the preview, as sided modifier ids.
			heldSides: new Set(),
			lost: null,
			dirty: false
		};
		const doc = () => state.history.current();

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

		function replace(next, lost) {
			state.history.reset(next);
			state.layer = (next.layers || []).some((l) => l.id === 'base') ? 'base' : null;
			state.selected = null;
			state.presses = [];
			state.lost = lost || null;
			state.dirty = false;
			state.deadKey = null;
			state.approximate = false;
		}

		// ============================
		// ======= 4/ Files ===========
		// ============================

		function openText(name, text) {
			if (/\.keylayout$/i.test(name)) {
				const convention = root.querySelector('#le-import-convention').value;
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
			Promise.resolve(host.saveFile(filename, text, mime)).then(
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
			const hold = root.querySelector('#le-nav-hold').value;
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

		function toolbar() {
			const fileInput = el('input', {
				type: 'file',
				id: 'le-open-file',
				accept: '.toml,.keylayout',
				hidden: true,
				onchange: (event) => readFile(event.target, openText)
			});
			const navInput = el('input', {
				type: 'file',
				id: 'le-nav-file',
				accept: '.toml',
				hidden: true,
				onchange: (event) => readFile(event.target, importNav)
			});
			const keyOptions = [['', tl('nav_hold_placeholder')]].concat(
				data.keys.filter((k) => k.kind === 'key').map((k) => [k.code, keyName(k.code)])
			);
			return el('div', { class: 'le-toolbar' }, [
				el('button', {
					type: 'button',
					id: 'le-new',
					text: tl('btn.new'),
					onclick: () => {
						const fresh = () => {
							replace(LayoutSourceIO.create('my_layout', tl('default_name')));
							render();
						};
						if (state.dirty) ask(tl('discard_confirm'), fresh);
						else fresh();
					}
				}),
				el('button', {
					type: 'button',
					id: 'le-open',
					text: tl('btn.open'),
					onclick: () => fileInput.click()
				}),
				el('label', { class: 'le-inline' }, [
					tl('import_convention'),
					select(
						[
							['iso', tl('physical.iso')],
							['ansi', tl('physical.ansi')]
						],
						'iso',
						() => {},
						{ id: 'le-import-convention' }
					)
				]),
				fileInput,
				el('button', {
					type: 'button',
					id: 'le-save',
					class: 'primary',
					text: tl('btn.save'),
					onclick: saveSource
				}),
				el('button', {
					type: 'button',
					id: 'le-undo',
					text: tl('btn.undo'),
					disabled: !state.history.canUndo(),
					onclick: () => {
						state.history.undo();
						render();
					}
				}),
				el('button', {
					type: 'button',
					id: 'le-redo',
					text: tl('btn.redo'),
					disabled: !state.history.canRedo(),
					onclick: () => {
						state.history.redo();
						render();
					}
				}),
				el('button', {
					type: 'button',
					id: 'le-print',
					text: tl('btn.print'),
					onclick: () => window.print()
				}),
				el('span', { class: 'le-sep' }),
				el('label', { class: 'le-inline' }, [
					tl('nav_hold'),
					select(keyOptions, '', () => {}, { id: 'le-nav-hold' })
				]),
				el('button', {
					type: 'button',
					id: 'le-nav-import',
					text: tl('btn.nav_import'),
					disabled: LayoutSourceIO.isPreserved(doc()),
					onclick: () => navInput.click()
				}),
				navInput,
				host.onClose
					? el('button', {
							type: 'button',
							id: 'le-close',
							text: tl('btn.close'),
							onclick: host.onClose
						})
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
			return el('section', { class: 'le-meta' }, [
				field('name', 'le-name'),
				field('description', 'le-description'),
				field('author', 'le-author'),
				el('p', { class: 'le-note', text: tl('meta.id', { id: layout.id }) })
			]);
		}

		// ============================
		// ======= 7/ Layers ==========
		// ============================

		function modifierOptions() {
			return BUILTIN_MODIFIERS.concat((doc().modifiers || []).map((m) => m.id));
		}

		function layerTabs() {
			const tabs = LayoutEditorModel.layers(doc()).map((layer) =>
				el('button', {
					type: 'button',
					class: `le-tab${layer.id === state.layer ? ' active' : ''}`,
					'data-layer': layer.id,
					title: layer.required.join('+') || tl('layer.no_modifier'),
					text: layer.id,
					onclick: () => {
						state.layer = layer.id;
						render();
					}
				})
			);
			const idInput = el('input', {
				type: 'text',
				id: 'le-layer-id',
				placeholder: tl('layer.id_placeholder')
			});
			const checks = modifierOptions().map((id) =>
				el('label', { class: 'le-check' }, [el('input', { type: 'checkbox', value: id }), id])
			);
			const addForm = el('details', { class: 'le-add' }, [
				el('summary', { text: tl('layer.add') }),
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
						if (doc().layers.some((l) => l.id === id)) {
							state.layer = id;
							render();
						}
					}
				}),
				state.layer && state.layer !== 'base'
					? el('button', {
							type: 'button',
							id: 'le-layer-remove',
							class: 'danger',
							text: tl('layer.remove', { id: state.layer }),
							onclick: () => {
								const removed = state.layer;
								apply((d) => LayoutEditorModel.removeLayer(d, removed));
								if (!doc().layers.some((l) => l.id === removed)) {
									state.layer = 'base';
									render();
								}
							}
						})
					: null
			]);
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
			return el('section', { class: 'le-layers' }, [
				el('div', { class: 'le-tabs', role: 'tablist' }, tabs),
				el('label', { class: 'le-inline' }, [tl('scope.label'), scope]),
				el('label', { class: 'le-inline' }, [
					el('input', {
						type: 'checkbox',
						id: 'le-numpad',
						checked: state.numpad,
						onchange: (event) => {
							state.numpad = event.target.checked;
							render();
						}
					}),
					tl('numpad')
				]),
				LayoutSourceIO.isPreserved(doc()) ? null : addForm
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

		function board() {
			const keys = data.keys.filter(
				(k) =>
					k.kind === 'key' && k.geometry && k.geometry.iso && (state.numpad || k.group !== 'numpad')
			);
			const width = Math.max(...keys.map((k) => k.geometry.iso.col + k.geometry.iso.width));
			const height = Math.max(
				...keys.map((k) => k.geometry.iso.row + (k.geometry.iso.height || 1))
			);
			const container = el('div', {
				class: 'le-board',
				id: 'le-board',
				style: `width:${width * KEY_UNIT_PX}px;height:${height * KEY_UNIT_PX}px`
			});
			const remap = doc().remap || {};
			for (const key of keys) {
				const g = key.geometry.iso;
				const found = currentMapping(key.code);
				const classes = ['le-key'];
				if (found) classes.push(found.scope === 'all' ? 'mapped' : 'platform');
				if (key.code === state.selected) classes.push('selected');
				if (Object.prototype.hasOwnProperty.call(remap, key.code)) classes.push('remapped');
				container.append(
					el(
						'button',
						{
							type: 'button',
							class: classes.join(' '),
							'data-code': key.code,
							title: keyName(key.code),
							style:
								`left:${g.col * KEY_UNIT_PX}px;top:${g.row * KEY_UNIT_PX}px;` +
								`width:${g.width * KEY_UNIT_PX - 4}px;height:${(g.height || 1) * KEY_UNIT_PX - 4}px`,
							onclick: () => {
								state.selected = key.code;
								render();
							}
						},
						[
							el('span', { class: 'le-legend', text: found ? legend(found.mapping, doc()) : '' }),
							el('span', { class: 'le-code', text: keyName(key.code) })
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
				el('button', {
					type: 'button',
					id: 'le-apply',
					class: 'primary',
					text: tl('btn.apply'),
					onclick: () =>
						apply((d) =>
							LayoutEditorModel.setMapping(d, state.layer, code, built(), state.platform || null)
						)
				})
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
						title: `U+${point.toString(16).toUpperCase().padStart(4, '0')}`,
						text: visible(char),
						onclick: () => {
							target.value += char;
							target.focus();
						}
					})
				);
			}
			const hex = el('input', { type: 'text', id: 'le-codepoint', placeholder: 'U+00E9', size: 8 });
			return el('details', { class: 'le-palette' }, [
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
				grid
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
			return el('div', { class: 'le-group' }, [
				el('h3', { text: tl('inspector.key') }),
				el('label', { class: 'le-field' }, [tl('caps.label'), capsSelect]),
				el('label', { class: 'le-field' }, [tl('caps.layer'), capsLayer]),
				el('label', { class: 'le-field' }, [tl('caps.shift_layer'), capsShift]),
				el('label', { class: 'le-field' }, [tl('key.name'), nameInput]),
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
			return el('div', { class: 'le-group' }, [
				el('h3', { text: tl('inspector.remap') }),
				select(
					options,
					current === null ? '__none' : current,
					(value) =>
						apply((d) => LayoutEditorModel.setRemap(d, code, value === '__none' ? null : value)),
					{ id: 'le-remap' }
				)
			]);
		}

		function shortcutEditor(code) {
			const shortcuts = (doc().shortcuts || []).filter((s) => s.key === code);
			const modifierChecks = (prefix) =>
				modifierOptions().map((id) =>
					el('label', { class: 'le-check' }, [
						el('input', { type: 'checkbox', value: id, 'data-group': prefix }),
						id
					])
				);
			const from = modifierChecks('from');
			const to = modifierChecks('to');
			const sendKey = select(
				data.keys.filter((k) => k.kind === 'key').map((k) => [k.code, keyName(k.code)]),
				code,
				() => {},
				{ id: 'le-shortcut-send' }
			);
			const checked = (list) =>
				list
					.map((c) => c.firstChild)
					.filter((c) => c.checked)
					.map((c) => c.value);
			return el('div', { class: 'le-group' }, [
				el('h3', { text: tl('inspector.shortcuts') }),
				el(
					'ul',
					{ class: 'le-list', id: 'le-shortcuts' },
					shortcuts.map((s) =>
						el('li', {}, [
							`${s.modifiers.concat([keyName(s.key)]).join('+')} → ${s.send_modifiers.concat([keyName(s.send_key)]).join('+')} `,
							el('button', {
								type: 'button',
								class: 'danger',
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
					text: tl('btn.add'),
					onclick: () =>
						apply((d) =>
							LayoutEditorModel.setShortcut(d, {
								key: code,
								modifiers: checked(from),
								send_key: sendKey.value,
								send_modifiers: checked(to)
							})
						)
				})
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
			const threshold = el('input', {
				type: 'number',
				id: 'le-threshold',
				min: 1,
				step: TAP_HOLD_THRESHOLD_STEP,
				value: entry ? entry.threshold_ms : ''
			});
			return el('div', { class: 'le-group' }, [
				el('h3', { text: tl('inspector.tap_hold') }),
				el('label', { class: 'le-field' }, [tl('tap_hold.tap_text'), tapText]),
				el('label', { class: 'le-field' }, [tl('tap_hold.hold'), hold]),
				el('label', { class: 'le-field' }, [tl('tap_hold.threshold'), threshold]),
				el('button', {
					type: 'button',
					id: 'le-tap-hold-apply',
					text: tl('btn.apply'),
					onclick: () => {
						const [kind, id] = hold.value.split(':');
						const next = {
							key: code,
							tap: tapText.value === '' ? { key: code } : { text: tapText.value },
							threshold_ms: Number(threshold.value)
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
				state.layer ? mappingEditor(code) : null,
				keyProperties(code),
				remapEditor(code),
				shortcutEditor(code),
				tapHoldEditor(code)
			]);
		}

		// ==================================
		// ======= 10/ Modifiers, dead keys ==
		// ==================================

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
			return el('details', { class: 'le-panel', id: 'le-modifiers' }, [
				el('summary', { text: tl('modifier.title') }),
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
				el('summary', { text: tl('dead.title') }),
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
			return el(
				'details',
				{ class: 'le-panel', id: 'le-dead-keys', open: Boolean(current) },
				parts
			);
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
			return held;
		}

		function customModifier(code) {
			return (doc().modifiers || []).find((m) => m.keys.includes(code));
		}

		function preview() {
			const result = LayoutSourceIO.isPreserved(doc())
				? { text: '', pending: null }
				: LayoutEditorModel.simulate(doc(), state.presses, state.platform || null);
			const output = el('output', {
				class: 'le-preview-output',
				id: 'le-preview-output',
				text: result.text
			});
			const pad = el('input', {
				type: 'text',
				id: 'le-preview-input',
				placeholder: tl('preview.placeholder'),
				onkeydown: (event) => {
					const modifier = customModifier(event.code);
					event.preventDefault();
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
					state.presses.push({ code: event.code, held: heldModifiers(event) });
					renderPreviewOnly();
				},
				onkeyup: (event) => {
					state.heldSides.delete(SIDED_MODIFIERS[event.code]);
					const modifier = customModifier(event.code);
					if (modifier && modifier.mode === 'held') state.heldCustom.delete(modifier.id);
				}
			});
			return el('section', { class: 'le-preview' }, [
				el('h2', { text: tl('preview.title') }),
				pad,
				output,
				result.pending
					? el('p', { class: 'le-note', text: tl('preview.pending', { id: result.pending }) })
					: null,
				el('button', {
					type: 'button',
					id: 'le-preview-clear',
					text: tl('btn.clear'),
					onclick: () => {
						state.presses = [];
						render();
					}
				})
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
						Promise.resolve(host.install(payload)).then(
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
			for (const variant of ['iso', 'ansi']) {
				let file = null;
				try {
					file = LayoutSourceIO.keylayoutFile(doc(), variant);
				} catch (error) {
					// This variant is not producible here; the report row says why.
				}
				if (file)
					buttons.push(
						el('button', {
							type: 'button',
							id: `le-export-keylayout-${variant}`,
							text: tl(`export.keylayout_${variant}`),
							onclick: () => save(file.filename, file.text, 'application/xml')
						})
					);
			}
			if (host.install) buttons.push(installButton(report));
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
			const macFormat = ((doc().exports || {}).macos || {}).format || 'bundle';
			return el('section', { class: 'le-export', id: 'le-export' }, [
				el('h2', { text: tl('export.title') }),
				el('label', { class: 'le-inline' }, [
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
				el('p', { class: 'le-note', text: tl('export.bundle_note') }),
				el('p', { class: 'le-note', text: tl('export.tooling_note') }),
				el('code', {
					class: 'le-cli',
					text: `npm run layout-source -- export-xkb ${doc().layout.id}.toml out-linux`
				}),
				el('div', { class: 'le-buttons' }, buttons)
			]);
		}

		// ============================
		// ======= 13/ Stickers =======
		// ============================

		/** Printable key caps: one sticker per key with its four character levels. */
		function stickers() {
			const levels = STICKER_LAYERS.filter((id) => (doc().layers || []).some((l) => l.id === id));
			const keys = data.keys.filter((k) => k.kind === 'key' && k.character);
			return el(
				'section',
				{ class: 'le-stickers', id: 'le-stickers', 'aria-hidden': 'true' },
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
										text: found ? legend(found.mapping, doc()) : ''
									});
								})
							)
						)
			);
		}

		// ============================
		// ======= 14/ Render =========
		// ============================

		function render() {
			keyView = makeKeyView(doc(), state.platform || host.platform || null);
			root.replaceChildren(
				el('header', { class: 'le-header' }, [
					el('h1', { text: tl('title') }),
					el('p', { class: 'le-subtitle', text: tl('subtitle') })
				]),
				toolbar(),
				messageBar(),
				metadata(),
				layerTabs(),
				el('div', { class: 'le-main' }, [board(), inspector()]),
				el('div', { class: 'le-panels' }, [
					LayoutSourceIO.isPreserved(doc()) ? null : modifiersPanel(),
					LayoutSourceIO.isPreserved(doc()) ? null : deadKeysPanel()
				]),
				preview(),
				exportPanel(),
				stickers()
			);
		}

		if (typeof host.initial === 'string') {
			const parsed = LayoutSourceIO.parse(host.initial);
			if (parsed.ok) replace(parsed.doc);
			else state.message = { kind: 'error', text: problemText(parsed.error) };
		}
		render();
		document.addEventListener('i18n:applied', () => {
			// The first document is made before the locale arrives: give an untouched one its translated name.
			const untouched =
				!state.dirty && !state.history.canUndo() && !LayoutSourceIO.isPreserved(doc());
			if (untouched && doc().layout.name === PREFIX + 'default_name')
				state.history.reset(LayoutEditorModel.setLayout(doc(), { name: tl('default_name') }));
			render();
		});
		return {
			open: (name, text) => openText(name, text),
			current: () => doc(),
			render
		};
	}

	return { mount, t };
})();
