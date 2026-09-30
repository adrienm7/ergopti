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
 * 6. Legends (layer-editor-current-layout-legends): a character key shows what
 *    the host says the user's layout types on it (the shared corpus
 *    _shared/tests/corpus/layer_editor/legends.json), never a QWERTY letter
 *    of the page's own; a key the host did not resolve shows its registry
 *    code; a named key its translated name; the host is asked again when the
 *    window comes back to the front, and its answer keeps the edits.
 * 7. Keycaps: a bound key shows its action's catalogue label, icon and words,
 *    or the short form of a repeat count or a shortcut (read with the key's
 *    current legend); an unbound key only its legend; the key whose hold
 *    enters the layer is marked; the numeric keypad shows when asked or when
 *    one of its keys is bound.
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
const LEGENDS_CORPUS = JSON.parse(
	fs.readFileSync(shared('tests', 'corpus', 'layer_editor', 'legends.json'), 'utf8')
);
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
	const windowListeners = {};
	// The context's global object is the page's window, as in a browser, so the
	// UMD model's self.LayerModel is the bare LayerModel script.js reads.
	const context = vm.createContext({
		document,
		console,
		addEventListener(type, fn) {
			(windowListeners[type] = windowListeners[type] || []).push(fn);
		},
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
		// What a key shows as its action: icon then words, as one text.
		binding: (code) => {
			const node = all().find(
				(n) =>
					n.classList.contains('key') &&
					n.dataset.code === code &&
					!n.classList.contains('enter-lower')
			);
			const action = node.children[0].children.find((c) => c.className.split(' ')[0] === 'action');
			return action ? action.children.map((c) => c.textContent).join('') : '';
		},
		// The legend in a key's corner.
		legend: (code) => {
			const node = all().find(
				(n) =>
					n.classList.contains('key') &&
					n.dataset.code === code &&
					!n.classList.contains('enter-lower')
			);
			const legend = node.children[0].children.find((c) => c.className === 'legend');
			return legend ? legend.textContent : null;
		},
		fireWindow: (type) => (windowListeners[type] || []).slice().forEach((fn) => fn({ type })),
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
	// The keypad is hidden until asked for or bound (section 7).
	const isoKeys = DATA.keys.filter((k) => k.geometry && k.geometry.iso && k.group !== 'numpad');
	const drawn = page.keys('board');
	check(isoKeys.length > 75, `only ${isoKeys.length} ISO keys in the data`);
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
		page.binding('Digit1') === EN['layer_editor.caption.repeat_count'].replace('{1}', '1'),
		`Digit1 must show its repeat count, not "${page.binding('Digit1')}"`
	);
	check(
		!page.key('WheelUp').classList.contains('unavailable'),
		'the wheel is a layer key on Windows'
	);

	page.el('form').value = 'ansi';
	page.el('form').dispatch('change');
	const ansiKeys = DATA.keys.filter((k) => k.geometry && k.geometry.ansi && k.group !== 'numpad');
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
		!page.key('WheelUp').classList.contains('unavailable') &&
			page.key('WheelUp').classList.contains('custom'),
		'the wheel is a layer key on macOS, recommended as volume and unbound in an empty file'
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

// The wheel slots (layer-wheel-slots): Scroll up and down are layer inputs on
// Windows and macOS, volume up and down by default, editable like any key;
// Linux cannot intercept the wheel and says so.
for (const os of ['windows', 'macos']) {
	const page = loadPage();
	page.call(
		`init(${JSON.stringify({ os, path: '/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [] })})`
	);
	check(
		page.binding('WheelUp') === EN['sg_actions.vol_up'] &&
			page.binding('WheelDown') === EN['sg_actions.vol_down'] &&
			page.key('WheelUp').classList.contains('recommended'),
		`(layer-wheel-slots) the recommended wheel is volume up and down on ${os}, shows "${page.binding('WheelUp')}"`
	);
	page.key('WheelUp').click();
	page.row(EN['sg_actions.mute']).click();
	page.el('btn-save').click();
	const saved = page.lastSave();
	const edited = saved && bindingsOf(saved.text, os);
	check(
		edited && edited.ok && edited.bindings.WheelUp === 'keystroke:AudioVolumeMute',
		`(layer-wheel-slots) the wheel slot takes another action on ${os}: ${edited && edited.bindings.WheelUp}`
	);
	for (const other of DATA.platforms.filter((o) => o !== os))
		check(
			bindingsOf(saved.text, other).ok,
			`(layer-wheel-slots) an edited ${os} wheel slot still loads on ${other}`
		);
}
{
	const page = loadPage();
	page.call(
		`init(${JSON.stringify({ os: 'linux', path: '/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [] })})`
	);
	check(
		page.key('WheelUp').classList.contains('unavailable') &&
			page.key('WheelUp').title === EN['platform_reason.layer_wheel_source_is_not_linux'],
		'(layer-wheel-slots) the wheel cannot be a layer key on Linux, and the key says why'
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

/**
 * Runs one section of checks: an exception is one failed check naming the
 * section, so a page that breaks early cannot hide the sections after it.
 */
function section(name, fn) {
	try {
		fn();
	} catch (e) {
		check(false, `(${name}) threw: ${e.message}`);
	}
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

section('layer-editor-action-wrap', () => {
	const binding = cssRule('.key .action');
	const legend = cssRule('.key .legend');
	const cap = cssRule('.key .cap');
	const slot = cssRule('.key');
	check(binding !== null, '(layer-editor-action-wrap) style.css has no `.key .action` rule');
	check(
		legend !== null && cap !== null && slot !== null,
		'(layer-editor-action-wrap) a key rule is missing'
	);
	// The rule of the narrow window: a 1u key holds one line less there.
	const narrow = /@media\s*\(max-width:\s*(\d+)px\)\s*\{\s*\.key \.action\s*\{([^}]*)\}/.exec(CSS);
	check(
		narrow !== null,
		'(layer-editor-action-wrap) style.css has no narrow-window clamp for `.key .action`'
	);
	if (binding && legend && cap && slot && narrow) {
		check(
			binding['white-space'] === 'normal',
			`(layer-editor-action-wrap) a key's action must wrap (white-space: normal), not ${binding['white-space']}`
		);
		check(
			binding['overflow-wrap'] === 'break-word' || binding['overflow-wrap'] === 'anywhere',
			"(layer-editor-action-wrap) a key's action must break a word longer than the key"
		);
		check(
			!('text-overflow' in binding),
			"(layer-editor-action-wrap) a key's action is clamped by lines, never cut on one line"
		);
		check(
			cap.display === undefined || cap.display === 'block',
			'(layer-editor-action-wrap) the cap is a plain block: a line clamp inside a flex column collapsed in WebKit'
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
		const narrowWidth = Number(narrow[1]);
		const narrowClamp = Number((/-webkit-line-clamp:\s*(\d+)/.exec(narrow[2]) || [])[1]);
		check(
			narrowClamp >= MIN_BINDING_LINES_AT_MIN_WIDTH,
			`(layer-editor-action-wrap) the narrow window clamps a key's action to ${narrowClamp} line(s)`
		);
		check(
			binding.display === '-webkit-box' && binding['-webkit-box-orient'] === 'vertical',
			'(layer-editor-action-wrap) the line clamp needs display: -webkit-box and a vertical box'
		);
		check(
			binding.overflow === 'hidden',
			"(layer-editor-action-wrap) the action must hide what does not fit in its key's cap"
		);

		// The lines a 1u key holds at a window width, with the page's own board,
		// keypad shown: its widest, so its narrowest keys.
		const page = loadPage();
		page.call(
			`init(${JSON.stringify({ os: 'windows', path: 'C:/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [] })})`
		);
		page.el('numpad').checked = true;
		page.el('numpad').dispatch('change');
		const columns = page.call('boardColumns(boardKeys({}))');
		check(columns > 20, `the board with its keypad is ${columns} columns wide`);
		const rows = page.call('BOARD_ROWS + FUNCTION_ROW_GAP');
		const boardRatio = parseFloat(page.el('board').style.paddingTop) / 100;
		const keyHeightPerWidth = (boardRatio * columns) / rows;
		const slotPad = paddingOf(slot.padding);
		const capPad = paddingOf(cap.padding);
		const border = px(String(cap.border).split(/\s+/)[0]);
		const margin = binding['margin-top'] === undefined ? 0 : px(binding['margin-top']);
		const linesAt = (windowWidth) => {
			const unit = (windowWidth - BOARD_SIDE_ALLOWANCE_PX) / columns;
			const inner =
				unit * keyHeightPerWidth -
				slotPad.top -
				slotPad.bottom -
				2 * border -
				capPad.top -
				capPad.bottom;
			return Math.floor((inner - lineHeightPx(legend) - margin) / lineHeightPx(binding) + 1e-9);
		};
		const app = APPS.apps ? APPS.apps.layer_editor : APPS.layer_editor;
		check(
			app && app.width > narrowWidth && linesAt(app.width) >= clamp,
			`(layer-editor-action-wrap) a 1u key holds ${app && linesAt(app.width)} line(s) of its action at the default ${app && app.width}px window, not ${clamp}`
		);
		check(
			linesAt(narrowWidth + 1) >= clamp,
			`(layer-editor-action-wrap) a 1u key holds ${linesAt(narrowWidth + 1)} line(s) just above the ${narrowWidth}px breakpoint, not ${clamp}`
		);
		check(
			app && app.min_width <= narrowWidth && linesAt(app.min_width) >= narrowClamp,
			`(layer-editor-action-wrap) a 1u key holds ${app && linesAt(app.min_width)} line(s) of its action at the minimum ${app && app.min_width}px window, not ${narrowClamp}`
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
});

// ==========================================================================
// ==========================================================================
// ======= 6/ Legends (layer-editor-current-layout-legends) =================
// ==========================================================================
// ==========================================================================

// Every key used to show a QWERTY letter the page spelled from its code
// (KeyQ -> "Q"), whatever the user typed with. A character key now shows what
// its host read from the user's layout, and nothing the page made up.

const CHARACTER_CODES = DATA.keys.filter((k) => k.character === true).map((k) => k.code);
check(
	CHARACTER_CODES.length >= 45,
	`only ${CHARACTER_CODES.length} keys are marked as typing the layout's characters`
);

section('layer-editor-current-layout-legends: no legend', () => {
	// A host that sent no legend: the page shows each character key's registry
	// code, never a letter of its own.
	const page = loadPage();
	page.call(
		`init(${JSON.stringify({ os: 'windows', path: 'C:/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [] })})`
	);
	for (const code of CHARACTER_CODES) {
		const legend = page.legend(code);
		if (legend === null) continue;
		check(
			legend === code,
			`(layer-editor-current-layout-legends) ${code} shows "${legend}" with no legend from its host, not its code`
		);
	}
	check(
		(page.el('legend-source') || { textContent: '' }).textContent.includes(
			EN['layer_editor.legends.missing']
		),
		'(layer-editor-current-layout-legends) the page must say why keys show their code'
	);
});

section('layer-editor-current-layout-legends: corpus', () => {
	for (const vector of LEGENDS_CORPUS.cases) {
		for (const os of DATA.platforms) {
			const page = loadPage();
			page.call(
				`init(${JSON.stringify({ os, path: '/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [], legends: { source: vector.source, keys: vector.expected }, layer_keys: LEGENDS_CORPUS.recommended_layer_keys[os] })})`
			);
			for (const [code, legend] of Object.entries(vector.expected)) {
				if (!page.key(code)) continue;
				check(
					page.legend(code) === legend,
					`(layer-editor-current-layout-legends) ${vector.name} on ${os}: ${code} shows "${page.legend(code)}", not "${legend}"`
				);
			}
			for (const code of vector.unresolved) {
				if (!page.key(code)) continue;
				check(
					page.legend(code) === code,
					`(layer-editor-current-layout-legends) ${vector.name} on ${os}: unresolved ${code} shows "${page.legend(code)}"`
				);
			}
			check(
				page.legend('Space') === EN['layer_editor.key.space'] &&
					page.legend('Enter') === EN['layer_editor.key.enter'] &&
					page.legend('ArrowUp') === '↑',
				`(layer-editor-current-layout-legends) a named key keeps its translated name on ${os}`
			);
			check(
				page.legend('MetaLeft') === { windows: 'Win', macos: '⌘', linux: 'Super' }[os],
				`(layer-editor-current-layout-legends) the meta key reads ${page.legend('MetaLeft')} on ${os}`
			);
			const note = (page.el('legend-source') || { textContent: '' }).textContent;
			check(
				note.startsWith(EN['layer_editor.legends.' + vector.source]) &&
					note.includes(EN['layer_editor.legends.missing']) === vector.unresolved.length > 0,
				`(layer-editor-current-layout-legends) the header must say which layout the keys follow on ${os}, not "${note}"`
			);
		}
	}
});

section('layer-editor-current-layout-legends: shortcut and refresh', () => {
	// A shortcut presses a physical key: it reads as what that key types.
	const page = loadPage();
	const azerty = LEGENDS_CORPUS.cases[0].expected;
	page.call(
		`init(${JSON.stringify({ os: 'windows', path: 'C:/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [], legends: { source: 'os', keys: azerty } })})`
	);
	page.key('KeyY').click();
	page.el('mod-primary').checked = true;
	page.el('mod-shift').checked = true;
	page.el('keystroke-key').value = 'KeyZ';
	page.el('keystroke-apply').click();
	const chord = `${EN['layer_editor.key.ctrl']}+${EN['layer_editor.key.shift']}+${azerty.KeyZ}`;
	check(
		page.binding('KeyY') === EN['layer_editor.caption.keystroke'].replace('{1}', chord),
		`(layer-editor-current-layout-legends) a shortcut on KeyZ reads "${page.binding('KeyY')}" on AZERTY, not with "${azerty.KeyZ}"`
	);
	check(
		page.key('KeyY').title === EN['layer_editor.value.keystroke'].replace('{1}', chord),
		'(layer-editor-current-layout-legends) the tooltip names the shortcut with the current legend'
	);

	// Back in front: the page asks its host again, and the answer keeps the edits.
	const before = page.posts.length;
	page.fireWindow('focus');
	check(
		page.posts.length === before + 1 && page.posts[before].action === 'legends',
		'(layer-editor-current-layout-legends) the page must ask for the legends again when its window comes back'
	);
	const ergo = { KeyZ: 'é', KeyQ: 'è' };
	page.call(`setLegends(${JSON.stringify({ source: 'emulation', keys: ergo })})`);
	check(
		page.legend('KeyQ') === 'è' && page.legend('KeyW') === 'KeyW',
		'(layer-editor-current-layout-legends) setLegends() redraws every legend'
	);
	check(
		page.binding('KeyY').endsWith('+é'),
		`(layer-editor-current-layout-legends) the edited shortcut must survive setLegends(), got "${page.binding('KeyY')}"`
	);
	check(
		page.el('status').textContent === EN['layer_editor.unsaved'],
		'(layer-editor-current-layout-legends) new legends keep the unsaved edits'
	);
});

// ========================================
// ========================================
// ======= 7/ Keycaps =====================
// ========================================
// ========================================

section('keycaps', () => {
	const page = loadPage();
	page.call(
		`init(${JSON.stringify({ os: 'linux', path: '/cfg/layers.toml', text: RECOMMENDED_TEXT, errors: [], legends: { source: 'os', keys: LEGENDS_CORPUS.cases[0].expected }, layer_keys: ['AltLeft'] })})`
	);
	const effective = page.call(`LayerModel.effective(state.doc, DATA.layer, 'linux')`);
	let bound = 0;
	for (const k of DATA.keys) {
		const node = page.key(k.code);
		if (!node || k.code === 'AltLeft') continue;
		const entry = effective[k.code];
		if (entry === undefined) {
			check(
				page.binding(k.code) === '' && !node.classList.contains('bound'),
				`(keycaps) unbound ${k.code} must stay quiet, shows "${page.binding(k.code)}"`
			);
			continue;
		}
		bound += 1;
		const caption = page.call(`LayerModel.bindingCaption(${JSON.stringify(entry.value)}, view())`);
		const shown = page.binding(k.code);
		check(
			shown !== '' &&
				shown === (caption.icon && caption.text ? caption.icon + ' ' : caption.icon) + caption.text,
			`(keycaps) bound ${k.code} shows "${shown}"`
		);
		check(node.classList.contains('bound'), `(keycaps) bound ${k.code} is not drawn as bound`);
		const parsed = page.call(`LayerModel.parseBinding(${JSON.stringify(entry.value)}, DATA)`);
		if (parsed.type === 'action') {
			const label = EN[DATA.actions[parsed.id].label_key];
			check(
				shown === label,
				`(keycaps) ${k.code} must show its action's catalogue label "${label}", not "${shown}"`
			);
		}
	}
	check(bound >= 30, `(keycaps) only ${bound} bound keys compared on Linux`);
	check(
		page.key('AltLeft').classList.contains('layer-key') &&
			page.binding('AltLeft') === EN['layer_editor.layer_key'] &&
			page.key('AltLeft').title.includes(EN['layer_editor.layer_key_hint']),
		'(keycaps) the key whose hold enters the layer must be marked'
	);
	check(
		!page.key('AltRight').classList.contains('layer-key'),
		'(keycaps) only the layer key is marked'
	);
	check(
		page.binding('KeyT') === EN['layer_editor.caption.keystroke'].replace('{1}', 'F2'),
		`(keycaps) a shortcut shows its short form, not "${page.binding('KeyT')}"`
	);

	// The keypad: hidden, shown on request, and kept shown by a bound key.
	check(!page.key('Numpad7'), '(keycaps) the keypad is hidden by default');
	page.el('numpad').checked = true;
	page.el('numpad').dispatch('change');
	check(!!page.key('Numpad7'), '(keycaps) the keypad shows when asked');
	check(page.legend('Numpad7') === '7', '(keycaps) a keypad digit reads as itself');
	page.key('Numpad7').click();
	page.row(EN['sg_actions.arrow_up']).click();
	page.el('numpad').checked = false;
	page.el('numpad').dispatch('change');
	check(
		!!page.key('Numpad7') && page.el('numpad').disabled === true,
		'(keycaps) a bound keypad key keeps the keypad shown'
	);
	check(
		page.binding('Numpad7') === EN['sg_actions.arrow_up'],
		`(keycaps) the bound keypad key shows "${page.binding('Numpad7')}"`
	);
});

if (checks < 400) fail(`only ${checks} checks ran (floor 400)`);
if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the layer editor page breaks the host protocol:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] layer editor page: ${checks} checks — render, pick, save payload, presets and host replies.\x1b[0m`
);
