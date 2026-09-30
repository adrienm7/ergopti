// tools/test/test-layer-editor-page.cjs

/**
 * ==============================================================================
 * MODULE: Layer Editor Page Regression
 * DESCRIPTION:
 * Executes the shared navigation layer editor page (index.html's scripts:
 * host_bridge.js, the generated layer data, layer_model.js and script.js)
 * against a minimal DOM and drives it through the host protocol every driver
 * speaks: "ready", init(), clicks, {action: "save", text}, saveResult().
 *
 * WHAT IS CHECKED:
 * 1. Render: every registry key with a geometry for the chosen form is drawn
 *    (the ISO Enter as two blocks), every mouse button and wheel direction is
 *    listed, and each input shows recommended / custom / unavailable.
 * 2. Pick: clicking a key and a picker row, a repeat count or a shortcut
 *    changes that key on this OS only, and the save payload is a layers.toml
 *    every OS's loader reads without an error.
 * 3. Presets: Restore recommended saves Ergopti's layer, Clear all saves no layer.
 * 4. Host replies: a refused save keeps the edits and says why; a first Close
 *    with unsaved edits warns instead of closing.
 * 5. Key captions (layer-editor-action-wrap): a key's action wraps over
 *    several lines of a readable size that its key holds at the window's
 *    default and minimum sizes, and its tooltip carries the whole text.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { shared } = require('../lib/paths.cjs');
const { loadContext, loadLayers, formatResolution } = require('../lib/keymap-layers.cjs');

const UI = shared('ui');
const APP = path.join(UI, 'layer_editor');
const HTML = fs.readFileSync(path.join(APP, 'index.html'), 'utf8');
const EN = JSON.parse(
	fs.readFileSync(shared('data', 'locales', 'en.json'), 'utf8').replace(/^\uFEFF/, '')
);
const RECOMMENDED_TEXT = fs.readFileSync(shared('keymap', 'layers.recommended.toml'), 'utf8');
const ctx = loadContext();

const errors = [];
const fail = (msg) => errors.push(msg);
let checks = 0;
function check(condition, msg) {
	checks += 1;
	if (!condition) fail(msg);
}

// ======================================
// ======================================
// ======= 1/ Minimal DOM ===============
// ======================================
// ======================================

/**
 * Loads the page with a DOM wide enough for what script.js touches.
 * @returns {object} The page handle: context, posts, element lookups, click().
 */
