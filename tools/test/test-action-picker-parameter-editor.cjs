// tools/test/test-action-picker-parameter-editor.cjs

/**
 * ==============================================================================
 * MODULE: Action Picker Parameter Editor (behavioural)
 * DESCRIPTION:
 * Runs the shared picker page (_shared/ui/action_picker/script.js) against a
 * minimal DOM and checks its editor for the send_text, send_key and
 * send_shortcut parameters: a text field, a key capture and a shortcut capture,
 * each validated with the rules the drivers apply, before the page confirms
 * the action together with its value.
 *
 * ROOT CAUSE ENCODED:
 * The picker only chose an action; every parameter was asked afterwards in a
 * native text prompt, so a key or a shortcut had to be spelled by hand ("ctrl+a",
 * "page_down") instead of pressed, and a typo was refused only after the picker
 * had closed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SCRIPT = path.join(SP, '_shared', 'ui', 'action_picker', 'script.js');
const HTML = path.join(SP, '_shared', 'ui', 'action_picker', 'index.html');
const CORPUS = path.join(SP, '_shared', 'tests', 'corpus', 'action_parameters', 'send_input_vectors.json');
const VOCABULARY = path.join(SP, '_shared', 'modules', 'actions', 'send_keys.json');

/** A DOM element with just what the page script touches. */
class FakeElement {
	constructor(tag, id) {
		this.tagName = tag;
		this.id = id || '';
		this.children = [];
		this.listeners = {};
		this.attributes = {};
		this.dataset = {};
		this.style = {};
		this.hidden = false;
		this.textContent = '';
		this.value = '';
		this.placeholder = '';
		this.title = '';
		this._classes = new Set();
		const self = this;
		this.classList = {
			add: (c) => self._classes.add(c),
			remove: (c) => self._classes.delete(c),
			contains: (c) => self._classes.has(c)
		};
	}
	set className(v) {
		this._classes = new Set(String(v).split(/\s+/).filter(Boolean));
	}
	get className() {
		return [...this._classes].join(' ');
	}
	set innerHTML(v) {
		if (v === '') this.children = [];
	}
	appendChild(child) {
		this.children.push(child);
		return child;
	}
	addEventListener(type, fn) {
		(this.listeners[type] = this.listeners[type] || []).push(fn);
	}
	setAttribute(name, value) {
		this.attributes[name] = String(value);
	}
	scrollIntoView() {}
	focus() {}
	select() {
		this.selectionStart = 0;
		this.selectionEnd = this.value.length;
	}
	/** Simulates typing: the value, with the caret after it. */
	type(value) {
		this.value = value;
		this.selectionStart = value.length;
		this.selectionEnd = value.length;
	}
	dispatch(type, event) {
		for (const fn of this.listeners[type] || []) fn(event || { preventDefault() {} });
	}
}

const errors = [];
const check = (cond, message) => {
	if (!cond) errors.push(message);
};

// Every element the page reaches by id must exist in index.html, or the editor
// works here and throws in a real webview.
const html = fs.readFileSync(HTML, 'utf8');
const IDS = ['title', 'subtitle', 'search', 'search-bar', 'btn-cancel', 'list', 'empty', 'count', 'toc', 'toc-inner',
	'param', 'param-title', 'param-prompt', 'param-hint', 'param-input', 'param-error', 'param-back', 'param-save'];
for (const id of IDS) check(html.includes(`id="${id}"`), `index.html must declare #${id}`);