function loadPage() {
	const byId = new Map();
	const roots = [];
	const posts = [];
	const docListeners = {};

	function makeElement(tag) {
		const listeners = {};
		const el = {
			tagName: tag.toUpperCase(),
			id: '',
			className: '',
			textContent: '',
			title: '',
			value: '',
			type: '',
			min: '',
			max: '',
			placeholder: '',
			hidden: false,
			disabled: false,
			checked: false,
			style: {},
			dataset: {},
			children: [],
			parent: null,
			classList: {
				add: (...names) => {
					const set = new Set(el.className.split(/\s+/).filter(Boolean));
					names.forEach((n) => set.add(n));
					el.className = [...set].join(' ');
				},
				remove: (...names) => {
					el.className = el.className
						.split(/\s+/)
						.filter((n) => n && !names.includes(n))
						.join(' ');
				},
				contains: (n) => el.className.split(/\s+/).includes(n)
			},
			addEventListener(type, fn) {
				(listeners[type] = listeners[type] || []).push(fn);
			},
			dispatch(type, extra) {
				(listeners[type] || [])
					.slice()
					.forEach((fn) => fn(Object.assign({ target: el, preventDefault() {} }, extra || {})));
			},
			click() {
				el.dispatch('click');
			},
			appendChild(child) {
				child.parent = el;
				el.children.push(child);
				return child;
			},
			set innerHTML(_) {
				el.children = [];
			},
			get innerHTML() {
				return '';
			},
			focus() {},
			scrollIntoView() {}
		};
		return el;
	}

	for (const match of HTML.matchAll(/<(\w+)[^>]*\sid="([^"]+)"/g)) {
		const el = makeElement(match[1]);
		el.id = match[2];
		byId.set(el.id, el);
		roots.push(el);
	}

	function walk(visit) {
		const seen = new Set();
		const stack = roots.slice();
		while (stack.length) {
			const node = stack.pop();
			if (seen.has(node)) continue;
			seen.add(node);
			visit(node);
			for (const child of node.children) stack.push(child);
		}
	}

	const document = {
		readyState: 'complete',
		createElement: (tag) => makeElement(tag),
		getElementById(id) {
			if (byId.has(id) && byId.get(id).parent === null) return byId.get(id);
			let found = null;
			walk((node) => {
				if (!found && node.id === id) found = node;
			});
			return found;
		},
		addEventListener(type, fn) {
			(docListeners[type] = docListeners[type] || []).push(fn);
		},
		dispatchEvent(event) {
			(docListeners[event.type] || []).slice().forEach((fn) => fn(event));
		}
	};

	const storage = new Map();
	// The context's global object is the page's window, as in a browser, so the
	// UMD model's self.LayerModel is the bare LayerModel script.js reads.
	const context = vm.createContext({
		document,
		console,
		_i18n_strings: EN,
		localStorage: {
			getItem: (k) => (storage.has(k) ? storage.get(k) : null),
			setItem: (k, v) => storage.set(k, String(v))
		},
		// WebView2's channel: host_bridge.js posts a string as-is ("ready") and
		// any other payload as its JSON text.
		chrome: {
			webview: {
				postMessage: (message) => posts.push(message === 'ready' ? message : JSON.parse(message))
			}
		}
	});
	vm.runInContext('var window = this; var self = this;', context);
	for (const file of [
		path.join(UI, 'host_bridge.js'),
		path.join(APP, '_generated', 'layer_data.js'),
		path.join(APP, 'layer_model.js'),
		path.join(APP, 'script.js')
	]) {
		vm.runInContext(fs.readFileSync(file, 'utf8'), context, { filename: file });
	}
	(docListeners.DOMContentLoaded || []).forEach((fn) => fn({ type: 'DOMContentLoaded' }));

	const all = () => {
		const out = [];
		walk((node) => out.push(node));
		return out;
	};
	return {
		context,
		posts,
		el: (id) => document.getElementById(id),
		keys: (container) => {
			const out = [];
			(function visit(node) {
				for (const child of node.children) {
					if (child.classList.contains('key')) out.push(child);
					visit(child);
				}
			})(document.getElementById(container));
			return out;
		},
		binding: (code) => {
			const node = all().find(
				(n) =>
					n.classList.contains('key') &&
					n.dataset.code === code &&
					!n.classList.contains('enter-lower')
			);
			return node.children[0].children[1].textContent;
		},
		key: (code) =>
			all().find(
				(n) =>
					n.classList.contains('key') &&
					n.dataset.code === code &&
					!n.classList.contains('enter-lower')
			),
		rows: () => all().filter((n) => n.classList.contains('row')),
		row: (label) =>
			all().find(
				(n) => n.classList.contains('row') && n.children.some((c) => c.textContent === label)
			),
		call: (source) => vm.runInContext(source, context),
		lastSave: () => posts.filter((p) => p && p.action === 'save').pop()
	};
}

/** Every binding a saved file gives the edited layer on one OS. */
function bindingsOf(text, os) {
	const result = loadLayers(text, os, ctx);
	const out = {};
	for (const [code, r] of Object.entries(result.layers.nav || {})) out[code] = formatResolution(r);
	return { ok: result.ok, errors: result.errors, bindings: out };
}

const DATA = (() => {
	const sandbox = {};
	vm.createContext(sandbox);
	vm.runInContext(fs.readFileSync(path.join(APP, '_generated', 'layer_data.js'), 'utf8'), sandbox);
	return vm.runInContext('LAYER_EDITOR_DATA', sandbox);
})();

// =================================
// =================================
// ======= 2/ Render ===============
// =================================
// =================================

{
	const page = loadPage();
	check(page.posts[0] === 'ready', 'the page must post "ready" once its scripts are loaded');
	check(
		page.el('btn-save').disabled === true,
		'Save must stay disabled until the host has sent the file'
	);
	page.call(
		`init(${JSON.stringify({ os: 'windows', path: 'C:/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [] })})`
	);
	const isoKeys = DATA.keys.filter((k) => k.geometry && k.geometry.iso);
	const drawn = page.keys('board');
	check(isoKeys.length > 90, `only ${isoKeys.length} ISO keys in the data`);
	check(
		drawn.length === isoKeys.length + 1,
		`the ISO board draws ${drawn.length} blocks for ${isoKeys.length} keys (+1 for the Enter's lower row)`
	);
	check(
		page.keys('mouse').length ===
			DATA.keys.filter((k) => k.kind === 'mouse_button' || k.kind === 'wheel').length,
		'every mouse button and wheel direction must be listed'
	);
	check(
		page.key('KeyQ').classList.contains('recommended'),
		'KeyQ bound as recommended must show as recommended'
	);
	check(
		page.binding('KeyQ') === EN['layer_actions.sel_doc_start'],
		'KeyQ must show its action label'
	);
	check(
		page.binding('Digit1') === EN['layer_editor.value.repeat_count'].replace('{1}', '1'),
		'Digit1 must show its repeat count'
	);
	check(
		!page.key('WheelUp').classList.contains('unavailable'),
		'the wheel is a layer key on Windows'
	);

	page.el('form').value = 'ansi';
	page.el('form').dispatch('change');
	const ansiKeys = DATA.keys.filter((k) => k.geometry && k.geometry.ansi);
	check(
		page.keys('board').length === ansiKeys.length,
		`the ANSI board draws ${page.keys('board').length} blocks for ${ansiKeys.length} keys`
	);
	check(!page.key('IntlBackslash'), 'the ANSI board has no ISO key left of Z');
}

{
	const page = loadPage();
	page.call(
		`init(${JSON.stringify({ os: 'macos', path: '/cfg/layers.toml', text: null, errors: [] })})`
	);
	check(
		page.key('WheelUp').classList.contains('unavailable'),
		'the wheel cannot be a layer key on macOS'
	);
	check(
		page.key('WheelUp').title === EN['platform_reason.layer_wheel_source_is_windows_only'],
		'an unavailable input must say why'
	);
	check(
		page.key('KeyQ').classList.contains('custom'),
		'a key the recommended layer binds and the empty file does not is custom'
	);
	page.key('KeyA').click();
	check(page.el('repeat-apply').disabled === true, 'the repeat count cannot be picked on macOS');
	check(
		page.row(EN['sg_actions.spotlight']) &&
			!page.row(EN['sg_actions.spotlight']).classList.contains('disabled'),
		'Spotlight is offered on macOS'
	);
}

// =================================
// =================================
// ======= 3/ Pick and save ========
// =================================
// =================================