function loadPage(platform) {
	const byId = {};
	for (const id of IDS) byId[id] = new FakeElement('div', id);
	const docListeners = {};
	const posted = [];
	const context = {
		document: {
			getElementById: (id) => byId[id] || null,
			createElement: (tag) => new FakeElement(tag),
			addEventListener: (type, fn) => {
				(docListeners[type] = docListeners[type] || []).push(fn);
			}
		},
		setTimeout: () => 0,
		makeHostBridge: () => (msg) => posted.push(msg),
		console
	};
	vm.createContext(context);
	vm.runInContext(fs.readFileSync(SCRIPT, 'utf8'), context, { filename: SCRIPT });
	for (const fn of docListeners.DOMContentLoaded || []) fn();
	posted.length = 0;
	context.__vocabulary = JSON.parse(fs.readFileSync(VOCABULARY, 'utf8'));
	context.__platform = platform;
	vm.runInContext(
		`init({
			title: 'T', current: 'none', noneLabel: 'Nothing', platform: __platform,
			sendVocabulary: __vocabulary,
			parameterStrings: {
				save: 'Save', back: 'Back', captureKey: 'Press a key', captureShortcut: 'Press a shortcut',
				prompts: { text: 'Text?', key: 'Key?', shortcut: 'Shortcut?' },
				errors: { text: 'Bad text', key: 'Bad key', shortcut: 'Bad shortcut' }
			},
			items: [
				{ type: 'action', id: 'send_text', label: 'Type a text', parameter: 'text', parameterValue: 'salut' },
				{ type: 'action', id: 'send_key', label: 'Press a key', parameter: 'key' },
				{ type: 'action', id: 'send_shortcut', label: 'Press a shortcut', parameter: 'shortcut' },
				{ type: 'action', id: 'open_url', label: 'Open a link', parameter: 'url' },
				{ type: 'action', id: 'enter', label: 'Enter' }
			]
		})`,
		context
	);
	const keydown = (event) => {
		const e = Object.assign({ preventDefault() { e.prevented = true; }, prevented: false }, event);
		for (const fn of docListeners.keydown || []) fn(e);
		return e;
	};
	return { byId, posted, context, keydown };
}

// 1. The page's rules are the drivers' rules: the shared corpus replayed.
{
	const page = loadPage('ahk');
	const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
	let replayed = 0;
	for (const vector of corpus.vectors) {
		page.context.__value = vector.value.repeat(vector.repeat || 1);
		page.context.__kind = vector.kind;
		const parsed = vm.runInContext('parseParameter(__kind, __value)', page.context);
		if (vector.valid === false) {
			check(parsed === null, `${vector.id}: the page accepts it as ${JSON.stringify(parsed)}`);
		} else {
			const canonical = vector.canonical.repeat(vector.canonical_repeat || 1);
			check(parsed === canonical, `${vector.id}: the page reads ${JSON.stringify(parsed)}, not ${canonical}`);
		}
		replayed += 1;
	}
	check(replayed >= 40, `only ${replayed} vector(s) replayed`);

	// A Lua host's JSON encoder writes an empty alias list as {}: the page must
	// still find the entry by its id.
	const luaEncoded = JSON.parse(JSON.stringify(page.context.__vocabulary));
	for (const entry of luaEncoded.modifiers.concat(luaEncoded.keys)) {
		if (entry.aliases.length === 0) entry.aliases = {};
	}
	page.context.__luaVocabulary = luaEncoded;
	const parsed = vm.runInContext(
		"sendVocabulary = __luaVocabulary; parseParameter('shortcut', 'primary+a')", page.context);
	check(parsed === 'primary+a', `an empty alias list encoded as {} breaks the lookup: ${JSON.stringify(parsed)}`);
}

// 2. Picking a parameterized action opens the editor instead of confirming.
{
	const page = loadPage('ahk');
	vm.runInContext("doConfirm('send_text')", page.context);
	check(page.posted.length === 0, 'send_text must not confirm before its text is entered');
	check(page.byId.param.hidden === false && page.byId.list.hidden === true, 'the editor replaces the list');
	check(page.byId['param-input'].value === 'salut', 'the editor starts from the binding\'s current value');
	page.byId['param-input'].value = 'a\nb';
	page.byId['param-save'].dispatch('click');
	check(page.posted.length === 0 && page.byId['param-error'].hidden === false, 'an invalid text is refused in place');
	page.byId['param-input'].value = 'bonjour cela va bien?';
	page.byId['param-save'].dispatch('click');
	check(page.posted.length === 1 && page.posted[0].action === 'confirm' && page.posted[0].id === 'send_text'
		&& page.posted[0].parameter === 'bonjour cela va bien?', 'a valid text confirms the action with it');
}

// 3. The key capture turns a keystroke into its name; the shortcut capture into
//    modifiers + key, Control being "primary" off macOS and Command on it.
{
	const page = loadPage('ahk');
	vm.runInContext("doConfirm('send_key')", page.context);
	const e = page.keydown({ key: 'PageDown', code: 'PageDown' });
	check(e.prevented && page.byId['param-input'].value === 'page_down', 'PageDown is captured as page_down');
	page.keydown({ key: 'Escape', code: 'Escape' });
	check(page.byId['param-input'].value === 'escape' && page.posted.length === 0,
		'Escape is a key to capture here, not a cancel');
	page.byId['param-back'].dispatch('click');
	check(page.byId.param.hidden === true && page.byId.list.hidden === false, 'Back returns to the list');

	vm.runInContext("doConfirm('send_shortcut')", page.context);
	page.keydown({ key: 'Control', code: 'ControlLeft', ctrlKey: true });
	check(page.byId['param-input'].value === '', 'a lone modifier captures nothing yet');
	page.keydown({ key: 'a', code: 'KeyA', ctrlKey: true });
	check(page.byId['param-input'].value === 'primary+a', 'Ctrl+A is primary+a on Windows and Linux');
	page.keydown({ key: 'T', code: 'KeyT', ctrlKey: true, shiftKey: true });
	check(page.byId['param-input'].value === 'primary+shift+t', 'Ctrl+Shift+T captures the letter, not the capital');
	page.byId['param-save'].dispatch('click');
	check(page.posted.length === 1 && page.posted[0].parameter === 'primary+shift+t', 'the capture is what is saved');

	const mac = loadPage('hs');
	vm.runInContext("doConfirm('send_shortcut')", mac.context);
	mac.keydown({ key: 'a', code: 'KeyA', metaKey: true });
	check(mac.byId['param-input'].value === 'primary+a', 'Cmd+A is primary+a on macOS');
	mac.keydown({ key: 'a', code: 'KeyA', ctrlKey: true });
	check(mac.byId['param-input'].value === 'ctrl+a', 'Ctrl+A stays ctrl+a on macOS');
}

// 4. The captures still let a name be typed: a character types itself, the
//    editing keys edit a field that holds text, and Enter saves it; only an
//    empty (or wholly selected) field turns those keys into captures.
{
	const page = loadPage('ahk');
	const input = page.byId['param-input'];
	vm.runInContext("doConfirm('send_key')", page.context);
	check(!page.keydown({ key: 'f', code: 'KeyF' }).prevented, 'a character types into the key field');
	input.type('f13');
	check(!page.keydown({ key: 'Backspace', code: 'Backspace' }).prevented, 'Backspace edits a typed name');
	page.keydown({ key: 'Enter', code: 'Enter' });
	check(page.posted.length === 1 && page.posted[0].parameter === 'f13', 'Enter saves a typed key name');

	const empty = loadPage('ahk');
	vm.runInContext("doConfirm('send_key')", empty.context);
	empty.keydown({ key: 'Backspace', code: 'Backspace' });
	check(empty.byId['param-input'].value === 'backspace', 'an empty key field captures Backspace');
	check(!empty.keydown({ key: 'a', code: 'KeyA', ctrlKey: true }).prevented,
		'Ctrl+A selects the key field instead of being captured');

	const shortcut = loadPage('ahk');
	const field = shortcut.byId['param-input'];
	vm.runInContext("doConfirm('send_shortcut')", shortcut.context);
	check(!shortcut.keydown({ key: 'c', code: 'KeyC' }).prevented, 'a plain letter types into the shortcut field');
	field.type('ctrl');
	check(!shortcut.keydown({ key: '+', code: 'Equal', shiftKey: true }).prevented,
		'Shift+= types "+" after a modifier name');
	check(!shortcut.keydown({ key: '€', code: 'KeyE', ctrlKey: true, altKey: true,
		getModifierState: (name) => name === 'AltGraph' }).prevented, 'AltGr types its character');
	field.type('ctrl++');
	shortcut.keydown({ key: 'Enter', code: 'Enter' });
	check(shortcut.posted.length === 1 && shortcut.posted[0].parameter === 'ctrl++', 'Enter saves a typed shortcut');

	const fresh = loadPage('ahk');
	vm.runInContext("doConfirm('send_shortcut')", fresh.context);
	fresh.keydown({ key: 'A', code: 'KeyA', shiftKey: true });
	check(fresh.byId['param-input'].value === 'shift+a', 'an empty shortcut field captures Shift+A');
	fresh.keydown({ key: 'Escape', code: 'Escape' });
	check(fresh.byId.param.hidden === true && fresh.posted.length === 0, 'Escape returns from a shortcut to the list');
}

// 5. A kind the page does not edit, and an action without one, confirm directly:
//    the host keeps its own prompt for those.
{
	const page = loadPage('ahk');
	vm.runInContext("doConfirm('open_url')", page.context);
	check(page.posted.length === 1 && page.posted[0].id === 'open_url' && page.posted[0].parameter === undefined,
		'a URL is still asked by the host');
	vm.runInContext("doConfirm('enter')", page.context);
	check(page.posted.length === 2 && page.posted[1].id === 'enter', 'an ordinary action confirms at once');
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] action picker parameter editor:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] the picker edits a text, captures a key and a shortcut, and validates them as the drivers do.\x1b[0m');