{
	const page = loadPage();
	page.call(
		`init(${JSON.stringify({ os: 'windows', path: 'C:/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [] })})`
	);
	page.key('KeyT').click();
	check(
		page.el('current-value').textContent.includes('F2'),
		'the panel must show what KeyT does now'
	);
	const spotlight = page.row(EN['sg_actions.spotlight']);
	check(
		spotlight && spotlight.classList.contains('disabled'),
		'Spotlight must be offered disabled on Windows'
	);
	spotlight.click();
	page.row(EN['sg_actions.arrow_up']).click();
	check(
		page.key('KeyT').classList.contains('custom'),
		'KeyT bound to something else than recommended must show as custom'
	);
	check(
		page.el('status').textContent === EN['layer_editor.unsaved'],
		'an edit must say it is not saved'
	);

	page.key('KeyY').click();
	page.el('mod-primary').checked = true;
	page.el('mod-shift').checked = true;
	page.el('keystroke-key').value = 'KeyZ';
	page.el('keystroke-apply').click();

	page.key('Digit5').click();
	page.el('repeat-count').value = '7';
	page.el('repeat-apply').click();

	page.key('KeyG').click();
	page.row(EN['layer_editor.value.native']).click();

	page.el('btn-save').click();
	const saved = page.lastSave();
	check(saved && typeof saved.text === 'string', 'Save must post {action: "save", text}');
	check(
		page.el('btn-save').disabled === true,
		'Save must wait for the host while a save is in flight'
	);
	if (saved) {
		const windows = bindingsOf(saved.text, 'windows');
		check(windows.ok, `the saved file must load on Windows: ${JSON.stringify(windows.errors)}`);
		check(
			windows.bindings.KeyT === 'keystroke:ArrowUp@repeat',
			`KeyT saved as ${windows.bindings.KeyT}`
		);
		check(
			windows.bindings.KeyY === 'keystroke:ctrl+shift+KeyZ',
			`KeyY saved as ${windows.bindings.KeyY}`
		);
		check(
			windows.bindings.Digit5 === 'repeat_count:7',
			`Digit5 saved as ${windows.bindings.Digit5}`
		);
		check(windows.bindings.KeyG === undefined, 'KeyG made native must not be bound on Windows');
		for (const os of ['macos', 'linux']) {
			const other = bindingsOf(saved.text, os);
			const before = bindingsOf(RECOMMENDED_TEXT, os);
			check(other.ok, `the saved file must load on ${os}: ${JSON.stringify(other.errors)}`);
			check(
				JSON.stringify(other.bindings) === JSON.stringify(before.bindings),
				`edits made on Windows changed ${os}`
			);
		}
	}

	page.call(
		`saveResult(${JSON.stringify({ saved: false, errors: [{ code: 'write_failed', detail: 'disk full' }] })})`
	);
	check(
		page.el('status').textContent === EN['layer_editor.save_refused'].replace('{1}', 'disk full'),
		'a refused save must say why'
	);
	check(page.el('btn-save').disabled === false, 'a refused save must let the user save again');
	page.el('btn-close').click();
	check(
		page.posts.every((p) => !p || p.action !== 'cancel'),
		'the first Close with unsaved edits must warn, not close'
	);
	check(
		page.el('status').textContent === EN['layer_editor.unsaved_close'],
		'the first Close must say the edits would be lost'
	);
	page.el('btn-close').click();
	check(
		page.posts.some((p) => p && p.action === 'cancel'),
		'the second Close must close'
	);
}

{
	const page = loadPage();
	page.call(
		`init(${JSON.stringify({ os: 'linux', path: '/cfg/layers.toml', text: null, errors: [] })})`
	);
	page.el('btn-restore').click();
	page.el('btn-save').click();
	const restored = page.lastSave();
	for (const os of DATA.platforms) {
		const got = bindingsOf(restored.text, os);
		const want = bindingsOf(RECOMMENDED_TEXT, os);
		check(
			got.ok && JSON.stringify(got.bindings) === JSON.stringify(want.bindings),
			`Restore recommended must save Ergopti's layer on ${os}`
		);
	}
	page.call('saveResult({ saved: true, applied: true, errors: [] })');
	check(page.el('status').textContent === EN['common.saved'], 'a successful save must say so');
	page.el('btn-clear').click();
	page.el('btn-save').click();
	const clearedText = page.lastSave().text;
	for (const os of DATA.platforms) {
		const got = bindingsOf(clearedText, os);
		check(
			got.ok && Object.keys(got.bindings).length === 0,
			`Clear all must save no binding on ${os}`
		);
	}
}

{
	const page = loadPage();
	page.call(
		`init(${JSON.stringify({ os: 'windows', path: 'C:/cfg/layers.toml', text: '[layers.nav.all\n', errors: [{ code: 'toml_invalid', detail: 'line 1' }] })})`
	);
	check(page.el('banner').hidden === false, 'an unreadable file must be announced');
	check(
		page
			.el('banner')
			.children[0].textContent.endsWith(EN['layer_editor.file_problem'].split('{2}')[1]),
		'the banner must say the file will be replaced'
	);
	check(
		page.key('KeyQ').classList.contains('custom'),
		'an unreadable file edits from an empty layer'
	);
	page.call(
		`init(${JSON.stringify({ os: 'windows', path: 'x', text: RECOMMENDED_TEXT, errors: [] })})`
	);
	check(
		page.key('KeyQ').classList.contains('custom'),
		'a second init must not replace the document being edited'
	);
}

{
	const page = loadPage();
	page.call(
		`init(${JSON.stringify({ os: 'linux', path: '/cfg/layers.toml', text: null, errors: [{ code: 'file_unreadable', detail: 'permission denied' }] })})`
	);
	check(
		!page.el('banner').hidden &&
			page.el('banner').children[0].textContent.includes('permission denied'),
		'a file the host cannot read must be announced'
	);
	page.call('saveResult({ saved: false, errors: {} })');
	check(
		page.el('status').textContent === EN['layer_editor.save_refused'].replace('{1}', '?'),
		'an empty error object from a Lua host is read as no error list'
	);
}

// ==================================================================
// ==================================================================
// ======= 5/ Key captions (layer-editor-action-wrap) ===============
// ==================================================================
// ==================================================================

// A key's action used to be one 9.5 px line cut with an ellipsis at the bottom
// of the key: unreadable. It now wraps over several lines of a readable size
// inside a key tall enough to hold them, and the key's tooltip carries the
// whole text. The CSS is read as data, so a rule that stops wrapping, shrinks
// the text or cuts the lines fails here, not only on a screen.

const CSS = fs.readFileSync(path.join(APP, 'style.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
// The smallest font size a key's action may use, in CSS pixels.
const MIN_BINDING_FONT_PX = 11;
// The fewest lines a key's action must be able to show at the default window size.
const MIN_BINDING_LINES = 3;
// The fewest lines it must still show at the window's minimum size.
const MIN_BINDING_LINES_AT_MIN_WIDTH = 2;
// Horizontal space the board does not get: #main's side padding and a
// vertical scrollbar (WebView2 draws a classic one).
const BOARD_SIDE_ALLOWANCE_PX = 36 + 17;
const APPS = JSON.parse(fs.readFileSync(path.join(UI, 'apps.manifest.json'), 'utf8'));

/** The declarations of the rule whose selector list is exactly `selector`. */
function cssRule(selector) {
	for (const match of CSS.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
		const selectors = match[1].split(',').map((s) => s.trim().replace(/\s+/g, ' '));
		if (!selectors.includes(selector)) continue;
		const out = {};
		for (const declaration of match[2].split(';')) {
			const at = declaration.indexOf(':');
			if (at > 0) out[declaration.slice(0, at).trim()] = declaration.slice(at + 1).trim();
		}
		return out;
	}
	return null;
}

/** A length in px (`12px`), or NaN. */
function px(value) {
	const m = /^(-?\d+(?:\.\d+)?)px$/.exec(String(value || '').trim());
	return m ? Number(m[1]) : NaN;
}

/** The four sides of a padding shorthand, in px. */
function paddingOf(value) {
	const parts = String(value || '0px')
		.trim()
		.split(/\s+/)
		.map((p) => (p === '0' ? 0 : px(p)));
	const [top, right = top, bottom = top] = parts;
	return { top, right, bottom, left: parts.length === 4 ? parts[3] : right };
}

/** A unitless line-height times the font size, in px. */
function lineHeightPx(rule) {
	const factor = Number(rule['line-height']);
	return factor * px(rule['font-size']);
}

{
	const binding = cssRule('.key .binding');
	const legend = cssRule('.key .legend');
	const cap = cssRule('.key .cap');
	const slot = cssRule('.key');
	check(binding !== null, '(layer-editor-action-wrap) style.css has no `.key .binding` rule');
	check(
		legend !== null && cap !== null && slot !== null,
		'(layer-editor-action-wrap) a key rule is missing'
	);
	if (binding && legend && cap && slot) {
		check(
			binding['white-space'] === 'normal',
			`(layer-editor-action-wrap) a key's action must wrap (white-space: normal), not ${binding['white-space']}`
		);
		check(
			binding['overflow-wrap'] === 'anywhere' || binding['word-break'] === 'break-word',
			"(layer-editor-action-wrap) a key's action must break a word longer than the key"
		);
		check(
			!('text-overflow' in binding),
			"(layer-editor-action-wrap) a key's action is clamped by lines, never cut on one line"
		);
		const fontPx = px(binding['font-size']);
		check(
			fontPx >= MIN_BINDING_FONT_PX,
			`(layer-editor-action-wrap) a key's action is ${binding['font-size']}, below ${MIN_BINDING_FONT_PX}px`
		);
		const clamp = Number(binding['-webkit-line-clamp']);
		check(
			Number.isInteger(clamp) && clamp >= MIN_BINDING_LINES,
			`(layer-editor-action-wrap) a key's action must be clamped to at least ${MIN_BINDING_LINES} lines, not ${binding['-webkit-line-clamp']}`
		);
		check(
			binding.display === '-webkit-box' && binding['-webkit-box-orient'] === 'vertical',
			'(layer-editor-action-wrap) the line clamp needs display: -webkit-box and a vertical box'
		);
		check(
			binding.overflow === 'hidden' && binding['min-height'] === '0',
			"(layer-editor-action-wrap) the action must shrink inside its key's cap and hide what does not fit"
		);

		// The lines a 1u key holds at a window width, with the page's own board.
		const page = loadPage();
		page.call(
			`init(${JSON.stringify({ os: 'windows', path: 'C:/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [] })})`
		);
		const columns = Math.max(
			...DATA.keys
				.filter((k) => k.geometry && k.geometry.iso)
				.map((k) => {
					const g = k.geometry.iso;
					return Math.max(
						g.col + g.width,
						g.bottom_col !== undefined ? g.bottom_col + g.bottom_width : 0
					);
				})
		);
		const rows = page.call('BOARD_ROWS + FUNCTION_ROW_GAP');
		const boardRatio = parseFloat(page.el('board').style.paddingTop) / 100;
		const keyHeightPerWidth = (boardRatio * columns) / rows;
		const slotPad = paddingOf(slot.padding);
		const capPad = paddingOf(cap.padding);
		const border = px(String(cap.border).split(/\s+/)[0]);
		const gap = cap.gap === undefined ? 0 : px(cap.gap);
		const linesAt = (windowWidth) => {
			const unit = (windowWidth - BOARD_SIDE_ALLOWANCE_PX) / columns;
			const inner =
				unit * keyHeightPerWidth -
				slotPad.top -
				slotPad.bottom -
				2 * border -
				capPad.top -
				capPad.bottom;
			return Math.floor((inner - lineHeightPx(legend) - gap) / lineHeightPx(binding) + 1e-9);
		};
		const app = APPS.apps ? APPS.apps.layer_editor : APPS.layer_editor;
		check(
			app && linesAt(app.width) >= Math.min(clamp, MIN_BINDING_LINES),
			`(layer-editor-action-wrap) a 1u key holds ${app && linesAt(app.width)} line(s) of its action at the default ${app && app.width}px window, not ${MIN_BINDING_LINES}`
		);
		check(
			app && linesAt(app.min_width) >= MIN_BINDING_LINES_AT_MIN_WIDTH,
			`(layer-editor-action-wrap) a 1u key holds ${app && linesAt(app.min_width)} line(s) of its action at the minimum ${app && app.min_width}px window`
		);
		check(
			page.key('KeyQ').title === EN['layer_actions.sel_doc_start'],
			`(layer-editor-action-wrap) a key's tooltip must carry its whole action, not "${page.key('KeyQ').title}"`
		);
		check(
			page.key('Digit1').title === EN['layer_editor.value.repeat_count'].replace('{1}', '1'),
			"(layer-editor-action-wrap) a repeat count's tooltip must carry its whole text"
		);
	}
}

if (checks < 40) fail(`only ${checks} checks ran (floor 40)`);
if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the layer editor page breaks the host protocol:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] layer editor page: ${checks} checks — render, pick, save payload, presets and host replies.\x1b[0m`
);
